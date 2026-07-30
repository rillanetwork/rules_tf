"""A `bazel run` target that records signature-verified provider hashes."""

load("@rules_tf//tf/toolchains:utils.bzl", "MIRROR_PLATFORMS")

# The extension whose facts hold the verified hashes. Resolved through a Label
# so the canonical repository name is stamped in at analysis time rather than
# guessed at runtime -- it depends on how rules_tf entered the module graph.
_EXTENSION_KEY = str(Label("@rules_tf//tf:extensions.bzl")) + "%tf_repositories"

_LAUNCHER = """#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${{BUILD_WORKSPACE_DIRECTORY:-}}" ]]; then
  echo "rules_tf: {label} must be run with \\`bazel run\\`, not built" >&2
  exit 1
fi

exec ./{harvester} \\
  --config "$PWD/{config}" \\
  --tool "$PWD/{tool}" \\
  --lockfile "${{BUILD_WORKSPACE_DIRECTORY}}/{lockfile}" \\
  "$@"
"""

def _tf_providers_lock_impl(ctx):
    tf_runtime = ctx.toolchains["@rules_tf//:tf_toolchain_type"].runtime

    # The manifest comes from the toolchain, already resolved: whatever the
    # extension selected for a constraint is what gets locked, so the hashes
    # cover the packages the mirror actually holds.
    config = ctx.actions.declare_file("%s.config.json" % ctx.label.name)
    ctx.actions.write(
        output = config,
        content = json.encode_indent({
            "extension_key": _EXTENSION_KEY,
            "mirror_versions": tf_runtime.mirror_versions,
            "default_registry": tf_runtime.default_registry,
            "platforms": ctx.attr.platforms,
        }),
    )

    harvester = ctx.attr._harvester[DefaultInfo].files_to_run.executable

    ctx.actions.write(
        output = ctx.outputs.executable,
        content = _LAUNCHER.format(
            label = str(ctx.label),
            harvester = harvester.short_path,
            config = config.short_path,
            tool = tf_runtime.tf.short_path,
            lockfile = ctx.attr.lockfile,
        ),
        is_executable = True,
    )

    return [DefaultInfo(
        runfiles = ctx.runfiles(files = [config, tf_runtime.tf]).merge(
            ctx.attr._harvester[DefaultInfo].default_runfiles,
        ),
    )]

tf_providers_lock = rule(
    implementation = _tf_providers_lock_impl,
    doc = """Runs `terraform providers lock` over the mirror manifest and records the hashes it
verified in `MODULE.bazel.lock`, where the module extension reads them back and checks every
mirrored package against them.

The lock command verifies the registry's `SHA256SUMS` signature against the public keys compiled
into the terraform binary, so a hash it emits is a trust root independent of the registry's own
answer. Run it whenever the manifest changes, and commit the resulting lockfile diff:

```sh
bazel run //:providers_lock
```

Requires network access and any credentials the registries involved need. `tofu providers lock` is
run instead under a tofu toolchain, since the two registries serve differently-signed packages.""",
    attrs = {
        "platforms": attr.string_list(
            doc = "Platforms to pass to the lock command. Rarely needed: the zh: hashes it " +
                  "records come from the signed SHA256SUMS document and cover every platform " +
                  "regardless, so the default (the host alone) already produces a hash set " +
                  "usable from any host. Set it when a provider ships no package for the host " +
                  "running this, which would otherwise fail the lock. Recognised values are " +
                  "terraform's, of which the mirror itself can be built on {}.".format(
                      ", ".join(MIRROR_PLATFORMS),
                  ),
        ),
        "lockfile": attr.string(
            default = "MODULE.bazel.lock",
            doc = "Lockfile to merge the verified hashes into, relative to the workspace root.",
        ),
        "_harvester": attr.label(
            default = "@rules_tf//tf/rules:providers_lock",
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = ["@rules_tf//:tf_toolchain_type"],
    executable = True,
)
