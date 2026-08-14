#!/usr/bin/env bash

# Integration test runner for the tests/bcr_mirror_json child module: the
# committed lock file admits the whole mirror, then an unrelated lock file
# must fail the build despite the verified marks already recorded in
# MODULE.bazel.lock. Those marks belong to "auto"; under
# provider_verification = "files" the supplied files are asserted against
# every package on every evaluation, so a mark recorded earlier must not
# stand in for coverage the current files do not provide.

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

echo "--- bazel test //... (the committed lock file covers the mirror)"
bit::bazel test //...

echo "--- replacing the lock file with one covering nothing the mirror stocks"
cat > tf/providers.lock.hcl <<'HCL'
provider "registry.terraform.io/hashicorp/unrelated" {
  version = "9.9.9"
  hashes = [
    "zh:0000000000000000000000000000000000000000000000000000000000000000",
  ]
}
HCL

echo "--- bazel build //... (must fail: recorded marks are not coverage)"
if bit::bazel build //... 2> stderr.log; then
  echo >&2 "The build passed against a lock file covering none of the mirror."
  echo >&2 "Recorded verified marks must not satisfy provider_verification = 'files'."
  exit 1
fi

if ! grep -q "no verified hashes cover" stderr.log; then
  cat >&2 stderr.log
  echo >&2 ""
  echo >&2 "The build failed, but not with the lock coverage error expected here."
  exit 1
fi
