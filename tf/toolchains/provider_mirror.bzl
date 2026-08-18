"""Resolving the provider mirror manifest, and fetching what it names.

The two halves run in different places and are kept together because they share
the shape of a resolved package. `resolve_providers` runs in the module
extension, turning "[hostname/]namespace/type:version" entries into concrete
coordinates and returning what it learned as facts; `download_providers` runs in
the download repository, fetching those coordinates against hashes the
extension already resolved, so it reaches no registry at all.
"""

load(
    ":facts.bzl",
    "MIRROR_PLATFORMS",
    "package_fact_key",
    "resolve_fact_key",
)
load(
    ":registry.bzl",
    "auth_headers",
    "new_registry_client",
    "providers_base_url",
    "resolve_url",
    "url_host",
)
load(
    ":semver.bzl",
    "is_exact_version",
    "parse_version_constraint",
    "select_matching_version",
)

def parse_mirror_entries(mirror):
    """Parses a list of "[hostname/]namespace/type:version" strings.

    A version is either an exact 'x.y.z[-prerelease][+build]' pin or a
    constraint (`>= 1.0`, `~> 3.0`, `>= 1.0, < 2.0`). Constraints are resolved
    against the registry's published version list when the mirror is built, and
    the selection is then held by an extension fact in `MODULE.bazel.lock`, so
    it does not drift on the next evaluation. Refresh a constraint deliberately
    with `bazel mod deps --lockfile_mode=refresh`.

    Args:
      mirror: the manifest, as the `mirror` attribute or `mirror_json` holds it.

    Returns:
      A list of {"source", "version", "is_exact"} dicts, deduplicated on
      (source, version). Fails on a malformed entry or a duplicate.
    """
    seen = {}
    parsed = []
    for entry in mirror:
        # Last colon only: a host may carry a port, a version never does.
        elems = entry.rsplit(":", 1)
        if len(elems) != 2 or elems[0] == "" or elems[1] == "":
            fail("mirror entry must be of the form '[hostname/]namespace/type:version', was: %s" % entry)

        source = elems[0]
        version = elems[1]

        source_elems = source.split("/")
        if len(source_elems) < 2 or len(source_elems) > 3:
            fail("mirror entry source must be '[hostname/]namespace/type', was: %s" % source)

        is_exact = is_exact_version(version)
        if not is_exact and parse_version_constraint(version) == None:
            fail(("mirror entry version must be an exact 'x.y.z[-prerelease][+build]' pin or a " +
                  "version constraint such as '>= 1.0', '~> 3.0' or '>= 1.0, < 2.0' " +
                  "(got '%s' in '%s')") % (version, entry))

        key = "%s@%s" % (source, version)
        if key in seen:
            fail("duplicate mirror entry: %s" % entry)
        seen[key] = True
        parsed.append({"source": source, "version": version, "is_exact": is_exact})

    return parsed

def provider_source_parts(source, default_host):
    """Splits a "[hostname/]namespace/type" source into (host, namespace, type).

    The source shape itself is already validated by `parse_mirror_entries`.

    Args:
      source: a mirror entry's source, with or without a leading host.
      default_host: host to assume when source carries no host prefix.

    Returns:
      A (host, namespace, type) tuple.
    """
    parts = source.split("/")
    if len(parts) == 2:
        return default_host, parts[0], parts[1]
    return parts[0], parts[1], parts[2]

def mirror_manifest(parsed_entries):
    """Returns the canonical "source@version" strings used as the toolchain manifest.

    Args:
      parsed_entries: entries carrying "source" and "version", as
        `parse_mirror_entries` and `resolve_providers` both produce.

    Returns:
      One "source@version" string per entry.
    """
    return ["%s@%s" % (e["source"], e["version"]) for e in parsed_entries]

def _provider_label(t):
    return "%s/%s/%s %s" % (t["host"], t["namespace"], t["type"], t["version"])

def _dedupe_targets(targets):
    """Drops targets addressing a package that an earlier target already covers.

    Two constraints can select the same version, and a constraint can land on a
    version an exact pin already names; mirroring one twice would race two
    downloads onto the same output directory.
    """
    deduped = []
    seen = {}
    for t in targets:
        key = "%s/%s/%s@%s" % (t["host"], t["namespace"], t["type"], t["version"])
        if key in seen:
            continue
        seen[key] = True
        deduped.append(t)

    return deduped

def _resolve_constraints(ctx, client, targets):
    """Replaces every constraint target's version with a concrete published one.

    The registry's version listing is fetched for each constrained provider,
    all in flight at once. Targets that already carry an exact pin cost nothing.
    """

    # A target whose host could not be discovered has already recorded an error;
    # there is no base URL to ask against, so it is left unresolved.
    constrained = [t for t in targets if not t["is_exact"] and t.get("base")]
    if len(constrained) == 0:
        return targets

    ctx.report_progress("Resolving %d version constraint(s)" % len(constrained))

    # One listing per provider however many constraints reference it. Fetching
    # per constraint would issue duplicate requests and, worse, race two
    # concurrent downloads onto the same output path.
    listings = {}
    for t in constrained:
        key = "%s/%s/%s" % (t["host"], t["namespace"], t["type"])
        t["listing"] = key
        if key in listings:
            continue
        listings[key] = {
            "host": t["host"],
            "url": "{base}{ns}/{type}/versions".format(
                base = t["base"],
                ns = t["namespace"],
                type = t["type"],
            ),
            "file": "provider_versions_%s.json" % key.replace("/", "_"),
        }

    for listing in listings.values():
        listing["pending"] = ctx.download(
            url = [listing["url"]],
            output = listing["file"],
            allow_fail = True,
            headers = auth_headers(client, listing["host"]),
            block = False,
        )

    for key, listing in listings.items():
        if not listing["pending"].wait().success:
            client["errors"].append(
                "failed to list versions of %s from %s" % (key, listing["url"]),
            )
            continue

        doc = json.decode(ctx.read(listing["file"]))
        listing["available"] = [v["version"] for v in doc.get("versions", []) if v.get("version")]

    for t in constrained:
        listing = listings[t["listing"]]
        available = listing.get("available")
        if available == None:
            continue

        selected = select_matching_version(available, t["version"])
        if selected == "":
            client["errors"].append(
                ("no published version of %s/%s/%s satisfies '%s' (%d version(s) offered by " +
                 "%s). Note that prereleases are never selected by a constraint -- pin the " +
                 "exact version to mirror one.") % (
                    t["host"],
                    t["namespace"],
                    t["type"],
                    t["version"],
                    len(available),
                    listing["url"],
                ),
            )
            continue

        t["version"] = selected
        t["is_exact"] = True

    return targets

def resolve_providers(ctx, entries, default_host, os, arch, facts):
    """Resolves every mirror entry to a concrete version, package URL and sha256.

    This runs in the module extension rather than in the download repo so that
    what it learns from the registry is returned as extension facts, which
    bzlmod persists in `MODULE.bazel.lock` -- a second evaluation then resolves
    from the lockfile and reaches the registry not at all.

    `facts` is the previously persisted table (`module_ctx.facts`). A hit on a
    `resolve/` key skips the version listing; a hit on a `package/` key skips
    the metadata request. A miss is not an error: that entry resolves live, and
    its result joins the facts returned to the caller.

    Work is batched rather than run per provider: every version listing is put
    in flight before any is awaited, then every metadata request likewise, so a
    manifest of N providers costs two rounds of latency instead of 2N.

    Coordinates are resolved for every platform in `MIRROR_PLATFORMS`, so one
    build writes a lockfile covering them all. Only the host's package is
    downloaded; a platform a provider does not publish is skipped, not fatal.

    Args:
      ctx: the module extension's `module_ctx`.
      entries: parsed manifest entries, from `parse_mirror_entries`.
      default_host: registry an unqualified source resolves against.
      os: host operating system, in terraform's spelling ("linux", "darwin").
      arch: host architecture, in terraform's spelling ("amd64", "arm64").
      facts: the previously persisted fact table, `module_ctx.facts`.

    Returns:
      A (packages, facts, errors) tuple: packages carries the concrete
      coordinates for this platform, facts is the table to hand back to bzlmod,
      and errors names every entry that could not be resolved.

      A registry failure is reported rather than fatal. Extension evaluation is
      not lazy, so failing here would break every build in the workspace,
      including ones that touch no terraform at all.
    """
    client = new_registry_client(ctx)

    targets = []
    for entry in entries:
        host, namespace, provider_type = provider_source_parts(entry["source"], default_host)
        t = {
            "source": entry["source"],
            "host": host,
            "namespace": namespace,
            "type": provider_type,
            "version": entry["version"],
            "is_exact": entry["is_exact"],
        }

        # Remembered against the spec as written: that is the question whose
        # answer is being recorded. Exact pins ask nothing.
        if not t["is_exact"]:
            t["spec"] = entry["version"]
            remembered = facts.get(resolve_fact_key(host, namespace, provider_type, t["spec"]))
            if remembered:
                t["version"] = remembered["version"]
                t["is_exact"] = True

        targets.append(t)

    # Service discovery blocks every registry URL and is memoized per host, so
    # resolve it up front -- but only for targets that still have a question.
    for t in targets:
        if not t["is_exact"]:
            t["base"] = providers_base_url(client, t["host"])

    targets = _resolve_constraints(ctx, client, targets)

    # Before the dedupe below, never after: two constraints can select the same
    # version, and the one that collapses would be left with no fact of its own
    # -- a lockfile that looks complete while that spec re-resolves every time.
    spec_facts = {}
    for t in targets:
        spec = t.get("spec")
        if spec and t["is_exact"]:
            spec_facts[resolve_fact_key(t["host"], t["namespace"], t["type"], spec)] = {
                "version": t["version"],
            }

    # A constraint left unresolved has recorded its error already; it carries no
    # concrete version, so there is nothing further to ask about it.
    targets = [t for t in targets if t["is_exact"]]

    targets = _dedupe_targets(targets)

    platform = "%s_%s" % (os, arch)

    # Every platform, not just the host, so the lockfile a build writes is
    # complete whichever machine wrote it. Host-only would leave the others to
    # append their facts later, dirtying the lockfile on the next machine to
    # build -- enough to fail a CI job that gates on a clean tree.
    wanted_platforms = list(MIRROR_PLATFORMS)
    if platform not in wanted_platforms:
        wanted_platforms.append(platform)

    requests = []
    for t in targets:
        t["metas"] = {}
        for p in wanted_platforms:
            remembered = facts.get(package_fact_key(
                t["host"],
                t["namespace"],
                t["type"],
                t["version"],
                p,
            ))
            if remembered:
                t["metas"][p] = remembered
            else:
                requests.append({"target": t, "platform": p})

    # An unknown API base needs service discovery, which costs a round trip and
    # can fail. Worth it for the host platform, whose package is about to be
    # fetched; for the others it only costs the lockfile some completeness. This
    # is what lets a workspace resolve from facts alone against a dead registry.
    for r in requests:
        t = r["target"]
        if r["platform"] == platform and not t.get("base"):
            t["base"] = providers_base_url(client, t["host"])

    requests = [
        r
        for r in requests
        if r["target"].get("base") or client["bases"].get(r["target"]["host"])
    ]
    if len(requests) > 0:
        ctx.report_progress("Resolving %d provider platform(s) from registry" % len(requests))

    for r in requests:
        t = r["target"]
        p = r["platform"]
        if not t.get("base"):
            t["base"] = client["bases"][t["host"]]

        p_os, _, p_arch = p.partition("_")
        r["url"] = "{base}{ns}/{type}/{version}/download/{os}/{arch}".format(
            base = t["base"],
            ns = t["namespace"],
            type = t["type"],
            version = t["version"],
            os = p_os,
            arch = p_arch,
        )

        # The metadata JSON is not content-addressable, so this small fetch is
        # live the first time; thereafter the fact answers it. Each lands in its
        # own path to avoid collisions between versions or platforms.
        r["file"] = "provider_meta_{host}_{ns}_{type}_{version}_{platform}.json".format(
            host = t["host"].replace(".", "_").replace(":", "_"),
            ns = t["namespace"],
            type = t["type"],
            version = t["version"],
            platform = p,
        )

        # allow_fail lets the actionable messages below surface instead of
        # Bazel's raw HTTP error, which does not say which entry was at fault.
        r["pending"] = ctx.download(
            url = [r["url"]],
            output = r["file"],
            allow_fail = True,
            headers = auth_headers(client, t["host"]),
            block = False,
        )

    for r in requests:
        t = r["target"]
        p = r["platform"]

        # Only the host platform's metadata is required. A provider shipping no
        # package for one of the others simply goes unrecorded.
        if not r["pending"].wait().success:
            if p != platform:
                continue
            client["errors"].append(
                ("failed to fetch provider metadata for %s (%s) from %s -- check that the " +
                 "source and version exist in the registry") % (
                    _provider_label(t),
                    p,
                    r["url"],
                ),
            )
            continue

        meta = json.decode(ctx.read(r["file"]))

        missing = [f for f in ["download_url", "shasum"] if not meta.get(f)]
        if len(missing) > 0:
            if p != platform:
                continue
            client["errors"].append("registry response for %s (%s) has no '%s'" % (
                _provider_label(t),
                r["url"],
                missing[0],
            ))
            continue

        # Resolved before it is recorded: the download repository never saw the
        # metadata request a relative URL would be relative to.
        t["metas"][p] = {
            "download_url": resolve_url(r["url"], meta["download_url"]),
            "sha256": meta["shasum"],
        }

    # Built fresh rather than merged: `module_ctx.facts` is a lookup, not an
    # iterable. The persisted facts therefore track the manifest exactly -- an
    # entry dropped from the mirror takes its facts with it.
    new_facts = dict(spec_facts)
    packages = []
    for t in targets:
        for p, meta in t["metas"].items():
            new_facts[package_fact_key(
                t["host"],
                t["namespace"],
                t["type"],
                t["version"],
                p,
            )] = meta

        if platform not in t["metas"]:
            client["errors"].append(
                "no package coordinates resolved for %s on %s" % (_provider_label(t), platform),
            )
            continue

        packages.append({
            "source": t["source"],
            "host": t["host"],
            "namespace": t["namespace"],
            "type": t["type"],
            "version": t["version"],
            "download_url": t["metas"][platform]["download_url"],
            "sha256": t["metas"][platform]["sha256"],
            # Every platform's hash, not just the host's: a generated
            # `.terraform.lock.hcl` covering one platform is what terraform
            # warns about.
            "hashes": sorted({meta["sha256"]: True for meta in t["metas"].values()}),
        })

    return packages, new_facts, client["errors"]

def download_providers(ctx, packages, os, arch):
    """Unpacks every resolved package into the filesystem-mirror layout.

    Every coordinate arrives already resolved, so this reaches no registry: it
    fetches known URLs against known hashes. That makes each package
    content-addressed for `--repository_cache`, so a warm cache serves the whole
    mirror offline.

    The extract target reproduces the "unpacked" filesystem-mirror layout that
    downstream `terraform init -plugin-dir=<mirror>` consumes, letting init
    symlink the plugin into each module's .terraform/providers/ rather than
    extracting a fresh copy per target.

    Args:
      ctx: the download repository's `repository_ctx`.
      packages: resolved coordinates, as `resolve_providers` returns them.
      os: host operating system, in terraform's spelling.
      arch: host architecture, in terraform's spelling.
    """
    if len(packages) == 0:
        # No placeholder: the mirror is consumed as the files under it, so an
        # empty one is genuinely no files, and the rules leave `-plugin-dir` off
        # rather than name a directory holding nothing.
        return

    ctx.report_progress("Downloading %d provider(s) into mirror" % len(packages))

    # Built solely for the credential lookup: a package served by the registry
    # host itself may need a token, which cannot travel as an attribute without
    # the lockfile recording it.
    client = new_registry_client(ctx)

    staged = []
    for p in packages:
        # Credentials go out only when the package is served by the registry
        # host itself. Public registries hand back a third-party object store
        # (releases.hashicorp.com, github.com) and must never receive the token.
        package_headers = {}
        if url_host(p["download_url"]) == p["host"]:
            package_headers = auth_headers(client, p["host"])

        # download + extract rather than download_and_extract: only `download`
        # accepts block = False, and putting every package in flight at once is
        # worth staging the zip. Host-qualified because two registries may serve
        # the same coordinate, and both are fetched concurrently.
        archive = "provider_pkg_{host}_{ns}_{type}_{version}.zip".format(
            host = p["host"].replace(".", "_").replace(":", "_"),
            ns = p["namespace"],
            type = p["type"],
            version = p["version"],
        )
        staged.append({
            "package": p,
            "archive": archive,
            "headers": package_headers,
            "output": "mirror/{host}/{ns}/{type}/{version}/{os}_{arch}".format(
                host = p["host"],
                ns = p["namespace"],
                type = p["type"],
                version = p["version"],
                os = os,
                arch = arch,
            ),
            "pending": ctx.download(
                url = [p["download_url"]],
                sha256 = p["sha256"],
                output = archive,
                allow_fail = True,
                headers = package_headers,
                block = False,
            ),
        })

    for s in staged:
        if not s["pending"].wait().success:
            p = s["package"]

            # allow_fail hides why: re-issue unsuppressed so Bazel's own error
            # distinguishes a checksum mismatch from a network failure.
            ctx.report_progress("Re-fetching %s to report why it failed" % _provider_label(p))
            ctx.download(
                url = [p["download_url"]],
                sha256 = p["sha256"],
                output = s["archive"],
                headers = s["headers"],
            )

        ctx.extract(archive = s["archive"], output = s["output"])
        ctx.delete(s["archive"])
