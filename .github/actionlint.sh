#!/usr/bin/env bash

# Resolve actionlint, shellcheck, config, and workflow YAMLs from runfiles,
# then run actionlint over the workflows.
#
# Usage:
#   actionlint.sh --bin <path> --config <path> --shellcheck <path> -- <yml-path>...
#
# Paths are rlocationpath-encoded labels.

# --- begin runfiles.bash initialization v3 ---
set -uo pipefail
set +e
f=bazel_tools/tools/bash/runfiles/runfiles.bash
# shellcheck disable=SC1090
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null ||
    source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null ||
    source "$0.runfiles/$f" 2>/dev/null ||
    source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null ||
    source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null ||
    {
        echo >&2 "ERROR: cannot find $f"
        exit 1
    }
f=
set -e
# --- end runfiles.bash initialization v3 ---

bin=
config=
shellcheck=
while [[ $# -gt 0 ]]; do
    case "$1" in
    --bin)
        bin=$(rlocation "$2")
        shift 2
        ;;
    --config)
        config=$(rlocation "$2")
        shift 2
        ;;
    --shellcheck)
        shellcheck=$(rlocation "$2")
        shift 2
        ;;
    --)
        shift
        break
        ;;
    *)
        echo >&2 "$0: unknown flag: $1"
        exit 2
        ;;
    esac
done

if [[ -z "$bin" || -z "$config" || -z "$shellcheck" ]]; then
    echo >&2 "$0: --bin, --config, and --shellcheck are all required"
    exit 2
fi

files=()
for path in "$@"; do
    files+=("$(rlocation "$path")")
done

exec "$bin" -config-file "$config" -shellcheck "$shellcheck" -color "${files[@]}"
