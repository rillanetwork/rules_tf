#!/usr/bin/env bash

# Checks that re-resolving tests/bcr_multi_tag reproduces its committed
# MODULE.bazel.lock, verified marks included.

set -euo pipefail

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

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

committed_lock="${BIT_WORKSPACE_DIR}/MODULE.bazel.lock"

echo "--- checking the committed facts carry the verified marks"
python3 - "${committed_lock}" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    (facts,) = json.load(f)["facts"].values()

marked = [k for k in facts if k.startswith(("package/", "tflint_plugin/"))]
unmarked = [k for k in marked if not facts[k].get("verified")]
if not marked or unmarked:
    sys.exit(
        "MODULE.bazel.lock in tests/bcr_multi_tag must record every package "
        "and ruleset as verified; unmarked: %s" % (unmarked or "no entries at all")
    )
PY

bit::enter_scratch_dir

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
  echo >&2 "committed in tests/bcr_multi_tag. If a verified mark went missing,"
  echo >&2 "a later tag overwrote an earlier tag's facts. Otherwise regenerate it with:"
  echo >&2 "  bazel mod deps --lockfile_mode=update"
  echo >&2 "from tests/bcr_multi_tag, and commit the result."
  exit 1
fi
