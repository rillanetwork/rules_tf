"""The download repository shared by the terraform and tofu toolchains.

The two differ only in what they are called and where their releases live, so
the attributes, the implementation and the BUILD chunk that declares the
toolchain are all written once here and parameterised by tool.
"""

load(":provider_mirror.bzl", "download_providers", "mirror_manifest")

TF_DOWNLOAD_ATTRS = {
    "version": attr.string(mandatory = True),
    "os": attr.string(mandatory = True),
    "arch": attr.string(mandatory = True),
    "tool_sha256": attr.string(
        mandatory = True,
        doc = "sha256 of the tool's release archive for this platform, resolved by the " +
              "module extension from the release's SHA256SUMS. Passed in rather than " +
              "fetched so that every download this repository makes is pinned by an " +
              "attribute.",
    ),
    "providers_json": attr.string(
        mandatory = True,
        doc = "JSON list of the providers to mirror, each already resolved by the " +
              "module extension to a concrete version, download_url and sha256. " +
              "The extension is reproducible, so this is not itself recorded in " +
              "MODULE.bazel.lock; the facts it was derived from are.",
    ),
    "resolve_errors": attr.string(
        default = "[]",
        doc = "JSON list of the mirror entries the module extension could not resolve. " +
              "Reported here rather than there so that a registry the extension cannot " +
              "reach fails only the builds that need the mirror.",
    ),
}

def tf_download_impl(ctx, tool, build_tpl, url_template):
    """Shared implementation of the terraform and tofu download repository rules.

    The two differ only in what they are called and where their releases live.

    Args:
      ctx: the download repository's `repository_ctx`.
      tool: the tool's name, which names both its archive and its output directory.
      build_tpl: Label of the toolchain BUILD template to instantiate.
      url_template: release archive URL, taking `{version}` and `{file}`.

    Returns:
      A `repo_metadata` marking the repository reproducible.
    """
    resolve_errors = json.decode(ctx.attr.resolve_errors)
    if len(resolve_errors) > 0:
        fail("the provider mirror could not be resolved:\n  " + "\n  ".join(resolve_errors))

    ctx.report_progress("Downloading %s" % tool)

    ctx.template(
        "BUILD",
        build_tpl,
        executable = False,
        substitutions = {
            "{version}": ctx.attr.version,
            "{os}": ctx.attr.os,
            "{arch}": ctx.attr.arch,
        },
    )

    file = "{tool}_{version}_{os}_{arch}.zip".format(
        tool = tool,
        version = ctx.attr.version,
        os = ctx.attr.os,
        arch = ctx.attr.arch,
    )
    url = url_template.format(version = ctx.attr.version, file = file)

    res = ctx.download_and_extract(
        url = url,
        sha256 = ctx.attr.tool_sha256,
        type = "zip",
        output = tool,
    )

    if not res.success:
        fail("!failed to dl: ", url)

    # Every coordinate was resolved by the module extension, so this reaches no
    # registry: known URLs against known hashes, which makes each package
    # content-addressed for --repository_cache and lets a warm cache serve the
    # whole mirror offline.
    #
    # Each (source, version) is fetched independently, so multiple versions of a
    # single source coexist in the mirror -- terraform would otherwise AND their
    # required_providers constraints into an unsatisfiable set.
    packages = json.decode(ctx.attr.providers_json)
    download_providers(ctx, packages, ctx.attr.os, ctx.attr.arch)

    # The manifest as it actually landed, for a build to inspect. Constraints
    # are already resolved by this point, so these are all concrete pins.
    ctx.file(
        "mirror_versions.json",
        content = json.encode(mirror_manifest(packages)),
    )

    # reproducible: the contents are a function of the attributes alone. Every
    # provider package is fetched against a sha256 the extension resolved and
    # passed in, and the tool's own archive against the tool_sha256 attribute,
    # resolved the same way. That makes the whole ~750MB directory eligible for the repo
    # contents cache, so a cold output base links it rather than downloading
    # and extracting it again -- which the repository cache alone cannot do,
    # since it holds the archives rather than the unpacked mirror.
    return ctx.repo_metadata(reproducible = True)

_DECLARE_TOOLCHAIN_CHUNK = """
tf_toolchain(
   name = "{toolchain_repo}_toolchain_impl",
   tf = "@{toolchain_repo}//:runtime",
   mirror_files = "@{toolchain_repo}//:mirror_files",
   mirror_versions_json = "@{toolchain_repo}//:mirror_versions.json",
   mirror_versions = {mirror_versions},
   mirror_hashes = {mirror_hashes},
   default_registry = "{default_registry}",
)

toolchain(
  name = "{toolchain_repo}_toolchain",
  exec_compatible_with = platforms["{os}_{arch}"]["exec_compatible_with"],
  target_compatible_with = platforms["{os}_{arch}"]["target_compatible_with"],
  toolchain = ":{toolchain_repo}_toolchain_impl",
  toolchain_type = "@rules_tf//:tf_toolchain_type",
  visibility = ["//visibility:public"],
)
"""

def tf_declare_toolchain_chunk(tool):
    """The BUILD chunk declaring one tf toolchain, aliased under the tool's name.

    Args:
      tool: the tool's name, which the alias is given.

    Returns:
      The chunk, still carrying the placeholders `tf_toolchains` substitutes.
    """
    return _DECLARE_TOOLCHAIN_CHUNK + """
alias(
    name = "%s",
    actual = "@{toolchain_repo}//:runtime",
)
""" % tool
