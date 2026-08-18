"""Unit tests for reading the ruleset plugins a tflint config declares.

These run at analysis time and reach no release API, which limits them to the
config grammar and to the narrowing that decides what the verification pass is
asked to check. Both are worth asserting on: a block misread is a ruleset
silently not installed, which surfaces downstream as a lint rule that never
fires rather than as an error, and a narrowing that drops a ruleset is a
signature check silently not made.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@rules_tf//tf/toolchains:facts.bzl", "tflint_plugin_fact_key")
load(":plugins.bzl", "parse_tflint_plugins", "unverified_plugins")

_PLATFORMS = ["linux_amd64", "darwin_arm64"]

def _plugin(source = "github.com/terraform-linters/tflint-ruleset-google", version = "0.39.0"):
    return {"source": source, "version": version}

def _facts(plugin, verified_platforms):
    return {
        tflint_plugin_fact_key(plugin["source"], plugin["version"], platform): (
            {"sha256": "abc", "verified": True} if platform in verified_platforms else {"sha256": "abc"}
        )
        for platform in _PLATFORMS
    }

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

    # Neither block carries a signing_key, and tflint checks a release against
    # its own key only for terraform-linters' own rulesets.
    asserts.equals(env, [False, False], [p["signing_key"] for p in parsed])

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

    # Read off the opener, since the body is skipped wholesale. Nothing but its
    # presence is recorded: the key itself is tflint's to read from the config.
    asserts.true(env, parsed[0]["signing_key"])

    return unittest.end(env)

def _quoted_signing_key_test_impl(ctx):
    env = unittest.begin(ctx)

    # tflint accepts a quoted string as well as a heredoc, and a ruleset
    # misread as keyless is one that "auto" then refuses to verify.
    parsed = parse_tflint_plugins("""
plugin "custom" {
  enabled     = true
  version     = "1.2.3"
  source      = "github.com/acme/tflint-ruleset-custom"
  signing_key = "-----BEGIN PGP PUBLIC KEY BLOCK-----"
}
""")

    asserts.equals(env, 1, len(parsed))
    asserts.true(env, parsed[0]["signing_key"])

    return unittest.end(env)

def _unverified_plugins_test_impl(ctx):
    env = unittest.begin(ctx)

    plugin = _plugin()

    # A mark on every platform settles the release, which is what keeps a
    # second evaluation from running tflint again.
    asserts.equals(env, [], unverified_plugins(
        _facts(plugin, _PLATFORMS),
        [plugin],
        _PLATFORMS,
    ))

    # One platform short is not settled: the facts are replaced wholesale by
    # what this evaluation returns, so an unmarked key would stay unmarked.
    asserts.equals(env, [plugin], unverified_plugins(
        _facts(plugin, ["linux_amd64"]),
        [plugin],
        _PLATFORMS,
    ))

    # No mark at all is what a lockfile written before this check existed
    # carries, and it verifies once rather than needing the schema versioned.
    asserts.equals(env, [plugin], unverified_plugins(
        _facts(plugin, []),
        [plugin],
        _PLATFORMS,
    ))

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
_quoted_signing_key_test = unittest.make(_quoted_signing_key_test_impl)
_unverified_plugins_test = unittest.make(_unverified_plugins_test_impl)
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
        _quoted_signing_key_test,
        _unverified_plugins_test,
    )
