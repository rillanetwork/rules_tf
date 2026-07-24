load(
    "@rules_tf//tf/toolchains:utils.bzl",
    "download_provider_to_mirror",
    "get_sha256sum",
    "mirror_manifest",
    "parse_mirror_entries",
    "provider_source_parts",
)

def _download_impl(ctx):
    ctx.report_progress("Downloading terraform")

    parsed_entries = parse_mirror_entries(ctx.attr.mirror)
    manifest = mirror_manifest(parsed_entries)

    ctx.template(
        "BUILD",
        Label("@rules_tf//tf/toolchains/terraform:BUILD.toolchain.tpl"),
        executable = False,
        substitutions = {
            "{version}": ctx.attr.version,
            "{os}": ctx.attr.os,
            "{arch}": ctx.attr.arch,
            "{mirror_versions}": json.encode(manifest),
        },
    )

    file = "terraform_{version}_{os}_{arch}.zip".format(version = ctx.attr.version, os = ctx.attr.os, arch = ctx.attr.arch)

    url_template = "https://releases.hashicorp.com/terraform/{version}/{file}"
    url = url_template.format(version = ctx.attr.version, file = file)

    url_sha256sums_template = "https://releases.hashicorp.com/terraform/{version}/terraform_{version}_SHA256SUMS"
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
        output = "terraform",
    )

    if not res.success:
        fail("!failed to dl: ", url)

    ctx.file("mirror_versions.json", content = json.encode(manifest))

    # Fetch each provider through ctx.download_and_extract (content-addressed by
    # sha256) so its bytes land in Bazel's --repository_cache and are served
    # offline on subsequent runs. This replaces shelling out to `terraform
    # init`, whose subprocess downloads bypassed the repository cache entirely
    # and re-fetched hundreds of MB of providers on every ephemeral CI run.
    #
    # Each (source, version) is fetched independently, so multiple versions of a
    # single source coexist in the mirror -- terraform would otherwise AND their
    # required_providers constraints into an unsatisfiable set.
    if len(parsed_entries) > 0:
        for entry in parsed_entries:
            host, namespace, provider_type = provider_source_parts(entry["source"], "registry.terraform.io")
            download_provider_to_mirror(ctx, host, namespace, provider_type, entry["version"], ctx.attr.os, ctx.attr.arch)
    else:
        ctx.file("mirror/.keep", content = "")

    return

terraform_download = repository_rule(
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
    name = "terraform",
    actual = "@{toolchain_repo}//:runtime",
)
"""
