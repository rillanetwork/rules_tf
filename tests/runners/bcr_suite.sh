#!/usr/bin/env bash

# Integration test runner for the tests/bcr child module: the tests, then the
# generators and root module commands, which only show their behaviour when
# they are run.

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

bit::enter_scratch_dir

echo "--- bazel test //..."
bit::bazel test //...

bit::bazel_run_kind "tf_format rule"
bit::bazel_run_kind "tf_gen_doc rule"

# The generated version scripts rewrite the versions files in place, so
# building them proves nothing -- they have to be run.
echo "--- tf_gen_versions"
gen_versions_targets=()
while IFS=$'\n' read -r target; do gen_versions_targets+=("${target}"); done < <(
  bit::bazel query 'kind("tf_gen_versions rule", //...)'
)
if [[ ${#gen_versions_targets[@]} -eq 0 ]]; then
  echo >&2 "No tf_gen_versions targets found."
  exit 1
fi
bit::bazel build "${gen_versions_targets[@]}"

while IFS=$'\n' read -r script; do
  echo "--- bash ${script}"
  bash "${script}"
done < <(bit::bazel cquery 'kind("tf_gen_versions rule", //...)' --output files)

# plan runs unlocked because there is no backend to lock.
echo "--- root module apply rules"
bit::bazel run //tf/root-modules/root-mod-a:root-mod-a.init
bit::bazel run //tf/root-modules/root-mod-a:root-mod-a.plan -- -lock=false
