load(
    "@rules_tf//tf/toolchains:utils.bzl",
    "download_providers",
    "get_sha256sum",
)

def _download_impl(ctx):
    ctx.report_progress("Downloading tofu")

    ctx.template(
        "BUILD",
        Label("@rules_tf//tf/toolchains/tofu:BUILD.toolchain.tpl"),
        executable = False,
        substitutions = {
            "{version}": ctx.attr.version,
            "{os}": ctx.attr.os,
            "{arch}": ctx.attr.arch,
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
        content = json.encode(["%s@%s" % (p["source"], p["version"]) for p in packages]),
    )

tofu_download = repository_rule(
    implementation = _download_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "os": attr.string(mandatory = True),
        "arch": attr.string(mandatory = True),
        "providers_json": attr.string(
            mandatory = True,
            doc = "JSON list of the providers to mirror, each already resolved by the " +
                  "module extension to a concrete version, download_url and sha256. " +
                  "Recorded verbatim in MODULE.bazel.lock, which is what makes the " +
                  "resolved mirror reviewable.",
        ),
    },
)

DECLARE_TOOLCHAIN_CHUNK = """
tf_toolchain(
   name = "{toolchain_repo}_toolchain_impl",
   tf = "@{toolchain_repo}//:runtime",
   mirror = "@{toolchain_repo}//:mirror",
   mirror_versions = {mirror_versions},
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

alias(
    name = "tofu",
    actual = "@{toolchain_repo}//:runtime",
)
"""
