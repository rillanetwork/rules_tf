"""Reading the remote modules a terraform module calls out of its sources.

Terraform keys `.terraform/modules/modules.json` by call path, and a call path
is a chain of the names HCL gives its `module` blocks. Nothing in the Bazel
graph knows those names: a dependency is a label, and one module target may be
called twice under two different names. So supplying a mirrored module to
terraform means reading the configuration back.

terraform-docs does the parsing, which is why it is a toolchain here rather
than a parser of our own: terraform forbids interpolation in `source` and
`version`, so both are always literal, and a tool already pinned and
checksum-verified can be trusted to find them.
"""

TFDOC_TOOLCHAIN = "@rules_tf//:tfdoc_toolchain_type"

def declare_module_calls(ctx, srcs):
    """Declares the action recording which remote modules this one reaches.

    Args:
      ctx: the tf_module rule's context.
      srcs: depset of the module's sources together with its local
        dependencies', since a local call is followed into the called
        directory rather than reported.

    Returns:
      A File of TSV rows, `<call path>\\t<source>\\t<version>`, sorted.
    """
    tfdoc = ctx.toolchains[TFDOC_TOOLCHAIN].runtime
    config = ctx.file._module_calls_config
    script = ctx.file._module_calls_script

    out = ctx.actions.declare_file("%s.module_calls.tsv" % ctx.label.name)

    ctx.actions.run_shell(
        command = 'bash "$1" "$2" "$3" "$4" "$5"',
        arguments = [
            script.path,
            tfdoc.tfdoc.path,
            config.path,

            # Sources sit at their own package paths, so the module's directory
            # is the package itself. A module in the repository root has none.
            ctx.label.package or ".",
            out.path,
        ],
        inputs = depset([config, script], transitive = [srcs]),
        tools = [tfdoc.tfdoc],
        outputs = [out],
        mnemonic = "TfModuleCalls",
        progress_message = "Reading terraform module calls in %s" % ctx.label,
    )

    return out

# Attributes the rule declaring the action must carry.
MODULE_CALLS_ATTRS = {
    "_module_calls_script": attr.label(
        default = Label("//tf/rules:module_calls.sh"),
        allow_single_file = True,
    ),
    "_module_calls_config": attr.label(
        default = Label("//tf/rules:module_calls.yml"),
        allow_single_file = True,
    ),
}
