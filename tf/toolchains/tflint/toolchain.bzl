"""Downloads a tflint release and declares its toolchain."""

load(":plugins.bzl", "download_tflint_plugins")

# The release archive carries no version in its name, unlike terraform's, so the
# platform alone identifies it.
ARCHIVE_TEMPLATE = "{tool}_{os}_{arch}.zip"

URL_TEMPLATE = "https://github.com/terraform-linters/tflint/releases/download/v{version}/{file}"

SHA256SUMS_TEMPLATE = "https://github.com/terraform-linters/tflint/releases/download/v{version}/checksums.txt"

# Where the wrapper points TFLINT_PLUGIN_DIR, and so where a ruleset must land.
_PLUGIN_DIR = "tflint_plugins"

TflintInfo = provider(
    doc = "Information about how to invoke tflint.",
    fields = ["runner", "deps", "config", "tflint_plugins"],
)

def _tflint_toolchain_impl(ctx):
    toolchain_info = platform_common.ToolchainInfo(
        runtime = TflintInfo(
            runner = ctx.file.wrapper,
            config = ctx.file.config,
            tflint_plugins = ctx.file.tflint_plugins,
            deps = ctx.files.bash_tools + [
                ctx.file.wrapper,
                ctx.file.config,
                ctx.file.tflint,
                ctx.file.tflint_plugins,
            ],
        ),
    )
    return [toolchain_info]

tflint_toolchain = rule(
    implementation = _tflint_toolchain_impl,
    attrs = {
        "tflint": attr.label(
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
        "wrapper": attr.label(
            mandatory = True,
            allow_single_file = True,
            executable = True,
            cfg = "target",
        ),
        "bash_tools": attr.label(
            mandatory = False,
            default = "@bazel_tools//tools/bash/runfiles",
            allow_files = True,
            cfg = "target",
        ),
        "tflint_plugins": attr.label(
            mandatory = True,
            allow_single_file = True,
            cfg = "target",
        ),
    },
)

def _tflint_download_impl(ctx):
    resolve_errors = json.decode(ctx.attr.resolve_errors)
    if len(resolve_errors) > 0:
        fail("the tflint toolchain could not be resolved:\n  " + "\n  ".join(resolve_errors))

    ctx.report_progress("Downloading tflint")

    ctx.template(
        "BUILD.bazel",
        Label("@rules_tf//tf/toolchains/tflint:BUILD.toolchain.tpl"),
        executable = False,
        substitutions = {
            "{version}": ctx.attr.version,
            "{os}": ctx.attr.os,
            "{arch}": ctx.attr.arch,
        },
    )

    ctx.template(
        "wrapper.sh",
        Label("@rules_tf//tf/toolchains/tflint:wrapper.sh"),
        executable = True,
    )

    ctx.template(
        "config.hcl",
        ctx.attr.config,
        executable = False,
    )

    file = ARCHIVE_TEMPLATE.format(tool = "tflint", os = ctx.attr.os, arch = ctx.attr.arch)
    url = URL_TEMPLATE.format(version = ctx.attr.version, file = file)

    res = ctx.download_and_extract(
        url = url,
        sha256 = ctx.attr.tool_sha256,
        type = "zip",
        output = "tflint",
    )

    if not res.success:
        fail("!failed to dl: ", url)

    # The rulesets the config declares, laid out where the wrapper tells tflint
    # to look. This is what `tflint --init` used to do from inside this
    # repository, on coordinates it chose itself.
    download_tflint_plugins(ctx, json.decode(ctx.attr.plugins_json), _PLUGIN_DIR)

    # reproducible: the contents are a function of the attributes alone. The
    # tflint archive is fetched against tool_sha256 and every ruleset against a
    # sha256 the extension resolved and passed in, so a cold output base can
    # link this directory from the repo contents cache rather than fetching it
    # again.
    return ctx.repo_metadata(reproducible = True)

tflint_download = repository_rule(
    _tflint_download_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "os": attr.string(mandatory = True),
        "arch": attr.string(mandatory = True),
        "tool_sha256": attr.string(
            mandatory = True,
            doc = "sha256 of tflint's release archive for this platform, resolved by the " +
                  "module extension from the release's checksums. Passed in rather than " +
                  "fetched so that every download this repository makes is pinned by an " +
                  "attribute.",
        ),
        "plugins_json": attr.string(
            default = "[]",
            doc = "JSON list of the rulesets the config declares, each already resolved by " +
                  "the module extension to a download_url and sha256. The extension is " +
                  "reproducible, so this is not itself recorded in MODULE.bazel.lock; the " +
                  "facts it was derived from are.",
        ),
        "resolve_errors": attr.string(
            default = "[]",
            doc = "JSON list of the releases the module extension could not resolve. " +
                  "Reported here rather than there so that an unreachable release fails " +
                  "only the builds that lint something.",
        ),
        "config": attr.label(
            mandatory = False,
            default = "@rules_tf//tf/toolchains/tflint:config.hcl",
            allow_single_file = True,
            cfg = "target",
        ),
    },
)

DECLARE_TOOLCHAIN_CHUNK = """
tflint_toolchain(
   name = "{toolchain_repo}_toolchain_impl",
   tflint = "@{toolchain_repo}//:runtime",
   config = "@{toolchain_repo}//:config.hcl",
   wrapper = "@{toolchain_repo}//:wrapper.sh",
   tflint_plugins = "@{toolchain_repo}//:tflint_plugins",
)

toolchain(
  name = "{toolchain_repo}_toolchain",
  exec_compatible_with = platforms["{os}_{arch}"]["exec_compatible_with"],
  target_compatible_with = platforms["{os}_{arch}"]["target_compatible_with"],
  toolchain = ":{toolchain_repo}_toolchain_impl",
  toolchain_type = "@rules_tf//:tflint_toolchain_type",
  visibility = ["//visibility:public"],
)

alias(
    name = "tflint",
    actual = "@{toolchain_repo}//:runtime",
)
"""
