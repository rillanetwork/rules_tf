"""Unit tests for reading the ruleset plugins a tflint config declares.

These run at analysis time and reach no release API: only the config grammar is
covered here, not the resolution that consumes it. The grammar is the part worth
asserting on -- a block misread is a ruleset silently not installed, which
surfaces downstream as a lint rule that never fires rather than as an error.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":plugins.bzl", "parse_tflint_plugins")

def _bundled_plugin_test_impl(ctx):
    env = unittest.begin(ctx)

    # The block every config carries: bundled into the tflint binary, named by
    # no source, and so nothing to download. Skipped rather than reported
    # missing.
    asserts.equals(env, [], parse_tflint_plugins("""
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
"""))

    return unittest.end(env)

def _declared_plugin_test_impl(ctx):
    env = unittest.begin(ctx)

    parsed = parse_tflint_plugins("""
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.30.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

plugin "google" {
  # A disabled ruleset is still installed: `tflint --init` fetches it too, and
  # a config that toggles one on has no second chance to fetch it.
  enabled = false
  version = "0.31.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}
""")

    asserts.equals(env, ["aws", "google"], [p["name"] for p in parsed])
    asserts.equals(env, ["0.30.0", "0.31.0"], [p["version"] for p in parsed])

    # The release's assets are named for the repository, not for the plugin.
    asserts.equals(
        env,
        ["tflint-ruleset-aws", "tflint-ruleset-google"],
        [p["repo"] for p in parsed],
    )

    return unittest.end(env)

def _signing_key_heredoc_test_impl(ctx):
    env = unittest.begin(ctx)

    # PGP armor holds braces, hashes and equals signs, so a scan that read the
    # heredoc's body as syntax would lose its place: the '}' below would close
    # the block early and the coordinates after it would go unread.
    parsed = parse_tflint_plugins("""
plugin "custom" {
  enabled = true
  source  = "github.com/acme/tflint-ruleset-custom"

  signing_key = <<-KEY
  -----BEGIN PGP PUBLIC KEY BLOCK-----

  mQINBF{not}syntax=
  # nor is this a comment
  -----END PGP PUBLIC KEY BLOCK-----
  KEY

  version = "1.2.3"
}
""")

    asserts.equals(env, 1, len(parsed))
    asserts.equals(env, "1.2.3", parsed[0]["version"])
    asserts.equals(env, "github.com/acme/tflint-ruleset-custom", parsed[0]["source"])

    return unittest.end(env)

def _nested_and_commented_blocks_test_impl(ctx):
    env = unittest.begin(ctx)

    # A commented-out block declares nothing, and a nested block holds no
    # coordinates of its own -- neither may contribute a version or a source.
    parsed = parse_tflint_plugins("""
config {
  call_module_type = "local"
}

# plugin "ignored" {
#   version = "9.9.9"
#   source  = "github.com/acme/tflint-ruleset-ignored"
# }

plugin "aws" {
  enabled = true
  version = "0.30.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"

  rule "aws_instance_invalid_type" {
    enabled = true
    version = "not-the-plugin-version"
  }
}
""")

    asserts.equals(env, 1, len(parsed))
    asserts.equals(env, "aws", parsed[0]["name"])
    asserts.equals(env, "0.30.0", parsed[0]["version"])

    return unittest.end(env)

_bundled_plugin_test = unittest.make(_bundled_plugin_test_impl)
_declared_plugin_test = unittest.make(_declared_plugin_test_impl)
_signing_key_heredoc_test = unittest.make(_signing_key_heredoc_test_impl)
_nested_and_commented_blocks_test = unittest.make(_nested_and_commented_blocks_test_impl)

def tflint_plugins_test_suite():
    """Declares the tflint config parsing tests."""
    unittest.suite(
        "tflint_plugins_tests",
        _bundled_plugin_test,
        _declared_plugin_test,
        _signing_key_heredoc_test,
        _nested_and_commented_blocks_test,
    )
