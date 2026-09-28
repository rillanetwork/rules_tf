#!/usr/bin/env bash

# Invokes `terraform init` in the specified Terraform directory.
# The output .terraform directory and lock file are symlinked into the root
# module's own directory under bazel-tf on the workspace root.

set -euo pipefail

tf_bin="${PWD}/%tf_bin%"
# The module's package inside this target's runfiles tree, which is unique to the root and command.
work_dir="${PWD}/%module_dir%"
plugins_dir="%plugins_dir%"

# Empty when nothing is mirrored: the flag is left off and init resolves against
# the registry instead.
plugin_dir_flag=()
if [ -n "$plugins_dir" ]; then
    plugin_dir_flag=(-plugin-dir="${PWD}/${plugins_dir}")
fi

if [ -z "${BUILD_WORKSPACE_DIRECTORY:-}" ]; then
    echo "BUILD_WORKSPACE_DIRECTORY is not set. Please set it before running this script."
    exit 1
fi

# Accept additional terraform arguments passed via bazel -- syntax
if [ $# -gt 0 ]; then
    echo "Additional terraform arguments provided: $*"
fi

state_dir="$BUILD_WORKSPACE_DIRECTORY/bazel-tf/%state_dir%"
mkdir -p "$state_dir"

# Init on a clean working directory
rm -rf "$work_dir/.terraform"
rm -rf "$work_dir/.terraform.lock.hcl"

# remove any existing .terraform and .terraform.lock.hcl files
rm -rf "$state_dir/.terraform"
rm -rf "$state_dir/.terraform.lock.hcl"

echo "Running 'terraform init' in directory: $work_dir"

# Run terraform init
$tf_bin -chdir="$work_dir" init -input=false "${plugin_dir_flag[@]}" $@

# symlink the .terraform directory to the output directory
ln -s  "$work_dir/.terraform" "$state_dir/.terraform"
ln -s "$work_dir/.terraform.lock.hcl" "$state_dir/.terraform.lock.hcl"
