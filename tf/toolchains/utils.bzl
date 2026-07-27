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

def _split_version(version, min_components, max_components):
    """Splits a semver string into ([major, minor, patch], [prerelease idents]).

    Missing trailing core components are padded with zero, so a partial operand
    such as '1.2' becomes [1, 2, 0]. Build metadata is validated then dropped,
    as semver excludes it from precedence. Returns None if version does not
    parse, along with the count of core components actually written.
    """
    plus = version.split("+", 1)
    if len(plus) == 2 and not _is_dot_separated_idents(plus[1]):
        return None

    body = plus[0].split("-", 1)
    pre = []
    if len(body) == 2:
        if not _is_dot_separated_idents(body[1]):
            return None
        pre = body[1].split(".")

    written = body[0].split(".")
    if len(written) < min_components or len(written) > max_components:
        return None

    core = []
    for part in written:
        if not _is_numeric(part):
            return None
        core.append(int(part))

    given = len(core)
    for _ in range(3 - given):
        core.append(0)

    return struct(core = core, pre = pre, given = given)

def _parse_exact_version(version):
    """Parses an exact semver pin 'x.y.z[-prerelease][+build]', or returns None."""
    return _split_version(version, 3, 3)

def _is_exact_version(version):
    """True if version is an exact semver pin: 'x.y.z[-prerelease][+build]'.

    Registries publish prerelease versions (e.g. 'hashicorp/aws:6.0.0-beta1'),
    which are exact pins just as much as a bare 'x.y.z' is -- the check here
    only needs to distinguish a pin from range/constraint syntax.
    """
    return _parse_exact_version(version) != None

def _cmp_int(a, b):
    if a < b:
        return -1
    if a > b:
        return 1
    return 0

def _cmp_prerelease_ident(a, b):
    """Compares two prerelease identifiers; numeric ones rank below alphanumeric."""
    a_num = _is_numeric(a)
    b_num = _is_numeric(b)
    if a_num and b_num:
        return _cmp_int(int(a), int(b))
    if a_num:
        return -1
    if b_num:
        return 1
    if a < b:
        return -1
    if a > b:
        return 1
    return 0

def _cmp_version(x, y):
    """Orders two parsed versions by semver precedence."""
    for i in range(3):
        c = _cmp_int(x.core[i], y.core[i])
        if c != 0:
            return c

    # A version carrying a prerelease ranks below the same core release.
    if len(x.pre) == 0 and len(y.pre) == 0:
        return 0
    if len(x.pre) == 0:
        return 1
    if len(y.pre) == 0:
        return -1

    shared = min(len(x.pre), len(y.pre))
    for i in range(shared):
        c = _cmp_prerelease_ident(x.pre[i], y.pre[i])
        if c != 0:
            return c
    return _cmp_int(len(x.pre), len(y.pre))

# Longest first, so ">=" is not mistaken for ">".
_CONSTRAINT_OPERATORS = ["~>", ">=", "<=", "!=", "=", ">", "<"]

def parse_version_constraint(spec):
    """Parses a comma-separated version constraint into a list of terms.

    Accepts terraform's operators (`=`, `!=`, `>`, `>=`, `<`, `<=`, `~>`, and a
    bare version meaning `=`), joined by commas to mean AND. Returns None if
    any term fails to parse.
    """
    terms = []
    for raw in spec.split(","):
        term = raw.strip()
        if term == "":
            return None

        op = "="
        for candidate in _CONSTRAINT_OPERATORS:
            if term.startswith(candidate):
                op = candidate
                term = term[len(candidate):].strip()
                break

        bound = _split_version(term, 1, 3)
        if bound == None:
            return None

        terms.append(struct(op = op, bound = bound))

    if len(terms) == 0:
        return None
    return terms

def _satisfies_term(candidate, term):
    c = _cmp_version(candidate, term.bound)
    op = term.op

    if op == "=":
        return c == 0
    if op == "!=":
        return c != 0
    if op == ">":
        return c > 0
    if op == ">=":
        return c >= 0
    if op == "<":
        return c < 0
    if op == "<=":
        return c <= 0

    # "~>" pins every component to the left of the rightmost one written and
    # lets that one increment: `~> 1.0.4` is < 1.1.0, but `~> 1.1` is < 2.0.0.
    if c < 0:
        return False
    index = term.bound.given - 2
    if index < 0:
        index = 0

    upper = list(term.bound.core)
    upper[index] = upper[index] + 1
    for j in range(index + 1, 3):
        upper[j] = 0

    return _cmp_version(candidate, struct(core = upper, pre = [], given = 3)) < 0

def select_matching_version(available, spec):
    """Returns the highest published version satisfying spec, or "" if none do.

    Prereleases are never selected by a constraint, matching terraform: pin the
    exact version to mirror a prerelease.
    """
    terms = parse_version_constraint(spec)
    if terms == None:
        return ""

    best = ""
    best_parsed = None
    for version in available:
        parsed = _parse_exact_version(version)
        if parsed == None or len(parsed.pre) > 0:
            continue

        satisfied = True
        for term in terms:
            if not _satisfies_term(parsed, term):
                satisfied = False
                break
        if not satisfied:
            continue

        if best_parsed == None or _cmp_version(parsed, best_parsed) > 0:
            best = version
            best_parsed = parsed

    return best

def parse_mirror_entries(mirror):
    """Parses a list of "[hostname/]namespace/type:version" strings.

    Returns a list of {"source", "version", "is_exact"} dicts, deduplicated on
    (source, version). Fails on malformed entries or duplicates.

    A version is either an exact 'x.y.z[-prerelease][+build]' pin or a
    constraint (`>= 1.0`, `~> 3.0`, `>= 1.0, < 2.0`). Constraints are resolved
    against the registry's published version list when the mirror is built.
    Pinning is still the recommended form: a constraint lets mirror contents
    drift with no change to the manifest, so the resolved set is recorded in
    the toolchain's `mirror_versions` for a build to inspect.
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

        is_exact = _is_exact_version(version)
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

    Host defaults to `default_host` when the source carries no host prefix. The
    source shape itself is already validated by `parse_mirror_entries`.
    """
    parts = source.split("/")
    if len(parts) == 2:
        return default_host, parts[0], parts[1]
    return parts[0], parts[1], parts[2]

# Service-discovery results for the two default registries. Seeding them keeps
# the common case free of an extra `.well-known` round trip per build; every
# other host is discovered for real by `_providers_base_url`.
_KNOWN_PROVIDER_REGISTRIES = {
    "registry.terraform.io": "https://registry.terraform.io/v1/providers/",
    "registry.opentofu.org": "https://registry.opentofu.org/v1/providers/",
}

def new_registry_client(ctx):
    """Creates the per-repository-rule registry client.

    Carries the memoized service-discovery and credential lookups so a mirror
    naming several providers on the same host resolves each only once.
    """
    return {
        "ctx": ctx,
        "bases": dict(_KNOWN_PROVIDER_REGISTRIES),
        "tokens": {},
    }

def _url_host(url):
    return url.split("://", 1)[-1].split("/", 1)[0]

def _token_env_names(host):
    """Environment variable names that may hold a token for host.

    Terraform's convention is `TF_TOKEN_<host>` with periods encoded as
    underscores. Hostnames containing a hyphen have no valid direct spelling,
    so terraform also accepts a double underscore in its place; that form is
    tried first when it applies.
    """
    encoded = host.replace(".", "_")
    if "-" in encoded:
        return ["TF_TOKEN_" + encoded.replace("-", "__"), "TF_TOKEN_" + encoded]
    return ["TF_TOKEN_" + encoded]

def _credentials_file_token(ctx, host):
    """Reads a host token from terraform's JSON credentials file, if present."""
    path = ctx.getenv("TF_CLI_CONFIG_FILE")
    if path:
        # A .tfrc is HCL, which Starlark cannot parse; only the JSON
        # credentials format is understood.
        if not path.endswith(".json"):
            return ""
    else:
        home = ctx.getenv("HOME")
        if not home:
            return ""
        path = home + "/.terraform.d/credentials.tfrc.json"

    p = ctx.path(path)
    if not p.exists:
        return ""

    # watch = "no": the file lives outside the workspace, and rotating a
    # credential should not by itself invalidate the mirror.
    creds = json.decode(ctx.read(p, watch = "no")).get("credentials", {})
    return creds.get(host, {}).get("token", "")

def _auth_headers(client, host):
    """Authorization header for host, or an empty dict when unauthenticated."""
    tokens = client["tokens"]
    if host not in tokens:
        ctx = client["ctx"]
        token = ""
        for name in _token_env_names(host):
            token = ctx.getenv(name) or ""
            if token:
                break
        if not token:
            token = _credentials_file_token(ctx, host)
        tokens[host] = token

    if not tokens[host]:
        return {}
    return {"Authorization": "Bearer " + tokens[host]}

def _providers_base_url(client, host):
    """Returns host's providers.v1 API base URL, via remote service discovery."""
    bases = client["bases"]
    if host in bases:
        return bases[host]

    ctx = client["ctx"]
    url = "https://%s/.well-known/terraform.json" % host
    output = "discovery_%s.json" % host.replace(".", "_").replace(":", "_")

    res = ctx.download(
        url = [url],
        output = output,
        allow_fail = True,
        headers = _auth_headers(client, host),
    )
    if not res.success:
        fail(("failed service discovery for registry host '%s' (%s) -- the host must serve a " +
              "terraform service-discovery document") % (host, url))

    doc = json.decode(ctx.read(output))
    ctx.delete(output)

    path = doc.get("providers.v1")
    if not path:
        fail(("registry host '%s' does not advertise a provider registry: no 'providers.v1' " +
              "key in %s") % (host, url))

    # providers.v1 may be an absolute URL or a path relative to the host.
    if path.startswith("http://") or path.startswith("https://"):
        base = path
    elif path.startswith("/"):
        base = "https://%s%s" % (host, path)
    else:
        base = "https://%s/%s" % (host, path)

    if not base.endswith("/"):
        base += "/"

    bases[host] = base
    return base

def _provider_label(t):
    return "%s/%s/%s %s" % (t["host"], t["namespace"], t["type"], t["version"])

def _resolve_constraints(ctx, client, targets):
    """Replaces every constraint target's version with a concrete published one.

    The registry's version listing is fetched for each constrained provider,
    all in flight at once. Targets that already carry an exact pin cost nothing.
    Deduplicates the result, since two different constraints may well select the
    same version and would otherwise be mirrored twice.
    """
    constrained = [t for t in targets if not t["is_exact"]]
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
            headers = _auth_headers(client, listing["host"]),
            block = False,
        )

    for key, listing in listings.items():
        if not listing["pending"].wait().success:
            fail("failed to list versions of %s from %s" % (key, listing["url"]))

        doc = json.decode(ctx.read(listing["file"]))
        ctx.delete(listing["file"])
        listing["available"] = [v["version"] for v in doc.get("versions", []) if v.get("version")]

    for t in constrained:
        listing = listings[t["listing"]]
        available = listing["available"]
        selected = select_matching_version(available, t["version"])
        if selected == "":
            fail(("no published version of %s/%s/%s satisfies '%s' (%d version(s) offered by " +
                  "%s). Note that prereleases are never selected by a constraint -- pin the " +
                  "exact version to mirror one.") % (
                t["host"],
                t["namespace"],
                t["type"],
                t["version"],
                len(available),
                listing["url"],
            ))

        t["version"] = selected
        t["is_exact"] = True

    # Two constraints on one source can land on the same version; mirroring it
    # twice would download and unpack over the same directory.
    deduped = []
    seen = {}
    for t in targets:
        key = "%s/%s/%s@%s" % (t["host"], t["namespace"], t["type"], t["version"])
        if key in seen:
            continue
        seen[key] = True
        deduped.append(t)

    return deduped

def download_providers_to_mirror(ctx, entries, default_host, os, arch):
    """Fetches every parsed mirror entry into the unpacked filesystem-mirror layout.

    Each provider zip is routed through `ctx.download_and_extract` so its bytes
    land in Bazel's `--repository_cache` (keyed by sha) and are served offline
    on subsequent runs. This replaces the old `terraform init` subprocess, whose
    downloads bypassed the repository cache entirely.

    The extract target reproduces the "unpacked" filesystem-mirror layout that
    downstream `terraform init -plugin-dir=<mirror>` consumes, letting init
    symlink the plugin into each module's .terraform/providers/ rather than
    extracting a fresh ~750MB copy per target.

    Work is batched rather than run per provider: every metadata request is put
    in flight before any is awaited, then every package download likewise. A
    manifest of N providers costs two rounds of latency instead of 2N.

    Only the host platform is mirrored, matching the host-scoped toolchain repo.

    Returns the resolved entries as {"source", "version"} dicts with every
    constraint replaced by the concrete version it selected, which is what the
    toolchain publishes as its mirror manifest.
    """
    client = new_registry_client(ctx)

    targets = []
    for entry in entries:
        host, namespace, provider_type = provider_source_parts(entry["source"], default_host)
        targets.append({
            "source": entry["source"],
            "host": host,
            "namespace": namespace,
            "type": provider_type,
            "version": entry["version"],
            "is_exact": entry["is_exact"],
        })

    # Service discovery is a blocking prerequisite of every metadata URL and is
    # memoized per host, so it is resolved up front rather than inside the fan-out.
    for t in targets:
        t["base"] = _providers_base_url(client, t["host"])

    targets = _resolve_constraints(ctx, client, targets)

    ctx.report_progress("Resolving %d provider(s) from registry" % len(targets))

    for t in targets:
        t["meta_url"] = "{base}{ns}/{type}/{version}/download/{os}/{arch}".format(
            base = t["base"],
            ns = t["namespace"],
            type = t["type"],
            version = t["version"],
            os = os,
            arch = arch,
        )

        # The metadata JSON is not content-addressable (its sha is unknown ahead
        # of time), so this small fetch is always live; only the provider bytes
        # below are cache-served. Each lands in its own path to avoid collisions.
        t["meta_file"] = "provider_meta_{ns}_{type}_{version}.json".format(
            ns = t["namespace"],
            type = t["type"],
            version = t["version"],
        )

        # allow_fail lets the actionable messages below surface instead of
        # Bazel's raw HTTP error, which does not say which entry was at fault.
        t["pending"] = ctx.download(
            url = [t["meta_url"]],
            output = t["meta_file"],
            allow_fail = True,
            headers = _auth_headers(client, t["host"]),
            block = False,
        )

    for t in targets:
        if not t["pending"].wait().success:
            fail(("failed to fetch provider metadata for %s (%s/%s) from %s -- check that the " +
                  "source and version exist in the registry") % (
                _provider_label(t),
                os,
                arch,
                t["meta_url"],
            ))

        meta = json.decode(ctx.read(t["meta_file"]))
        ctx.delete(t["meta_file"])

        for field in ["download_url", "shasum"]:
            if not meta.get(field):
                fail("registry response for %s (%s) has no '%s'" % (
                    _provider_label(t),
                    t["meta_url"],
                    field,
                ))

        t["meta"] = meta

    if len(targets) > 0:
        ctx.report_progress("Downloading %d provider(s) into mirror" % len(targets))

    for t in targets:
        # Credentials go out only when the package is served by the registry
        # host itself. Public registries hand back a third-party object store
        # (releases.hashicorp.com, github.com) and must never receive the token.
        package_headers = {}
        if _url_host(t["meta"]["download_url"]) == t["host"]:
            package_headers = _auth_headers(client, t["host"])

        t["output"] = "mirror/{host}/{ns}/{type}/{version}/{os}_{arch}".format(
            host = t["host"],
            ns = t["namespace"],
            type = t["type"],
            version = t["version"],
            os = os,
            arch = arch,
        )

        # download + extract rather than download_and_extract: only `download`
        # accepts block = False, and putting every package in flight at once is
        # worth staging the zip, which is deleted as soon as it is unpacked.
        # sha256 still makes the bytes content-addressed for --repository_cache.
        t["archive"] = "provider_pkg_{ns}_{type}_{version}.zip".format(
            ns = t["namespace"],
            type = t["type"],
            version = t["version"],
        )
        t["pending"] = ctx.download(
            url = [t["meta"]["download_url"]],
            sha256 = t["meta"]["shasum"],
            output = t["archive"],
            allow_fail = True,
            headers = package_headers,
            block = False,
        )

    for t in targets:
        if not t["pending"].wait().success:
            fail("failed to download provider %s from %s" % (
                _provider_label(t),
                t["meta"]["download_url"],
            ))

        ctx.extract(archive = t["archive"], output = t["output"])
        ctx.delete(t["archive"])

    return [{"source": t["source"], "version": t["version"]} for t in targets]

def mirror_manifest(parsed_entries):
    """Returns the canonical "source@version" strings used as the toolchain manifest."""
    return ["%s@%s" % (e["source"], e["version"]) for e in parsed_entries]
