"""SHA-256 and SHA-512, because a signature is a statement about a digest.

Bazel exposes no hash function to Starlark. `module_ctx.download` reports the
sha256 of what it fetched, but an OpenPGP signature covers the document plus a
trailer the signature packet itself carries, so the digest has to be computed
here rather than read off a download.

Both are needed and neither is optional: terraform signs with SHA-256 (OpenPGP
hash algorithm 8) and OpenTofu with SHA-512 (algorithm 10), consistently across
every release version checked.

Implemented against FIPS 180-4. The round constants are the fractional parts of
the cube roots of the first primes and the initial state the square roots, both
generated rather than transcribed; `sha2_test.bzl` checks the result against
published test vectors, which is what actually establishes they are right.
"""

_MASK32 = 0xffffffff

_MASK64 = 0xffffffffffffffff

_K256 = [
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
]

_H256 = [
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
]

_K512 = [
    0x428a2f98d728ae22,
    0x7137449123ef65cd,
    0xb5c0fbcfec4d3b2f,
    0xe9b5dba58189dbbc,
    0x3956c25bf348b538,
    0x59f111f1b605d019,
    0x923f82a4af194f9b,
    0xab1c5ed5da6d8118,
    0xd807aa98a3030242,
    0x12835b0145706fbe,
    0x243185be4ee4b28c,
    0x550c7dc3d5ffb4e2,
    0x72be5d74f27b896f,
    0x80deb1fe3b1696b1,
    0x9bdc06a725c71235,
    0xc19bf174cf692694,
    0xe49b69c19ef14ad2,
    0xefbe4786384f25e3,
    0x0fc19dc68b8cd5b5,
    0x240ca1cc77ac9c65,
    0x2de92c6f592b0275,
    0x4a7484aa6ea6e483,
    0x5cb0a9dcbd41fbd4,
    0x76f988da831153b5,
    0x983e5152ee66dfab,
    0xa831c66d2db43210,
    0xb00327c898fb213f,
    0xbf597fc7beef0ee4,
    0xc6e00bf33da88fc2,
    0xd5a79147930aa725,
    0x06ca6351e003826f,
    0x142929670a0e6e70,
    0x27b70a8546d22ffc,
    0x2e1b21385c26c926,
    0x4d2c6dfc5ac42aed,
    0x53380d139d95b3df,
    0x650a73548baf63de,
    0x766a0abb3c77b2a8,
    0x81c2c92e47edaee6,
    0x92722c851482353b,
    0xa2bfe8a14cf10364,
    0xa81a664bbc423001,
    0xc24b8b70d0f89791,
    0xc76c51a30654be30,
    0xd192e819d6ef5218,
    0xd69906245565a910,
    0xf40e35855771202a,
    0x106aa07032bbd1b8,
    0x19a4c116b8d2d0c8,
    0x1e376c085141ab53,
    0x2748774cdf8eeb99,
    0x34b0bcb5e19b48a8,
    0x391c0cb3c5c95a63,
    0x4ed8aa4ae3418acb,
    0x5b9cca4f7763e373,
    0x682e6ff3d6b2b8a3,
    0x748f82ee5defb2fc,
    0x78a5636f43172f60,
    0x84c87814a1f0ab72,
    0x8cc702081a6439ec,
    0x90befffa23631e28,
    0xa4506cebde82bde9,
    0xbef9a3f7b2c67915,
    0xc67178f2e372532b,
    0xca273eceea26619c,
    0xd186b8c721c0c207,
    0xeada7dd6cde0eb1e,
    0xf57d4f7fee6ed178,
    0x06f067aa72176fba,
    0x0a637dc5a2c898a6,
    0x113f9804bef90dae,
    0x1b710b35131c471b,
    0x28db77f523047d84,
    0x32caab7b40c72493,
    0x3c9ebe0a15c9bebc,
    0x431d67c49c100d4c,
    0x4cc5d4becb3e42b6,
    0x597f299cfc657e2a,
    0x5fcb6fab3ad6faec,
    0x6c44198c4a475817,
]

_H512 = [
    0x6a09e667f3bcc908,
    0xbb67ae8584caa73b,
    0x3c6ef372fe94f82b,
    0xa54ff53a5f1d36f1,
    0x510e527fade682d1,
    0x9b05688c2b3e6c1f,
    0x1f83d9abfb41bd6b,
    0x5be0cd19137e2179,
]

def _rotr(value, bits, width, mask):
    return ((value >> bits) | (value << (width - bits))) & mask

def _pad(data, block_bytes, length_bytes):
    """Appends the 0x80 byte, the zero fill, and the big-endian bit length."""
    bit_length = len(data) * 8

    # Zeroes up to the point where the length field ends the final block.
    # Computed rather than appended one at a time: Starlark has no while loop,
    # which is the constraint most of this file is written around.
    filled = len(data) + 1
    room = block_bytes - length_bytes
    zeros = (room - filled % block_bytes + block_bytes) % block_bytes

    padded = data + [0x80] + [0] * zeros
    for i in range(length_bytes - 1, -1, -1):
        padded.append((bit_length >> (8 * i)) & 0xff)
    return padded

def _words(block, word_bytes):
    out = []
    for i in range(0, len(block), word_bytes):
        value = 0
        for j in range(word_bytes):
            value = (value << 8) | block[i + j]
        out.append(value)
    return out

def _digest_bytes(state, word_bytes):
    out = []
    for word in state:
        for i in range(word_bytes - 1, -1, -1):
            out.append((word >> (8 * i)) & 0xff)
    return out

def sha256(data):
    """Computes the SHA-256 digest of a byte list.

    Args:
      data: the message, as a list of ints from 0 to 255.

    Returns:
      The 32-byte digest, as a list of ints.
    """
    state = list(_H256)
    padded = _pad(data, 64, 8)

    for start in range(0, len(padded), 64):
        w = _words(padded[start:start + 64], 4)
        for i in range(16, 64):
            s0 = _rotr(w[i - 15], 7, 32, _MASK32) ^ _rotr(w[i - 15], 18, 32, _MASK32) ^ (w[i - 15] >> 3)
            s1 = _rotr(w[i - 2], 17, 32, _MASK32) ^ _rotr(w[i - 2], 19, 32, _MASK32) ^ (w[i - 2] >> 10)
            w.append((w[i - 16] + s0 + w[i - 7] + s1) & _MASK32)

        a, b, c, d, e, f, g, h = state

        for i in range(64):
            S1 = _rotr(e, 6, 32, _MASK32) ^ _rotr(e, 11, 32, _MASK32) ^ _rotr(e, 25, 32, _MASK32)
            ch = (e & f) ^ ((~e & _MASK32) & g)
            temp1 = (h + S1 + ch + _K256[i] + w[i]) & _MASK32
            S0 = _rotr(a, 2, 32, _MASK32) ^ _rotr(a, 13, 32, _MASK32) ^ _rotr(a, 22, 32, _MASK32)
            maj = (a & b) ^ (a & c) ^ (b & c)
            temp2 = (S0 + maj) & _MASK32

            h, g, f, e = g, f, e, (d + temp1) & _MASK32
            d, c, b, a = c, b, a, (temp1 + temp2) & _MASK32

        for i, value in enumerate([a, b, c, d, e, f, g, h]):
            state[i] = (state[i] + value) & _MASK32

    return _digest_bytes(state, 4)

def sha512(data):
    """Computes the SHA-512 digest of a byte list.

    Args:
      data: the message, as a list of ints from 0 to 255.

    Returns:
      The 64-byte digest, as a list of ints.
    """
    state = list(_H512)
    padded = _pad(data, 128, 16)

    for start in range(0, len(padded), 128):
        w = _words(padded[start:start + 128], 8)
        for i in range(16, 80):
            s0 = _rotr(w[i - 15], 1, 64, _MASK64) ^ _rotr(w[i - 15], 8, 64, _MASK64) ^ (w[i - 15] >> 7)
            s1 = _rotr(w[i - 2], 19, 64, _MASK64) ^ _rotr(w[i - 2], 61, 64, _MASK64) ^ (w[i - 2] >> 6)
            w.append((w[i - 16] + s0 + w[i - 7] + s1) & _MASK64)

        a, b, c, d, e, f, g, h = state

        for i in range(80):
            S1 = _rotr(e, 14, 64, _MASK64) ^ _rotr(e, 18, 64, _MASK64) ^ _rotr(e, 41, 64, _MASK64)
            ch = (e & f) ^ ((~e & _MASK64) & g)
            temp1 = (h + S1 + ch + _K512[i] + w[i]) & _MASK64
            S0 = _rotr(a, 28, 64, _MASK64) ^ _rotr(a, 34, 64, _MASK64) ^ _rotr(a, 39, 64, _MASK64)
            maj = (a & b) ^ (a & c) ^ (b & c)
            temp2 = (S0 + maj) & _MASK64

            h, g, f, e = g, f, e, (d + temp1) & _MASK64
            d, c, b, a = c, b, a, (temp1 + temp2) & _MASK64

        for i, value in enumerate([a, b, c, d, e, f, g, h]):
            state[i] = (state[i] + value) & _MASK64

    return _digest_bytes(state, 8)
