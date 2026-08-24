"""Resolving remote terraform modules ahead of the repository that fetches them.

Terraform reaches modules through go-getter, whose source grammar covers the
registry, several VCS shorthands, plain http, and a handful of object stores,
each with its own scheme detection, subdirectory handling and credentials.
Re-implementing that in Starlark would be a standing fidelity gap, so the tool
itself does the resolving: `terraform get` installs a module and writes the
closure it reached to `.terraform/modules/modules.json`.

That run belongs here, in the extension, rather than in the repository that
fetches the modules. `repo_metadata(reproducible = True)` promises the same
output "even if other untracked conditions change, such as information from the
internet, output from running arbitrary executables", which is precisely what a
`terraform get` inside a repository rule would be. Resolving here and recording
the answers as facts leaves the download repository holding concrete pins in its
attributes, which is what lets it make that promise and be served from the repo
contents cache.

The same split is already how providers are mirrored, and how tflint's rulesets
came to be: both moved the coordinate-choosing out of the repository once it had
to be cacheable.
"""

load(
    ":facts.bzl",
    "module_closure_fact_key",
    "module_package_fact_key",
)
load(
    ":registry.bzl",
    "auth_headers",
    "modules_base_url",
    "new_registry_client",
)

_GET_TIMEOUT = 600

# Written as JSON rather than HCL so that a source containing quotes, braces or
# backslashes needs no escaping of ours.
_ROOT_TF_JSON = """{"module": %s}"""

# Prefix for the synthetic call name each declared entry is installed under. The
# closure terraform reports is keyed by call path (finding: a nested module
# appears as "parent.child"), so the prefix is what maps an entry's subtree back
# to the entry that asked for it.
_CALL_PREFIX = "m"

# Where terraform installs modules, relative to the directory it runs in. The
# manifest's `Dir` paths are rooted here, which is what makes a module's
# subdirectory recoverable from them.
_INSTALL_DIR = ".terraform/modules"

# Hosts terraform's own getter detectors claim before it tries to read a
# registry address. A source under one of these has the shape of a registry
# address but the meaning of a git source.
_DETECTED_HOSTS = ["github.com", "bitbucket.org"]

def is_registry_source(source):
    """Reports whether a module source is a registry address.

    Only registry addresses take a separate version constraint; every other
    scheme pins itself inside the source string. The distinction decides both
    how an entry is spelled and whether a `version` may accompany it.

    A registry address is `[<host>[:<port>]/]<namespace>/<name>/<target_system>`
    with no scheme marker, so it is recognised by shape: three or four
    slash-separated parts, none of them a path segment, and no getter prefix.
    Any source may carry a `//<subdir>` suffix, which addresses a directory
    within the package rather than the package, and so is not part of the shape.

    Args:
      source: the module source, as a user or a manifest spells it.

    Returns:
      True when source addresses a module registry.
    """
    if "::" in source or "://" in source:
        return False

    # With no scheme left to confuse it, a remaining "//" separates the
    # subdirectory from the package that holds it.
    source, _, _ = source.partition("//")
    if source.startswith("./") or source.startswith("../") or source.startswith("/"):
        return False

    # scp-style git remotes ("git@host:org/repo") carry no scheme but are not
    # registry addresses either.
    if "@" in source:
        return False

    parts = source.split("/")
    if len(parts) not in (3, 4):
        return False

    # `github.com/acme/mod` is the same shape as a registry address but is not
    # one: terraform runs its getter detectors before parsing a registry
    # address, so these hosts are claimed by the git getter and reject the
    # `version` a registry entry carries.
    if parts[0] in _DETECTED_HOSTS:
        return False

    return all([p != "" and p != "." and p != ".." for p in parts])

def parse_module_entries(specs):
    """Parses the declared module manifest into resolvable entries.

    A registry entry is spelled `<address>@<version>`, where the version may be
    an exact pin or any constraint terraform accepts. Every other source is
    spelled verbatim, because a getter source already carries its own ref and
    terraform rejects a `version` alongside one.

    Args:
      specs: manifest entries, as the tag's string list holds them.

    Returns:
      A list of entry dicts, each with `source`, `version` (empty for a
      non-registry source) and `spec`, the entry as written.
    """
    entries = []
    for spec in specs:
        source, sep, version = spec.rpartition("@")

        # rpartition yields ("", "", spec) when there is no "@" at all, and a
        # source that merely contains one (an scp-style remote) is not a
        # registry address, so neither case splits.
        if not sep or not is_registry_source(source):
            source, version = spec, ""

        if version == "" and is_registry_source(spec):
            fail(("module entry {} names the registry module {} without a version. Registry " +
                  "sources take a version constraint; write it as '{}@<version>'.").format(
                spec,
                spec,
                spec,
            ))

        entries.append({
            "source": source,
            "version": version,
            "spec": spec,
        })

    return entries

def module_manifest(entries):
    """Renders parsed entries back to their manifest spelling.

    Args:
      entries: entries as `parse_module_entries` returns them.

    Returns:
      A list of `<source>@<version>` strings, or bare sources where no version
      applies, in the order given.
    """
    return [
        "%s@%s" % (e["source"], e["version"]) if e["version"] else e["source"]
        for e in entries
    ]

def module_store_key(source, version):
    """Returns the store-relative directory a resolved module unpacks into.

    Keyed by source and version rather than by the commit the registry resolves
    to: terraform itself does neither, installing a module once per call path
    and duplicating identical copies, so this already shares what upstream
    duplicates. A commit-keyed store would share strictly more -- two versions
    that resolve to one commit, or a git source naming the same commit as a
    registry entry -- and can replace this without the manifest changing, since
    the directory a module lives in is ours to choose.

    Args:
      source: the module's source, as terraform reports it in the closure.
      version: the concrete version, empty for a non-registry source.

    Returns:
      A single path segment, safe to use as a directory name.
    """
    key = "%s@%s" % (source, version) if version else source

    # A source carries slashes, colons, and query strings; the store is flat, so
    # each becomes part of one segment.
    flattened = key
    for ch in ["://", "::", "/", ":", "?", "=", "&", "@", " "]:
        flattened = flattened.replace(ch, "_")

    # Flattening is lossy -- "a/b" and "a_b" collapse together -- and the store
    # is shared, so a collision would serve one module's content under another's
    # coordinates. The suffix is taken over the unflattened key, which nothing
    # collapses, so distinct coordinates stay distinct directories.
    return "%s-%x" % (flattened, hash(key))

def closure_from_manifest(manifest, call_name, install_dir = _INSTALL_DIR):
    """Extracts one declared entry's subtree from a modules.json manifest.

    A module addressed with a `//subdir` suffix is installed whole and pointed
    at from within, so `Dir` is the package's directory joined with the
    subdirectory. The suffix is recorded as terraform resolved it rather than
    re-parsed out of the source, since terraform is what decides where a package
    ends and a path into it begins.

    Args:
      manifest: the decoded `.terraform/modules/modules.json`.
      call_name: the synthetic call the entry was installed under.
      install_dir: directory the manifest's `Dir` paths are rooted at.

    Returns:
      The entry's modules, each with `key` relative to the entry's own root
      (empty for the entry itself), `source`, `version`, and `subdir`, the path
      within the package the module itself occupies.
    """
    prefix = call_name + "."
    modules = []

    for record in manifest.get("Modules", []):
        key = record.get("Key", "")
        if key == call_name:
            relative = ""
        elif key.startswith(prefix):
            relative = key[len(prefix):]
        else:
            # The synthetic root, and the subtrees of the other entries.
            continue

        # Everything below the package's own directory is the subdirectory the
        # source named. A local module is recorded in place rather than
        # installed, so its Dir sits outside install_dir and leaves this empty.
        package_dir = "%s/%s" % (install_dir, key)
        directory = record.get("Dir", "")
        subdir = ""
        if directory.startswith(package_dir + "/"):
            subdir = directory[len(package_dir) + 1:]

        modules.append({
            "key": relative,
            "source": record.get("Source", ""),
            "version": record.get("Version", ""),
            "subdir": subdir,
        })

    return modules

def unresolved_modules(facts, entries):
    """Returns the entries no recorded closure covers.

    Asked before the tool is fetched: resolution needs a terraform binary, and
    an evaluation the lockfile already answers should download nothing at all.

    Args:
      facts: the previously persisted fact table, `module_ctx.facts`.
      entries: entries as `parse_module_entries` returns them.

    Returns:
      The subset of entries still to resolve, in the order given.
    """
    return [
        e
        for e in entries
        if not facts.get(module_closure_fact_key(e["source"], e["version"]))
    ]

def recorded_closures(facts, entries):
    """Returns the closures already recorded for these entries.

    Separate from resolution so that an evaluation the lockfile fully answers
    never reaches for a tool it has no use for.

    Args:
      facts: the previously persisted fact table, `module_ctx.facts`.
      entries: entries as `parse_module_entries` returns them.

    Returns:
      A (closures, facts) pair. `closures` maps each answered entry's spec to
      its recorded modules; `facts` re-emits those entries, since an
      extension's facts are replaced wholesale by what it returns.
    """
    closures = {}
    kept = {}

    for entry in entries:
        key = module_closure_fact_key(entry["source"], entry["version"])
        remembered = facts.get(key)
        if remembered:
            kept[key] = remembered
            closures[entry["spec"]] = remembered["modules"]

    return closures, kept

def resolve_modules(ctx, entries, tool):
    """Resolves each entry to the closure terraform installs for it.

    One `terraform get` covers every entry: a module call is resolved on its own
    terms, so batching them into a single synthetic root costs nothing and asks
    each source once. Terraform ANDs version constraints per provider rather
    than per module call, so two entries naming one module at different versions
    coexist in that root.

    Args:
      ctx: the module extension's `module_ctx`.
      entries: entries still to resolve, as `unresolved_modules` returns them.
      tool: path of the terraform or tofu binary to run.

    Returns:
      A (closures, facts, errors) tuple. `closures` maps each entry's spec to
      its resolved modules; `facts` is the table to hand back; `errors` holds
      messages for the caller to defer, empty when every entry resolved.
    """
    closures = {}
    new_facts = {}
    errors = []

    if not entries:
        return closures, new_facts, errors

    pending = [
        {"entry": entry, "call": "%s%d" % (_CALL_PREFIX, index)}
        for index, entry in enumerate(entries)
    ]

    workdir = "modules"
    blocks = {}
    for p in pending:
        block = {"source": p["entry"]["source"]}
        if p["entry"]["version"]:
            block["version"] = p["entry"]["version"]
        blocks[p["call"]] = block

    ctx.file(
        workdir + "/root.tf.json",
        _ROOT_TF_JSON % json.encode(blocks),
        executable = False,
    )

    ctx.report_progress("Resolving %d terraform module(s)" % len(pending))

    # `get` installs modules and writes the manifest without initialising a
    # backend or touching providers, so this needs no credentials beyond
    # whatever the sources themselves require. The environment is inherited, so
    # a private registry's token reaches the tool the way it does anywhere else.
    result = ctx.execute(
        [tool, "-chdir=%s" % ctx.path(workdir), "get"],
        timeout = _GET_TIMEOUT,
    )
    if result.return_code != 0:
        return closures, new_facts, errors + [
            ("could not resolve %s: `terraform get` exited %d. The command reaches each " +
             "module's source, so it needs network access and any credentials those " +
             "sources require.\n%s") % (
                ", ".join([p["entry"]["spec"] for p in pending]),
                result.return_code,
                result.stderr,
            ),
        ]

    manifest_path = ctx.path("%s/%s/modules.json" % (workdir, _INSTALL_DIR))
    if not manifest_path.exists:
        return closures, new_facts, errors + [
            "`terraform get` wrote no module manifest for %s" % ", ".join(
                [p["entry"]["spec"] for p in pending],
            ),
        ]

    manifest = json.decode(ctx.read(manifest_path))

    for p in pending:
        entry = p["entry"]
        modules = closure_from_manifest(manifest, p["call"])
        if not modules:
            errors.append("`terraform get` installed nothing for %s" % entry["spec"])
            continue

        closures[entry["spec"]] = modules
        new_facts[module_closure_fact_key(entry["source"], entry["version"])] = {
            "modules": modules,
        }

    return closures, new_facts, errors

def package_source(source):
    """Strips any `//subdir` suffix, leaving the package a source names.

    Args:
      source: a module source, as terraform reports it in a closure.

    Returns:
      The source with its subdirectory removed.
    """
    if "::" in source or "://" in source:
        scheme, sep, rest = source.partition("://")
        if sep:
            body, _, _ = rest.partition("//")
            return scheme + sep + body

    body, _, _ = source.partition("//")
    return body

def module_packages(closures):
    """Reduces resolved closures to the distinct packages they need fetched.

    Two entries reaching different directories of one repository, and the same
    module reached by two call paths, collapse here: the store holds one copy
    and every manifest points into it.

    Args:
      closures: resolved closures, as `resolve_modules` and `recorded_closures`
        return them, keyed by entry spec.

    Returns:
      A list of package dicts, each with `source` (no subdirectory) and
      `version`, ordered by store key so the result does not depend on the
      order the closures were resolved in.
    """
    packages = {}
    for modules in closures.values():
        for m in modules:
            source = package_source(m["source"])

            # A local module is recorded in place rather than installed, and so
            # is not something the store holds.
            if source.startswith("./") or source.startswith("../"):
                continue

            packages[module_store_key(source, m["version"])] = {
                "source": source,
                "version": m["version"],
            }

    return [packages[k] for k in sorted(packages.keys())]

def registry_module_parts(source, default_host):
    """Splits a registry module address into its host and coordinates.

    Args:
      source: a registry address, with any subdirectory already removed.
      default_host: host to assume when the address names none.

    Returns:
      A (host, namespace, name, target_system) tuple.
    """
    parts = source.split("/")
    if len(parts) == 4:
        return parts[0], parts[1], parts[2], parts[3]

    return default_host, parts[0], parts[1], parts[2]

def _codeload_url(repo_url, tag):
    """Returns the archive URL for a GitHub repository at a tag, or "".

    GitHub is singled out because it is what the public module registry resolves
    to, and because its archive endpoint is a plain URL that `ctx.download` can
    fetch against a recorded hash. A package hosted anywhere else has no such
    endpoint and is left to terraform, which costs that package's repository its
    reproducibility rather than its support.

    Args:
      repo_url: the repository URL the registry advertises.
      tag: the tag the registry published this version from.

    Returns:
      The archive URL, or "" when the repository is not one this can address.
    """
    prefix = "https://github.com/"
    if not repo_url.startswith(prefix) or not tag:
        return ""

    slug = repo_url[len(prefix):]
    if slug.endswith(".git"):
        slug = slug[:-len(".git")]
    if slug.endswith("/"):
        slug = slug[:-1]

    if len(slug.split("/")) != 2:
        return ""

    return "https://codeload.github.com/%s/tar.gz/refs/tags/%s" % (slug, tag)

def unresolved_packages(facts, packages):
    """Returns the packages no recorded fetch coordinate covers.

    Args:
      facts: the previously persisted fact table, `module_ctx.facts`.
      packages: packages as `module_packages` returns them.

    Returns:
      The subset still to resolve, in the order given.
    """
    return [
        p
        for p in packages
        if not facts.get(module_package_fact_key(p["source"], p["version"]))
    ]

def recorded_packages(facts, packages):
    """Returns the fetch coordinates already recorded for these packages.

    Args:
      facts: the previously persisted fact table, `module_ctx.facts`.
      packages: packages as `module_packages` returns them.

    Returns:
      A (coordinates, facts) pair. `coordinates` maps each answered package's
      store key to its recorded value; `facts` re-emits those entries, since an
      extension's facts are replaced wholesale by what it returns.
    """
    coordinates = {}
    kept = {}

    for p in packages:
        key = module_package_fact_key(p["source"], p["version"])
        remembered = facts.get(key)
        if remembered:
            kept[key] = remembered
            coordinates[module_store_key(p["source"], p["version"])] = remembered

    return coordinates, kept

def resolve_module_packages(ctx, packages, default_host):
    """Resolves each package to an archive it can be fetched from, where one exists.

    A module registry publishes no checksums, so the hash recorded here is
    observed on this fetch rather than attested by a publisher: it pins the
    package against later drift, which is a weaker claim than the signature a
    provider's hash carries, and the difference is worth keeping in mind.

    A package that cannot be reduced to an archive is recorded as a getter
    source. Support is unaffected -- terraform fetches it either way -- but the
    repository holding it cannot be reproducible, and so cannot be served from
    the repo contents cache.

    Args:
      ctx: the module extension's `module_ctx`.
      packages: packages still to resolve, as `unresolved_packages` returns them.
      default_host: registry host to assume for an address naming none.

    Returns:
      A (coordinates, facts, errors) tuple. `coordinates` maps each package's
      store key to its fetch coordinates; `facts` is the table to hand back.
    """
    coordinates = {}
    new_facts = {}
    errors = []

    if not packages:
        return coordinates, new_facts, errors

    client = new_registry_client(ctx)

    for index, p in enumerate(packages):
        source, version = p["source"], p["version"]
        key = module_package_fact_key(source, version)
        store_key = module_store_key(source, version)
        resolved = {"getter": source}

        if is_registry_source(source):
            resolved = _resolve_registry_package(
                ctx,
                client,
                source,
                version,
                default_host,
                index,
            )

        # An archive is only worth recording once its bytes have been seen: the
        # registry hands back no checksum, so the hash comes from fetching it.
        if resolved.get("download_url"):
            observed = ctx.download(
                url = [resolved["download_url"]],
                output = "module_pkg_%d.tar.gz" % index,
                allow_fail = True,
            )
            if observed.success:
                resolved["sha256"] = observed.sha256
            else:
                # Reachable through terraform even when this endpoint is not.
                resolved = {"getter": source}

        coordinates[store_key] = resolved
        new_facts[key] = resolved

    return coordinates, new_facts, errors

def _resolve_registry_package(ctx, client, source, version, default_host, index):
    """Resolves one registry package to an archive URL, where the registry allows it.

    Args:
      ctx: the module extension's `module_ctx`.
      client: the registry client from `new_registry_client`.
      source: the registry address, with any subdirectory removed.
      version: the concrete version to resolve.
      default_host: registry host to assume for an address naming none.
      index: position in the batch, which names the response on disk.

    Returns:
      A dict carrying `download_url`, or `getter` when the package must be left
      to terraform.
    """
    host, namespace, name, target_system = registry_module_parts(source, default_host)

    base = modules_base_url(client, host)
    if not base:
        return {"getter": source}

    # The download endpoint answers with the archive named in a header, which
    # `ctx.download` cannot read; the metadata document carries the same
    # repository and tag in a body, which it can.
    output = "module_meta_%d.json" % index
    res = ctx.download(
        url = ["%s%s/%s/%s/%s" % (base, namespace, name, target_system, version)],
        output = output,
        allow_fail = True,
        headers = auth_headers(client, host),
    )
    if not res.success:
        return {"getter": source}

    meta = json.decode(ctx.read(output))
    url = _codeload_url(meta.get("source", ""), meta.get("tag", ""))
    if not url:
        return {"getter": source}

    return {"download_url": url}
