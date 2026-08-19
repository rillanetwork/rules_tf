"""Resolving the tflint rulesets a config declares, and fetching what it names.

`parse_tflint_plugins` reads a config's `plugin` blocks. `resolve_tflint_plugins`
and `verify_tflint_plugins` run in the module extension, turning each block into
a per-platform sha256 returned as facts. `download_tflint_plugins` runs in the
download repository, fetching those releases against those hashes.

Together they replace `tflint --init`, which the download repository used to
shell out to: `--init` chooses for itself what to fetch, so identical attributes
did not pin identical contents. The signature check `--init` performs is kept, by
running it in the extension when a ruleset's facts are first minted.
"""

load("@rules_tf//tf/toolchains:checksums.bzl", "get_sha256sum")
load(
    "@rules_tf//tf/toolchains:facts.bzl",
    "MIRROR_PLATFORMS",
    "tflint_plugin_fact_key",
)

# tflint installs rulesets from GitHub releases and nowhere else.
_PLUGIN_HOST = "github.com"

_ARCHIVE_TEMPLATE = "{repo}_{os}_{arch}.zip"

# The owner whose rulesets tflint verifies against the key built into it. Anyone
# else's needs a `signing_key` in the plugin block.
_OFFICIAL_OWNER = "terraform-linters"

# The binary a ruleset archive holds, named for the plugin, not its repository.
_BINARY_TEMPLATE = "tflint-ruleset-{name}"

# `--init` fetches a release per ruleset, so this bounds downloads.
_INIT_TIMEOUT = 1800

_RELEASE_URL_TEMPLATE = "https://{source}/releases/download/v{version}/{file}"

_CHECKSUMS_URL_TEMPLATE = "https://{source}/releases/download/v{version}/checksums.txt"

def _quoted_value(text):
    """The first double-quoted run in text, or "" when it holds none."""
    _, _, rest = text.partition("\"")
    value, sep, _ = rest.partition("\"")
    if not sep:
        return ""
    return value

def _heredoc_terminator(line):
    """The terminator opened by a heredoc on line, or None when it opens none.

    A `signing_key` heredoc holds PGP armor, full of the braces and hashes the
    scan below would otherwise read as syntax.
    """
    if "<<" not in line:
        return None
    _, _, marker = line.partition("<<")

    # `<<-` is the indented form; the terminator is the word either way.
    return marker.strip().lstrip("-").strip()

def parse_tflint_plugins(config):
    """Reads the ruleset plugins a tflint config declares.

    Only `plugin` blocks carrying a `source` are returned; a block without one
    names a ruleset built into the tflint binary, which is not downloadable.

    Args:
      config: contents of a tflint config file.

    Returns:
      One {"name", "source", "version", "repo", "signing_key"} dict per declared
      ruleset, in declaration order. `signing_key` records only that the block
      carries one; the key itself stays in the config tflint reads it from.
      Fails on a source without a version, or a source that is not a GitHub
      repository.
    """
    plugins = []
    current = None
    depth = 0
    heredoc = None

    for raw in config.splitlines():
        if heredoc != None:
            if raw.strip() == heredoc:
                heredoc = None
            continue

        line = raw.strip()

        # Whole-line comments only: a '#' inside a quoted value is content.
        if line.startswith("#") or line.startswith("//"):
            continue

        terminator = _heredoc_terminator(line)
        if terminator != None:
            heredoc = terminator

            # Read off the opener, since the body is skipped wholesale.
            if current != None and depth == 1 and line.partition("=")[0].strip() == "signing_key":
                current["signing_key"] = True
            continue

        if current == None:
            if line.startswith("plugin ") and line.endswith("{"):
                current = {
                    "name": _quoted_value(line),
                    "source": "",
                    "version": "",
                    "signing_key": False,
                }
                depth = 1
            continue

        depth += line.count("{") - line.count("}")
        if depth <= 0:
            plugins.append(current)
            current = None
            continue

        # Only the plugin block's own attributes; a nested `rule` block has none.
        if depth != 1:
            continue

        key, sep, value = line.partition("=")
        if not sep:
            continue
        if key.strip() in ["source", "version"]:
            current[key.strip()] = _quoted_value(value)
        elif key.strip() == "signing_key":
            current["signing_key"] = True

    # An unterminated final block still gets the checks below.
    if current != None:
        plugins.append(current)

    declared = []
    for p in plugins:
        if not p["source"]:
            continue

        if not p["version"]:
            fail(("tflint plugin \"%s\" names a source but no version. A downloadable " +
                  "ruleset must pin one, so that the release its hash covers is the " +
                  "release a later build fetches.") % p["name"])

        parts = p["source"].split("/")
        if len(parts) != 3 or parts[0] != _PLUGIN_HOST:
            fail(("tflint plugin \"%s\" has source '%s'; it must be " +
                  "'%s/<owner>/<repo>', which is the only form tflint publishes " +
                  "releases under.") % (p["name"], p["source"], _PLUGIN_HOST))

        # Release assets are named for the repository, which need not match the
        # plugin name.
        declared.append({
            "name": p["name"],
            "source": p["source"],
            "version": p["version"],
            "repo": parts[2],
            "signing_key": p["signing_key"],
        })

    return declared

def resolve_tflint_plugins(ctx, plugins, os, arch, facts):
    """Resolves every declared ruleset's release sha256, for every platform.

    Runs in the module extension, so the hashes come back as facts that bzlmod
    persists in `MODULE.bazel.lock`. One checksum document covers every platform
    a ruleset publishes, so resolving all of `MIRROR_PLATFORMS` costs what
    resolving the host alone would, and a lockfile written on one machine serves
    the rest.

    Args:
      ctx: the module extension's `module_ctx`.
      plugins: declared rulesets, from `parse_tflint_plugins`.
      os: host operating system, in the release's spelling.
      arch: host architecture, in the release's spelling.
      facts: the previously persisted fact table, `module_ctx.facts`.

    Returns:
      A (resolved, facts, errors) tuple: resolved carries each ruleset with the
      host's `download_url` and `sha256`, facts is the table to hand back, and
      errors names every ruleset that could not be resolved. Errors are
      returned rather than raised because extension evaluation is not lazy: the
      caller defers them to the download repository, which fails when a target
      actually needs tflint.
    """
    platform = "%s_%s" % (os, arch)

    wanted = list(MIRROR_PLATFORMS)
    if platform not in wanted:
        wanted.append(platform)

    new_facts = {}
    errors = []

    # A ruleset already remembered for the host asks nothing. Its other
    # platforms are re-emitted to survive: facts are replaced wholesale by what
    # this evaluation returns.
    pending = []
    for p in plugins:
        remembered = {}
        for w in wanted:
            fact = facts.get(tflint_plugin_fact_key(p["source"], p["version"], w))
            if fact:
                remembered[w] = fact

        if platform in remembered:
            for w, fact in remembered.items():
                new_facts[tflint_plugin_fact_key(p["source"], p["version"], w)] = fact
            p["sha256"] = remembered[platform]["sha256"]
            continue

        # One path per ruleset: these downloads run concurrently.
        output = "tflint_plugin_checksums_{owner}_{repo}_{version}".format(
            owner = p["source"].split("/")[1],
            repo = p["repo"],
            version = p["version"],
        )
        url = _CHECKSUMS_URL_TEMPLATE.format(source = p["source"], version = p["version"])
        pending.append({
            "plugin": p,
            "url": url,
            "output": output,
            # allow_fail so the error below can name the ruleset at fault.
            "download": ctx.download(
                url = [url],
                output = output,
                allow_fail = True,
                block = False,
            ),
        })

    if len(pending) > 0:
        ctx.report_progress("Resolving %d tflint ruleset(s)" % len(pending))

    for r in pending:
        p = r["plugin"]
        if not r["download"].wait().success:
            errors.append("failed to fetch the checksums for tflint ruleset %s %s from %s" % (
                p["source"],
                p["version"],
                r["url"],
            ))
            continue

        shasums = ctx.read(r["output"])
        for w in wanted:
            w_os, _, w_arch = w.partition("_")
            sha256 = get_sha256sum(shasums, _ARCHIVE_TEMPLATE.format(
                repo = p["repo"],
                os = w_os,
                arch = w_arch,
            ))

            # A platform the ruleset does not publish goes unrecorded; only the
            # host's absence fails, below.
            if sha256:
                new_facts[tflint_plugin_fact_key(p["source"], p["version"], w)] = {
                    "sha256": sha256,
                }

        host = new_facts.get(tflint_plugin_fact_key(p["source"], p["version"], platform))
        if not host:
            errors.append("no sha256 for %s in %s" % (
                _ARCHIVE_TEMPLATE.format(repo = p["repo"], os = os, arch = arch),
                r["url"],
            ))
            continue

        p["sha256"] = host["sha256"]

    resolved = []
    for p in plugins:
        if not p.get("sha256"):
            continue
        resolved.append({
            "name": p["name"],
            "source": p["source"],
            "version": p["version"],
            "repo": p["repo"],
            "signing_key": p["signing_key"],
            "sha256": p["sha256"],
            "download_url": _RELEASE_URL_TEMPLATE.format(
                source = p["source"],
                version = p["version"],
                file = _ARCHIVE_TEMPLATE.format(repo = p["repo"], os = os, arch = arch),
            ),
        })

    return resolved, new_facts, errors

def unverified_plugins(facts, plugins, platforms):
    """The rulesets whose recorded coordinates carry no verification yet.

    One signature covers a release's whole `checksums.txt`, so a release is
    pending while any platform's fact still lacks the flag. A fact carrying no
    `verified` at all -- what a lockfile predating this check holds -- verifies
    once and settles.

    Args:
      facts: the fact table this evaluation will return.
      plugins: resolved rulesets, as `resolve_tflint_plugins` returns them.
      platforms: the platforms whose coordinates were resolved.

    Returns:
      The subset of `plugins` still to verify.
    """
    pending = []
    for p in plugins:
        for platform in platforms:
            meta = facts.get(tflint_plugin_fact_key(p["source"], p["version"], platform))
            if meta and not meta.get("verified"):
                pending.append(p)
                break

    return pending

def warn_unverified_plugins(plugins):
    """Warns for each ruleset admitted on the release host's word alone.

    Args:
      plugins: resolved rulesets left unverified under
        tflint_plugin_verification = "off".
    """
    if not plugins:
        return

    names = ", ".join(["%s %s" % (p["source"], p["version"]) for p in plugins])

    print(("rules_tf: no signature check covers the tflint ruleset(s): %s. Those releases are " +
           "pinned by a hash read from checksums.txt, which is the release host's word rather " +
           "than a publisher's signature.") % names)  # buildifier: disable=print

def _file_sha256(ctx, path, output):
    """The sha256 of a file already on disk.

    Starlark has no hashing function, so this borrows `download`'s: it reports
    the sha256 of what it fetched, and a `file://` URL makes a local path
    fetchable.

    Args:
      ctx: the module extension's `module_ctx`.
      path: the file to hash.
      output: where the copy `download` insists on writing goes.

    Returns:
      The hex sha256, or None when the file could not be read.
    """
    result = ctx.download(url = "file://" + str(path), output = output, allow_fail = True)
    if not result.success:
        return None

    return result.sha256

def verify_tflint_plugins(ctx, tflint, config, plugins, facts, platforms, workdir):
    """Checks each ruleset's recorded hashes against the release whose signature tflint verified.

    `tflint --init` is run once over the config as written, which is what puts a
    third-party ruleset's `signing_key` in front of tflint. Rulesets tflint has
    no way to check are refused before it runs, since `--init` installs those
    with a warning and still exits 0.

    Exiting 0 only says tflint authenticated a document of its own fetching, so
    the binary is what ties that to the hashes recorded here: the archive the
    host's recorded sha256 pins must hold the binary `--init` installed. That
    corroborates the document, and every recorded hash is then checked against
    it, not just the host's.

    Args:
      ctx: the module extension's `module_ctx`.
      tflint: path of the tflint binary to run.
      config: contents of the toolchain-wide tflint config.
      plugins: resolved rulesets to verify.
      facts: the fact table this evaluation will return; marked in place.
      platforms: the platforms whose coordinates were resolved.
      workdir: directory to install and unpack into, relative to the
        extension's working directory. One per download tag: two tags carry
        two configs and must not share a plugin directory.

    Returns:
      A message per ruleset that could not be verified, for the caller to defer.
    """
    errors = []
    verifiable = []
    for p in plugins:
        if p["source"].split("/")[1] == _OFFICIAL_OWNER or p["signing_key"]:
            verifiable.append(p)
        else:
            errors.append(
                ("tflint ruleset %s %s carries no signing_key, and tflint verifies a release " +
                 "signature against its own key only for %s. Add signing_key to the plugin " +
                 "block, or set tflint_plugin_verification = \"off\" on the tf.download tag to " +
                 "pin it on the release host's word alone.") % (
                    p["source"],
                    p["version"],
                    _OFFICIAL_OWNER,
                ),
            )

    if not verifiable:
        return errors

    ctx.report_progress("Verifying %d tflint ruleset(s)" % len(verifiable))

    # In flight before `--init` runs, which fetches a release per ruleset and is
    # the long pole. Fetched again rather than carried over from the resolution:
    # a ruleset resolved from the lockfile never had a document read at all.
    pending = []
    for index, p in enumerate(verifiable):
        url = _CHECKSUMS_URL_TEMPLATE.format(source = p["source"], version = p["version"])
        output = "%s/checksums/%d" % (workdir, index)
        pending.append({
            "plugin": p,
            "index": index,
            "url": url,
            "output": output,
            "download": ctx.download(
                url = [url],
                output = output,
                allow_fail = True,
                block = False,
            ),
        })

    plugin_dir = ctx.path(workdir + "/plugins")
    config_file = workdir + "/.tflint.hcl"
    ctx.file(config_file, config, executable = False)

    # The environment is inherited, so a GitHub token reaches tflint here too.
    result = ctx.execute(
        [
            tflint,
            "--chdir=%s" % ctx.path(workdir),
            "--init",
            "--config=%s" % ctx.path(config_file),
        ],
        environment = {"TFLINT_PLUGIN_DIR": str(plugin_dir)},
        timeout = _INIT_TIMEOUT,
    )
    if result.return_code != 0:
        return errors + [
            ("could not verify the tflint ruleset(s) %s: `tflint --init` exited %d. It checks " +
             "each release's checksums.txt against its signature, so it needs network access, " +
             "and a signing_key that does not match the publisher's fails here.\n%s") % (
                ", ".join(["%s %s" % (p["source"], p["version"]) for p in verifiable]),
                result.return_code,
                result.stderr or result.stdout,
            ),
        ]

    for r in pending:
        p = r["plugin"]
        if not r["download"].wait().success:
            errors.append("failed to fetch the checksums for tflint ruleset %s %s from %s" % (
                p["source"],
                p["version"],
                r["url"],
            ))
            continue

        binary = _BINARY_TEMPLATE.format(name = p["name"])
        installed = ctx.path("{dir}/{source}/{version}/{binary}".format(
            dir = plugin_dir,
            source = p["source"],
            version = p["version"],
            binary = binary,
        ))
        if not installed.exists:
            errors.append(
                ("`tflint --init` installed no %s for ruleset %s %s, so there is nothing to " +
                 "check its recorded hash against.") % (binary, p["source"], p["version"]),
            )
            continue

        # One path per ruleset, so no binary is overwritten before it is read.
        unpacked = "%s/pinned/%d" % (workdir, r["index"])
        if not ctx.download_and_extract(
            url = p["download_url"],
            sha256 = p["sha256"],
            type = "zip",
            output = unpacked,
            allow_fail = True,
        ).success:
            errors.append(
                ("the recorded sha256 for tflint ruleset %s %s does not pin %s. Either the " +
                 "hash is stale, or the release host served an archive that was not the one " +
                 "the hash was read for -- do not ignore this without establishing which.") % (
                    p["source"],
                    p["version"],
                    p["download_url"],
                ),
            )
            continue

        pinned_sha256 = _file_sha256(
            ctx,
            ctx.path("%s/%s" % (unpacked, binary)),
            "%s/pinned.sha256" % unpacked,
        )
        installed_sha256 = _file_sha256(ctx, installed, "%s/installed.sha256" % unpacked)

        if pinned_sha256 == None or installed_sha256 == None:
            errors.append(
                ("could not read back the %s of tflint ruleset %s %s to compare it against " +
                 "the release tflint verified.") % (binary, p["source"], p["version"]),
            )
            continue

        if pinned_sha256 != installed_sha256:
            errors.append(
                ("tflint ruleset %s %s does not match the release whose signature tflint " +
                 "verified: the archive its recorded sha256 pins holds a %s of %s, and the " +
                 "one tflint installed is %s. The hashes recorded for it were not read from " +
                 "the document tflint authenticated.") % (
                    p["source"],
                    p["version"],
                    binary,
                    pinned_sha256,
                    installed_sha256,
                ),
            )
            continue

        shasums = ctx.read(r["output"])
        contradicted = []
        marked = {}
        for platform in platforms:
            key = tflint_plugin_fact_key(p["source"], p["version"], platform)
            meta = facts.get(key)
            if not meta:
                continue

            p_os, _, p_arch = platform.partition("_")
            signed = get_sha256sum(shasums, _ARCHIVE_TEMPLATE.format(
                repo = p["repo"],
                os = p_os,
                arch = p_arch,
            ))
            if meta["sha256"] != signed:
                contradicted.append(platform)
                continue

            verified = dict(meta)
            verified["verified"] = True
            marked[key] = verified

        if contradicted:
            errors.append(
                ("tflint ruleset %s %s has recorded hashes the signed checksums.txt " +
                 "contradicts, for: %s. The document at %s is the one tflint's signature " +
                 "check covered, so those coordinates came from somewhere else -- do not " +
                 "ignore this without establishing where.") % (
                    p["source"],
                    p["version"],
                    ", ".join(contradicted),
                    r["url"],
                ),
            )
            continue

        # Marked only once nothing is contradicted, so a release settles whole:
        # a half-marked one would never report the mismatch again.
        facts.update(marked)

    return errors

def download_tflint_plugins(ctx, plugins, plugin_dir):
    """Unpacks every resolved ruleset into the layout tflint loads plugins from.

    Coordinates arrive already resolved, so this reaches no release API: known
    URLs against known hashes. The directory is created even when nothing is
    declared, since the BUILD template exports it either way.

    Args:
      ctx: the download repository's `repository_ctx`.
      plugins: resolved rulesets, as `resolve_tflint_plugins` returns them.
      plugin_dir: directory to install into, relative to the repository root.
    """
    if len(plugins) == 0:
        ctx.file("%s/.keep" % plugin_dir, content = "")
        return

    ctx.report_progress("Downloading %d tflint ruleset(s)" % len(plugins))

    staged = []
    for p in plugins:
        # download + extract rather than download_and_extract: only `download`
        # accepts block = False. The staged zip is deleted once unpacked.
        archive = "tflint_plugin_{repo}_{version}.zip".format(
            repo = p["repo"],
            version = p["version"],
        )

        # The path tflint looks a plugin up under: source and version verbatim.
        output = "{dir}/{source}/{version}".format(
            dir = plugin_dir,
            source = p["source"],
            version = p["version"],
        )
        staged.append({
            "plugin": p,
            "archive": archive,
            "output": output,
            "pending": ctx.download(
                url = [p["download_url"]],
                sha256 = p["sha256"],
                output = archive,
                allow_fail = True,
                block = False,
            ),
        })

    for s in staged:
        p = s["plugin"]
        if not s["pending"].wait().success:
            # Re-issue unsuppressed, so Bazel's own error says what went wrong.
            ctx.report_progress("Re-fetching %s to report why it failed" % p["source"])
            ctx.download(
                url = [p["download_url"]],
                sha256 = p["sha256"],
                output = s["archive"],
            )

        ctx.extract(archive = s["archive"], output = s["output"])
        ctx.delete(s["archive"])

        # tflint loads a plugin by name, so an archive holding a differently
        # named binary would install cleanly and then not be found.
        binary = "%s/tflint-ruleset-%s" % (s["output"], p["name"])
        if not ctx.path(binary).exists:
            fail(("the tflint ruleset archive %s holds no 'tflint-ruleset-%s', which is " +
                  "the name tflint loads plugin \"%s\" by. It holds: %s") % (
                p["download_url"],
                p["name"],
                p["name"],
                ", ".join([f.basename for f in ctx.path(s["output"]).readdir()]),
            ))
