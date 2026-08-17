"""The tf toolchain type: a terraform or tofu binary plus its provider mirror."""

TfInfo = provider(
    doc = "Information about how to invoke Terraform/Tofu.",
    fields = ["tf", "deps", "mirror", "mirror_versions", "mirror_hashes", "default_registry"],
)

def _tf_toolchain_impl(ctx):
    toolchain_info = platform_common.ToolchainInfo(
        runtime = TfInfo(
            tf = ctx.file.tf,
            mirror = ctx.file.mirror,
            mirror_versions = ctx.attr.mirror_versions,
            mirror_hashes = ctx.attr.mirror_hashes,
            default_registry = ctx.attr.default_registry,
            deps = [ctx.file.tf, ctx.file.mirror],
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
        "mirror": attr.label(
            mandatory = True,
            allow_single_file = True,
            executable = True,
            cfg = "target",
        ),
        "mirror_versions": attr.string_list(
            doc = "Canonical 'source@version' strings for every provider present in the mirror.",
        ),
        "mirror_hashes": attr.string_dict(
            doc = "Package hashes per mirrored provider: '<host>/<ns>/<type>@<version>' -> the " +
                  "comma-joined sha256 of its package on each platform the extension resolved. " +
                  "What a module's generated .terraform.lock.hcl is written from.",
        ),
        "default_registry": attr.string(
            doc = "Registry host an unqualified mirror source resolves against, so a rule can " +
                  "address a provider exactly as the mirror did.",
        ),
    },
)
