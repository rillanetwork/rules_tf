#!/usr/bin/env bash

# Integration test runner that executes a list of Bazel commands against a
# child module. The commands arrive newline separated in TF_BAZEL_CMDS and run
# in order, sharing one output base, so a suite can ask for things like a clean
# between two passes.

set -euo pipefail

# --- begin runfiles.bash initialization v2 ---
# Copy-pasted from the Bazel Bash runfiles library v2.
set -uo pipefail
f=bazel_tools/tools/bash/runfiles/runfiles.bash
# shellcheck disable=SC1090
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null ||
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null ||
  source "$0.runfiles/$f" 2>/dev/null ||
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null ||
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null ||
  {
    echo >&2 "ERROR: ${BASH_SOURCE[0]} cannot find $f"
    exit 1
  }
f=
set -e
# --- end runfiles.bash initialization v2 ---

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ -z "${TF_BAZEL_CMDS:-}" ]]; then
  echo >&2 "No Bazel commands were specified in TF_BAZEL_CMDS."
  exit 1
fi

bazel_cmds=()
while IFS=$'\n' read -r cmd; do bazel_cmds+=("${cmd}"); done <<< "${TF_BAZEL_CMDS}"

bit::enter_scratch_dir

for cmd in "${bazel_cmds[@]}"; do
  echo "--- bazel ${cmd}"
  # Word splitting is the point: each command arrives as a single string.
  # shellcheck disable=SC2086
  bit::bazel ${cmd}
done
