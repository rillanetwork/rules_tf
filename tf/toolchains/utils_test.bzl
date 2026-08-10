"""Unit tests for the pure helpers in utils.bzl.

These run at analysis time and reach no registry, which is the point: the semver
comparator, the constraint solver and the lock parser are otherwise only
exercised end to end by the integration workspaces, where a regression surfaces
as "the wrong version was mirrored" rather than as a failing assertion.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    ":utils.bzl",
    "hcl_credentials_token",
    "merge_provider_locks",
    "mirror_manifest",
    "package_fact_key",
    "parse_mirror_entries",
    "parse_provider_locks",
    "parse_version_constraint",
    "provider_source_parts",
    "select_matching_version",
    "unverified_packages",
    "verify_provider_hashes",
)

_AVAILABLE = ["3.1.0", "3.1.9", "3.2.0", "3.9.0", "4.0.0", "4.0.4", "4.0.5"]

def _pessimistic_operator_test_impl(ctx):
    env = unittest.begin(ctx)

    # '~>' pins every component to the left of the rightmost one written, so the
    # two- and three-component forms bound different components. This is the
    # part of terraform's syntax most easily got wrong.
    asserts.equals(env, "3.1.9", select_matching_version(_AVAILABLE, "~> 3.1.0"))
    asserts.equals(env, "3.9.0", select_matching_version(_AVAILABLE, "~> 3.1"))
    asserts.equals(env, "3.9.0", select_matching_version(_AVAILABLE, "~> 3"))

    return unittest.end(env)

def _comparison_operators_test_impl(ctx):
    env = unittest.begin(ctx)

    # The highest satisfying version, not the first or the last offered.
    asserts.equals(env, "4.0.5", select_matching_version(_AVAILABLE, ">= 3.2.0"))
    asserts.equals(env, "3.1.0", select_matching_version(_AVAILABLE, "< 3.1.9"))
    asserts.equals(env, "3.2.0", select_matching_version(_AVAILABLE, "<= 3.2.0"))
    asserts.equals(env, "3.2.0", select_matching_version(_AVAILABLE, "3.2.0"))
    asserts.equals(env, "3.2.0", select_matching_version(_AVAILABLE, "= 3.2.0"))

    # Commas mean AND, and '!=' subtracts from what the others admit.
    asserts.equals(env, "4.0.4", select_matching_version(_AVAILABLE, ">= 4.0.0, < 4.0.5"))
    asserts.equals(env, "3.1.0", select_matching_version(_AVAILABLE, ">= 3.1.0, < 3.2.0, != 3.1.9"))

    return unittest.end(env)

def _prerelease_selection_test_impl(ctx):
    env = unittest.begin(ctx)

    # Never selected by a constraint, matching terraform: a prerelease reaches
    # the mirror only through an exact pin.
    asserts.equals(env, "3.6.0", select_matching_version(["3.6.0", "3.7.0-alpha1"], ">= 3.0.0"))
    asserts.equals(env, "", select_matching_version(["3.7.0-alpha1"], "~> 3.7"))

    # A prerelease may still appear in a bound, where it ranks below the release
    # it qualifies -- so 4.0.0 satisfies '>= 4.0.0-beta1'.
    asserts.equals(env, "4.0.0", select_matching_version(["4.0.0"], ">= 4.0.0-beta1"))
    asserts.equals(env, "", select_matching_version(["4.0.0"], "< 4.0.0-beta1"))

    return unittest.end(env)

def _unsatisfiable_and_malformed_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, "", select_matching_version(_AVAILABLE, ">= 5.0.0"))
    asserts.equals(env, "", select_matching_version([], "~> 3.1"))

    # A spec that does not parse selects nothing rather than everything; the
    # caller reports it as an unsatisfied constraint.
    asserts.equals(env, "", select_matching_version(_AVAILABLE, "not-a-version"))
    asserts.equals(env, None, parse_version_constraint("~> "))
    asserts.equals(env, None, parse_version_constraint("3.1.0, "))

    return unittest.end(env)

def _mirror_entry_test_impl(ctx):
    env = unittest.begin(ctx)

    parsed = parse_mirror_entries([
        "hashicorp/random:3.6.0",
        "hashicorp/null:3.2.4-alpha.2",
        "tf.example.com/acme/thing:>= 1.0, < 2.0",
        # A host may carry a port, so only the last colon separates the version.
        "tf.example.com:8443/acme/ported:1.2.0",
    ])

    # A prerelease pin is an exact pin; only range syntax is a constraint.
    asserts.equals(env, [True, True, False, True], [e["is_exact"] for e in parsed])
    asserts.equals(
        env,
        [
            "hashicorp/random@3.6.0",
            "hashicorp/null@3.2.4-alpha.2",
            "tf.example.com/acme/thing@>= 1.0, < 2.0",
            "tf.example.com:8443/acme/ported@1.2.0",
        ],
        mirror_manifest(parsed),
    )

    asserts.equals(env, ("tf.example.com:8443", "acme", "ported"), provider_source_parts(
        "tf.example.com:8443/acme/ported",
        "registry.terraform.io",
    ))

    asserts.equals(env, ("registry.terraform.io", "hashicorp", "random"), provider_source_parts(
        "hashicorp/random",
        "registry.terraform.io",
    ))
    asserts.equals(env, ("tf.example.com", "acme", "thing"), provider_source_parts(
        "tf.example.com/acme/thing",
        "registry.terraform.io",
    ))

    return unittest.end(env)

_LOCK_NULL = """
# This file is maintained automatically by "terraform init".

provider "registry.terraform.io/hashicorp/null" {
  version     = "3.1.1"
  constraints = "3.1.1"
  hashes = [
    "h1:71sNUDvmiJcijsvfXpiLCz0lXIBSsEJjMxljt7hxMhw=",
    "zh:aaaa",
    "zh:bbbb",
  ]
}
"""

_LOCK_RANDOM = """
provider "registry.terraform.io/hashicorp/random" {
  version = "3.1.3"
  hashes = [
    "zh:cccc",
  ]
}
"""

# A lock file whose hashes list is written on one line. Valid HCL, and what a
# hand-edited or reformatted lock file may look like.
_LOCK_ONE_LINE = """
provider "registry.terraform.io/hashicorp/tls" {
  version = "4.0.4"
  hashes = ["zh:dddd", "zh:eeee"]
}
"""

def _parse_provider_locks_test_impl(ctx):
    env = unittest.begin(ctx)

    locks = parse_provider_locks([_LOCK_NULL, _LOCK_RANDOM, _LOCK_ONE_LINE])

    # Keyed by address and version, since a mirror may stock several versions of
    # one provider and each needs its own lock file.
    asserts.equals(env, [
        "registry.terraform.io/hashicorp/null@3.1.1",
        "registry.terraform.io/hashicorp/random@3.1.3",
        "registry.terraform.io/hashicorp/tls@4.0.4",
    ], sorted(locks.keys()))

    # Every hash on the line is taken, and the block still closes.
    asserts.equals(env, ["dddd", "eeee"], sorted(locks["registry.terraform.io/hashicorp/tls@4.0.4"].keys()))

    # h1: is dropped: it covers the extracted directory, not the package, and
    # admitting it would let a package match on a hash of something else.
    asserts.equals(env, ["aaaa", "bbbb"], sorted(locks["registry.terraform.io/hashicorp/null@3.1.1"].keys()))
    asserts.equals(env, ["cccc"], sorted(locks["registry.terraform.io/hashicorp/random@3.1.3"].keys()))

    return unittest.end(env)

_TERRAFORMRC = """
# A CLI configuration, as ~/.terraformrc holds it.
plugin_cache_dir = "$HOME/.terraform.d/plugin-cache"

credentials "app.terraform.io" {
  token = "public-token"
}

credentials "tf.example.com:8443" { token = "ported-token" }
"""

def _hcl_credentials_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, "public-token", hcl_credentials_token(_TERRAFORMRC, "app.terraform.io"))

    # A block written on one line, and a host carrying a port.
    asserts.equals(env, "ported-token", hcl_credentials_token(_TERRAFORMRC, "tf.example.com:8443"))

    # No block for the host asked about, and no accidental match on another's.
    asserts.equals(env, "", hcl_credentials_token(_TERRAFORMRC, "registry.terraform.io"))
    asserts.equals(env, "", hcl_credentials_token("", "app.terraform.io"))

    return unittest.end(env)

def _facts_and_merge_test_impl(ctx):
    env = unittest.begin(ctx)

    platforms = ["linux_amd64", "darwin_arm64"]
    null = {"host": "registry.terraform.io", "namespace": "hashicorp", "type": "null", "version": "3.1.1"}
    random = {"host": "registry.terraform.io", "namespace": "hashicorp", "type": "random", "version": "3.1.3"}

    def key(p, platform):
        return package_fact_key(p["host"], p["namespace"], p["type"], p["version"], platform)

    facts = {
        key(null, "linux_amd64"): {"download_url": "https://example/null-linux", "sha256": "aaaa"},
        key(null, "darwin_arm64"): {"download_url": "https://example/null-darwin", "sha256": "bbbb"},
        # Already checked on an earlier evaluation, so nothing is pending for it
        # and no lock command has to run.
        key(random, "linux_amd64"): {
            "download_url": "https://example/random-linux",
            "sha256": "cccc",
            "verified": True,
        },
    }

    asserts.equals(env, [null], unverified_packages(facts, [null, random], platforms))

    # One zh: set covers every platform, so a single lock verifies both of
    # null's recorded packages.
    verify_provider_hashes(
        facts,
        [null],
        platforms,
        {"registry.terraform.io/hashicorp/null@3.1.1": {"aaaa": True, "bbbb": True, "eeee": True}},
        True,
    )
    asserts.true(env, facts[key(null, "linux_amd64")]["verified"])
    asserts.true(env, facts[key(null, "darwin_arm64")]["verified"])
    asserts.equals(env, "aaaa", facts[key(null, "linux_amd64")]["sha256"])
    asserts.equals(env, [], unverified_packages(facts, [null, random], platforms))

    # Hashes from several lock files are unioned, and neither input is mutated
    # in the process.
    from_lock = {"registry.terraform.io/hashicorp/null@3.1.1": {"dddd": True}}
    from_other_lock = {
        "registry.terraform.io/hashicorp/null@3.1.1": {"eeee": True},
        "registry.terraform.io/hashicorp/random@3.1.3": {"ffff": True},
    }
    merged = merge_provider_locks(from_lock, from_other_lock)
    asserts.equals(env, ["dddd", "eeee"], sorted(merged["registry.terraform.io/hashicorp/null@3.1.1"].keys()))
    asserts.equals(env, ["ffff"], sorted(merged["registry.terraform.io/hashicorp/random@3.1.3"].keys()))
    asserts.equals(env, {"registry.terraform.io/hashicorp/null@3.1.1": {"dddd": True}}, from_lock)

    return unittest.end(env)

_pessimistic_operator_test = unittest.make(_pessimistic_operator_test_impl)
_comparison_operators_test = unittest.make(_comparison_operators_test_impl)
_prerelease_selection_test = unittest.make(_prerelease_selection_test_impl)
_unsatisfiable_and_malformed_test = unittest.make(_unsatisfiable_and_malformed_test_impl)
_mirror_entry_test = unittest.make(_mirror_entry_test_impl)
_parse_provider_locks_test = unittest.make(_parse_provider_locks_test_impl)
_hcl_credentials_test = unittest.make(_hcl_credentials_test_impl)
_facts_and_merge_test = unittest.make(_facts_and_merge_test_impl)

def utils_test_suite(name = "utils_test"):
    unittest.suite(
        name,
        _pessimistic_operator_test,
        _comparison_operators_test,
        _prerelease_selection_test,
        _unsatisfiable_and_malformed_test,
        _mirror_entry_test,
        _parse_provider_locks_test,
        _hcl_credentials_test,
        _facts_and_merge_test,
    )
