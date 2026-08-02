"""Helpers shared by the module extension and the toolchain download rules.

The mirror is resolved in the extension -- version constraints, registry service
discovery, package coordinates -- and fetched in the download repository, so the
parts both need live here. Keeping them free of any particular ctx is also what
lets utils_test.bzl exercise them without reaching a registry.
"""

def get_sha256sum(shasums, file):
    """Reads one file's checksum out of a SHA256SUMS document.

    Args:
      shasums: contents of a SHA256SUMS document, one "<hash>  <name>" per line.
      file: name of the file whose checksum is wanted.

    Returns:
      The hex checksum, or None when the document has no line for file.
    """
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
    bare version meaning `=`), joined by commas to mean AND.

    Args:
      spec: the constraint as written in the manifest, e.g. ">= 1.0, < 2.0".

    Returns:
      A list of (op, bound) structs, or None if any term fails to parse.
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

    Args:
      available: version strings the registry publishes for one provider.
      spec: the constraint to satisfy, in `parse_version_constraint` syntax.

    Returns:
      The highest satisfying version, or "" when none match or spec is malformed.
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

# The registry an unqualified source resolves against, keyed by use_tofu. Read
# by the module extension and stamped into each toolchain, so the lock target
# addresses providers exactly as the mirror did.
DEFAULT_REGISTRY = {
    True: "registry.opentofu.org",
    False: "registry.terraform.io",
}

# Service-discovery results for the two default registries. Seeding them keeps
# the common case free of an extra `.well-known` round trip per build; every
# other host is discovered for real by `_providers_base_url`.
_KNOWN_PROVIDER_REGISTRIES = {
    "registry.terraform.io": "https://registry.terraform.io/v1/providers/",
    "registry.opentofu.org": "https://registry.opentofu.org/v1/providers/",
}

def new_registry_client(ctx):
    """Creates the registry client, over either a module_ctx or a repository_ctx.

    Carries the memoized service-discovery and credential lookups so a mirror
    naming several providers on the same host resolves each only once. The
    module extension uses the full client to resolve providers; the download
    repo constructs one solely for `auth_headers`, since a token must never be
    passed down as a repo attribute where the lockfile would record it.
    """
    return {
        "ctx": ctx,
        "bases": dict(_KNOWN_PROVIDER_REGISTRIES),
        "tokens": {},
    }

def url_host(url):
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

def auth_headers(client, host):
    """Authorization header for host, or an empty dict when unauthenticated.

    Args:
      client: the registry client from `new_registry_client`, which memoizes the
        lookup so a manifest naming several providers on one host reads the
        credential once.
      host: registry hostname the request is bound for.

    Returns:
      A headers dict carrying a bearer token, or {} when no token was found.
    """
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
        headers = auth_headers(client, host),
    )
    if not res.success:
        fail(("failed service discovery for registry host '%s' (%s) -- the host must serve a " +
              "terraform service-discovery document") % (host, url))

    # Not cleaned up: module_ctx has no delete(), and these land in the
    # extension's own working directory rather than in any repo.
    doc = json.decode(ctx.read(output))

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
            headers = auth_headers(client, listing["host"]),
            block = False,
        )

    for key, listing in listings.items():
        if not listing["pending"].wait().success:
            fail("failed to list versions of %s from %s" % (key, listing["url"]))

        doc = json.decode(ctx.read(listing["file"]))
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

    return targets

# Fact keys are unversioned, and changing the shape of one (or of its value)
# is therefore a breaking change to any lockfile already carrying them. Do it
# by adopting `module_extension(facts_version = ...)`, which invalidates the
# old facts for us -- and note that raises the Bazel floor to 9.2.
def resolve_fact_key(host, namespace, provider_type, spec):
    """Fact key under which a constraint's selected version is remembered."""
    return "resolve/{host}/{ns}/{type}/{spec}".format(
        host = host,
        ns = namespace,
        type = provider_type,
        spec = spec,
    )

def package_fact_key(host, namespace, provider_type, version, platform):
    """Fact key under which one platform's package coordinates are remembered."""
    return "package/{host}/{ns}/{type}/{version}/{platform}".format(
        host = host,
        ns = namespace,
        type = provider_type,
        version = version,
        platform = platform,
    )

def verified_fact_key(host, namespace, provider_type, version):
    """Fact key under which a version's signature-verified zh: hashes are remembered.

    Not platform-scoped: a `zh:` hash set covers every platform's package and
    the lock does not record which hash belongs to which, so the check it
    supports is set membership either way.
    """
    return "verified/{host}/{ns}/{type}/{version}".format(
        host = host,
        ns = namespace,
        type = provider_type,
        version = version,
    )

# The platforms a tf toolchain can run on, and so the set whose package
# coordinates every resolution records -- one lockfile then serves every machine
# in a team, whichever wrote it. Enumerated rather than discovered because
# `module_ctx.facts` is a lookup with no iteration, so a platform's coordinates
# can only be asked for by name.
MIRROR_PLATFORMS = [
    "linux_amd64",
    "linux_arm64",
    "darwin_amd64",
    "darwin_arm64",
]

def resolve_providers(ctx, entries, default_host, os, arch, facts):
    """Resolves every mirror entry to a concrete version, package URL and sha256.

    This runs in the module extension rather than in the download repo, for two
    reasons. The coordinates it produces are passed to the repo rule as plain
    attributes, so `MODULE.bazel.lock` records in `generatedRepoSpecs` exactly
    which version a constraint selected. And what it learns from the registry is
    returned as extension facts, which bzlmod persists in that same lockfile --
    so a second evaluation resolves from the lockfile and reaches the registry
    not at all.

    `facts` is the previously persisted table (`module_ctx.facts`). A hit on a
    `resolve/` key skips the version listing; a hit on a `package/` key skips
    the metadata request. A miss is not an error: that entry resolves live, and
    its result joins the facts returned to the caller.

    Work is batched rather than run per provider: every version listing is put
    in flight before any is awaited, then every metadata request likewise, so a
    manifest of N providers costs two rounds of latency instead of 2N.

    Coordinates are resolved for every platform in `MIRROR_PLATFORMS`, so one
    build writes a lockfile that covers them all -- the property terraform gets
    from a multi-platform `.terraform.lock.hcl`. Only the host's package is
    downloaded; the others cost one small metadata GET each. A platform a
    provider does not publish is skipped rather than fatal.

    Args:
      ctx: the module extension's `module_ctx`.
      entries: parsed manifest entries, from `parse_mirror_entries`.
      default_host: registry an unqualified source resolves against.
      os: host operating system, in terraform's spelling ("linux", "darwin").
      arch: host architecture, in terraform's spelling ("amd64", "arm64").
      facts: the previously persisted fact table, `module_ctx.facts`.

    Returns:
      A (packages, facts) tuple: packages carries the concrete coordinates for
      this platform, facts is the table to hand back to bzlmod.
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

        # A constraint is remembered against the spec as written, since that is
        # the question whose answer is being recorded. Exact pins ask nothing.
        if not t["is_exact"]:
            t["spec"] = entry["version"]
            remembered = facts.get(resolve_fact_key(host, namespace, provider_type, t["spec"]))
            if remembered:
                t["version"] = remembered["version"]
                t["is_exact"] = True

        targets.append(t)

    # Service discovery is a blocking prerequisite of every registry URL and is
    # memoized per host, so it is resolved up front rather than inside the
    # fan-out -- but only for targets that still have a question to ask.
    for t in targets:
        if not t["is_exact"]:
            t["base"] = _providers_base_url(client, t["host"])

    targets = _resolve_constraints(ctx, client, targets)

    # Each constraint's answer is remembered before the dedupe below, never
    # after: two constraints can select the same version, and the one that
    # collapses would otherwise be left with no fact of its own. The lockfile
    # would look complete while that spec still had to be re-resolved against
    # the registry on every later evaluation.
    spec_facts = {}
    for t in targets:
        spec = t.get("spec")
        if spec:
            spec_facts[resolve_fact_key(t["host"], t["namespace"], t["type"], spec)] = {
                "version": t["version"],
            }

    targets = _dedupe_targets(targets)

    platform = "%s_%s" % (os, arch)

    # Metadata is resolved for every platform a toolchain can run on, not just
    # the host, so the lockfile a build writes is complete whichever machine
    # wrote it. Resolving only the host would leave every other platform to
    # append its own facts later, which dirties the lockfile on the next machine
    # to build -- enough to fail a CI job that gates on a clean tree. Only the
    # host's package is downloaded; the rest cost one small GET each, all in
    # flight together.
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

    # A host whose API base is not yet known would need service discovery, which
    # is a hard failure. Worth it for the host platform, whose package is about
    # to be fetched; not worth it for the others, whose absence only costs the
    # lockfile some completeness. This is what lets a workspace resolve entirely
    # from facts against a registry that no longer answers.
    for r in requests:
        t = r["target"]
        if r["platform"] == platform and "base" not in t:
            t["base"] = _providers_base_url(client, t["host"])

    requests = [r for r in requests if "base" in r["target"] or r["target"]["host"] in client["bases"]]
    if len(requests) > 0:
        ctx.report_progress("Resolving %d provider platform(s) from registry" % len(requests))

    for r in requests:
        t = r["target"]
        p = r["platform"]
        if "base" not in t:
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

        # The metadata JSON is not content-addressable (its sha is unknown ahead
        # of time), so this small fetch is live the first time it is asked for;
        # thereafter the fact answers it. Each lands in its own path to avoid
        # collisions between two versions or two platforms of one provider.
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

        # Only the host platform's metadata is required. A provider that ships
        # no package for one of the others is ordinary -- it simply goes
        # unrecorded, rather than failing a build that was never going to fetch
        # it.
        if not r["pending"].wait().success:
            if p != platform:
                continue
            fail(("failed to fetch provider metadata for %s (%s) from %s -- check that the " +
                  "source and version exist in the registry") % (
                _provider_label(t),
                p,
                r["url"],
            ))

        meta = json.decode(ctx.read(r["file"]))

        missing = [f for f in ["download_url", "shasum"] if not meta.get(f)]
        if len(missing) > 0:
            if p != platform:
                continue
            fail("registry response for %s (%s) has no '%s'" % (
                _provider_label(t),
                r["url"],
                missing[0],
            ))

        t["metas"][p] = {"download_url": meta["download_url"], "sha256": meta["shasum"]}

    # Built fresh rather than merged into what was read: `module_ctx.facts` is a
    # lookup, not an iterable, so the previous table cannot be enumerated. The
    # result is that the persisted facts track the manifest exactly -- an entry
    # dropped from the mirror takes its facts with it instead of silting up.
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
            fail("no package coordinates resolved for %s on %s" % (_provider_label(t), platform))

        packages.append({
            "source": t["source"],
            "host": t["host"],
            "namespace": t["namespace"],
            "type": t["type"],
            "version": t["version"],
            "download_url": t["metas"][platform]["download_url"],
            "sha256": t["metas"][platform]["sha256"],
        })

    return packages, new_facts

def download_providers(ctx, packages, os, arch):
    """Unpacks every resolved package into the filesystem-mirror layout.

    Every coordinate arrives already resolved, so this reaches no registry: it
    fetches known URLs against known hashes. That makes each package
    content-addressed for `--repository_cache`, so a warm cache serves the whole
    mirror offline.

    The extract target reproduces the "unpacked" filesystem-mirror layout that
    downstream `terraform init -plugin-dir=<mirror>` consumes, letting init
    symlink the plugin into each module's .terraform/providers/ rather than
    extracting a fresh ~750MB copy per target.

    Args:
      ctx: the download repository's `repository_ctx`.
      packages: resolved coordinates, as `resolve_providers` returns them.
      os: host operating system, in terraform's spelling.
      arch: host architecture, in terraform's spelling.
    """
    if len(packages) == 0:
        ctx.file("mirror/.keep", content = "")
        return

    ctx.report_progress("Downloading %d provider(s) into mirror" % len(packages))

    # Built solely for the credential lookup: a package served by the registry
    # host itself may need a token, which cannot be passed down as an attribute
    # without the lockfile recording it.
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
        # worth staging the zip, which is deleted as soon as it is unpacked.
        archive = "provider_pkg_{ns}_{type}_{version}.zip".format(
            ns = p["namespace"],
            type = p["type"],
            version = p["version"],
        )
        staged.append({
            "package": p,
            "archive": archive,
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
            fail("failed to download provider %s from %s" % (
                _provider_label(s["package"]),
                s["package"]["download_url"],
            ))

        ctx.extract(archive = s["archive"], output = s["output"])
        ctx.delete(s["archive"])

def parse_provider_locks(documents):
    """Merges `.terraform.lock.hcl` documents into {source@version: {zh hash: True}}.

    A terraform dependency lock file records, per provider, the sha256 of the
    release package for every platform, as `zh:` entries. Those hashes are
    produced by `terraform providers lock`, which verifies the registry's
    SHA256SUMS against the signing keys embedded in the terraform binary -- so
    a `zh:` value is a hash that survived a signature check, and is a trust
    root independent of whatever the registry later claims.

    A lock file holds one version per provider, while a mirror may stock
    several, so several documents merge into one table keyed by source and
    version. `h1:` hashes are ignored: they cover the extracted directory, not
    the package, and only for the platforms the lock was generated for.

    The grammar used here is the narrow subset terraform itself emits, not
    general HCL.

    Args:
      documents: contents of one or more `.terraform.lock.hcl` files.

    Returns:
      {"<host>/<ns>/<type>@<version>": {"<zh hash>": True}}, merged across
      every document given.
    """
    locks = {}
    for raw in documents:
        address = ""
        version = ""
        hashes = []
        in_hashes = False

        for line in raw.splitlines():
            text = line.strip()
            if text == "" or text.startswith("#"):
                continue

            if text.startswith("provider \""):
                address = text.split("\"")[1]
                version = ""
                hashes = []
                in_hashes = False
                continue

            if address == "":
                continue

            if in_hashes:
                if text.startswith("]"):
                    in_hashes = False
                elif "\"" in text:
                    value = text.split("\"")[1]
                    if value.startswith("zh:"):
                        hashes.append(value[len("zh:"):])
                continue

            if text.startswith("hashes"):
                in_hashes = True
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
                address = ""

    return locks

def provider_locks_from_facts(facts, packages):
    """Reads the verified zh: hashes recorded as facts for the packages given.

    The hashes are put there by the `tf_providers_lock` target, which runs
    `terraform providers lock` (or `tofu providers lock`) and merges what it
    verified into `MODULE.bazel.lock` -- the same file that already holds the
    resolved coordinates, so the check needs no lock file of its own.

    Re-emitting matters: an extension's facts are replaced wholesale by what it
    returns, so a key not asked for by name here would be dropped from the
    lockfile on the next evaluation.

    Args:
      facts: the previously persisted fact table, `module_ctx.facts`.
      packages: resolved coordinates whose hashes are wanted.

    Returns:
      A (locks, facts) tuple: locks has the shape `parse_provider_locks`
      produces, so the two sources can be merged; facts is the subset to hand
      back from the extension.
    """
    locks = {}
    reemit = {}
    for p in packages:
        key = verified_fact_key(p["host"], p["namespace"], p["type"], p["version"])
        remembered = facts.get(key)
        if not remembered:
            continue

        # Checked rather than indexed blindly: these are the one class of fact a
        # tool outside the extension writes, so a hand-edited or half-written
        # lockfile should say which entry is wrong.
        hashes = remembered.get("zh") if type(remembered) == "dict" else None
        if type(hashes) != "list":
            fail(("the verified hashes recorded for %s in MODULE.bazel.lock are malformed: " +
                  "expected {\"zh\": [...]}, got %r. Delete the '%s' fact and re-run the " +
                  "tf_providers_lock target.") % (key, remembered, key))

        reemit[key] = remembered
        locks["%s/%s/%s@%s" % (p["host"], p["namespace"], p["type"], p["version"])] = {
            h: True
            for h in hashes
        }

    return locks, reemit

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

def verify_against_provider_locks(packages, locks, strict):
    """Checks each package hash against the signature-verified lock hashes.

    Args:
      packages: resolved coordinates, each carrying the sha256 the mirror would
        be fetched against.
      locks: verified hashes, as `parse_provider_locks` or
        `provider_locks_from_facts` produce them.
      strict: fail rather than warn when an entry has no hash covering it.
    """
    uncovered = []
    for t in packages:
        key = "%s/%s/%s@%s" % (t["host"], t["namespace"], t["type"], t["version"])
        expected = locks.get(key)
        if expected == None:
            uncovered.append(key)
            continue

        actual = t["sha256"]
        if actual not in expected:
            fail(("provider %s does not match the dependency lock: sha256 %s is not among the " +
                  "%d zh: hashes recorded for it. Either the lock is stale, or the registry " +
                  "served a package that was not the signed one -- do not ignore this without " +
                  "establishing which.") % (key, actual, len(expected)))

    if len(uncovered) == 0:
        return

    message = ("no verified hashes cover: %s. Those providers were fetched on the registry's " +
               "word alone, with no signature-derived hash to check against. Run the " +
               "tf_providers_lock target to record hashes for the whole manifest, or run " +
               "`terraform providers lock` (`tofu providers lock`, for a tofu toolchain) " +
               "yourself and add the file to provider_locks.") % (
        ", ".join(uncovered)
    )
    if strict:
        fail(message)

    # A lock file holds one version per provider, so partial coverage is
    # expected of a multi-version mirror; enumerate the gap rather than
    # blocking on it. Set provider_locks_strict to make it fatal.
    print("rules_tf: " + message)  # buildifier: disable=print

def mirror_manifest(parsed_entries):
    """Returns the canonical "source@version" strings used as the toolchain manifest."""
    return ["%s@%s" % (e["source"], e["version"]) for e in parsed_entries]
