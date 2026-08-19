"""Repository rule generating the BUILD file that declares every tf toolchain."""

load("@rules_tf//tf/toolchains:registry.bzl", "DEFAULT_REGISTRY")
load("@rules_tf//tf/toolchains:tf_toolchain.bzl", _tf_toolchain = "tf_toolchain")
load("@rules_tf//tf/toolchains/terraform:toolchain.bzl", _terraform_declare_toolchain_chunk = "DECLARE_TOOLCHAIN_CHUNK")
load("@rules_tf//tf/toolchains/tfdoc:toolchain.bzl", _tfdoc_declare_toolchain_chunk = "DECLARE_TOOLCHAIN_CHUNK", _tfdoc_toolchain = "tfdoc_toolchain")
load("@rules_tf//tf/toolchains/tflint:toolchain.bzl", _tflint_declare_toolchain_chunk = "DECLARE_TOOLCHAIN_CHUNK", _tflint_toolchain = "tflint_toolchain")
load("@rules_tf//tf/toolchains/tofu:toolchain.bzl", _tofu_declare_toolchain_chunk = "DECLARE_TOOLCHAIN_CHUNK")

platforms = {
    "linux_amd64": {
        "exec_compatible_with": [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
        "target_compatible_with": [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
    },
    "linux_arm64": {
        "exec_compatible_with": [
            "@platforms//os:linux",
            "@platforms//cpu:arm64",
        ],
        "target_compatible_with": [
            "@platforms//os:linux",
            "@platforms//cpu:arm64",
        ],
    },
    "darwin_amd64": {
        "exec_compatible_with": [
            "@platforms//os:osx",
            "@platforms//cpu:x86_64",
        ],
        "target_compatible_with": [
            "@platforms//os:osx",
            "@platforms//cpu:x86_64",
        ],
    },
    "darwin_arm64": {
        "exec_compatible_with": [
            "@platforms//os:osx",
            "@platforms//cpu:aarch64",
        ],
        "target_compatible_with": [
            "@platforms//os:osx",
            "@platforms//cpu:aarch64",
        ],
    },
}

def detect_host_platform(ctx):
    """Returns the host's (os, arch) pair, in the spelling terraform releases use.

    Args:
      ctx: a module_ctx or repository_ctx, for its `os` field.

    Returns:
      An (os, arch) tuple, e.g. ("darwin", "arm64").
    """
    os = ctx.os.name
    if os == "mac os x":
        os = "darwin"
    elif os.startswith("windows"):
        os = "windows"

    arch = ctx.os.arch
    if arch == "aarch64":
        arch = "arm64"
    elif arch == "x86_64":
        arch = "amd64"

    return os, arch

tf_toolchain = _tf_toolchain
tfdoc_toolchain = _tfdoc_toolchain
tflint_toolchain = _tflint_toolchain

def _render_mirror_versions(joined):
    if joined == "":
        return "[]"
    return "[" + ", ".join(['"%s"' % v for v in joined.split(",")]) + "]"

def _render_mirror_hashes(encoded):
    """Renders a repo's hash table as the dict literal the BUILD chunk carries.

    Args:
      encoded: the table as JSON, keyed "<host>/<ns>/<type>@<version>".

    Returns:
      A Starlark dict literal, sorted so the generated BUILD file is stable.
    """
    if encoded == "":
        return "{}"

    hashes = json.decode(encoded)
    return "{" + ", ".join([
        '"%s": "%s"' % (key, hashes[key])
        for key in sorted(hashes)
    ]) + "}"

def _tf_toolchains_impl(ctx):
    content = """
load("@rules_tf//tf:toolchains.bzl", "platforms")
load("@rules_tf//tf:toolchains.bzl", "tfdoc_toolchain")
load("@rules_tf//tf:toolchains.bzl", "tflint_toolchain")
load("@rules_tf//tf:toolchains.bzl", "tf_toolchain")

package(default_visibility = ["//visibility:public"])
    """

    for repo in ctx.attr.tflint_repos:
        chunk = _tflint_declare_toolchain_chunk.format(
            toolchain_repo = repo,
            os = ctx.attr.os,
            arch = ctx.attr.arch,
        )
        content += chunk

    for repo in ctx.attr.tfdoc_repos:
        chunk = _tfdoc_declare_toolchain_chunk.format(
            toolchain_repo = repo,
            os = ctx.attr.os,
            arch = ctx.attr.arch,
        )
        content += chunk

    # Constraints are resolved in the module extension, so it knows the
    # concrete manifest and passes it straight down here.
    for repo in ctx.attr.terraform_repos:
        chunk = _terraform_declare_toolchain_chunk.format(
            toolchain_repo = repo,
            os = ctx.attr.os,
            arch = ctx.attr.arch,
            mirror_versions = _render_mirror_versions(ctx.attr.repo_mirrors.get(repo, "")),
            mirror_hashes = _render_mirror_hashes(ctx.attr.repo_hashes.get(repo, "")),
            default_registry = DEFAULT_REGISTRY[False],
        )
        content += chunk

    for repo in ctx.attr.tofu_repos:
        chunk = _tofu_declare_toolchain_chunk.format(
            toolchain_repo = repo,
            os = ctx.attr.os,
            arch = ctx.attr.arch,
            mirror_versions = _render_mirror_versions(ctx.attr.repo_mirrors.get(repo, "")),
            mirror_hashes = _render_mirror_hashes(ctx.attr.repo_hashes.get(repo, "")),
            default_registry = DEFAULT_REGISTRY[True],
        )
        content += chunk

    ctx.file("BUILD.bazel", content, executable = False)

tf_toolchains = repository_rule(
    implementation = _tf_toolchains_impl,
    attrs = {
        "tflint_repos": attr.string_list(mandatory = True),
        "tfdoc_repos": attr.string_list(mandatory = True),
        "terraform_repos": attr.string_list(mandatory = True),
        "tofu_repos": attr.string_list(mandatory = True),
        "repo_mirrors": attr.string_dict(
            doc = "Per-repo resolved manifest: repo name -> comma-joined 'source@version' entries.",
        ),
        "repo_hashes": attr.string_dict(
            doc = "Per-repo package hashes: repo name -> JSON of " +
                  "'<host>/<ns>/<type>@<version>' -> comma-joined, scheme-prefixed hashes.",
        ),
        "os": attr.string(mandatory = True),
        "arch": attr.string(mandatory = True),
    },
)
