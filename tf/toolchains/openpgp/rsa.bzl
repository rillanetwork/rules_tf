"""RSA signature verification, by recomputing the encoded block and comparing.

Verifying `s^e mod n` against a PKCS#1 v1.5 block can be done two ways: parse
the recovered block and pull the digest out of it, or build the block the signer
should have produced and compare the whole thing. This does the latter. The
parsing form is where the classic forgery bugs live -- a lenient parser that
skips padding or ignores trailing bytes accepts signatures no one signed, which
is the Bleichenbacher'06 family -- and none of them are reachable when the check
is one equality over the full block.

Starlark integers are arbitrary precision, so the modular exponentiation is
ordinary arithmetic. With e = 65537 it is seventeen big multiplications, which
costs nothing next to the download it protects.
"""

load(":bytes.bzl", "bytes_to_int", "hex_to_bytes")

# The ASN.1 DigestInfo each hash's block carries ahead of the digest, fixed by
# RFC 8017 and quoted from it. The trailing byte is the digest length, so a
# prefix paired with the wrong hash cannot accidentally agree.
DIGEST_INFO = {
    "sha256": hex_to_bytes("3031300d060960864801650304020105000420"),
    "sha512": hex_to_bytes("3051300d060960864801650304020305000440"),
}

# An exponent is part of a vendored key rather than anything a signature
# carries, so this bound is a sanity check on our own constants.
_MAX_EXPONENT_BITS = 64

def _exponent_bits(exponent):
    """The exponent's bits, least significant first."""
    if exponent < 1:
        fail("exponent must be positive, got %d" % exponent)

    bits = []
    remaining = exponent
    for _ in range(_MAX_EXPONENT_BITS):
        if remaining == 0:
            break
        bits.append(remaining % 2)
        remaining = remaining // 2

    if remaining != 0:
        fail("exponent wider than %d bits" % _MAX_EXPONENT_BITS)
    return bits

def modexp(base, exponent, modulus):
    """Computes `base ** exponent % modulus` by square and multiply.

    Args:
      base: the base, a non-negative int.
      exponent: the exponent, a positive int.
      modulus: the modulus, an int greater than 1.

    Returns:
      The result as an int.
    """
    if modulus <= 1:
        fail("modulus must be greater than 1")

    bits = _exponent_bits(exponent)

    result = 1
    power = base % modulus

    # Least significant bit first, squaring the running power each step, which
    # keeps the loop bounded by the exponent's width.
    for bit in bits:
        if bit == 1:
            result = (result * power) % modulus
        power = (power * power) % modulus

    return result

def pkcs1_v15_block(digest, digest_name, size):
    """Builds the EMSA-PKCS1-v1_5 encoded block for a digest.

    Args:
      digest: the hash, as a byte list.
      digest_name: which hash produced it, keying `DIGEST_INFO`.
      size: the modulus width in bytes, which the block fills exactly.

    Returns:
      The block, as a byte list of length `size`.
    """
    info = DIGEST_INFO.get(digest_name)
    if info == None:
        fail("no DigestInfo for hash %s" % digest_name)

    tail = info + digest

    # At least eight 0xff bytes of padding are required; anything less means the
    # modulus is too small for the hash, not that the signature is bad.
    padding = size - len(tail) - 3
    if padding < 8:
        fail("modulus of %d bytes is too small for a %s signature" % (size, digest_name))

    return [0x00, 0x01] + [0xff] * padding + [0x00] + tail

def verify(signature, digest, digest_name, modulus, exponent):
    """Checks an RSA signature over a digest.

    Args:
      signature: the signature value, as a byte list.
      digest: the hash of the signed data, as a byte list.
      digest_name: which hash produced it, keying `DIGEST_INFO`.
      modulus: the key's modulus, as an int.
      exponent: the key's public exponent, as an int.

    Returns:
      True when the signature is the key's, False otherwise.
    """
    size = 0
    remaining = modulus
    for _ in range(1024):
        if remaining == 0:
            break
        size += 1
        remaining = remaining // 256
    if remaining != 0:
        fail("modulus is implausibly large")

    value = bytes_to_int(signature)
    if value >= modulus:
        return False

    recovered = modexp(value, exponent, modulus)
    expected = bytes_to_int(pkcs1_v15_block(digest, digest_name, size))

    return recovered == expected
