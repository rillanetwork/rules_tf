"""Unit tests for the module manifest grammar and closure extraction.

These run at analysis time and reach no source: the resolution itself needs a
terraform binary and the network, so only what surrounds it is covered here.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    ":module_mirror.bzl",
    "closure_from_manifest",
    "is_registry_source",
    "module_manifest",
    "module_store_key",
    "parse_module_entries",
)

def _registry_source_test_impl(ctx):
    env = unittest.begin(ctx)

    # Three parts, or four with a host, and nothing that marks a scheme.
    asserts.true(env, is_registry_source("terraform-aws-modules/vpc/aws"))
    asserts.true(env, is_registry_source("app.terraform.io/acme/vpc/aws"))
    asserts.true(env, is_registry_source("tf.example.com:8443/acme/vpc/aws"))

    # A //subdir addresses a directory inside the package, so it is not part of
    # the address's shape. Missing this left the version glued to the source and
    # terraform tried to read a directory named after the constraint.
    asserts.true(env, is_registry_source("terraform-aws-modules/iam/aws//modules/iam-policy"))
    asserts.true(env, is_registry_source("app.terraform.io/acme/iam/aws//modules/policy"))

    # Every other getter carries a marker the registry grammar cannot.
    asserts.false(env, is_registry_source("git::https://github.com/acme/mod.git?ref=v1"))
    asserts.false(env, is_registry_source("https://example.com/mod.zip"))
    asserts.false(env, is_registry_source("s3::https://bucket.s3.amazonaws.com/mod.zip"))
    asserts.false(env, is_registry_source("git@github.com:acme/mod.git"))

    # Shaped like a registry address, but terraform's getter detectors claim
    # these hosts first, so they are git sources and take no version.
    asserts.false(env, is_registry_source("github.com/acme/mod"))
    asserts.false(env, is_registry_source("bitbucket.org/acme/mod"))
    asserts.false(env, is_registry_source("./local"))
    asserts.false(env, is_registry_source("../sibling"))
    asserts.false(env, is_registry_source("/absolute/path"))

    # Wrong arity either way.
    asserts.false(env, is_registry_source("acme/vpc"))
    asserts.false(env, is_registry_source("a/b/c/d/e"))

    return unittest.end(env)

def _module_entry_test_impl(ctx):
    env = unittest.begin(ctx)

    parsed = parse_module_entries([
        "terraform-aws-modules/vpc/aws@5.19.0",
        "terraform-aws-modules/iam/aws@~> 5.0",
        "app.terraform.io/acme/vpc/aws@1.0.0",
        "terraform-aws-modules/iam/aws//modules/iam-policy@~> 5.0",
        # A getter source pins itself, so no version is split off it.
        "git::https://github.com/acme/mod.git?ref=v1.2.0",
        "git@github.com:acme/mod.git",
    ])

    asserts.equals(
        env,
        [
            "terraform-aws-modules/vpc/aws",
            "terraform-aws-modules/iam/aws",
            "app.terraform.io/acme/vpc/aws",
            "terraform-aws-modules/iam/aws//modules/iam-policy",
            "git::https://github.com/acme/mod.git?ref=v1.2.0",
            "git@github.com:acme/mod.git",
        ],
        [e["source"] for e in parsed],
    )
    asserts.equals(
        env,
        ["5.19.0", "~> 5.0", "1.0.0", "~> 5.0", "", ""],
        [e["version"] for e in parsed],
    )

    # The manifest spelling round-trips, so a recorded entry can be compared
    # against a declared one without re-parsing either.
    asserts.equals(
        env,
        [
            "terraform-aws-modules/vpc/aws@5.19.0",
            "terraform-aws-modules/iam/aws@~> 5.0",
            "app.terraform.io/acme/vpc/aws@1.0.0",
            "terraform-aws-modules/iam/aws//modules/iam-policy@~> 5.0",
            "git::https://github.com/acme/mod.git?ref=v1.2.0",
            "git@github.com:acme/mod.git",
        ],
        module_manifest(parsed),
    )

    return unittest.end(env)

def _store_key_test_impl(ctx):
    env = unittest.begin(ctx)

    # One flat segment, and distinct for every coordinate that names distinct
    # content: the store is shared across every root module that calls it.
    asserts.true(
        env,
        module_store_key("terraform-aws-modules/vpc/aws", "5.19.0").startswith(
            "terraform-aws-modules_vpc_aws_5.19.0-",
        ),
    )
    asserts.true(
        env,
        module_store_key("terraform-aws-modules/vpc/aws", "5.19.0") !=
        module_store_key("terraform-aws-modules/vpc/aws", "5.20.0"),
    )

    # Flattening separators is lossy, so coordinates that differ only in a
    # separator must still land in different directories.
    asserts.true(
        env,
        module_store_key("acme/mod", "1.0.0") != module_store_key("acme_mod", "1.0.0"),
    )
    asserts.true(
        env,
        module_store_key("a/b/c", "") != module_store_key("a:b:c", ""),
    )

    key = module_store_key("git::https://github.com/acme/mod.git?ref=v1", "")
    for ch in ["/", ":", "?", "="]:
        asserts.false(env, ch in key, "store key must be one path segment, got %s" % key)

    return unittest.end(env)

# Captured verbatim from a real `terraform get` over three entries batched into
# one synthetic root: a registry module that calls registry modules of its own,
# a registry module addressed with a //subdir, and a git source. It is the
# contract this parser is written against, so it is recorded rather than
# hand-written.
_REAL_MANIFEST = {
    "Modules": [
        {"Key": "", "Source": "", "Dir": "."},
        {
            "Key": "m0",
            "Source": "registry.terraform.io/cloudposse/vpc/aws",
            "Version": "2.1.1",
            "Dir": ".terraform/modules/m0",
        },
        {
            "Key": "m0.label",
            "Source": "registry.terraform.io/cloudposse/label/null",
            "Version": "0.25.0",
            "Dir": ".terraform/modules/m0.label",
        },
        {
            "Key": "m0.this",
            "Source": "registry.terraform.io/cloudposse/label/null",
            "Version": "0.25.0",
            "Dir": ".terraform/modules/m0.this",
        },
        {
            "Key": "m1",
            "Source": "registry.terraform.io/terraform-aws-modules/iam/aws//modules/iam-policy",
            "Version": "5.60.0",
            "Dir": ".terraform/modules/m1/modules/iam-policy",
        },
        {
            "Key": "m2",
            "Source": "git::https://github.com/terraform-aws-modules/terraform-aws-security-group.git?ref=v5.1.0",
            "Dir": ".terraform/modules/m2",
        },
    ],
}

def _closure_test_impl(ctx):
    env = unittest.begin(ctx)

    # A transitive closure comes back flat, keyed by call path relative to the
    # declared entry, with the entry itself under the empty key.
    m0 = closure_from_manifest(_REAL_MANIFEST, "m0")
    asserts.equals(env, ["", "label", "this"], [m["key"] for m in m0])
    asserts.equals(env, ["2.1.1", "0.25.0", "0.25.0"], [m["version"] for m in m0])

    # Neither the synthetic root nor a sibling entry's subtree leaks in.
    asserts.equals(env, 3, len(m0))

    # A //subdir address installs the package and points within it, so the
    # subdirectory is recovered from Dir rather than parsed out of the source.
    m1 = closure_from_manifest(_REAL_MANIFEST, "m1")
    asserts.equals(env, [""], [m["key"] for m in m1])
    asserts.equals(env, "modules/iam-policy", m1[0]["subdir"])
    asserts.equals(env, "5.60.0", m1[0]["version"])

    # A getter source carries its own ref and reports no version.
    m2 = closure_from_manifest(_REAL_MANIFEST, "m2")
    asserts.equals(env, "", m2[0]["version"])
    asserts.equals(env, "", m2[0]["subdir"])

    # "m0" must not swallow "m0.label" by bare prefix, nor a hypothetical "m00".
    asserts.equals(env, 0, len(closure_from_manifest(_REAL_MANIFEST, "m00")))

    # Identical coordinates reached by two call paths share one store entry,
    # which is what the mirror dedupes on where terraform does not.
    asserts.equals(
        env,
        module_store_key(m0[1]["source"], m0[1]["version"]),
        module_store_key(m0[2]["source"], m0[2]["version"]),
    )

    return unittest.end(env)

_registry_source_test = unittest.make(_registry_source_test_impl)
_closure_test = unittest.make(_closure_test_impl)
_module_entry_test = unittest.make(_module_entry_test_impl)
_store_key_test = unittest.make(_store_key_test_impl)

def module_mirror_test_suite(name = "module_mirror_test"):
    """Declares the module manifest tests.

    Args:
      name: the suite's name.
    """
    unittest.suite(
        name,
        _registry_source_test,
        _module_entry_test,
        _store_key_test,
        _closure_test,
    )
