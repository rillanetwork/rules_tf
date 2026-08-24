"""Signature-derived hashes, and checking mirrored packages against them.

A `zh:` hash in a `.terraform.lock.hcl` is one that survived a signature check
against the keys embedded in the tf binary, which makes it a trust root
independent of whatever a registry later claims when the package is fetched.
The helpers here read those hashes out of a lock file, produce them by running
`providers lock` when no lock file covers an entry, and match a resolved
package's sha256 against them before the mirror is allowed to fetch it.

The same documents carry `h1:` hashes, which cover the extracted directory a
mirror hands terraform rather than the release zip. They verify nothing here --
only terraform can compute one, over a tree it already has -- but they are what
makes a generated `.terraform.lock.hcl` complete, so they are read alongside
and carried out for the renderer.
"""

load(":checksums.bzl", "DEFAULT_ARCHIVE_TEMPLATE")
load(":facts.bzl", "dirhash_fact_key", "package_fact_key")

# `providers lock` fetches a package per provider, so the ceiling is a download
# rather than a computation.
_LOCK_TIMEOUT = 1800

_VERSIONS_TF_JSON = """{
  "terraform": {
    "required_providers": {
      "p": {
        "source": "%s",
        "version": "%s"
      }
    }
  }
}
"""

def _hashes_in_line(text, scheme):
    """Every hash of one scheme quoted on one line, with the prefix stripped."""
    prefix = scheme + ":"
    found = []
    parts = text.split("\"")

    # Quoted values are the odd-numbered fields of a split on the quote.
    for i in range(1, len(parts), 2):
        if parts[i].startswith(prefix):
            found.append(parts[i][len(prefix):])

    return found

def parse_provider_locks(documents):
    """Merges `.terraform.lock.hcl` documents into a `zh:` and an `h1:` table.

    A terraform dependency lock file records, per provider, the sha256 of the
    release package for every platform, as `zh:` entries. Those hashes are
    produced by `terraform providers lock`, which verifies the registry's
    SHA256SUMS against the signing keys embedded in the terraform binary -- so
    a `zh:` value is a hash that survived a signature check, and is a trust
    root independent of whatever the registry later claims.

    A lock file holds one version per provider, while a mirror may stock
    several, so several documents merge into one table keyed by source and
    version.

    `h1:` hashes come back in a table of their own, never mixed into the `zh:`
    one: they are a dirhash over the extracted package, so a mirrored package's
    sha256 must never be admitted by matching one, and only the `zh:` table is
    what `verify_provider_hashes` checks against. They matter to the generated
    lock document instead, which terraform reads against an extracted
    directory, and they carry no platform label -- a document lists them flat,
    however many platforms it was generated for.

    The grammar used here is the narrow subset terraform itself emits, not
    general HCL.

    Args:
      documents: contents of one or more `.terraform.lock.hcl` files.

    Returns:
      A (zh, h1) tuple, each shaped
      {"<host>/<ns>/<type>@<version>": {"<hash>": True}} with the scheme prefix
      stripped, merged across every document given.
    """
    locks = {}
    dirhashes = {}
    for raw in documents:
        address = ""
        version = ""
        hashes = []
        dirs = []
        in_hashes = False

        for line in raw.splitlines():
            text = line.strip()
            if text == "" or text.startswith("#"):
                continue

            if text.startswith("provider \""):
                address = text.split("\"")[1]
                version = ""
                hashes = []
                dirs = []
                in_hashes = False
                continue

            if address == "":
                continue

            if in_hashes:
                hashes += _hashes_in_line(text, "zh")
                dirs += _hashes_in_line(text, "h1")
                if "]" in text:
                    in_hashes = False
                continue

            if text.startswith("hashes"):
                # `hashes = [...]` may be written on one line or span several.
                hashes += _hashes_in_line(text, "zh")
                dirs += _hashes_in_line(text, "h1")
                in_hashes = "]" not in text
            elif text.startswith("version"):
                parts = text.split("\"")
                if len(parts) >= 2:
                    version = parts[1]
            elif text.startswith("}"):
                if version != "":
                    key = "%s@%s" % (address, version)
                    merged = locks.get(key, {})
                    for h in hashes:
                        merged[h] = True
                    locks[key] = merged

                    merged_dirs = dirhashes.get(key, {})
                    for h in dirs:
                        merged_dirs[h] = True
                    if merged_dirs:
                        dirhashes[key] = merged_dirs
                address = ""

    return locks, dirhashes

def merge_provider_locks(a, b):
    """Unions two `parse_provider_locks`-shaped tables.

    Args:
      a: one table of hashes; not mutated.
      b: another table, whose hashes are added to a's.

    Returns:
      A new table holding every hash from both.
    """
    merged = {k: dict(v) for k, v in a.items()}
    for key, hashes in b.items():
        merged.setdefault(key, {}).update(hashes)
    return merged

def unverified_packages(facts, packages, platforms):
    """The packages whose recorded coordinates carry no verification yet.

    Verification covers a version rather than a platform: one `zh:` set holds
    the hash of every platform's package. A version is pending while any
    platform's recorded coordinates still lack the flag.

    Args:
      facts: the fact table this evaluation will return.
      packages: resolved coordinates, one per provider version.
      platforms: the platforms whose coordinates were resolved.

    Returns:
      The subset of `packages` still to verify.
    """
    pending = []
    for p in packages:
        for platform in platforms:
            meta = facts.get(package_fact_key(
                p["host"],
                p["namespace"],
                p["type"],
                p["version"],
                platform,
            ))
            if meta and not meta.get("verified"):
                pending.append(p)
                break

    return pending

def fetch_lock_tool(
        ctx,
        tool,
        version,
        os,
        arch,
        url_template,
        sha256,
        archive_template = DEFAULT_ARCHIVE_TEMPLATE):
    """Downloads a binary the extension verifies with, into its working directory.

    The archive is content-addressed by the sha256 already resolved for it, so
    the toolchain repository fetches the same URL later and finds it in
    `--repository_cache`.

    Each release unpacks under its own name: one evaluation fetches terraform
    to lock providers and tflint to check ruleset signatures, and several
    download tags may ask for different versions of either.

    Args:
      ctx: the module extension's `module_ctx`.
      tool: the tool's name, which names both its archive and its directory.
      version: the release to fetch.
      os: the host operating system, in the release's spelling.
      arch: the host architecture, in the release's spelling.
      url_template: release archive URL, taking `{version}` and `{file}`.
      sha256: the release archive's sha256, from `resolve_tool_sha256`.
      archive_template: the archive's name as the release publishes it, taking
        `{tool}`, `{version}`, `{os}` and `{arch}`. Stated by the caller for
        the reason `resolve_tool_sha256` has it stated: the tools do not agree
        on how an archive is named.

    Returns:
      The path of the extracted binary.
    """
    file = archive_template.format(
        tool = tool,
        version = version,
        os = os,
        arch = arch,
    )
    output = "lock/{tool}_{version}".format(tool = tool, version = version)

    ctx.download_and_extract(
        url = url_template.format(version = version, file = file),
        sha256 = sha256,
        type = "zip",
        output = output,
    )

    return ctx.path("%s/%s" % (output, tool))

def lock_providers(ctx, tool, packages, platforms):
    """Runs `<tool> providers lock` over each package and returns the hashes it verified.

    The lock command verifies the registry's SHA256SUMS signature against the
    signing keys the tf binary carries, then records the sha256 of every
    platform's release package as a `zh:` entry. A hash it emits is therefore
    one a publisher signed, which is a trust root independent of whatever the
    registry claims when the package is later fetched.

    One run per version, each over a single-provider configuration: a
    `.terraform.lock.hcl` holds one version per provider, and asking for one at
    a time lets a mirror stock as many versions of a provider as it likes.

    Every platform is named with a `-platform=` flag, which is what makes the
    run emit an `h1:` dirhash per platform rather than only for the machine it
    ran on. That costs a package download each -- the `zh:` values come from the
    signed SHA256SUMS, but a dirhash can only be computed over an unpacked
    package -- and it is what lets one generated lock document serve every
    machine in a team. The flag also narrows what is recorded to the platforms
    named, so `platforms` must cover every one whose coordinates were resolved,
    or `verify_provider_hashes` would find a package no `zh:` entry covers.

    Args:
      ctx: the module extension's `module_ctx`.
      tool: path of the terraform or tofu binary to run.
      packages: resolved coordinates to verify.
      platforms: the platforms to lock for, each as "<os>_<arch>".

    Returns:
      A (zh, h1) tuple, shaped as `parse_provider_locks` produces them.
    """
    locks = {}
    dirhashes = {}
    for index, p in enumerate(packages):
        address = "%s/%s/%s" % (p["host"], p["namespace"], p["type"])
        workdir = "lock/%d" % index

        ctx.report_progress("Verifying %s %s (%d platforms)" % (
            address,
            p["version"],
            len(platforms),
        ))
        ctx.file(
            workdir + "/versions.tf.json",
            _VERSIONS_TF_JSON % (address, p["version"]),
            executable = False,
        )

        # The environment is inherited, so a registry's credentials reach the
        # tool the way they reach it anywhere else: a CLI configuration file, or
        # the TF_TOKEN_<host> variables.
        result = ctx.execute(
            [tool, "-chdir=%s" % ctx.path(workdir), "providers", "lock"] +
            ["-platform=%s" % platform for platform in platforms],
            timeout = _LOCK_TIMEOUT,
        )
        if result.return_code != 0:
            fail(("could not verify %s %s: `providers lock` exited %d. The command checks the " +
                  "registry's signature, so it needs network access and any credentials the " +
                  "registry requires. Set provider_verification on the tf.download tag to " +
                  "mirror a registry that publishes no signatures.\n%s") % (
                address,
                p["version"],
                result.return_code,
                result.stderr,
            ))

        document = ctx.path(workdir + "/.terraform.lock.hcl")
        if not document.exists:
            fail("`providers lock` wrote no .terraform.lock.hcl for %s %s" % (address, p["version"]))

        run_locks, run_dirhashes = parse_provider_locks([ctx.read(document)])
        locks = merge_provider_locks(locks, run_locks)
        dirhashes = merge_provider_locks(dirhashes, run_dirhashes)

    return locks, dirhashes

def collect_provider_dirhashes(previous, packages, discovered):
    """The `h1:` hashes each package is known by, remembered ones included.

    A package's dirhashes only ever grow: what an evaluation discovers is
    unioned onto what a previous one recorded, because a lock document that
    dropped a platform's hash would send `init` back to appending its own. The
    remembered ones have to be read here rather than carried forward wholesale,
    since `module_ctx.facts` is a lookup with no iteration -- a key nobody asks
    for is a key the returned table loses.

    A package with no dirhashes from either source is simply absent: a mirror
    built under `provider_verification = "off"` never runs the tool, and a
    supplied lock file usually covers one platform, so incompleteness is the
    ordinary case rather than an error.

    Args:
      previous: the persisted fact table, `module_ctx.facts`.
      packages: resolved coordinates, one per provider version.
      discovered: `h1:` hashes found this evaluation, as
        `parse_provider_locks` returns them.

    Returns:
      {"<host>/<ns>/<type>@<version>": ["<h1 hash>", ...]}, covering only the
      packages something knows a hash for.
    """
    collected = {}
    for p in packages:
        key = "%s/%s/%s@%s" % (p["host"], p["namespace"], p["type"], p["version"])
        hashes = dict(discovered.get(key, {}))

        remembered = previous.get(dirhash_fact_key(
            p["host"],
            p["namespace"],
            p["type"],
            p["version"],
        ))
        if remembered:
            for h in remembered["hashes"].split(","):
                if h:
                    hashes[h] = True

        if hashes:
            collected[key] = sorted(hashes)

    return collected

def verify_provider_hashes(facts, packages, platforms, locks):
    """Checks every recorded package hash against the verified set, and marks it.

    Each platform's coordinates are checked, not just the host's: one `zh:` set
    covers them all, so a lockfile written on one machine arrives verified on
    every other.

    A package survives this only by matching a hash a publisher signed, so the
    flag left behind is what lets a later "auto" evaluation take the recorded
    sha256 as a pin and reach neither the registry nor the tool. Packages
    already carrying the flag are checked like any other: whether a recorded
    mark spares a package this pass is the caller's decision, made by what it
    puts in `packages`.

    A hash mismatch always fails, in every mode: a package that contradicts a
    hash set covering it is never fine. A package no hash set covers is merely
    returned; what that means depends on the verification mode, which is the
    caller's to enforce (see `enforce_lock_coverage`).

    Args:
      facts: the fact table this evaluation will return; marked in place.
      packages: resolved coordinates to check.
      platforms: the platforms whose coordinates were resolved.
      locks: verified hashes, as `parse_provider_locks` produces them.

    Returns:
      The subset of `packages` no hash set covers.
    """
    uncovered = []
    for p in packages:
        key = "%s/%s/%s@%s" % (p["host"], p["namespace"], p["type"], p["version"])
        expected = locks.get(key)
        if not expected:
            uncovered.append(p)
            continue

        for platform in platforms:
            fact_key = package_fact_key(
                p["host"],
                p["namespace"],
                p["type"],
                p["version"],
                platform,
            )
            meta = facts.get(fact_key)
            if not meta:
                continue

            if meta["sha256"] not in expected:
                fail(("provider %s (%s) does not match the verified hashes: sha256 %s is not " +
                      "among the %d recorded for it. Either the hashes are stale, or the " +
                      "registry served a package that was not the signed one -- do not ignore " +
                      "this without establishing which.") % (
                    key,
                    platform,
                    meta["sha256"],
                    len(expected),
                ))

            verified = dict(meta)
            verified["verified"] = True
            facts[fact_key] = verified

    return uncovered

def enforce_lock_coverage(verification, packages):
    """Fails or warns for packages no verified hash covered, per the mode.

    Args:
      verification: the tag's provider_verification value.
      packages: resolved coordinates that remain uncovered after every hash
        source the mode allows has been consulted.
    """
    if not packages:
        return

    names = ", ".join([
        "%s/%s/%s@%s" % (p["host"], p["namespace"], p["type"], p["version"])
        for p in packages
    ])

    if verification == "off":
        # Left unmarked, so the check is retried rather than silently settled.
        print(("rules_tf: no verified hashes cover: %s. Those packages are mirrored on the " +
               "registry's word alone, with no signature-derived hash to check them " +
               "against.") % names)  # buildifier: disable=print
        return

    if verification == "files":
        fail(("no verified hashes cover: %s. Under provider_verification = 'files' every " +
              "mirrored package must match the provider_locks files, on every evaluation. " +
              "Add a .terraform.lock.hcl covering them, or set provider_verification to " +
              "'auto' so the extension locks them itself.") % names)

    # "auto", after `providers lock` already ran: the tool exited cleanly but
    # what it wrote covers none of these.
    fail(("no verified hashes cover: %s. `providers lock` ran for them but recorded no " +
          "matching zh: hashes -- the registry may not publish signatures for these " +
          "providers, which provider_verification = 'off' admits with a warning.") % names)
