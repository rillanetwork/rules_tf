"""Unit tests for the generated `.terraform.lock.hcl`.

The document these render is what a module's `init` is handed, and the two ways
it can go wrong -- naming a version a module's constraints exclude, or naming
one address twice -- both fail `init` outright rather than degrading. So the
selection is asserted here rather than only end to end in the integration
workspaces.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    ":provider_lockfile.bzl",
    "declared_constraints",
    "module_lock_document",
    "parse_mirror_hashes",
    "select_lock_versions",
)

_REGISTRY = "registry.terraform.io"

# One provider stocked once, one stocked at two versions -- the case a lock file
# cannot represent without choosing. Hashes arrive scheme-prefixed, and a version
# may carry `h1:` dirhashes as well as the per-platform `zh:` package sha256s.
_MIRROR_HASHES = {
    "registry.terraform.io/hashicorp/null@3.2.2": "zh:aaaa,zh:bbbb",
    "registry.terraform.io/hashicorp/aws@5.0.0": "zh:cccc",
    "registry.terraform.io/hashicorp/aws@6.1.0": "h1:ffff=,zh:dddd,zh:eeee",
}

def _declared(source, version = None):
    config = {"source": source}
    if version:
        config["version"] = version
    return {"p": config}

def _parse_and_constraints_test_impl(ctx):
    env = unittest.begin(ctx)

    by_address = parse_mirror_hashes(_MIRROR_HASHES)
    asserts.equals(env, [
        "registry.terraform.io/hashicorp/aws",
        "registry.terraform.io/hashicorp/null",
    ], sorted(by_address))
    asserts.equals(env, ["5.0.0", "6.1.0"], sorted(by_address["registry.terraform.io/hashicorp/aws"]))
    asserts.equals(env, ["zh:aaaa", "zh:bbbb"], by_address["registry.terraform.io/hashicorp/null"]["3.2.2"])

    # An unqualified source is read against the default registry, and a builtin
    # provider -- which declares no version -- is present with an empty
    # constraint list: being declared at all is what admits an address to the
    # lock file, and the constraints only decide which version it names.
    constraints = declared_constraints(
        [
            _declared("hashicorp/aws", "~> 5.0"),
            _declared("registry.terraform.io/hashicorp/aws", ">= 5.1"),
            _declared("terraform.io/builtin/terraform"),
        ],
        _REGISTRY,
    )
    asserts.equals(env, [
        "registry.terraform.io/hashicorp/aws",
        "terraform.io/builtin/terraform",
    ], sorted(constraints))
    asserts.equals(env, ["~> 5.0", ">= 5.1"], constraints["registry.terraform.io/hashicorp/aws"])
    asserts.equals(env, [], constraints["terraform.io/builtin/terraform"])

    return unittest.end(env)

def _select_versions_test_impl(ctx):
    env = unittest.begin(ctx)

    by_address = parse_mirror_hashes(_MIRROR_HASHES)
    aws = "registry.terraform.io/hashicorp/aws"
    null = "registry.terraform.io/hashicorp/null"

    # A source nothing declares is never named, however many versions the mirror
    # stocks: a shared mirror holds other modules' providers, and init prunes a
    # block the configuration does not require -- rewriting the file to do it.
    asserts.equals(env, {}, select_lock_versions(by_address, {}))

    # Declared with no constraint, a source stocked once is named: nothing
    # chooses between versions, and one stocked version is all init could
    # install. Stocked twice it is left out until something does choose.
    asserts.equals(env, {null: "3.2.2"}, select_lock_versions(by_address, {null: [], aws: []}))

    # The module tree's constraints are ANDed, as terraform ANDs them across a
    # configuration.
    asserts.equals(env, "6.1.0", select_lock_versions(by_address, {aws: ["~> 6.0"]})[aws])
    asserts.equals(env, "5.0.0", select_lock_versions(by_address, {aws: [">= 4.0", "< 6.0"]})[aws])

    # Constraints no mirrored version satisfies leave the provider unnamed:
    # terraform then reports the conflict itself, against the whole
    # configuration, rather than against a version this file picked.
    asserts.false(env, aws in select_lock_versions(by_address, {aws: [">= 7.0"]}))

    # That holds for a source stocked once as well: a lock file naming it would
    # turn "no release matches" into the murkier "locked provider does not
    # match configured version constraint".
    asserts.false(env, null in select_lock_versions(by_address, {null: ["~> 4.0"]}))
    asserts.equals(env, "3.2.2", select_lock_versions(by_address, {null: ["~> 3.2"]})[null])

    # A prerelease is only ever named by an exact pin, which is how terraform
    # treats one too.
    prerelease = parse_mirror_hashes({"registry.terraform.io/hashicorp/null@3.2.4-alpha.2": "zh:ffff"})
    asserts.equals(env, "3.2.4-alpha.2", select_lock_versions(prerelease, {null: ["3.2.4-alpha.2"]})[null])
    asserts.false(env, null in select_lock_versions(prerelease, {null: [">= 3.0"]}))

    return unittest.end(env)

def _render_document_test_impl(ctx):
    env = unittest.begin(ctx)

    document = module_lock_document(
        _MIRROR_HASHES,
        [_declared("hashicorp/aws", "~> 6.0"), _declared("hashicorp/null")],
        _REGISTRY,
    )

    # One block per declared address, every platform's hash in the set, and
    # versions the declaration excluded left out entirely.
    asserts.equals(env, 1, document.count("provider \"registry.terraform.io/hashicorp/aws\""))
    asserts.equals(env, 1, document.count("provider \"registry.terraform.io/hashicorp/null\""))
    asserts.true(env, "version = \"6.1.0\"" in document)
    asserts.false(env, "5.0.0" in document)
    asserts.true(env, "\"zh:dddd\"" in document)
    asserts.true(env, "\"zh:eeee\"" in document)
    asserts.true(env, "\"zh:aaaa\"" in document)

    # Both schemes are emitted from the one set, sorted -- which puts the h1:
    # dirhash first, as terraform writes it. Without one, init recomputes the
    # dirhash for the running platform and rewrites the file it was handed.
    asserts.true(env, "\"h1:ffff=\"" in document)
    aws_block = document.split("provider \"registry.terraform.io/hashicorp/aws\"")[1]
    asserts.true(env, aws_block.index("\"h1:ffff=\"") < aws_block.index("\"zh:dddd\""))

    # A mirror stocking nothing the module declares produces no document at all,
    # rather than one init would only prune.
    asserts.equals(env, "", module_lock_document(_MIRROR_HASHES, [], _REGISTRY))

    # An empty mirror produces no document rather than an empty one, so the
    # caller can leave init alone.
    asserts.equals(env, "", module_lock_document({}, [], _REGISTRY))

    return unittest.end(env)

_parse_and_constraints_test = unittest.make(_parse_and_constraints_test_impl)
_select_versions_test = unittest.make(_select_versions_test_impl)
_render_document_test = unittest.make(_render_document_test_impl)

def provider_lockfile_test_suite(name = "provider_lockfile_test"):
    """Declares the lock file generation tests.

    Args:
      name: the suite's name.
    """
    unittest.suite(
        name,
        _parse_and_constraints_test,
        _select_versions_test,
        _render_document_test,
    )
