def get_sha256sum(shasums, file):
    lines = shasums.splitlines()
    for line in lines:
        if not line.endswith(file):
            continue
        return line.split(" ")[0].strip()

    return None

_DIGITS = "0123456789"

# Semver identifier characters, for prerelease and build-metadata segments.
_IDENT_CHARS = _DIGITS + "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-"

def _is_numeric(s):
    if s == "":
        return False
    for c in s.elems():
        if c not in _DIGITS:
            return False
    return True

def _is_dot_separated_idents(s):
    """True if s is a non-empty '.'-separated list of semver identifiers."""
    if s == "":
        return False
    for part in s.split("."):
        if part == "":
            return False
        for c in part.elems():
            if c not in _IDENT_CHARS:
                return False
    return True

def _is_exact_version(version):
    """True if version is an exact semver pin: 'x.y.z[-prerelease][+build]'.

    Registries publish prerelease versions (e.g. 'hashicorp/aws:6.0.0-beta1'),
    which are exact pins just as much as a bare 'x.y.z' is -- the check here
    only needs to reject range/constraint syntax ('>= 1.0', '~> 3.0', ...).
    """
    rest = version

    plus = rest.split("+", 1)
    rest = plus[0]
    if len(plus) == 2 and not _is_dot_separated_idents(plus[1]):
        return False

    dash = rest.split("-", 1)
    core = dash[0]
    if len(dash) == 2 and not _is_dot_separated_idents(dash[1]):
        return False

    parts = core.split(".")
    if len(parts) != 3:
        return False
    for part in parts:
        if not _is_numeric(part):
            return False
    return True

def parse_mirror_entries(mirror):
    """Parses a list of "[hostname/]namespace/type:version" strings.

    Returns a list of {"source": ..., "version": ...} dicts, deduplicated on
    (source, version). Fails on malformed entries or duplicates.

    BREAKING: versions must be exact 'x.y.z' pins. The mirror is fetched via
    `ctx.download_and_extract`, which needs a concrete (version, sha256) to be
    content-addressable and cacheable, so ranges and operators (`>=`, `~>`, ...)
    are rejected rather than resolved against the registry. This is a narrower
    input contract than the previous `terraform init` path accepted; it applies
    only to this pre-fetch manifest. Module `required_providers` constraints are
    unaffected and still resolve (ranges included) against the mirror at init.
    """
    seen = {}
    parsed = []
    for entry in mirror:
        elems = entry.split(":")
        if len(elems) != 2 or elems[0] == "" or elems[1] == "":
            fail("mirror entry must be of the form '[hostname/]namespace/type:version', was: %s" % entry)

        source = elems[0]
        version = elems[1]

        source_elems = source.split("/")
        if len(source_elems) < 2 or len(source_elems) > 3:
            fail("mirror entry source must be '[hostname/]namespace/type', was: %s" % source)

        if not _is_exact_version(version):
            fail(("mirror entry version must be an exact 'x.y.z[-prerelease][+build]' pin, not a range/constraint " +
                  "(got '%s' in '%s'). The mirror pre-fetches concrete provider versions, so " +
                  "pin the exact version here; module required_providers blocks may still use " +
                  "ranges -- they resolve against the mirror at init time.") % (version, entry))

        key = "%s@%s" % (source, version)
        if key in seen:
            fail("duplicate mirror entry: %s" % entry)
        seen[key] = True
        parsed.append({"source": source, "version": version})

    return parsed

def provider_source_parts(source, default_host):
    """Splits a "[hostname/]namespace/type" source into (host, namespace, type).

    Host defaults to `default_host` when the source carries no host prefix. The
    source shape itself is already validated by `parse_mirror_entries`.
    """
    parts = source.split("/")
    if len(parts) == 2:
        return default_host, parts[0], parts[1]
    return parts[0], parts[1], parts[2]

def download_provider_to_mirror(ctx, host, namespace, provider_type, version, os, arch):
    """Fetches one provider into the unpacked filesystem-mirror layout.

    Queries the registry download endpoint for the concrete `download_url` and
    sha256 `shasum`, then routes the provider zip through
    `ctx.download_and_extract` so its bytes land in Bazel's `--repository_cache`
    (keyed by sha) and are served offline on subsequent runs. This replaces the
    old `terraform init` subprocess, whose downloads bypassed the repository
    cache entirely.

    The extract target reproduces the "unpacked" filesystem-mirror layout that
    downstream `terraform init -plugin-dir=<mirror>` consumes, letting init
    symlink the plugin into each module's .terraform/providers/ rather than
    extracting a fresh ~750MB copy per target.

    Only the host platform is mirrored, matching the host-scoped toolchain repo.
    """
    meta_url = "https://{host}/v1/providers/{ns}/{type}/{version}/download/{os}/{arch}".format(
        host = host,
        ns = namespace,
        type = provider_type,
        version = version,
        os = os,
        arch = arch,
    )

    # The metadata JSON is not content-addressable (its sha is unknown ahead of
    # time), so this small fetch is always live; only the provider bytes below
    # are cache-served. Read into a per-entry temp path to avoid collisions.
    meta_file = "provider_meta_{ns}_{type}_{version}.json".format(
        ns = namespace,
        type = provider_type,
        version = version,
    )
    # allow_fail lets the actionable message below surface instead of Bazel's
    # raw HTTP error, which does not say which mirror entry was at fault.
    res = ctx.download(url = [meta_url], output = meta_file, allow_fail = True)
    if not res.success:
        fail(("failed to fetch provider metadata for %s/%s/%s %s (%s/%s) from %s -- check that " +
              "the source and version exist in the registry") % (
            host,
            namespace,
            provider_type,
            version,
            os,
            arch,
            meta_url,
        ))

    meta = json.decode(ctx.read(meta_file))
    ctx.delete(meta_file)

    output = "mirror/{host}/{ns}/{type}/{version}/{os}_{arch}".format(
        host = host,
        ns = namespace,
        type = provider_type,
        version = version,
        os = os,
        arch = arch,
    )

    res = ctx.download_and_extract(
        url = meta["download_url"],
        sha256 = meta["shasum"],
        type = "zip",
        output = output,
        allow_fail = True,
    )
    if not res.success:
        fail("failed to download provider %s/%s/%s %s from %s" % (
            host,
            namespace,
            provider_type,
            version,
            meta["download_url"],
        ))

def mirror_manifest(parsed_entries):
    """Returns the canonical "source@version" strings used as the toolchain manifest."""
    return ["%s@%s" % (e["source"], e["version"]) for e in parsed_entries]
