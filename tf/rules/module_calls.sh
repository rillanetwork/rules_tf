#!/usr/bin/env bash

# Emits every remote module a terraform module reaches, keyed by the call path
# terraform will look it up under.
#
# Terraform keys `.terraform/modules/modules.json` by call path -- "vpc",
# "vpc.label", "amodule.sg" -- which exists only in the HCL, so a mirrored
# module cannot be handed to terraform without reading the call names back out
# of the configuration. terraform-docs does that parsing; this script walks the
# local module tree and composes the dotted keys.
#
# Local calls are traversed but not emitted: terraform installs local modules
# itself, and only remote ones need to be supplied from the store.
#
# usage: module_calls.sh <terraform-docs> <config> <module-dir> <out>
#
# Output is TSV, `<call path>\t<source>\t<version>`, sorted. The source and
# version are as terraform-docs reports them, which for a getter source means a
# trailing "?ref=" has been split into the version column; recomposing the
# literal source is the caller's job, since only it knows which spellings the
# mirror recorded.

set -euo pipefail

TFDOC="$1"
CONFIG="$2"
ROOT="$3"
OUT="$4"

# Bounds a configuration that calls itself. Terraform would not accept one
# either, but it would recurse here first.
MAX_DEPTH=32

# terraform-docs is invoked from whichever directory is being read, so its own
# path and its config's must survive the change of directory.
TFDOC="$(cd "$(dirname "$TFDOC")" && pwd -P)/$(basename "$TFDOC")"
CONFIG="$(cd "$(dirname "$CONFIG")" && pwd -P)/$(basename "$CONFIG")"

TAB="$(printf '\t')"

emit() {
    local dir="$1" prefix="$2" depth="$3"
    local name source version target

    if [ "$depth" -gt "$MAX_DEPTH" ]; then
        echo "module_calls: nesting exceeded $MAX_DEPTH levels at $dir; a module calls itself" >&2
        exit 1
    fi

    while IFS="$TAB" read -r name source version; do
        [ -n "$name" ] || continue

        case "$source" in
            ./* | ../* | /*)
                # A local call contributes its own calls under the name it was
                # reached by, so one module used twice is seeded twice.
                target="$dir/$source"
                if [ ! -d "$target" ]; then
                    echo "module_calls: $dir calls local module \"$name\" at $source, which is not among the module's sources; add it to deps" >&2
                    exit 1
                fi
                emit "$target" "$prefix$name." "$((depth + 1))"
                ;;
            *)
                printf '%s\t%s\t%s\n' "$prefix$name" "$source" "$version"
                ;;
        esac
    done < <("$TFDOC" -c "$CONFIG" "$dir")
}

emit "$ROOT" "" 0 | LC_ALL=C sort > "$OUT"
