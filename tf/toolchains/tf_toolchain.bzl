"""The tf toolchain type: a terraform or tofu binary plus its provider mirror."""

load("@bazel_skylib//lib:paths.bzl", "paths")

TfInfo = provider(
    doc = "Information about how to invoke Terraform/Tofu.",
    fields = ["tf", "deps", "mirror_path", "mirror_versions", "default_registry"],
)

def _mirror_path(ctx):
    """The runfiles-relative path of the mirror's root.

    The mirror is staged as individual files, so no single File names the
    directory they share; `mirror_versions.json` sits beside it and anchors it.

    Args:
      ctx: the `tf_toolchain` rule context.

    Returns:
      The path, or the empty string when nothing is mirrored, in which case
      callers must leave `-plugin-dir` off.
    """
    if not ctx.files.mirror_files:
        return ""
    return paths.join(paths.dirname(ctx.file.mirror_versions_json.short_path), "mirror")

def _tf_toolchain_impl(ctx):
    toolchain_info = platform_common.ToolchainInfo(
        runtime = TfInfo(
            tf = ctx.file.tf,
            mirror_path = _mirror_path(ctx),
            mirror_versions = ctx.attr.mirror_versions,
            default_registry = ctx.attr.default_registry,
            deps = [ctx.file.tf] + ctx.files.mirror_files + [ctx.file.mirror_versions_json],
        ),
    )
    return [toolchain_info]

tf_toolchain = rule(
    implementation = _tf_toolchain_impl,
    attrs = {
        "tf": attr.label(
            mandatory = True,
            allow_single_file = True,
            executable = True,
            cfg = "target",
        ),
        "mirror_files": attr.label(
            mandatory = True,
            allow_files = True,
            cfg = "target",
            doc = "Every file under the mirror, individually. Not the `mirror` directory, " +
                  "whose contents Bazel never stages.",
        ),
        "mirror_versions_json": attr.label(
            mandatory = True,
            allow_single_file = True,
            cfg = "target",
            doc = "The mirror's manifest, which sits beside `mirror/` and so anchors its path.",
        ),
        "mirror_versions": attr.string_list(
            doc = "Canonical 'source@version' strings for every provider present in the mirror.",
        ),
        "default_registry": attr.string(
            doc = "Registry host an unqualified mirror source resolves against, so a rule can " +
                  "address a provider exactly as the mirror did.",
        ),
    },
)
