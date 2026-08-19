"""Known-answer tests for the OpenPGP verification, against real releases.

Every fixture below is a real published artefact, and every expected answer was
taken from `gpgv` verifying the same pair on the command line. That oracle is
the point of the file: a signature check that wrongly returns True is invisible
in every other test, because nothing else in the ruleset can tell a verified
release from an unverified one.

The documents are embedded as text and their digests asserted, so that an editor
trimming a trailing newline fails here, loudly, rather than surfacing as an
unexplained verification failure against a real release much later.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":bytes.bzl", "hex_to_bytes", "latin1_to_bytes")
load(":keys.bzl", "HASHICORP_SIGNING_KEY", "OPENTOFU_SIGNING_KEY", "PUBLISHER_KEYS")
load(":openpgp.bzl", "parse_signature", "verify_detached")
load(":sha2.bzl", "sha256")

_HEX = "0123456789abcdef"

def _to_hex(data):
    return "".join([_HEX[b // 16] + _HEX[b % 16] for b in data])

# terraform 1.9.8's SHA256SUMS, verbatim.
_TERRAFORM_DOCUMENT = """\
be591e8c59c49d0cfbc7664d24910a4b43840b89d0a4bbca662149bbf0397e91  terraform_1.9.8_darwin_amd64.zip
873d7b925d08578fb6bb9c12c7cd92ae73e289e07c360f2fdd69f9036b7baaab  terraform_1.9.8_darwin_arm64.zip
b1b56dbaa0ddda52a42b4398a1cebfd4ebc175391ef64b14747c65fa6debe072  terraform_1.9.8_freebsd_386.zip
aa7a936aeb5254abd1761282f4f0b2850b7507166f0344683f37a1e82da23f46  terraform_1.9.8_freebsd_amd64.zip
bdef3da36aa736bcc14767bd353667773d46aaf562b1d85dfa66e5266290247d  terraform_1.9.8_freebsd_arm.zip
aa85bb2e0c68f2ee148d1ea854ee0aa78086017cbda9058371be8be2f4c18d10  terraform_1.9.8_linux_386.zip
186e0145f5e5f2eb97cbd785bc78f21bae4ef15119349f6ad4fa535b83b10df8  terraform_1.9.8_linux_amd64.zip
cb6db8471e361bb9ad6bbd43d9c780d37208e6dbe416900fdc8999af9e459b77  terraform_1.9.8_linux_arm.zip
f85868798834558239f6148834884008f2722548f84034c9b0f62934b2d73ebb  terraform_1.9.8_linux_arm64.zip
851fa5b84efb78c31491f364ac1cdd6ea8e013ba04f9657acacc9401cfd479db  terraform_1.9.8_openbsd_386.zip
e9311ffaa728c31a40493e6de35c13e1f7879468dd568d32ace2458725fb02d0  terraform_1.9.8_openbsd_amd64.zip
a8eaecd78c68e2b748fd5d6e2cf1a1e97ad891aa36d53509c7ad04bb86bd24cc  terraform_1.9.8_solaris_amd64.zip
b9c5a8c3b4a91b89b67f8f58a84b27d0ad423f0286df959176691e077d9f6966  terraform_1.9.8_windows_386.zip
2667de56106bc6707968286357e29c20f8dbbb2f429ef57099b04994f82d9684  terraform_1.9.8_windows_amd64.zip
"""

_TERRAFORM_DOCUMENT_SHA256 = "d13d3d14a74864332d85aa4690602b67008890d8c78166387477cbc24ec5b67d"

# terraform_1.9.8_SHA256SUMS.sig: a new-format v4 RSA signature over SHA-256.
_TERRAFORM_SIGNATURE = (
    "c2c1730400010800270502670fbaaa0910c820c6d5cd27ab87162104374ec75b" +
    "485913604a831cc7c820c6d5cd27ab8700006bf40fff7c450696aedd59ae332b" +
    "065f0ae7b11a938fb57a9b4bab1ffc967dd77adeddc7c3370fefdc06e9957b5e" +
    "f9480027e696453bf5c7781ab3b2ffe657e8efe4dcc32c6ce01997f4bbbe5d5d" +
    "1318bbb7dabd1378e4718ebb53b6aa60e0194bd30da07cb41ea483fd40d98860" +
    "fabf1526dfdfcac8c1abab12a0ea5677b49d0c446328c8b2478d2d6c2065c086" +
    "d5f376254d2876330c2613277215e53751df235f29c535e2c5b8ad5df435a450" +
    "b63a1ea04bc3ecbf0380d52e6dc9ea2f59ff1484d1d879e1457f850983bd1899" +
    "52d4e7cbeee9ddc851d6ff6651273c53dd827a74c1a9ba38bb4a261d860d3199" +
    "74149030d914038d7fffba913757e22f1854a982d7b36c0c9413b2db96934acf" +
    "5277ffde0c1d42cffa829d26f5a2ed0d0dcdf8cd0af070c29bb7c86073404642" +
    "65e8f07b9287c3257c4cf89c0a7c12b27d251197dafd6050f40961b8f80c3f11" +
    "54fce3f7f5a5b5da9ca9a128ef46108c21448d6744b71eed81734914f7ae9bf4" +
    "5e209b6a6ec98fe44dbdd4cd84578bdb66dd39748208341cf62bad628112ba6c" +
    "dc9582af545c3822dd347b62ce328536232dedc323dc8a3cc09eee062f17cb73" +
    "7f14938be94ea5622404481d93bcebf4b7ef843c74517439ae8a56b8fbba7f2e" +
    "b8b815a70872d1070825b7f70e717024e2a0a6b8fdeadc3f588db7bd6f1d3c1a" +
    "dea9bce118d1ef43db9ed7a31a6a0fae7884234a3de9"
)

# tofu 1.8.5's SHA256SUMS, verbatim.
_TOFU_DOCUMENT = """\
060941a5fab595652eb517f0ef222f3f2e8d659d501433e0bdcd58af0ba48831  tofu_1.8.5_linux_arm.tar.gz
06a1c6b3720d0057d3bcb77933b1d765a9e23d1eba3fc0c3754b8cfb4cb42bb6  tofu_1.8.5_freebsd_386.zip
0a15fd191509db47991cf042f85c7390fb789643ef790688ce37b6c17d9ea0dd  tofu_1.8.5_linux_386.zip
14a43bbc31ec36e2aa3a0ad4eb6bebedfd5fea27c7cce6fdede3b9b7ed67b430  tofu_1.8.5_freebsd_386.tar.gz
1ad5072d66df85185440714556afed26e17636cf2635dc4154592fc15706306f  tofu_1.8.5_arm64.apk
2535e8d4979806cbf79a1b704dccf1fae45b4d50ccaee3e54c1771044db4a573  tofu_1.8.5_linux_arm64.zip
3933ff6807385a94c41535ab331de7bdc0abccf6a4d46bd0aeb51bb1f8dd5a10  tofu_1.8.5_openbsd_386.tar.gz
455f1ff4e79c56889e55ee192606439acca8bfc301f5e61bad9f400dacf5bf58  tofu_1.8.5_windows_386.tar.gz
49a06a59af709bb666ed8627655ccb72d23e3c16640d71f246c8a8f06c30afad  tofu_1.8.5_arm64.deb
4acecae2256013cec59af2caef265f1fc4f46ca7859ff4e0b043a6d3a21e7cc1  tofu_1.8.5_windows_amd64.tar.gz
51a984d6c01e1afcbc658c396560e9db9e81451a1dbd9ac119f29532c06f7662  tofu_1.8.5_freebsd_arm.zip
5478b9b0f9ec4124221e0a6317051ecc34795072e65f4979a0293377fdd7ef4f  tofu_1.8.5_386.rpm
65aadd14ef39eea8d4c3f1ee4579c2a46adb2f5fa5631324c48f086d4e7fa65c  tofu_1.8.5_windows_386.zip
67b5804b302ae35de7488ec880d49a90209b26a145dfc89814e3b09bd8911377  tofu_1.8.5_linux_386.tar.gz
6817a2bb50893352fafe7a7252209ab8e532739e73eeaa438cc35d9c5f585fb9  tofu_1.8.5_arm.apk
6ceb9a1ceeec8c90b3890f548fbf0d546234dd86508f841ee8229f2a4397c538  tofu_1.8.5_amd64.rpm
6ffc6a74a04020b19a5ef6fc10120f73e9f9b8274d11c28556d2ca2b3b5b0769  tofu_1.8.5_amd64.apk
7714daa82d210c9396a28915c85467f448673223f9ab11b31bd471a12f750db7  tofu_1.8.5_amd64.deb
79aa532eb8172afa4afd161972af8809814ec75ac4b8af069242800458cd7661  tofu_1.8.5_freebsd_arm.tar.gz
7d81c559912a772ca3836770c1986b8e3b953a61072d7b2a7a1b5221c05c6d6f  tofu_1.8.5_darwin_arm64.tar.gz
840dc6320917fba3af38ef621158ed1ccbbf1a64a9b79c8f534250323033bd36  tofu_1.8.5_arm.rpm
861a3f77f1bc01e367c000078bc94eb424d02692615cc9c0696d18263d883845  tofu_1.8.5_openbsd_amd64.tar.gz
86ca868d8b751b759cb6697da7859ad6d6a5b866317b28141603bede8a718abf  tofu_1.8.5_openbsd_amd64.zip
888346b870e5e9170a8b3fad1734d9e5e17cf48a17d1ccaa39f5f9de892440d2  tofu_1.8.5_freebsd_amd64.zip
8bcd1317392a7b1ce149c5dafc886497219f560527fe10ed0d58863120d59e67  tofu_1.8.5_windows_amd64.zip
90192c7e60d270afdf297c9fc868bc67aa58619e280af1135439bd188b741e18  tofu_1.8.5_solaris_amd64.zip
973dd26de6aabcf3738ac997204201dd0549a00976b082fe16fd35e42c7d0a3b  tofu_1.8.5_openbsd_386.zip
a5cd248121e90c1374b7ba6474a206ea1a8415fe225835002c606b9bc9de0a10  tofu_1.8.5_arm64.rpm
b1b00258e74ecddfbf2aa884718ab6138b1b8d5deaca1962c651506bc371a307  tofu_1.8.5_freebsd_amd64.tar.gz
b3216ab936fe6e569487c41ebaf78366c7120d2d3bb05e2fea46ee3eeeb44e4a  tofu_1.8.5_solaris_amd64.tar.gz
bdecf60068a8a08a60f0cbdd54834cc9d38037f587a3687cb328c1755c09fd86  tofu_1.8.5_386.deb
c0186b4d47c740433c8962a72e8e864225f79fb21028203925196a5b28aa6868  tofu_1.8.5_darwin_amd64.tar.gz
c1f77ff8bb5e6a62604877dcf51bda32d3ab11e3239908bbbbf59cfbc702e16a  tofu_1.8.5_386.apk
c77e545ab847c0d6acd322c010f457e1a30448476945c04074a48882c4b86dfe  tofu_1.8.5_darwin_arm64.zip
cb6d1b949691e50bed6c9cc17aefc999cf27e52200521efa9f107ce3ee08260f  tofu_1.8.5_darwin_amd64.zip
d1c7d6505a9e27ee79ba75f2a9849e6ce56e3e13f25916f067330c045567b0b3  tofu_1.8.5_linux_arm.zip
d66786a6b5a16ebd6d486167440b3c95a6556fb8128f368e8814eae446bfa035  tofu_1.8.5_arm.deb
d89c753fe440e1156fa8e523b2c8744322f29b2c40cc3fd049617271272b853d  tofu_1.8.5_linux_arm64.tar.gz
dc46f945f3718769604561c9bad569841443ffcc6e0b970d4dbc5bd224a52941  tofu_1.8.5_linux_amd64.tar.gz
e2951ba6be8ae9427aabbd5c6f243855e8b526cb2ae6bc33a05dae22d7e82632  tofu_1.8.5_linux_amd64.zip
"""

_TOFU_DOCUMENT_SHA256 = "4791d5c16300f1934aed0422042f7a37266a1087de81eb458a0081d9ca11ce10"

# tofu_1.8.5_SHA256SUMS.gpgsig: an old-format v4 RSA signature over SHA-512.
_TOFU_SIGNATURE = (
    "8902330400010a001d162104e3e6e43d84cb852eadb0051d0c0af313e5fd9f80" +
    "050267292f67000a09100c0af313e5fd9f8084060fff69adc397d927e6eb4235" +
    "595659d1efe8308cf5df52b1617aebfa97819e97d111adc0537cc344b4fbb31a" +
    "c59c599f6f24a822d905cdb6eb426b27979d23c844df13a14efa6823d5a72882" +
    "8c2f1f4e476e6b6f3ddf4d74c9d204b571c02021da745b978088bfe880331c25" +
    "afcddfaf0a4823a623c1e262934b49dbd8204f2db35f4015fc90feded2c6628d" +
    "aace43e38f408f4ad4c9b0ab1abb261efdf0d54f0a1d74a3fd72238f3fd725dd" +
    "d760ddb3d4eac7282a5e34baf4e884d5d5c394aefb57f77125927da0fc4c4231" +
    "2d6b1afda41ca756560d33dee1f6abe50f7213f0cd451b2a9bd5e65e1f84140d" +
    "b8e8b8e1d1e82beac85a5189026a656d08d48e7ae73beb07ead05d9a64b40168" +
    "79639b8d326bd46b08c1d3b5c76090cbee67d9d240523d1ffab48e8f92f23752" +
    "ea3abd72b6225bc0dbe4ad78539dd05a09eb4e331a3b43f46b18956651584c5f" +
    "05c2e3932ee74f272fbf333db90eabd9990630145b0d4a87ce764fb206538948" +
    "2bc4dc8d63ebe5edfbd0f2de55ff70639aa004e1fdc0d9ae81eb14d9b455f3dd" +
    "107c2a192ac8651e5a470fa29bae4a406faafb94cda2dd1155975047d848a4f8" +
    "46ac21bdfbe72dfd05719d7b5248f55d32a6f6ef3d15557adc8bf8cb1b1772f7" +
    "c3fa1591420d140f796cfcc9cca223161d5712733e75e53ee1295b52a9456983" +
    "08f3052db0ab20e5ec73a6bcf5d18608769eb606a91c"
)

def _fixtures_intact_test_impl(ctx):
    env = unittest.begin(ctx)

    # The signatures below cover these bytes exactly. If an editor or a merge
    # ever reflows one of the documents, this is the assertion that says so.
    asserts.equals(
        env,
        _TERRAFORM_DOCUMENT_SHA256,
        _to_hex(sha256(latin1_to_bytes(_TERRAFORM_DOCUMENT))),
    )
    asserts.equals(
        env,
        _TOFU_DOCUMENT_SHA256,
        _to_hex(sha256(latin1_to_bytes(_TOFU_DOCUMENT))),
    )

    return unittest.end(env)

def _parse_test_impl(ctx):
    env = unittest.begin(ctx)

    # HashiCorp's is a new-format packet signing a SHA-256 digest, and names its
    # issuer by full fingerprint.
    terraform = parse_signature(hex_to_bytes(_TERRAFORM_SIGNATURE))
    asserts.equals(env, "sha256", terraform.hash_name)
    asserts.equals(env, "374EC75B485913604A831CC7C820C6D5CD27AB87", terraform.issuer)

    # OpenTofu's is an old-format packet over SHA-512. Both forms appear in
    # practice, which is why both are implemented.
    tofu = parse_signature(hex_to_bytes(_TOFU_SIGNATURE))
    asserts.equals(env, "sha512", tofu.hash_name)
    asserts.equals(env, "E3E6E43D84CB852EADB0051D0C0AF313E5FD9F80", tofu.issuer)

    return unittest.end(env)

def _verify_test_impl(ctx):
    env = unittest.begin(ctx)

    verified, issuer, error = verify_detached(
        hex_to_bytes(_TERRAFORM_SIGNATURE),
        latin1_to_bytes(_TERRAFORM_DOCUMENT),
        PUBLISHER_KEYS,
    )
    asserts.true(env, verified, "terraform 1.9.8 SHA256SUMS should verify: %s" % error)
    asserts.equals(env, None, error)
    asserts.equals(env, "374EC75B485913604A831CC7C820C6D5CD27AB87", issuer)

    verified, issuer, error = verify_detached(
        hex_to_bytes(_TOFU_SIGNATURE),
        latin1_to_bytes(_TOFU_DOCUMENT),
        PUBLISHER_KEYS,
    )
    asserts.true(env, verified, "tofu 1.8.5 SHA256SUMS should verify: %s" % error)
    asserts.equals(env, "E3E6E43D84CB852EADB0051D0C0AF313E5FD9F80", issuer)

    return unittest.end(env)

def _rejects_tampering_test_impl(ctx):
    env = unittest.begin(ctx)

    # One flipped hex digit in one hash: the case the whole exercise exists to
    # catch, since it is exactly what an attacker substituting an archive needs.
    tampered = _TERRAFORM_DOCUMENT.replace(
        "be591e8c59c49d0cfbc7664d24910a4b43840b89d0a4bbca662149bbf0397e91",
        "ce591e8c59c49d0cfbc7664d24910a4b43840b89d0a4bbca662149bbf0397e91",
    )
    asserts.false(env, tampered == _TERRAFORM_DOCUMENT, "the tampered fixture must actually differ")

    verified, _, error = verify_detached(
        hex_to_bytes(_TERRAFORM_SIGNATURE),
        latin1_to_bytes(tampered),
        PUBLISHER_KEYS,
    )
    asserts.false(env, verified, "a modified document must not verify")
    asserts.true(env, error != None, "a failure must carry a message")

    # A trailing byte, which a check that hashed only a prefix would accept.
    verified, _, _ = verify_detached(
        hex_to_bytes(_TERRAFORM_SIGNATURE),
        latin1_to_bytes(_TERRAFORM_DOCUMENT + "\n"),
        PUBLISHER_KEYS,
    )
    asserts.false(env, verified, "an appended byte must not verify")

    return unittest.end(env)

def _rejects_wrong_pairing_test_impl(ctx):
    env = unittest.begin(ctx)

    # Each publisher's signature over the other's document. Both are genuine
    # signatures by trusted keys, so this fails only if the digest is really
    # being checked against the document in hand.
    verified, _, _ = verify_detached(
        hex_to_bytes(_TERRAFORM_SIGNATURE),
        latin1_to_bytes(_TOFU_DOCUMENT),
        PUBLISHER_KEYS,
    )
    asserts.false(env, verified, "terraform's signature must not verify tofu's document")

    verified, _, _ = verify_detached(
        hex_to_bytes(_TOFU_SIGNATURE),
        latin1_to_bytes(_TERRAFORM_DOCUMENT),
        PUBLISHER_KEYS,
    )
    asserts.false(env, verified, "tofu's signature must not verify terraform's document")

    return unittest.end(env)

def _rejects_untrusted_key_test_impl(ctx):
    env = unittest.begin(ctx)

    # A genuine signature over its own document, checked against a key set that
    # does not hold its issuer: verification is what the vendored keys say it
    # is, not what the signature claims about itself.
    verified, issuer, error = verify_detached(
        hex_to_bytes(_TERRAFORM_SIGNATURE),
        latin1_to_bytes(_TERRAFORM_DOCUMENT),
        {"E3E6E43D84CB852EADB0051D0C0AF313E5FD9F80": OPENTOFU_SIGNING_KEY},
    )
    asserts.false(env, verified, "a key outside the vendored set must not verify")
    asserts.equals(env, "374EC75B485913604A831CC7C820C6D5CD27AB87", issuer)
    asserts.true(env, error != None, "an untrusted issuer must be named")

    # And the reverse: the right document and key, but the modulus swapped for
    # the other publisher's under the issuer's own fingerprint.
    verified, _, _ = verify_detached(
        hex_to_bytes(_TERRAFORM_SIGNATURE),
        latin1_to_bytes(_TERRAFORM_DOCUMENT),
        {"374EC75B485913604A831CC7C820C6D5CD27AB87": OPENTOFU_SIGNING_KEY},
    )
    asserts.false(env, verified, "a substituted modulus must not verify")

    # The genuine pairing still passes with only its own key present, which
    # keeps the two assertions above from passing for the wrong reason.
    verified, _, _ = verify_detached(
        hex_to_bytes(_TERRAFORM_SIGNATURE),
        latin1_to_bytes(_TERRAFORM_DOCUMENT),
        {"374EC75B485913604A831CC7C820C6D5CD27AB87": HASHICORP_SIGNING_KEY},
    )
    asserts.true(env, verified, "the genuine key must still verify on its own")

    return unittest.end(env)

_fixtures_intact_test = unittest.make(_fixtures_intact_test_impl)
_parse_test = unittest.make(_parse_test_impl)
_verify_test = unittest.make(_verify_test_impl)
_rejects_tampering_test = unittest.make(_rejects_tampering_test_impl)
_rejects_wrong_pairing_test = unittest.make(_rejects_wrong_pairing_test_impl)
_rejects_untrusted_key_test = unittest.make(_rejects_untrusted_key_test_impl)

def openpgp_test_suite():
    """Declares the OpenPGP verification tests."""
    unittest.suite(
        "openpgp_tests",
        _fixtures_intact_test,
        _parse_test,
        _verify_test,
        _rejects_tampering_test,
        _rejects_wrong_pairing_test,
        _rejects_untrusted_key_test,
    )
