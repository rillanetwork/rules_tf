"""The tf_module rule and the packaging, validation and format rules around it."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rules_pkg//pkg:providers.bzl", "PackageFilegroupInfo", "PackageFilesInfo")
load("@rules_tf//tf/rules:providers.bzl", "TfArtifactInfo", "TfModuleInfo")
load("@rules_tf//tf/toolchains:provider_lockfile.bzl", "module_lock_document")

def _artifact_impl(ctx):
    return [
        DefaultInfo(
            files = depset([ctx.file.package]),
        ),
        TfArtifactInfo(
            module = ctx.attr.module,
            package = ctx.attr.package,
        ),
        ctx.attr.module[TfModuleInfo],
        ctx.attr.package[OutputGroupInfo],
    ]

tf_artifact = rule(
    implementation = _artifact_impl,
    attrs = {
        "module": attr.label(providers = [TfModuleInfo], mandatory = True),
        "package": attr.label(providers = [OutputGroupInfo], mandatory = True, allow_single_file = True),
    },
)

def _module_impl(ctx):
    if len([f for f in ctx.files.srcs if f.basename.endswith(".tf") or f.basename.endswith(".tf.json")]) == 0:
        fail("tf modules must contain at least one .tf file.")

    all_srcs = depset(
        ctx.files.srcs,
        transitive = [dep[TfModuleInfo].transitive_srcs if TfModuleInfo in dep else dep.files for dep in ctx.attr.deps],
    )

    # A child module declares providers of its own, and `init` resolves the
    # whole tree at once, so the version a lock file may name has to satisfy
    # every module that asks for the provider -- not just this one.
    all_providers = depset(
        [ctx.attr.providers_json] if ctx.attr.providers_json else [],
        transitive = [
            dep[TfModuleInfo].transitive_providers_json
            for dep in ctx.attr.deps
            if TfModuleInfo in dep
        ],
    )

    return [
        DefaultInfo(
            files = all_srcs,
        ),
        TfModuleInfo(
            files = ctx.attr.srcs,
            deps = ctx.attr.deps,
            module_path = ctx.label.package,
            transitive_srcs = all_srcs,
            transitive_providers_json = all_providers,
        ),
        ctx.attr.srcs[PackageFilesInfo],
    ]

tf_module = rule(
    implementation = _module_impl,
    attrs = {
        "srcs": attr.label(mandatory = True, providers = [PackageFilesInfo, DefaultInfo]),
        "deps": attr.label_list(providers = [[TfArtifactInfo], [PackageFilegroupInfo, DefaultInfo], [PackageFilesInfo, DefaultInfo]]),
        "providers_json": attr.string(
            doc = "The module's required providers as JSON, in the shape tf_gen_versions " +
                  "writes them. Read to pick the mirrored version a generated lock file " +
                  "names when the mirror stocks a provider at several.",
        ),
    },
)

def _compute_deps_pfi(s, prefix, files, mapped_files_depsets):
    src_files = s[PackageFilesInfo]
    new_pfi = PackageFilesInfo(
        dest_src_map = {
            paths.join(prefix, dest): src
            for dest, src in src_files.dest_src_map.items()
        },
        attributes = src_files.attributes,
    )
    files.append((new_pfi, s.label))
    src_default = s[DefaultInfo]
    mapped_files_depsets.append(src_default.files)

def _compute_deps_pfgi(s, prefix, files, mapped_files_depsets):
    old_pfgi, old_di = s[PackageFilegroupInfo], s[DefaultInfo]

    files.extend([
        (
            PackageFilesInfo(
                dest_src_map = {
                    paths.join(prefix, dest): src
                    for dest, src in pfi.dest_src_map.items()
                },
                attributes = pfi.attributes,
            ),
            origin,
        )
        for (pfi, origin) in old_pfgi.pkg_files
    ])
    mapped_files_depsets.append(old_di.files)

def _compute_deps(dep, files, mapped_files_depsets):
    if TfModuleInfo in dep:
        dep_mod = dep[TfModuleInfo]
        prefix = ""

        _compute_deps_pfi(dep_mod.files, prefix, files, mapped_files_depsets)

        for sub_dep in dep_mod.deps:
            if PackageFilesInfo in sub_dep:
                _compute_deps_pfi(sub_dep, prefix, files, mapped_files_depsets)
            if PackageFilegroupInfo in sub_dep:
                _compute_deps_pfgi(sub_dep, prefix, files, mapped_files_depsets)

    if PackageFilesInfo in dep:
        _compute_deps_pfi(dep, "", files, mapped_files_depsets)
    if PackageFilegroupInfo in dep:
        _compute_deps_pfgi(dep, "", files, mapped_files_depsets)

def _module_deps_impl(ctx):
    files = []
    mapped_files_depsets = []

    for dep in ctx.attr.mod[TfModuleInfo].deps:
        _compute_deps(dep, files, mapped_files_depsets)

    return [
        PackageFilegroupInfo(
            pkg_files = files,
            pkg_dirs = [],
            pkg_symlinks = [],
        ),
        # Necessary to ensure that dependent rules have access to files being
        # mapped in.
        DefaultInfo(
            files = depset(transitive = mapped_files_depsets),
        ),
    ]

tf_module_deps = rule(
    implementation = _module_deps_impl,
    attrs = {
        "mod": attr.label(providers = [TfModuleInfo]),
    },
)

def declare_module_lock(ctx, module, tf_runtime):
    """Writes the `.terraform.lock.hcl` covering what the mirror holds for a module.

    `init` against an unpacked mirror has no lock file to read, so it hashes
    what it finds and warns that the result covers only the platform it ran on.
    The hashes are already known here -- the module extension resolved one per
    platform, and every mirrored package was fetched against it -- so the file
    is written from those instead.

    Args:
      ctx: the rule context, which the file is declared against.
      module: the module's TfModuleInfo.
      tf_runtime: the tf toolchain's TfInfo.

    Returns:
      The lock file, or None when the mirror can name no provider for this
      module and `init` should be left to its own devices.
    """
    document = module_lock_document(
        tf_runtime.mirror_hashes,
        [json.decode(p) for p in module.transitive_providers_json.to_list()],
        tf_runtime.default_registry,
    )
    if not document:
        return None

    lock = ctx.actions.declare_file(ctx.label.name + ".terraform.lock.hcl")
    ctx.actions.write(output = lock, content = document)
    return lock

def install_module_lock(lock, module_dir):
    """The shell prefix placing a generated lock file in the module's rundir.

    Copied rather than symlinked: `init` rewrites the lock in place whenever the
    document is incomplete -- appending the `h1:` dirhash it computes for the
    running platform, which is absent when nothing signature-verified the mirror
    -- and through a runfiles symlink that would land on the build output.

    Args:
      lock: the generated lock file, or None.
      module_dir: the module's path, relative to the runfiles root.

    Returns:
      A shell fragment ending in `;`, or "" when there is no lock to install.
    """
    if not lock:
        return ""

    return "cp -f {lock} {dir}/.terraform.lock.hcl; chmod u+w {dir}/.terraform.lock.hcl; ".format(
        lock = lock.short_path,
        dir = module_dir,
    )

def _tf_validate_impl(ctx):
    tf_runtime = ctx.toolchains["@rules_tf//:tf_toolchain_type"].runtime
    module = ctx.attr.module[TfModuleInfo]
    lock = declare_module_lock(ctx, module, tf_runtime)

    # A mirror holding nothing stages no directory, so there is no path to hand
    # init: the flag is left off entirely rather than pointed somewhere absent.
    plugin_dir = " -plugin-dir=$PWD/" + tf_runtime.mirror_path if tf_runtime.mirror_path else ""

    cmd = "{install}{tf} -chdir={dir} init -backend=false -input=false{plugin_dir} > /dev/null; {tf} -chdir={dir} validate".format(
        install = install_module_lock(lock, ctx.attr.module.label.package),
        dir = ctx.attr.module.label.package,
        tf = tf_runtime.tf.short_path,
        plugin_dir = plugin_dir,
    )

    ctx.actions.write(
        output = ctx.outputs.executable,
        content = cmd,
    )

    deps = module.transitive_srcs.to_list() + tf_runtime.deps + ([lock] if lock else [])

    return [DefaultInfo(
        runfiles = ctx.runfiles(files = deps),
    )]

tf_validate_test = rule(
    implementation = _tf_validate_impl,
    attrs = {
        "module": attr.label(providers = [TfModuleInfo], allow_files = True),
    },
    test = True,
    toolchains = [
        "@rules_tf//:tf_toolchain_type",
    ],
)

def _format_test_impl(ctx):
    module = ctx.attr.module[TfModuleInfo]
    tf_runtime = ctx.toolchains["@rules_tf//:tf_toolchain_type"].runtime

    cmd = "{tf} fmt -check -diff {module_path}".format(
        tf = tf_runtime.tf.short_path,
        module_path = module.module_path,
    )
    ctx.actions.write(
        output = ctx.outputs.executable,
        content = cmd,
    )
    runtime_deps = [
        tf_runtime.tf,
    ]
    return [DefaultInfo(
        runfiles = ctx.runfiles(files = module.files[DefaultInfo].files.to_list() + runtime_deps),
    )]

tf_format_test = rule(
    implementation = _format_test_impl,
    attrs = {
        "module": attr.label(providers = [TfModuleInfo]),
    },
    test = True,
    toolchains = ["@rules_tf//:tf_toolchain_type"],
)

def _format_impl(ctx):
    tf_runtime = ctx.toolchains["@rules_tf//:tf_toolchain_type"].runtime

    if len(ctx.attr.modules) < 1:
        fail("you must provide a list of modules")

    cmd = "for mod in {mods}; do {tf} fmt ${{BUILD_WORKSPACE_DIRECTORY}}/${{mod}}; done".format(
        mods = " ".join([p.label.package for p in ctx.attr.modules]),
        tf = tf_runtime.tf.short_path,
    )

    ctx.actions.write(
        output = ctx.outputs.executable,
        content = cmd,
    )
    runtime_deps = [
        tf_runtime.tf,
    ]
    return [DefaultInfo(
        runfiles = ctx.runfiles(files = runtime_deps),
    )]

tf_format = rule(
    implementation = _format_impl,
    attrs = {
        "modules": attr.label_list(
            mandatory = True,
        ),
    },
    toolchains = [
        "@rules_tf//:tf_toolchain_type",
    ],
    executable = True,
)
