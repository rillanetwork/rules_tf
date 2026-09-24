#!/usr/bin/env bash

# Invokes `terraform plan -destroy` in the specified Terraform directory.
# The output destroy plan file is written to plan.tfplan and symlinked into the
# root module's own directory under bazel-tf on the workspace root, so a
# subsequent `bazel run <mod>.apply` will apply the destroy plan.

set -euo pipefail

tf_bin="${PWD}/%tf_bin%"
# The module's package inside this target's runfiles tree, which is unique to the root and command.
work_dir="${PWD}/%module_dir%"

if [ -z "${BUILD_WORKSPACE_DIRECTORY:-}" ]; then
    echo "BUILD_WORKSPACE_DIRECTORY is not set. Please set it before running this script."
    exit 1
fi

# Accept additional terraform arguments passed via bazel -- syntax
if [ $# -gt 0 ]; then
    echo "Additional terraform arguments provided: $*"
fi

state_dir="$BUILD_WORKSPACE_DIRECTORY/bazel-tf/%state_dir%"

# Check .terraform directory and .terraform.lock.hcl file
if [ ! -d "$state_dir/.terraform" ]; then
    echo ".terraform directory does not exist in $state_dir please run 'terraform_init' first."
    exit 1
fi

if [ ! -f "$state_dir/.terraform.lock.hcl" ]; then
    echo ".terraform.lock.hcl file does not exist in $state_dir please run 'terraform_init' first."
    exit 1
fi

# symlink the .terraform directory from the output directory
# Ensure that any existing .terraform directory or .terraform.lock.hcl file is removed first
test -d "$work_dir/.terraform" && rm -rf "$work_dir/.terraform"
test -f "$work_dir/.terraform.lock.hcl" && rm -rf "$work_dir/.terraform.lock.hcl"
test -f "$work_dir/plan.tfplan" && rm -rf "$work_dir/plan.tfplan"

ln -sfn "$state_dir/.terraform" "$work_dir/.terraform"
ln -sfn "$state_dir/.terraform.lock.hcl" "$work_dir/.terraform.lock.hcl"

# Drop the previous plan before planning, so a failed destroy plan cannot leave
# an earlier forward plan behind for .apply to execute.
rm -f "$state_dir/plan.tfplan" "$state_dir/plan.tfplan.json"

$tf_bin -chdir="$work_dir" plan -destroy -input=false -out="plan.tfplan" "$@"

# symlink the destroy plan output to the output directory so .apply can consume it
ln -sfn "$work_dir/plan.tfplan" "$state_dir/plan.tfplan"
