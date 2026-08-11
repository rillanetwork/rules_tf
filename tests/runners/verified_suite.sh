#!/usr/bin/env bash

# Integration test runner for the tests/bcr_verified child module.
#
# Two passes over the same module. The first is answered by the extension facts
# committed in its MODULE.bazel.lock. Discarding those facts and re-resolving
# makes the extension run `terraform providers lock` for every mirror entry
# against the live registry, and what it records back has to be exactly what
# was committed -- otherwise the committed facts assert hashes that the
# registry no longer agrees with.

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

# Keep a handle on the committed lock file before moving off it. The scratch
# copy is about to be rewritten, and this is what it has to end up matching.
committed_lock="${BIT_WORKSPACE_DIR}/MODULE.bazel.lock"

bit::enter_scratch_dir

echo "--- bazel test //... (resolving from the committed facts)"
bit::bazel test //...

echo "--- discarding the committed facts"
python3 - <<'PY'
import json

with open("MODULE.bazel.lock") as f:
    lock = json.load(f)

lock.pop("facts", None)

with open("MODULE.bazel.lock", "w") as f:
    json.dump(lock, f)
PY

echo "--- bazel mod deps (re-resolving against the registry)"
bit::bazel mod deps > /dev/null

echo "--- comparing the re-resolved facts with the committed ones"
if ! diff -u "${committed_lock}" MODULE.bazel.lock; then
  echo >&2 ""
  echo >&2 "Re-resolving produced a different MODULE.bazel.lock than the one"
  echo >&2 "committed in tests/bcr_verified. Regenerate it with:"
  echo >&2 "  bazel mod deps --lockfile_mode=update"
  echo >&2 "from tests/bcr_verified, and commit the result."
  exit 1
fi
