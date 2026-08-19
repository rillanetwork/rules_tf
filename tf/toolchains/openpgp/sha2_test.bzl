"""Unit tests for the SHA-2 implementations.

These are the published FIPS 180-4 test vectors. A hand-written hash that is
subtly wrong still produces a plausible-looking digest, and every layer above
this one would then reject good signatures with no hint as to why, so the
vectors are what establishes the implementation rather than the derivation of
the constants does.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":bytes.bzl", "hex_to_bytes")
load(":sha2.bzl", "sha256", "sha512")

def _ascii_bytes(text):
    """The message vectors are ASCII, so hex is a needless indirection here."""
    table = {}
    for i, c in enumerate("abcdefghijklmnopqrstuvwxyz".elems()):
        table[c] = 0x61 + i
    return [table[c] for c in text.elems()]

_ABC = "abc"

_SHA256_448 = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"

_SHA512_896 = ("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn" +
               "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu")

def _to_hex(data):
    digits = "0123456789abcdef"
    return "".join([digits[b // 16] + digits[b % 16] for b in data])

def _sha256_vectors_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        _to_hex(sha256([])),
    )
    asserts.equals(
        env,
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        _to_hex(sha256(_ascii_bytes(_ABC))),
    )

    # 448 bits, the vector that exercises a message needing a second block for
    # its padding alone.
    asserts.equals(
        env,
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
        _to_hex(sha256(_ascii_bytes(_SHA256_448))),
    )

    return unittest.end(env)

def _sha512_vectors_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce" +
        "47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e",
        _to_hex(sha512([])),
    )
    asserts.equals(
        env,
        "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a" +
        "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
        _to_hex(sha512(_ascii_bytes(_ABC))),
    )
    asserts.equals(
        env,
        "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018" +
        "501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909",
        _to_hex(sha512(_ascii_bytes(_SHA512_896))),
    )

    return unittest.end(env)

def _byte_range_test_impl(ctx):
    env = unittest.begin(ctx)

    # Every byte value 0-255, which catches a digest that only ever sees
    # printable input -- the signatures this exists for are binary.
    all_bytes = [b for b in range(256)]
    asserts.equals(
        env,
        "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880",
        _to_hex(sha256(all_bytes)),
    )
    asserts.equals(
        env,
        hex_to_bytes("40aff2e9d2d8922e47afd4648e6967497158785fbd1da870" +
                     "e7110266bf944880"),
        sha256(all_bytes),
    )

    return unittest.end(env)

_sha256_vectors_test = unittest.make(_sha256_vectors_test_impl)
_sha512_vectors_test = unittest.make(_sha512_vectors_test_impl)
_byte_range_test = unittest.make(_byte_range_test_impl)

def sha2_test_suite():
    """Declares the SHA-2 tests."""
    unittest.suite(
        "sha2_tests",
        _sha256_vectors_test,
        _sha512_vectors_test,
        _byte_range_test,
    )
