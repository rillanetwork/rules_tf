"""Unit tests for reading registry credentials out of a terraform CLI config.

These run at analysis time and reach no registry: only the HCL subset parser
and the URL reference resolver are covered, not the lookup that decides which
file to read.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":registry.bzl", "hcl_credentials_token", "resolve_url")

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

def _resolve_url_test_impl(ctx):
    env = unittest.begin(ctx)

    discovery = "https://registry.example/.well-known/terraform.json"

    # An absolute reference passes through untouched, query and all.
    asserts.equals(
        env,
        "https://elsewhere.example/v1/providers/?sig=abc",
        resolve_url(discovery, "https://elsewhere.example/v1/providers/?sig=abc"),
    )

    # Host-relative: resolved against the host root.
    asserts.equals(
        env,
        "https://registry.example/v1/providers/",
        resolve_url(discovery, "/v1/providers/"),
    )

    # Document-relative: resolved against the document's directory, which for
    # a discovery document means under /.well-known/.
    asserts.equals(
        env,
        "https://registry.example/.well-known/v1/providers/",
        resolve_url(discovery, "v1/providers/"),
    )

    # Scheme-relative adopts the base's scheme.
    asserts.equals(
        env,
        "https://cdn.example/providers/",
        resolve_url(discovery, "//cdn.example/providers/"),
    )

    # Dot-segments climb out of the request path, the shape a registry uses to
    # point a download at a sibling tree. The reference's query rides along.
    meta = "https://registry.example/v1/providers/acme/widget/1.0.0/download/linux/amd64"
    asserts.equals(
        env,
        "https://registry.example/v1/providers/acme/widget/packages/widget.zip?Expires=900",
        resolve_url(meta, "../../../packages/widget.zip?Expires=900"),
    )

    # ".." cannot climb past the root, and a bare host still resolves.
    asserts.equals(env, "https://h.example/x", resolve_url("https://h.example/a/", "../../x"))
    asserts.equals(env, "https://h.example/x", resolve_url("https://h.example", "x"))

    return unittest.end(env)

_hcl_credentials_test = unittest.make(_hcl_credentials_test_impl)
_resolve_url_test = unittest.make(_resolve_url_test_impl)

def registry_test_suite(name = "registry_test"):
    """Declares the registry credential and URL resolution tests.

    Args:
      name: the suite's name.
    """
    unittest.suite(
        name,
        _hcl_credentials_test,
        _resolve_url_test,
    )
