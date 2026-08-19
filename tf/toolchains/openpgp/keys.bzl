"""The publisher keys this ruleset will accept a release signature from.

A signature check is only worth what its trust root is, and the root here is
these two moduli. They are vendored as numbers rather than as keyrings on
purpose: parsing an armored key, its packet grammar and its subkey binding
signatures would be several hundred more lines of Starlark, all of it capable of
selecting the wrong key, and none of it needed to answer the one question asked
here. What a key can do and when it expires are decided by whoever puts a
fingerprint in this file, not at build time.

Each entry was extracted from the publisher's published key and is recorded with
the fingerprint it hashes to, so it can be re-derived. To check one, fetch the
key, dearmor it, and confirm gpg reports the fingerprint below:

    curl -s https://www.hashicorp.com/.well-known/pgp-key.txt |
        gpg --show-keys --with-subkey-fingerprint

Adding a publisher means adding its modulus here. Nothing discovers a key at
build time, which is the point: a release signed by a key not in this file fails
to verify rather than teaching the build a new key.
"""

load(":bytes.bzl", "bytes_to_int", "hex_to_bytes")

def _rsa_key(modulus_hex, exponent):
    return struct(
        modulus = bytes_to_int(hex_to_bytes(modulus_hex)),
        exponent = exponent,
    )

# HashiCorp's release signing subkey, under the primary key
# C874011F0AB405110D02105534365D9472D7468F published at
# https://www.hashicorp.com/.well-known/pgp-key.txt. Every terraform
# SHA256SUMS signature checked, from 0.12.31 to 1.13.3, was made by this
# subkey rather than by the primary, and the `.72D7468F.sig` file alongside
# the plain `.sig` is the same signature under the primary key's id.
HASHICORP_SIGNING_KEY = _rsa_key(
    # 374EC75B485913604A831CC7C820C6D5CD27AB87
    "d6e9136b65518d5ef1d506a4a23966b19755ce884a221cfb79d008a3b76e725d" +
    "b1bed241c8152a11fb583a2e1db42530828607d09061a3cd0bc4b86d474f0d3b" +
    "621b2f2dcd2992334c7eeea026a168c7fa20739de6cfaf4ec576aecd443f4d9d" +
    "bb183569501bbe1210cab75b373ad03a063cff72ca29fd49bb813d3e8af1f2bc" +
    "9fe319d9cf119bfcb4db9213f528fa19ff43d860f126ef799ce8dc2f94e0a71a" +
    "6c211210597c1aae9a462f6f01f6bae68c43e6329a233edccbea706f4962cea9" +
    "56ec7f6d425af77417dd21c773811e79853142e7f5eb73027afe71d51ffc46b2" +
    "411ab277c2417f1160a32ecb45000c9cbbd939196d8682c7e5d721c541f064ce" +
    "989568021ad349254b019b297c29e3c274b18ac0e7dd9cec62bab7715eac53c6" +
    "fe425217ed5023bab13ee5c6625656b18028f284aaa51a09a89e745e58e05a70" +
    "280bfd4beec0c98ca794d32e688b5cb4fbbb1786a23132a02938b0caeaad4d63" +
    "7af1f21a50c91fd4dabb1d791882c3c276057c0bcf17d58289de146783aec237" +
    "1ac5fcacdcbc4d89922552c5cd2b04b79a188c44be1346c6ece24e1013e2c830" +
    "eb1ab88bdcbe6f3f7ebc9dbd0fe45302215531fcd1718e1fdd3d6d8b49bd8ddf" +
    "b9d2bb4a12309bb6454ddb812541b8ef713f167dd59214e6057ebe3e3382e741" +
    "d1fc7c9bc1a442cdf0ebb8c7b74c0704fed48fe4250e6fd0bbf8ffa13f341c0f",
    65537,
)

# OpenTofu's release signing key, published at
# https://get.opentofu.org/opentofu.asc. Unlike HashiCorp, OpenTofu signs
# with the primary key itself, and the signature to check is the
# `SHA256SUMS.gpgsig` file -- the neighbouring `.sig` and `.pem` are a
# cosign keyless bundle, which is a different scheme entirely.
OPENTOFU_SIGNING_KEY = _rsa_key(
    # E3E6E43D84CB852EADB0051D0C0AF313E5FD9F80
    "cf83a8d4266e6588c4e20e7772a6b9f05d0db719dc909bf916f4c14e8580d192" +
    "c9a66eccf40c27ea9ed169ba82b13d7cc0f894eb66559938db54fa57998c83a5" +
    "015662cf4af0cf9109abbb88ae4b9e5ad524e8062404b37ecccb5bba2d33dc70" +
    "8f54d9d1e419553725d0796de396b42dcee29ebe3656cc8d206d01a010a3698f" +
    "e95fc9116eeaadeefd3d28de9ffa6ce3a5407c0232d9c5956a63afa7ff27611d" +
    "5153bfe8d6074332263e3e0b20d5c5ffe7aaa3bbfab2f16d6954ed4441b65765" +
    "7b59eedbbbf709f8d809607eeba3b5210754501f6934f4d769482b7d17ad0f54" +
    "4467391a7118190cfd5299ce0312cd1bdda71516c2b2f17c0c629eee5d75b066" +
    "df2d1bcda53cd0e4f78b5aab588a96ef77e67461d0ef581b27146bae8c8b3167" +
    "a18dc27ff56243c641eab1f3caa8189f62ca7afc9f67a5ccc37d253ecd80551a" +
    "947bddae0475b788456ab06c7d0b5a195b8b520ce5a14369930536463e016c8f" +
    "f8e1e7f0a7a1bba0ce221d4054ceefeef2f1697f61b758d525bb308ef3c562ab" +
    "afd43bd475ced53f6407cf7c5cb504b5199250d5e91c813bfdad161750e3b092" +
    "72278ed90cf64403b7206454b70473c85adc27e1e8f26c7083f9547c1a34c800" +
    "3ebf6db25df1a9dcf9ea5e543e315216e7a5f7c8d206a9fcdd5ad3d2e2b03343" +
    "e70d51ddffbabcf8383512d3a080cc19f37d0a39114d7637efeb276c06f97b7f",
    65537,
)

# Keyed by fingerprint, which is what a v4 signature names its issuer by.
PUBLISHER_KEYS = {
    "374EC75B485913604A831CC7C820C6D5CD27AB87": HASHICORP_SIGNING_KEY,
    "E3E6E43D84CB852EADB0051D0C0AF313E5FD9F80": OPENTOFU_SIGNING_KEY,
}
