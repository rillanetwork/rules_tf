#!/usr/bin/env bash

# Writes the `.terraform/modules/modules.json` that points terraform at the
# mirrored module store, so `init` resolves remote modules from disk.
#
# Run at execution time rather than built as an artefact: the manifest's `Dir`
# entries must be absolute, and only the running process knows where its
# runfiles were laid out.
#
# Local modules are seeded too, though terraform can install them itself:
# installing one discards whatever the manifest held beneath it, so a mirrored
# module nested inside a local module survives only if its parent is listed.
#
# usage: module_manifest.sh <store-table> <calls> <module-dir>

set -euo pipefail

TABLE="$1"
CALLS="$2"
DIR="$3"

# A module reaching no remote modules needs no manifest, and writing an empty
# one would only tell terraform that nothing is installed.
if [ ! -s "$CALLS" ]; then
    exit 0
fi

TAB="$(printf '\t')"

# The store table separates fields with a unit separator, not a tab: a closure's
# root member has an empty relative key, and `read` collapses empty fields when
# the separator is whitespace.
FIELD="$(printf '\037')"

# Matches a module call back to the entry it was mirrored under. terraform-docs
# splits a trailing "?ref=" out of a getter source into the version column, so
# the literal is recomposed here and tried alongside the registry spelling;
# whichever the manifest actually recorded is the one that matches.
resolve_spec() {
    local source="$1" version="$2" candidate matches count

    for candidate in \
        "${version:+$source@$version}" \
        "${version:+$source?ref=$version}" \
        "$source"; do
        [ -n "$candidate" ] || continue
        if grep -qF "E$FIELD$candidate$FIELD" "$TABLE"; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    # A constraint in the configuration need not be spelled the way the mirror
    # declares it -- pinning an exact version in MODULE.bazel while a module
    # asks for "~> 2.1" is the ordinary case -- so a single mirrored entry for
    # the same source answers it. Terraform still checks that the version it
    # finds satisfies the constraint.
    matches="$(awk -F"$FIELD" -v s="$source" '$1 == "E" && $3 == s { print $2 }' "$TABLE")"
    count="$(printf '%s' "$matches" | grep -c . || true)"

    if [ "$count" = "1" ]; then
        printf '%s' "$matches"
        return 0
    fi

    if [ "$count" = "0" ]; then
        echo "module_manifest: no mirrored module matches \"$source\"${version:+ version \"$version\"}." >&2
        echo "  Add it to the tf.download modules list in MODULE.bazel." >&2
    else
        echo "module_manifest: \"$source\" is mirrored at several versions, so the one \"$version\" wants cannot be chosen:" >&2
        printf '    %s\n' $matches >&2
    fi
    exit 1
}

# Only \ and " are special in a JSON string, and no other control character
# survives an HCL source or a filesystem path here.
json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

records=""

add_record() {
    local key="$1" source="$2" version="$3" dir="$4" record

    record="{\"Key\":\"$(json_escape "$key")\",\"Source\":\"$(json_escape "$source")\""
    if [ -n "$version" ]; then
        record="$record,\"Version\":\"$(json_escape "$version")\""
    fi
    record="$record,\"Dir\":\"$(json_escape "$dir")\"}"

    records="$records,
    $record"
}

# Terraform writes the calling module in as the empty key, relative to the
# directory it runs in.
records="    {\"Key\":\"\",\"Source\":\"\",\"Dir\":\".\"}"

# Each closure is read from a file rather than a process substitution, whose
# exit status bash never checks: a failure there would silently contribute no
# modules and leave the build green.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

while IFS="$FIELD" read -r kind call source version dir; do
    [ -n "$call" ] || continue

    # A local module is recorded exactly as terraform records it: the source as
    # written, and a directory relative to the module being initialised.
    if [ "$kind" = "L" ]; then
        add_record "$call" "$source" "" "$dir"
        continue
    fi

    spec="$(resolve_spec "$source" "$version")"

    # The closure recorded for that entry, keyed relative to the entry itself,
    # so a nested module lands under the call path that reached it.
    awk -F"$FIELD" -v s="$spec" -v fs="$FIELD" \
        '$1 == "M" && $2 == s { print $3 fs $4 fs $5 fs $6 }' \
        "$TABLE" > "$SCRATCH/closure"

    while IFS="$FIELD" read -r relative member_source member_version dir; do
        [ -n "$dir" ] || continue

        key="$call"
        if [ -n "$relative" ]; then
            key="$call.$relative"
        fi

        # Absolute, because terraform resolves a manifest Dir against its own
        # working directory rather than against the manifest's location.
        add_record "$key" "$member_source" "$member_version" "$PWD/$dir"
    done < "$SCRATCH/closure"
done < "$CALLS"

mkdir -p "$DIR/.terraform/modules"

# Written fresh rather than linked: terraform rewrites this file during init,
# and a runfiles symlink would put that write through to the store.
printf '{"Modules":[\n%s\n]}\n' "$records" > "$DIR/.terraform/modules/modules.json"
