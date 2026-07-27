load(
    "@rules_tf//tf/toolchains:utils.bzl",
    "download_providers_to_mirror",
    "get_sha256sum",
    "mirror_manifest",
    "parse_mirror_entries",
)

def _download_impl(ctx):
    ctx.report_progress("Downloading tofu")

    parsed_entries = parse_mirror_entries(ctx.attr.mirror)
    manifest = mirror_manifest(parsed_entries)

    ctx.template(
        "BUILD",
        Label("@rules_tf//tf/toolchains/tofu:BUILD.toolchain.tpl"),
        executable = False,
        substitutions = {
            "{version}": ctx.attr.version,
            "{os}": ctx.attr.os,
            "{arch}": ctx.attr.arch,
            "{mirror_versions}": json.encode(manifest),
        },
    )

    file = "tofu_{version}_{os}_{arch}.zip".format(version = ctx.attr.version, os = ctx.attr.os, arch = ctx.attr.arch)

    url_template = "https://github.com/opentofu/opentofu/releases/download/v{version}/{file}"
    url = url_template.format(version = ctx.attr.version, file = file)

    url_sha256sums_template = "https://github.com/opentofu/opentofu/releases/download/v{version}/tofu_{version}_SHA256SUMS"
    url_sha256sums = url_sha256sums_template.format(version = ctx.attr.version)

    ctx.download(
        url = [url_sha256sums],
        output = "sha256sums",
    )

    data = ctx.read("sha256sums")
    sha256sum = get_sha256sum(data, file)
    if sha256sum == None or sha256sum == "":
        fail("Could not find sha256sum for file {}".format(file))

    res = ctx.download_and_extract(
        url = url,
        sha256 = sha256sum,
        type = "zip",
        output = "tofu",
    )

    if not res.success:
        fail("!failed to dl: ", url)

    ctx.file("mirror_versions.json", content = json.encode(manifest))

    # See terraform/toolchain.bzl for the rationale: fetching each provider
    # through ctx.download_and_extract routes its bytes through Bazel's
    # --repository_cache so they are served offline on subsequent runs, and the
    # unpacked layout lets downstream init symlink plugins instead of extracting
    # full copies per target. tofu resolves providers from its own registry.
    if len(parsed_entries) > 0:
        download_providers_to_mirror(ctx, parsed_entries, "registry.opentofu.org", ctx.attr.os, ctx.attr.arch)
    else:
        ctx.file("mirror/.keep", content = "")

    return

tofu_download = repository_rule(
    implementation = _download_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "os": attr.string(mandatory = True),
        "arch": attr.string(mandatory = True),
        "mirror": attr.string_list(mandatory = True),
    },
)

DECLARE_TOOLCHAIN_CHUNK = """
tf_toolchain(
   name = "{toolchain_repo}_toolchain_impl",
   tf = "@{toolchain_repo}//:runtime",
   mirror = "@{toolchain_repo}//:mirror",
   mirror_versions = {mirror_versions},
)

toolchain(
  name = "{toolchain_repo}_toolchain",
  exec_compatible_with = platforms["{os}_{arch}"]["exec_compatible_with"],
  target_compatible_with = platforms["{os}_{arch}"]["target_compatible_with"],
  toolchain = ":{toolchain_repo}_toolchain_impl",
  toolchain_type = "@rules_tf//:tf_toolchain_type",
  visibility = ["//visibility:public"],
)

alias(
    name = "tofu",
    actual = "@{toolchain_repo}//:runtime",
)
"""
