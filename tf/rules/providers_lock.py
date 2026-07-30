"""Records signature-verified provider hashes into MODULE.bazel.lock.

`terraform providers lock` verifies the registry's SHA256SUMS signature against
the public keys compiled into the terraform binary, then writes the resulting
package hashes as `zh:` entries. A `zh:` value is exactly the sha256 of a
release zip, which is the same thing the mirror fetches against -- so those
hashes let the mirror admit a package on a signature rather than on the
registry's word.

This runs the lock command over the mirror manifest and merges what it verified
into the `facts` section of the consumer's MODULE.bazel.lock, alongside the
resolved coordinates the module extension already records there. The extension
reads those facts back on its next evaluation, so nothing here needs a lock
file of its own.

A dependency lock records one version per provider while a mirror may stock
several, so the manifest is split into version sets and the lock command runs
once per set.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

# Written by the module extension; kept in step with `verified_fact_key` in
# tf/toolchains/utils.bzl. Not platform-scoped, because a zh: hash set covers
# every platform's package and the lock does not record which is which.
VERIFIED_FACT_PREFIX = "verified"

_PROVIDER_BLOCK = re.compile(
    r'provider\s+"(?P<address>[^"]+)"\s*\{(?P<body>.*?)\n\}',
    re.DOTALL,
)
_VERSION = re.compile(r'^\s*version\s*=\s*"(?P<version>[^"]+)"', re.MULTILINE)
_ZH_HASH = re.compile(r'"zh:(?P<hash>[0-9a-f]+)"')


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, help="JSON written by the tf_providers_lock rule.")
    parser.add_argument("--tool", required=True, help="Path to the terraform/tofu binary to run.")
    parser.add_argument("--lockfile", required=True, help="MODULE.bazel.lock to merge the hashes into.")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report what would be recorded without writing the lockfile.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Like --dry-run, but exit non-zero when the lockfile is not already up to date.",
    )
    return parser.parse_args(argv)


def version_key(version):
    """Orders versions, so the split into version sets is the same every run.

    Total, deliberately: two versions that compared equal would leave the
    grouping to set iteration order, which varies between processes. Precedence
    follows semver in the two respects that matter here -- a prerelease precedes
    the release it qualifies, and build metadata does not count.
    """
    core, _, prerelease = version.partition("-")
    core = core.partition("+")[0]
    prerelease = prerelease.partition("+")[0]

    numbers = [int(part) if part.isdigit() else 0 for part in core.split(".")]
    return (numbers, 0 if prerelease else 1, prerelease)


def qualify(source, default_registry):
    """Expands a mirror source to the host-qualified address terraform uses."""
    parts = source.split("/")
    if len(parts) == 2:
        return "%s/%s" % (default_registry, source)
    return source


def parse_manifest(mirror_versions, default_registry):
    """Turns "[host/]ns/type@version" manifest entries into (address, version) pairs."""
    wanted = {}
    for entry in mirror_versions:
        source, _, version = entry.rpartition("@")
        if not source or not version:
            raise SystemExit("rules_tf: cannot parse mirror entry %r" % entry)
        wanted.setdefault(qualify(source, default_registry), set()).add(version)
    return wanted


def version_sets(wanted):
    """Splits the manifest into sets holding at most one version per provider.

    A `.terraform.lock.hcl` records a single version per provider, so a mirror
    stocking a provider at N versions needs N runs of the lock command.
    """
    ordered = {address: sorted(versions, key=version_key) for address, versions in wanted.items()}
    depth = max(len(versions) for versions in ordered.values())

    sets = []
    for index in range(depth):
        sets.append({
            address: versions[index]
            for address, versions in ordered.items()
            if index < len(versions)
        })
    return sets


def local_names(addresses):
    """Assigns each address a required_providers local name.

    The name is arbitrary, since `source` states the provider outright, but
    terraform restricts it to letters, digits and dashes -- so the address is
    transliterated, and a collision between two addresses that transliterate
    alike is broken with a suffix.
    """
    names = {}
    taken = {}
    for address in sorted(addresses):
        base = re.sub(r"[^a-z0-9]+", "-", address.lower()).strip("-")
        seen = taken.get(base, 0)
        taken[base] = seen + 1
        names[address] = base if seen == 0 else "%s-%d" % (base, seen)
    return names


def required_providers_document(version_set):
    names = local_names(version_set.keys())
    return {
        "terraform": {
            "required_providers": {
                names[address]: {"source": address, "version": version}
                for address, version in sorted(version_set.items())
            },
        },
    }


def run_lock(tool, version_set, platforms, workdir):
    """Runs `<tool> providers lock` over one version set and returns its lock file."""
    with open(os.path.join(workdir, "versions.tf.json"), "w") as handle:
        json.dump(required_providers_document(version_set), handle, indent=2)

    # No -platform by default, which locks for the host. The zh: hashes come
    # from the signed SHA256SUMS document and so cover every platform's package
    # whatever is asked for; -platform only decides which packages are
    # downloaded to compute the h1: hashes this ignores.
    command = [tool, "-chdir=%s" % workdir, "providers", "lock"]
    command += ["-platform=%s" % platform for platform in platforms]

    print("rules_tf: %s" % " ".join(command), flush=True)
    result = subprocess.run(command)
    if result.returncode != 0:
        raise SystemExit(
            "rules_tf: `providers lock` failed for %s. The command verifies signatures against "
            "the registry, so it needs network access and any credentials the registry requires."
            % ", ".join("%s@%s" % item for item in sorted(version_set.items()))
        )

    lock_path = os.path.join(workdir, ".terraform.lock.hcl")
    if not os.path.exists(lock_path):
        raise SystemExit("rules_tf: `providers lock` wrote no .terraform.lock.hcl in %s" % workdir)

    with open(lock_path) as handle:
        return handle.read()


def parse_lock(document):
    """Reads {(address, version): [zh hashes]} out of a .terraform.lock.hcl.

    `h1:` hashes are ignored: they cover the extracted directory rather than
    the package, and only for the platforms the lock was generated for.
    """
    verified = {}
    for block in _PROVIDER_BLOCK.finditer(document):
        body = block.group("body")
        version = _VERSION.search(body)
        if not version:
            continue

        hashes = sorted({match.group("hash") for match in _ZH_HASH.finditer(body)})
        if hashes:
            verified[(block.group("address"), version.group("version"))] = hashes
    return verified


def harvest(tool, wanted, platforms):
    """Runs the lock command over every version set and merges the results."""
    verified = {}
    for version_set in version_sets(wanted):
        workdir = tempfile.mkdtemp(prefix="rules_tf_providers_lock_")
        try:
            verified.update(parse_lock(run_lock(tool, version_set, platforms, workdir)))
        finally:
            shutil.rmtree(workdir, ignore_errors=True)

    missing = sorted(
        "%s@%s" % (address, version)
        for address, versions in wanted.items()
        for version in versions
        if (address, version) not in verified
    )
    if missing:
        raise SystemExit(
            "rules_tf: no verified hashes were produced for: %s. Every mirror entry must be "
            "lockable, or the mirror would still admit those packages on the registry's word."
            % ", ".join(missing)
        )

    return verified


def merge_into_lockfile(path, extension_key, verified, dry_run, check):
    """Merges the verified hashes into the extension's facts, in place.

    Merged rather than replaced: one target covers one toolchain, and a module
    may declare several. Entries that leave the manifest are dropped by the
    extension itself, which rebuilds its facts from what it looked up.
    """
    try:
        with open(path) as handle:
            document = json.load(handle)
    except FileNotFoundError:
        raise SystemExit(
            "rules_tf: %s does not exist. Resolve the module first (`bazel mod deps`), so there "
            "is a lockfile to record the verified hashes in." % path
        )

    facts = document.setdefault("facts", {}).setdefault(extension_key, {})

    added = 0
    changed = 0
    for (address, version), hashes in sorted(verified.items()):
        key = "%s/%s/%s" % (VERIFIED_FACT_PREFIX, address, version)
        value = {"zh": hashes}
        if key not in facts:
            added += 1
        elif facts[key] != value:
            changed += 1
        facts[key] = value

    document["facts"][extension_key] = dict(sorted(facts.items()))

    print(
        "rules_tf: %d provider version(s) verified, %d new, %d updated"
        % (len(verified), added, changed)
    )

    if check:
        if added or changed:
            raise SystemExit(
                "rules_tf: %s does not hold the current verified hashes (%d new, %d updated). "
                "Run this target without --check and commit the result."
                % (path, added, changed)
            )
        print("rules_tf: %s is up to date" % path)
        return

    if dry_run:
        print("rules_tf: --dry-run, leaving %s alone" % path)
        return

    with open(path, "w") as handle:
        json.dump(document, handle, indent=2)
        handle.write("\n")

    print("rules_tf: wrote %s" % path)
    print(
        "rules_tf: the hashes are enforced the next time the extension evaluates; "
        "review the diff and commit it."
    )


def main(argv):
    args = parse_args(argv)

    with open(args.config) as handle:
        config = json.load(handle)

    if not config["mirror_versions"]:
        raise SystemExit("rules_tf: the mirror is empty, so there is nothing to lock")

    wanted = parse_manifest(config["mirror_versions"], config["default_registry"])
    verified = harvest(args.tool, wanted, config["platforms"])
    merge_into_lockfile(
        args.lockfile,
        config["extension_key"],
        verified,
        args.dry_run,
        args.check,
    )


if __name__ == "__main__":
    main(sys.argv[1:])
