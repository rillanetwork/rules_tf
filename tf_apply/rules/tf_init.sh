#!/usr/bin/env bash

# Invokes `terraform init` in the specified Terraform directory.
# The output .terraform directory and lock file are symlinked to bazel-tf on the workspace root.

set -euo pipefail

TF_BIN_PATH="${PWD}/%TF_BIN_PATH%"
TF_DIR="%TF_DIR%"
TF_PLUGINS_DIR="%TF_PLUGINS_DIR%"
TF_LOCK_FILE="%TF_LOCK_FILE%"

# Empty when nothing is mirrored: the flag is left off and init resolves against
# the registry instead.
PLUGIN_DIR_FLAG=()
if [ -n "$TF_PLUGINS_DIR" ]; then
    PLUGIN_DIR_FLAG=(-plugin-dir="${PWD}/${TF_PLUGINS_DIR}")
fi

if [ -z "${BUILD_WORKSPACE_DIRECTORY:-}" ]; then
    echo "BUILD_WORKSPACE_DIRECTORY is not set. Please set it before running this script."
    exit 1
fi

# Accept additional terraform arguments passed via bazel -- syntax
if [ $# -gt 0 ]; then
    echo "Additional terraform arguments provided: $*"
fi

OUT_DIR="$BUILD_WORKSPACE_DIRECTORY/bazel-tf/$TF_DIR"
mkdir -p "$OUT_DIR"

# Init on a clean TF_DIR
rm -rf "$PWD/$TF_DIR/.terraform"
rm -rf "$PWD/$TF_DIR/.terraform.lock.hcl"

# remove any existing .terraform and .terraform.lock.hcl files
rm -rf "$OUT_DIR/.terraform"
rm -rf "$OUT_DIR/.terraform.lock.hcl"

if [ -n "$TF_LOCK_FILE" ]; then
    cp -f "$TF_LOCK_FILE" "$PWD/$TF_DIR/.terraform.lock.hcl"
    chmod u+w "$PWD/$TF_DIR/.terraform.lock.hcl"
fi

echo "Running 'terraform init' in directory: $PWD/$TF_DIR"

# Run terraform init
$TF_BIN_PATH -chdir="$TF_DIR" init -input=false "${PLUGIN_DIR_FLAG[@]}" $@

# symlink the .terraform directory to the output directory
ln -s  "$PWD/$TF_DIR/.terraform" "$OUT_DIR/.terraform"
ln -s "$PWD/$TF_DIR/.terraform.lock.hcl" "$OUT_DIR/.terraform.lock.hcl"
