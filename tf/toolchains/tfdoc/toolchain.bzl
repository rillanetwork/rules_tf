"""Downloads a terraform-docs release and declares its toolchain."""

# terraform-docs joins the platform with dashes and prefixes the version with a
# 'v', unlike every other tool this ruleset downloads.
ARCHIVE_TEMPLATE = "terraform-docs-v{version}-{os}-{arch}.tar.gz"

URL_TEMPLATE = "https://github.com/terraform-docs/terraform-docs/releases/download/v{version}/{file}"

SHA256SUMS_TEMPLATE = "https://github.com/terraform-docs/terraform-docs/releases/download/v{version}/terraform-docs-v{version}.sha256sum"

TfdocInfo = provider(
    doc = "Information about how to invoke tfdoc.",
    fields = ["tfdoc", "config", "deps"],
)

def _tfdoc_toolchain_impl(ctx):
    toolchain_info = platform_common.ToolchainInfo(
        runtime = TfdocInfo(
            tfdoc = ctx.file.tfdoc,
            config = ctx.file.config,
            deps = [
                ctx.file.config,
                ctx.file.tfdoc,
            ],
        ),
    )
    return [toolchain_info]

tfdoc_toolchain = rule(
    implementation = _tfdoc_toolchain_impl,
    attrs = {
        "tfdoc": attr.label(
            mandatory = True,
            allow_single_file = True,
            executable = True,
            cfg = "target",
        ),
        "config": attr.label(
            mandatory = True,
            allow_single_file = True,
            cfg = "target",
        ),
    },
)

def _tfdoc_download_impl(ctx):
    resolve_errors = json.decode(ctx.attr.resolve_errors)
    if len(resolve_errors) > 0:
        fail("the tfdoc toolchain could not be resolved:\n  " + "\n  ".join(resolve_errors))

    ctx.report_progress("Downloading tfdoc")

    ctx.template(
        "BUILD",
        Label("@rules_tf//tf/toolchains/tfdoc:BUILD.toolchain.tpl"),
        executable = False,
        substitutions = {
            "{version}": ctx.attr.version,
            "{os}": ctx.attr.os,
            "{arch}": ctx.attr.arch,
        },
    )

    ctx.template(
        "config.yaml",
        ctx.attr.config,
        executable = False,
    )

    file = ARCHIVE_TEMPLATE.format(version = ctx.attr.version, os = ctx.attr.os, arch = ctx.attr.arch)
    url = URL_TEMPLATE.format(version = ctx.attr.version, file = file)

    res = ctx.download_and_extract(
        url = url,
        sha256 = ctx.attr.tool_sha256,
        output = "terraform-docs",
    )

    if not res.success:
        fail("!failed to dl: ", url)

    # reproducible: the contents are a function of the attributes alone. The
    # archive is fetched against tool_sha256, resolved by the module extension
    # and held as a fact in MODULE.bazel.lock, so a cold output base can link
    # this directory from the repo contents cache rather than fetching it again.
    return ctx.repo_metadata(reproducible = True)

tfdoc_download = repository_rule(
    _tfdoc_download_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "os": attr.string(mandatory = True),
        "arch": attr.string(mandatory = True),
        "tool_sha256": attr.string(
            mandatory = True,
            doc = "sha256 of terraform-docs' release archive for this platform, resolved by " +
                  "the module extension from the release's checksum document. Passed in " +
                  "rather than fetched so that every download this repository makes is " +
                  "pinned by an attribute.",
        ),
        "resolve_errors": attr.string(
            default = "[]",
            doc = "JSON list of the releases the module extension could not resolve. " +
                  "Reported here rather than there so that an unreachable release fails " +
                  "only the builds that generate documentation.",
        ),
        "config": attr.label(
            mandatory = False,
            default = "@rules_tf//tf/toolchains/tfdoc:tf-doc.yaml",
            allow_single_file = True,
            cfg = "target",
        ),
    },
)

DECLARE_TOOLCHAIN_CHUNK = """
tfdoc_toolchain(
   name = "{toolchain_repo}_toolchain_impl",
   tfdoc = "@{toolchain_repo}//:runtime",
   config = "@{toolchain_repo}//:config.yaml",
)

toolchain(
  name = "{toolchain_repo}_toolchain",
  exec_compatible_with = platforms["{os}_{arch}"]["exec_compatible_with"],
  target_compatible_with = platforms["{os}_{arch}"]["target_compatible_with"],
  toolchain = ":{toolchain_repo}_toolchain_impl",
  toolchain_type = "@rules_tf//:tfdoc_toolchain_type",
  visibility = ["//visibility:public"],
)

alias(
    name = "tfdoc",
    actual = "@{toolchain_repo}//:runtime",
)
"""
