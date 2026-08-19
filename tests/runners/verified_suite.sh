#!/usr/bin/env bash

# Integration test runner for the tests/bcr_verified child module: one pass
# answered by the committed extension facts, then a re-resolve against the live
# registry that has to reproduce them exactly.

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

# The scratch copy is about to be rewritten; this is what it must match.
committed_lock="${BIT_WORKSPACE_DIR}/MODULE.bazel.lock"

bit::enter_scratch_dir

echo "--- bazel test //... (resolving from the committed facts)"
bit::bazel test //...

# The generated lock file is only complete when it carries the h1: dirhashes,
# which only a signature-verified mirror has. Incomplete, init rewrites the file
# it was handed and says so -- so the message and the rewrite are both asserted
# here, where the facts holding those hashes are committed.
echo "--- bazel run root-mod-verified.init (the lock must survive it)"
init_log="${TEST_TMPDIR}/init.log"
bit::bazel run //tf/root-modules/root-mod-verified:root-mod-verified.init 2>&1 | tee "${init_log}"

if grep -q "made some changes to the provider dependency selections" "${init_log}"; then
  echo >&2 ""
  echo >&2 "terraform rewrote the generated .terraform.lock.hcl during init. It does"
  echo >&2 "that when the document is incomplete: h1: hashes missing for the platform"
  echo >&2 "it ran on, or a provider named that the configuration does not require."
  exit 1
fi

bazel_bin="$(bit::bazel info bazel-bin)"
module_bin="${bazel_bin}/tf/root-modules/root-mod-verified"
if ! diff -u \
  "${module_bin}/root-mod-verified.init.terraform.lock.hcl" \
  "${module_bin}/root-mod-verified.init.runfiles/_main/tf/root-modules/root-mod-verified/.terraform.lock.hcl"; then
  echo >&2 ""
  echo >&2 "init left the rundir's .terraform.lock.hcl different from the generated"
  echo >&2 "one, above. The generated document is meant to be what terraform would"
  echo >&2 "have written itself."
  exit 1
fi

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
