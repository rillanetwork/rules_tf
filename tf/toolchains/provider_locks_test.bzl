"""Unit tests for the lock parser and the verification pass.

These run at analysis time and reach no registry, which is the point: the lock
grammar and the fact marking are otherwise only exercised end to end by the
integration workspaces, where a regression surfaces as "the wrong thing was
mirrored" rather than as a failing assertion.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":facts.bzl", "dirhash_fact_key", "package_fact_key")
load(
    ":provider_locks.bzl",
    "collect_provider_dirhashes",
    "merge_provider_locks",
    "parse_provider_locks",
    "unverified_packages",
    "verify_provider_hashes",
)

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
    "h1:one=",
    "h1:two=",
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

    locks, dirhashes = parse_provider_locks([_LOCK_NULL, _LOCK_RANDOM, _LOCK_ONE_LINE])

    # Keyed by address and version, since a mirror may stock several versions of
    # one provider and each needs its own lock file.
    asserts.equals(env, [
        "registry.terraform.io/hashicorp/null@3.1.1",
        "registry.terraform.io/hashicorp/random@3.1.3",
        "registry.terraform.io/hashicorp/tls@4.0.4",
    ], sorted(locks.keys()))

    # Every hash on the line is taken, and the block still closes.
    asserts.equals(env, ["dddd", "eeee"], sorted(locks["registry.terraform.io/hashicorp/tls@4.0.4"].keys()))

    asserts.equals(env, ["aaaa", "bbbb"], sorted(locks["registry.terraform.io/hashicorp/null@3.1.1"].keys()))
    asserts.equals(env, ["cccc"], sorted(locks["registry.terraform.io/hashicorp/random@3.1.3"].keys()))

    asserts.equals(env, [
        "registry.terraform.io/hashicorp/null@3.1.1",
        "registry.terraform.io/hashicorp/random@3.1.3",
    ], sorted(dirhashes.keys()))
    asserts.equals(
        env,
        ["71sNUDvmiJcijsvfXpiLCz0lXIBSsEJjMxljt7hxMhw="],
        sorted(dirhashes["registry.terraform.io/hashicorp/null@3.1.1"].keys()),
    )
    asserts.equals(
        env,
        ["one=", "two="],
        sorted(dirhashes["registry.terraform.io/hashicorp/random@3.1.3"].keys()),
    )

    asserts.false(env, "registry.terraform.io/hashicorp/tls@4.0.4" in dirhashes)

    return unittest.end(env)

def _collect_dirhashes_test_impl(ctx):
    env = unittest.begin(ctx)

    null = {"host": "registry.terraform.io", "namespace": "hashicorp", "type": "null", "version": "3.1.1"}
    random = {"host": "registry.terraform.io", "namespace": "hashicorp", "type": "random", "version": "3.1.3"}
    tls = {"host": "registry.terraform.io", "namespace": "hashicorp", "type": "tls", "version": "4.0.4"}

    _, dirhashes = parse_provider_locks([_LOCK_NULL, _LOCK_RANDOM, _LOCK_ONE_LINE])

    previous = {
        dirhash_fact_key(null["host"], null["namespace"], null["type"], null["version"]): {
            "hashes": "remembered=",
        },
    }

    collected = collect_provider_dirhashes(previous, [null, random, tls], dirhashes)

    asserts.equals(
        env,
        ["71sNUDvmiJcijsvfXpiLCz0lXIBSsEJjMxljt7hxMhw=", "remembered="],
        collected["registry.terraform.io/hashicorp/null@3.1.1"],
    )
    asserts.equals(env, ["one=", "two="], collected["registry.terraform.io/hashicorp/random@3.1.3"])

    asserts.false(env, "registry.terraform.io/hashicorp/tls@4.0.4" in collected)

    asserts.equals(
        env,
        {"registry.terraform.io/hashicorp/null@3.1.1": ["remembered="]},
        collect_provider_dirhashes(previous, [null], {}),
    )

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

    # A recorded mark spares a package only when the caller leaves it out of
    # the check: passed in regardless, random is reported uncovered even
    # though an earlier evaluation marked it. This is what makes the "files"
    # mode a standing assertion rather than a one-shot check.
    asserts.equals(env, [random], verify_provider_hashes(
        facts,
        [random],
        platforms,
        {},
    ))

    # One zh: set covers every platform, so a single lock verifies both of
    # null's recorded packages.
    asserts.equals(env, [], verify_provider_hashes(
        facts,
        [null],
        platforms,
        {"registry.terraform.io/hashicorp/null@3.1.1": {"aaaa": True, "bbbb": True, "eeee": True}},
    ))
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

_parse_provider_locks_test = unittest.make(_parse_provider_locks_test_impl)
_collect_dirhashes_test = unittest.make(_collect_dirhashes_test_impl)
_facts_and_merge_test = unittest.make(_facts_and_merge_test_impl)

def provider_locks_test_suite(name = "provider_locks_test"):
    """Declares the lock parsing and verification tests.

    Args:
      name: the suite's name.
    """
    unittest.suite(
        name,
        _parse_provider_locks_test,
        _collect_dirhashes_test,
        _facts_and_merge_test,
    )
