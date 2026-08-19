"""Verifying an OpenPGP detached signature over a release's checksum document.

Only the shape the four publishers actually emit is implemented: a single v4
signature packet, RSA, over a binary document. Anything else -- a v3 or v6
packet, a different algorithm, a key the caller did not vendor -- is refused by
name rather than skipped, so a publisher changing how it signs surfaces as a
failure to verify instead of as a silent pass.

The one subtlety worth stating is what a v4 signature actually covers, since it
is not the document. RFC 4880 section 5.2.4 has the signer hash the document,
then the signature packet's own header through the end of its hashed
subpackets, then a six-byte trailer restating how much of the packet that was.
Hashing the document alone yields a digest nothing will ever match, and it is
the mistake this file exists to get right once.
"""

load(":bytes.bzl", "bytes_to_int")
load(":rsa.bzl", "verify")
load(":sha2.bzl", "sha256", "sha512")

_SIGNATURE_TAG = 2

_RSA_ALGORITHM = 1

# OpenPGP hash algorithm ids, mapped to the implementations here. terraform
# signs with 8 and OpenTofu with 10; the rest are absent rather than
# unsupported, and adding one means implementing it.
_HASH_ALGORITHMS = {
    8: "sha256",
    10: "sha512",
}

_ISSUER_KEY_ID = 16

_ISSUER_FINGERPRINT = 33

# A detached signature is a few hundred bytes, so every scan over one is bounded
# by this rather than by a while loop Starlark does not have.
_MAX_PACKET_BYTES = 65536

_HEX = "0123456789ABCDEF"

def _to_hex(data):
    return "".join([_HEX[b // 16] + _HEX[b % 16] for b in data])

def _read_packet(data):
    """Reads the first packet's tag and body out of a message.

    Args:
      data: the message, as a byte list.

    Returns:
      A (tag, body) tuple.
    """
    if len(data) < 2:
        fail("signature is too short to hold a packet")

    ctb = data[0]
    if ctb < 0x80:
        fail("not an OpenPGP packet: first byte is 0x%02x" % ctb)

    if ctb & 0x40:
        # New format: the tag is five bits and the length is self-describing.
        tag = ctb & 0x3f
        first = data[1]
        if first < 192:
            length = first
            start = 2
        elif first < 224:
            length = ((first - 192) << 8) + data[2] + 192
            start = 3
        elif first == 255:
            length = bytes_to_int(data[2:6])
            start = 6
        else:
            fail("partial packet lengths are not supported in a signature")
    else:
        # Old format: the tag is four bits and two more say how wide the length
        # field is. HashiCorp's signatures are new format and OpenTofu's are
        # old, so both are reached in practice.
        tag = (ctb >> 2) & 0x0f
        length_type = ctb & 0x03
        if length_type == 0:
            length = data[1]
            start = 2
        elif length_type == 1:
            length = bytes_to_int(data[1:3])
            start = 3
        elif length_type == 2:
            length = bytes_to_int(data[1:5])
            start = 5
        else:
            fail("indeterminate packet lengths are not supported in a signature")

    if start + length > len(data):
        fail("packet claims %d bytes but only %d remain" % (length, len(data) - start))

    return tag, data[start:start + length]

def _subpackets(region):
    """Reads a subpacket region into a list of (type, body) tuples."""
    out = []
    offset = 0
    for _ in range(_MAX_PACKET_BYTES):
        if offset >= len(region):
            break

        first = region[offset]
        if first < 192:
            length = first
            offset += 1
        elif first < 255:
            length = ((first - 192) << 8) + region[offset + 1] + 192
            offset += 2
        else:
            length = bytes_to_int(region[offset + 1:offset + 5])
            offset += 5

        if length < 1:
            fail("subpacket claims no room for its type byte")
        if offset + length > len(region):
            fail("subpacket runs past the end of its region")

        out.append((region[offset], region[offset + 1:offset + length]))
        offset += length

    return out

def _read_mpi(data, offset):
    """Reads a multiprecision integer, returning it and the offset past it."""
    if offset + 2 > len(data):
        fail("signature ends where an MPI was expected")

    bits = bytes_to_int(data[offset:offset + 2])
    size = (bits + 7) // 8
    if offset + 2 + size > len(data):
        fail("MPI of %d bits runs past the end of the packet" % bits)

    return data[offset + 2:offset + 2 + size], offset + 2 + size

def parse_signature(data):
    """Reads a detached signature into the parts a check needs.

    Args:
      data: the signature file's bytes, as a list of ints.

    Returns:
      A struct with `hash_name`, `issuer` (an uppercase hex fingerprint or key
      id), `signature` (a byte list) and `trailer` (the bytes hashed after the
      signed document).
    """
    tag, body = _read_packet(data)
    if tag != _SIGNATURE_TAG:
        fail("expected a signature packet, got packet tag %d" % tag)

    if len(body) < 6:
        fail("signature packet is too short")

    version = body[0]
    if version != 4:
        fail("only v4 signatures are supported, got v%d" % version)

    algorithm = body[2]
    if algorithm != _RSA_ALGORITHM:
        fail("only RSA signatures are supported, got public key algorithm %d" % algorithm)

    hash_name = _HASH_ALGORITHMS.get(body[3])
    if hash_name == None:
        fail("unsupported OpenPGP hash algorithm %d" % body[3])

    hashed_length = bytes_to_int(body[4:6])
    hashed_end = 6 + hashed_length
    if hashed_end > len(body):
        fail("hashed subpackets run past the end of the signature packet")

    # What the signer hashed after the document: the packet up to here, then a
    # trailer restating that length. RFC 4880 section 5.2.4.
    trailer = body[0:hashed_end] + [0x04, 0xff] + [
        (hashed_end >> 24) & 0xff,
        (hashed_end >> 16) & 0xff,
        (hashed_end >> 8) & 0xff,
        hashed_end & 0xff,
    ]

    unhashed_length = bytes_to_int(body[hashed_end:hashed_end + 2])
    unhashed_end = hashed_end + 2 + unhashed_length
    if unhashed_end > len(body):
        fail("unhashed subpackets run past the end of the signature packet")

    issuer = None
    key_id = None
    for kind, value in _subpackets(body[6:hashed_end]) + _subpackets(body[hashed_end + 2:unhashed_end]):
        if kind == _ISSUER_FINGERPRINT and len(value) == 21:
            issuer = _to_hex(value[1:])
        elif kind == _ISSUER_KEY_ID and len(value) == 8:
            key_id = _to_hex(value)

    # The fingerprint is preferred because it names the key outright; a key id
    # is its low eight bytes and is all an older signature carries.
    if issuer == None:
        issuer = key_id
    if issuer == None:
        fail("signature names no issuing key")

    # Two bytes of the digest, then the signature MPI.
    signature, _ = _read_mpi(body, unhashed_end + 2)

    return struct(
        hash_name = hash_name,
        issuer = issuer,
        signature = signature,
        trailer = trailer,
    )

def digest_of(data, trailer, hash_name):
    """Hashes a signed document together with its signature's trailer.

    Args:
      data: the document's bytes, as a list of ints.
      trailer: the trailing bytes from `parse_signature`.
      hash_name: which hash to use, "sha256" or "sha512".

    Returns:
      The digest, as a byte list.
    """
    if hash_name == "sha256":
        return sha256(data + trailer)
    if hash_name == "sha512":
        return sha512(data + trailer)
    fail("unsupported hash %s" % hash_name)

def verify_detached(signature_data, document, keys):
    """Checks a detached signature over a document against vendored keys.

    Args:
      signature_data: the signature file's bytes, as a list of ints.
      document: the signed document's bytes, as a list of ints.
      keys: fingerprint (uppercase hex) to struct(modulus, exponent), holding
        the publisher keys this ruleset trusts.

    Returns:
      A (verified, issuer, error) tuple. `verified` is True only when the
      signature is one of `keys` over exactly this document.
    """
    parsed = parse_signature(signature_data)

    key = keys.get(parsed.issuer)
    if key == None:
        # A key id rather than a fingerprint identifies the key by its low eight
        # bytes, which is all an older signature carries.
        for fingerprint, candidate in keys.items():
            if fingerprint.endswith(parsed.issuer):
                key = candidate
                break

    if key == None:
        return False, parsed.issuer, "signed by key %s, which is not one of the vendored publisher keys" % parsed.issuer

    digest = digest_of(document, parsed.trailer, parsed.hash_name)

    if not verify(parsed.signature, digest, parsed.hash_name, key.modulus, key.exponent):
        return False, parsed.issuer, "signature by key %s does not match the document" % parsed.issuer

    return True, parsed.issuer, None
