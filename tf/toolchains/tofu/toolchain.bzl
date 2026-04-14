load(
    "@rules_tf//tf/toolchains:utils.bzl",
    "get_sha256sum",
    "mirror_manifest",
    "parse_mirror_entries",
    "render_mirror_versions_tf_jsons",
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
        url = [ url_sha256sums],
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

    versions_tf_jsons = render_mirror_versions_tf_jsons(parsed_entries)
    if len(versions_tf_jsons) > 0:
        for vtf in versions_tf_jsons:
            ctx.file("versions.tf.json", content = json.encode(vtf))
            res = ctx.execute([
                "bash",
                "-c",
                "mkdir -p mirror; tofu/tofu providers mirror ./mirror > /dev/null",
            ])
            if res.return_code != 0:
                fail("failed to populate tofu provider mirror:\n" + res.stderr)
        ctx.delete("versions.tf.json")
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
