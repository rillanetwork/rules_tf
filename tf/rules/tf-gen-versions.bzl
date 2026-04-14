def _impl(ctx):
    out_file = ctx.actions.declare_file(ctx.label.name + ".sh")
    tf_version = ctx.attr.tf_version

    required_providers_dict = {}
    if ctx.attr.providers_dict_json:
        providers_dict = json.decode(ctx.attr.providers_dict_json)
        for provider_name, provider_config in providers_dict.items():
            required_providers_dict[provider_name] = provider_config

    terraform_block = {
        "required_providers": required_providers_dict,
    }

    if tf_version != None and tf_version != "":
        terraform_block["required_version"] = tf_version

    if ctx.attr.experiments != None and len(ctx.attr.experiments) > 0:
        terraform_block["experiments"] = ctx.attr.experiments

    versions = {
        "terraform": terraform_block
    }

    cmd = "printf '%s' '{json}' > ${{BUILD_WORKSPACE_DIRECTORY:-$PWD}}/{package}/versions.tf.json".format(
        json = json.encode(versions),
        package = ctx.label.package,
    )

    ctx.actions.write(
        output = out_file,
        content = cmd,
        is_executable = True,
    )

    return [DefaultInfo(
        files = depset([out_file]),
        executable = out_file,
    )]


tf_gen_versions = rule(
    implementation = _impl,
    attrs = {
        "providers_dict_json": attr.string(mandatory = False, default = ""),
        "experiments": attr.string_list(mandatory = False, default = []),
        "tf_version": attr.string(mandatory = False, default = ""),
    },
    executable = True,
)
