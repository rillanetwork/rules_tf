"""Unit tests for reading a checksum document.

These run at analysis time and fetch nothing: the documents below are excerpts
of real releases, kept because the four tools this ruleset downloads spell their
archive names four different ways, and a name built wrongly reads as "no sha256
in the document" rather than as a typo.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//tf/toolchains/tfdoc:toolchain.bzl", TFDOC_ARCHIVE_TEMPLATE = "ARCHIVE_TEMPLATE")
load("//tf/toolchains/tflint:toolchain.bzl", TFLINT_ARCHIVE_TEMPLATE = "ARCHIVE_TEMPLATE")
load(":checksums.bzl", "DEFAULT_ARCHIVE_TEMPLATE", "get_sha256sum", "resolve_tool_sha256")
load(":facts.bzl", "tool_fact_key")

_TERRAFORM_SHA256SUMS = """
b8cf184dee15dfa89713fe56085313ab23db22e17f26d47fdb0af5f4d5e8ff4e  terraform_1.9.8_darwin_amd64.zip
e0e1a12a1c86d29d1b93e2f8bfb35c6b0dd1e9ab8a5b5a0b0f9dcc8c2c68f1e0  terraform_1.9.8_darwin_arm64.zip
7c1b1f0b3b9c3a9d1ed4e9d1d0e6c1c9e1a4f1e9d8c7b6a5f4e3d2c1b0a9f8e7  terraform_1.9.8_linux_amd64.zip
"""

_TFLINT_CHECKSUMS = """
271ce18e05429f9d324d73f946aebe8d00583bd1f48486012314eacd4b60b57a  tflint_darwin_amd64.zip
4e139b572723ada5e7cfbf214183c413e633f17d44d9fe649f1a8d8c4312ae3f  tflint_darwin_arm64.zip
f45cf2868b6606744d72c41473906546c5738ddba41a222221da9572ade92336  tflint_linux_amd64.zip
"""

_TFDOC_SHA256SUM = """
90654f8436ee28f9a245d9b6af88ba305b09c6cd773588b9362c29f76dad1732  terraform-docs-v0.18.0-darwin-arm64.tar.gz
7ccf78ca447e155ebf8ff0a390826283eded651d55b8e68cc534998f8f5fac2c  terraform-docs-v0.18.0-linux-amd64.tar.gz
"""

# A ruleset lists the bare binary alongside the archive, and the binary's line
# ends with the archive's name minus ".zip" -- so the two entries are only told
# apart by asking for the full archive name.
_RULESET_CHECKSUMS = """
26e4892a2e99bc87e21616590314b9bce4868cca789002fbbb619c43fde78e58  tflint-ruleset-aws_darwin_arm64
b6588b0b0c41e91a58e63d6fe72c6f915f903427f702a85ebf339e506890a33b  tflint-ruleset-aws_darwin_arm64.zip
"""

def _archive_naming_test_impl(ctx):
    env = unittest.begin(ctx)

    # terraform and tofu carry the version in the archive name; tflint does not;
    # terraform-docs joins the platform with dashes and prefixes a 'v'.
    asserts.equals(env, "terraform_1.9.8_darwin_arm64.zip", DEFAULT_ARCHIVE_TEMPLATE.format(
        tool = "terraform",
        version = "1.9.8",
        os = "darwin",
        arch = "arm64",
    ))
    asserts.equals(env, "tflint_darwin_arm64.zip", TFLINT_ARCHIVE_TEMPLATE.format(
        tool = "tflint",
        version = "0.51.1",
        os = "darwin",
        arch = "arm64",
    ))
    asserts.equals(
        env,
        "terraform-docs-v0.18.0-darwin-arm64.tar.gz",
        TFDOC_ARCHIVE_TEMPLATE.format(
            tool = "terraform-docs",
            version = "0.18.0",
            os = "darwin",
            arch = "arm64",
        ),
    )

    return unittest.end(env)

def _lookup_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "b8cf184dee15dfa89713fe56085313ab23db22e17f26d47fdb0af5f4d5e8ff4e",
        get_sha256sum(_TERRAFORM_SHA256SUMS, "terraform_1.9.8_darwin_amd64.zip"),
    )
    asserts.equals(
        env,
        "4e139b572723ada5e7cfbf214183c413e633f17d44d9fe649f1a8d8c4312ae3f",
        get_sha256sum(_TFLINT_CHECKSUMS, "tflint_darwin_arm64.zip"),
    )
    asserts.equals(
        env,
        "90654f8436ee28f9a245d9b6af88ba305b09c6cd773588b9362c29f76dad1732",
        get_sha256sum(_TFDOC_SHA256SUM, "terraform-docs-v0.18.0-darwin-arm64.tar.gz"),
    )

    # A platform the release does not publish has no line, which the callers
    # read as "skip this platform" rather than as a failure.
    asserts.equals(env, None, get_sha256sum(_TFLINT_CHECKSUMS, "tflint_linux_arm64.zip"))

    return unittest.end(env)

def _suffix_ambiguity_test_impl(ctx):
    env = unittest.begin(ctx)

    # Lines are matched on their suffix, so the archive and the bare binary it
    # unpacks to are distinguished only by the extension. Asking for the archive
    # must not return the binary's hash, whichever order the document lists them
    # in.
    asserts.equals(
        env,
        "b6588b0b0c41e91a58e63d6fe72c6f915f903427f702a85ebf339e506890a33b",
        get_sha256sum(_RULESET_CHECKSUMS, "tflint-ruleset-aws_darwin_arm64.zip"),
    )

    return unittest.end(env)

def _settled_facts_test_impl(ctx):
    env = unittest.begin(ctx)

    # A remembered hash a signature covered answers the question outright, with
    # no network involved. Passing None for the module_ctx is the assertion: any
    # fetch at all would fail on it.
    remembered = {
        tool_fact_key("terraform", "1.9.5", "darwin_arm64"): {
            "sha256": "b7eca5cd6f0f6644d45d8708c1b864e64a9e26c355d2c9b585faa049f640fe71",
            "verified": True,
        },
    }

    resolved = resolve_tool_sha256(
        None,
        "terraform",
        "1.9.5",
        "darwin",
        "arm64",
        remembered,
        "https://example.invalid/{version}/SHA256SUMS",
        signature_template = "https://example.invalid/{version}/SHA256SUMS.sig",
    )

    asserts.equals(
        env,
        "b7eca5cd6f0f6644d45d8708c1b864e64a9e26c355d2c9b585faa049f640fe71",
        resolved.sha256,
    )
    asserts.equals(env, None, resolved.error)
    asserts.true(env, resolved.verified, "a recorded mark should settle the release")
    asserts.false(env, resolved.minted, "nothing should be resolved afresh")

    return unittest.end(env)

def _unsigned_tool_settles_test_impl(ctx):
    env = unittest.begin(ctx)

    # A tool whose publisher signs nothing has no mark to record, so an
    # unmarked hash still settles rather than being re-fetched forever. Without
    # this, tflint and terraform-docs would refetch their checksum documents on
    # every evaluation in pursuit of a signature that does not exist.
    remembered = {
        tool_fact_key("tflint", "0.53.0", "darwin_arm64"): {
            "sha256": "2ba8eefe6cbd5d34e5a0589a8897646e4da44c48f4c2fd9a77581d1e2b03bff8",
        },
    }

    resolved = resolve_tool_sha256(
        None,
        "tflint",
        "0.53.0",
        "darwin",
        "arm64",
        remembered,
        "https://example.invalid/{version}/checksums.txt",
    )

    asserts.equals(
        env,
        "2ba8eefe6cbd5d34e5a0589a8897646e4da44c48f4c2fd9a77581d1e2b03bff8",
        resolved.sha256,
    )
    asserts.false(env, resolved.verified, "no signature covers a tflint release")
    asserts.false(env, resolved.minted, "an unsigned tool still settles")

    return unittest.end(env)

def _verification_off_settles_test_impl(ctx):
    env = unittest.begin(ctx)

    # Under "off" an unmarked hash settles even for a tool that does publish a
    # signature, since no check is going to be made of it.
    remembered = {
        tool_fact_key("terraform", "1.9.5", "darwin_arm64"): {
            "sha256": "b7eca5cd6f0f6644d45d8708c1b864e64a9e26c355d2c9b585faa049f640fe71",
        },
    }

    resolved = resolve_tool_sha256(
        None,
        "terraform",
        "1.9.5",
        "darwin",
        "arm64",
        remembered,
        "https://example.invalid/{version}/SHA256SUMS",
        signature_template = "https://example.invalid/{version}/SHA256SUMS.sig",
        verification = "off",
    )

    asserts.false(env, resolved.verified, "nothing was checked, so nothing is claimed")
    asserts.false(env, resolved.minted, "\"off\" should not re-resolve a recorded hash")

    return unittest.end(env)

_archive_naming_test = unittest.make(_archive_naming_test_impl)
_settled_facts_test = unittest.make(_settled_facts_test_impl)
_unsigned_tool_settles_test = unittest.make(_unsigned_tool_settles_test_impl)
_verification_off_settles_test = unittest.make(_verification_off_settles_test_impl)
_lookup_test = unittest.make(_lookup_test_impl)
_suffix_ambiguity_test = unittest.make(_suffix_ambiguity_test_impl)

def checksums_test_suite():
    """Declares the checksum document tests."""
    unittest.suite(
        "checksums_tests",
        _archive_naming_test,
        _lookup_test,
        _suffix_ambiguity_test,
        _settled_facts_test,
        _unsigned_tool_settles_test,
        _verification_off_settles_test,
    )
