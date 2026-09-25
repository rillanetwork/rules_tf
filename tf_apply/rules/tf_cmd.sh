#!/usr/bin/env bash

# Generic terraform runner. Forwards all arguments to `terraform -chdir=$work_dir`,
# with best-effort symlinking of .terraform, .terraform.lock.hcl, and plan.tfplan
# from the root module's bazel-tf output directory into the working directory.
#
# Usage: bazel run //path:my_module.tf -- <subcommand> [flags...]
# Examples:
#   bazel run //path:my_module.tf -- validate
#   bazel run //path:my_module.tf -- state list
#   bazel run //path:my_module.tf -- output
#   bazel run //path:my_module.tf -- destroy -auto-approve

set -euo pipefail

tf_bin="${PWD}/%tf_bin%"
# The module's package inside this target's runfiles tree, which is unique to the root and command.
work_dir="${PWD}/%module_dir%"

if [ -z "${BUILD_WORKSPACE_DIRECTORY:-}" ]; then
    echo "BUILD_WORKSPACE_DIRECTORY is not set. Please set it before running this script."
    exit 1
fi

if [ $# -eq 0 ]; then
    echo "Usage: bazel run <target> -- <terraform-subcommand> [flags...]" >&2
    echo "Examples:" >&2
    echo "  bazel run <target> -- validate" >&2
    echo "  bazel run <target> -- state list" >&2
    echo "  bazel run <target> -- destroy -auto-approve" >&2
    exit 2
fi

state_dir="$BUILD_WORKSPACE_DIRECTORY/bazel-tf/%state_dir%"

# Best-effort symlink the inited state into the working directory. We don't
# require these to exist — pre-init commands like `fmt` and `validate` work
# without them, and terraform itself emits a clear error for commands that
# need init.
if [ -d "$state_dir/.terraform" ]; then
    test -e "$work_dir/.terraform" && rm -rf "$work_dir/.terraform"
    ln -sfn "$state_dir/.terraform" "$work_dir/.terraform"
fi
if [ -f "$state_dir/.terraform.lock.hcl" ]; then
    test -e "$work_dir/.terraform.lock.hcl" && rm -rf "$work_dir/.terraform.lock.hcl"
    ln -sfn "$state_dir/.terraform.lock.hcl" "$work_dir/.terraform.lock.hcl"
fi
if [ -f "$state_dir/plan.tfplan" ]; then
    test -e "$work_dir/plan.tfplan" && rm -rf "$work_dir/plan.tfplan"
    ln -sfn "$state_dir/plan.tfplan" "$work_dir/plan.tfplan"
fi

exec "$tf_bin" -chdir="$work_dir" "$@"
