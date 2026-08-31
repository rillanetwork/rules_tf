#!/usr/bin/env bash

# Emits every module a terraform module reaches, keyed by the call path
# terraform will look it up under.
#
# Terraform keys `.terraform/modules/modules.json` by call path -- "vpc",
# "vpc.label", "amodule.sg" -- which exists only in the HCL, so a mirrored
# module cannot be handed to terraform without reading the call names back out
# of the configuration. terraform-docs does that parsing; this script walks the
# local module tree and composes the dotted keys.
#
# Local calls are walked into *and* recorded. Terraform installs a local module
# itself, but installing one discards whatever the manifest held beneath it, so
# a seeded remote module nested inside a local one survives only if its parent
# is seeded too.
#
# usage: module_calls.sh <terraform-docs> <config> <module-dir> <out>
#
# Output rows are `<kind> <call path> <source> <version> <dir>`, sorted, with
# fields separated by a unit separator rather than a tab: several fields are
# routinely empty, and `read` collapses empty fields when the separator is
# whitespace. Kind is `R` for a remote call or `L` for a local one; a local
# call carries the directory it resolves to, relative to this module, and a
# remote call carries the source and version as terraform-docs reports them,
# which for a getter source means a trailing "?ref=" has been split into the
# version. Recomposing the literal is the caller's job, since only it knows
# which spellings the mirror recorded.

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
FIELD="$(printf '\037')"

# Each directory's listing is captured here before it is read. Reading straight
# from a process substitution would hide a terraform-docs failure: bash never
# checks one's exit status, so unparseable HCL would arrive as a module with no
# calls at all, and the build would go green having mirrored nothing.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
READS=0

emit() {
    local dir="$1" prefix="$2" rel="$3" depth="$4"
    local name source version target child listing

    if [ "$depth" -gt "$MAX_DEPTH" ]; then
        echo "module_calls: nesting exceeded $MAX_DEPTH levels at $dir; a module calls itself" >&2
        exit 1
    fi

    READS=$((READS + 1))
    listing="$SCRATCH/calls.$READS"
    "$TFDOC" -c "$CONFIG" "$dir" > "$listing"

    while IFS="$TAB" read -r name source version; do
        [ -n "$name" ] || continue

        case "$source" in
            ./* | ../* | /*)
                target="$dir/$source"
                if [ ! -d "$target" ]; then
                    echo "module_calls: $dir calls local module \"$name\" at $source, which is not among the module's sources; add it to deps" >&2
                    exit 1
                fi

                # Terraform records a local module's directory relative to the
                # module it runs in, so the path accumulates down the walk.
                child="$source"
                if [ -n "$rel" ]; then
                    child="$rel/$source"
                fi

                printf 'L%s%s%s%s%s%s%s\n' \
                    "$FIELD" "$prefix$name" "$FIELD" "$source" "$FIELD" "" "$FIELD$child"

                # A local call contributes its own calls under the name it was
                # reached by, so one module used twice is seeded twice.
                emit "$target" "$prefix$name." "$child" "$((depth + 1))"
                ;;
            *)
                printf 'R%s%s%s%s%s%s%s\n' \
                    "$FIELD" "$prefix$name" "$FIELD" "$source" "$FIELD" "$version" "$FIELD"
                ;;
        esac
    done < "$listing"
}

emit "$ROOT" "" "" 0 | LC_ALL=C sort > "$OUT"
