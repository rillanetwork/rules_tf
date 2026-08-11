"""Unit tests for parsing the mirror manifest.

These run at analysis time and reach no registry: only the manifest grammar is
covered here, not the resolution that consumes it.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    ":provider_mirror.bzl",
    "mirror_manifest",
    "parse_mirror_entries",
    "provider_source_parts",
)

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

_mirror_entry_test = unittest.make(_mirror_entry_test_impl)

def provider_mirror_test_suite(name = "provider_mirror_test"):
    """Declares the mirror manifest tests.

    Args:
      name: the suite's name.
    """
    unittest.suite(
        name,
        _mirror_entry_test,
    )
