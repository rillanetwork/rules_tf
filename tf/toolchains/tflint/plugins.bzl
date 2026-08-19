"""Resolving the tflint rulesets a config declares, and fetching what it names.

The three halves run in different places and are kept together because they
share the shape of a declared plugin. `parse_tflint_plugins` reads the config's
`plugin` blocks, `resolve_tflint_plugins` runs in the module extension and turns
each into a per-platform sha256 it returns as facts, and
`download_tflint_plugins` runs in the download repository, fetching those
releases against hashes the extension already resolved.

This replaces `tflint --init`, which is what the download repository used to
shell out to. `--init` decides for itself what to fetch, so identical attributes
did not pin identical contents and the repository could not call itself
reproducible. What `--init` did give was a signature check: it verifies the
release's `checksums.txt` against `checksums.txt.sig`, using the key built into
tflint for `terraform-linters` rulesets or the `signing_key` the config carries
for anyone else's. `verify_tflint_plugins` keeps that check by running `--init`
once in the extension, at the point a fact is first minted -- the shape
`fetch_lock_tool` already uses for providers.

Exiting 0 is not on its own worth anything, for two separate reasons, and the
verification pass is built around both. `--init` fetches and verifies its own
copy of `checksums.txt`, so nothing yet connects what it authenticated to the
hashes read out of the copy fetched here; and for a third-party ruleset the
config gives no key for, it installs with a warning and still exits 0.
"""

load("@rules_tf//tf/toolchains:checksums.bzl", "get_sha256sum")
load(
    "@rules_tf//tf/toolchains:facts.bzl",
    "MIRROR_PLATFORMS",
    "tflint_plugin_fact_key",
)

# tflint installs a ruleset from a GitHub release and nothing else, so a source
# naming any other host has no release URL to build and is rejected rather than
# guessed at.
_PLUGIN_HOST = "github.com"

_ARCHIVE_TEMPLATE = "{repo}_{os}_{arch}.zip"

# The owner whose rulesets tflint verifies against the key built into it. Any
# other owner's release is verified only against a `signing_key` the config
# carries, so the two together are what "this ruleset can be verified at all"
# means. Hardcoded rather than read back out of tflint's output: were tflint to
# widen the set, this rejects a ruleset that would in fact have verified, which
# is the direction that fails safely.
_OFFICIAL_OWNER = "terraform-linters"

# The binary a ruleset archive holds, named for the plugin rather than for the
# repository it ships from.
_BINARY_TEMPLATE = "tflint-ruleset-{name}"

# `--init` fetches a release per ruleset, so the ceiling is a download rather
# than a computation.
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

    A `signing_key` is written as a heredoc holding PGP armor, whose body is
    full of the braces, hashes and equals signs the scan below reads as syntax.
    Recognising the opener lets those lines be skipped wholesale.
    """
    if "<<" not in line:
        return None
    _, _, marker = line.partition("<<")

    # `<<-` is the indented form; the terminator is the word either way.
    return marker.strip().lstrip("-").strip()

def parse_tflint_plugins(config):
    """Reads the ruleset plugins a tflint config declares.

    Only `plugin` blocks carrying a `source` are returned. A block without one
    names a ruleset bundled into the tflint binary -- `plugin "terraform"`, the
    one every config enables -- which is not downloadable and must not be
    treated as missing.

    Args:
      config: contents of a tflint config file.

    Returns:
      One {"name", "source", "version", "repo", "signing_key"} dict per declared
      ruleset, in the order the config declares them. `signing_key` records
      only that the block carries one, which is what decides whether the
      release can be signature-checked at all; the key itself stays in the
      config tflint reads it from. Fails on a block that names a source without
      a version, or one whose source is not a GitHub repository: both are
      configs `tflint --init` would reject too, and failing here says which
      block is at fault.
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

            # Read on the opener, because the body is about to be skipped
            # wholesale: a `signing_key` is written as a heredoc far more often
            # than as a quoted string, and both forms have to count.
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

        # Nested blocks (a `rule` inside a plugin, say) hold no coordinates of
        # their own, so only the plugin block's own attributes are read.
        if depth != 1:
            continue

        key, sep, value = line.partition("=")
        if not sep:
            continue
        if key.strip() in ["source", "version"]:
            current[key.strip()] = _quoted_value(value)
        elif key.strip() == "signing_key":
            current["signing_key"] = True

    # An unterminated final block is still worth reporting on: the coordinates
    # it did carry are what the messages below name.
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

        # The release's assets are named for the repository rather than for the
        # plugin, and the two need not agree.
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

    This runs in the module extension so that what it learns from the release
    comes back as facts, which bzlmod persists in `MODULE.bazel.lock`: the
    download repository is then handed the hashes as attributes and reaches
    GitHub only for the archives themselves.

    A ruleset's checksum document covers every platform it publishes, so
    resolving all of `MIRROR_PLATFORMS` costs exactly what resolving the host
    alone would -- and a lockfile written on one machine then serves the rest.

    Args:
      ctx: the module extension's `module_ctx`.
      plugins: declared rulesets, from `parse_tflint_plugins`.
      os: host operating system, in the release's spelling.
      arch: host architecture, in the release's spelling.
      facts: the previously persisted fact table, `module_ctx.facts`.

    Returns:
      A (resolved, facts, errors) tuple: resolved carries each ruleset with the
      host's `download_url` and `sha256`, facts is the table to hand back, and
      errors names every ruleset that could not be resolved.

      A GitHub failure is reported rather than fatal, for the reason a registry
      failure is: extension evaluation is not lazy, so failing here would break
      every build in the workspace, including ones that lint nothing. The caller
      passes the errors down to the download repository, which fails on them
      when a target actually needs tflint.
    """
    platform = "%s_%s" % (os, arch)

    wanted = list(MIRROR_PLATFORMS)
    if platform not in wanted:
        wanted.append(platform)

    new_facts = {}
    errors = []

    # A ruleset whose host key is already remembered asks nothing; the other
    # platforms' keys are re-emitted so they survive, since an extension's facts
    # are replaced wholesale by what it returns.
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

        # Each lands in its own path: two rulesets, or two versions of one, are
        # fetched concurrently and must not collide.
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
            # allow_fail lets the message below name the ruleset at fault
            # instead of surfacing Bazel's raw HTTP error.
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

            # A platform the ruleset does not publish simply goes unrecorded:
            # only the host's absence can fail a build, and it is caught below.
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

    Verification covers a release rather than a platform: one `checksums.txt`
    holds the hash of every platform's archive, and one signature covers that
    document. A release is pending while any platform's recorded coordinates
    still lack the flag.

    A fact carrying no `verified` at all is pending, which is what a lockfile
    written before this check existed looks like: it re-verifies once and
    settles, rather than needing the fact schema versioned.

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

    # Left unmarked, so the check is retried rather than silently settled.
    print(("rules_tf: no signature check covers the tflint ruleset(s): %s. Those releases are " +
           "pinned by a hash read from checksums.txt, which is the release host's word rather " +
           "than a publisher's signature.") % names)  # buildifier: disable=print

def _file_sha256(ctx, path, output):
    """The sha256 of a file already on disk.

    Starlark has no hashing function, so the hash is had from the one thing
    that does compute one: `download` reports the sha256 of whatever it
    fetched, and a `file://` URL makes a local path something it can fetch.

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

    `--init` is run once, over the config as written: that is what puts a
    third-party ruleset's `signing_key` in front of tflint, which reads the key
    from the config and verifies `checksums.txt.sig` against it. Rulesets the
    config gives tflint no way to check are refused before it runs, because
    `--init` installs those with a warning and still exits 0.

    Exiting 0 then says only that tflint authenticated a document of its own
    fetching. What ties that to the hashes recorded here is the binary: the
    archive the host's recorded sha256 pins is fetched and unpacked, and it
    must hold the binary `--init` installed. A document listing that hash is
    one whose host entry describes the release a publisher signed, and the rest
    of its entries stand or fall with it -- the leverage `terraform providers
    lock` gets from authenticating one SHA256SUMS.

    That corroborates a document, so every recorded hash is then checked
    against it, not just the host's. A recorded hash the document contradicts
    is never fine: it was read from some other document, which is exactly what
    a lockfile arriving here with no marks on it might be carrying.

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
      A message per ruleset that could not be verified, for the caller to
      defer. Fatal here would fail every build in the workspace, including the
      ones that lint nothing.
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

    # Put the documents in flight before `--init` runs, since that fetches a
    # release per ruleset and is the long pole. A checksum document is fetched
    # again here rather than carried over from the resolution: a ruleset whose
    # coordinates came from the lockfile never had one read at all, and that is
    # the case the check below is for.
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

    # The environment is inherited, so a token that lifts the release host's
    # rate limit reaches tflint the way it reaches it anywhere else.
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

        # Each unpacks into its own path: two rulesets, or two versions of one,
        # must not overwrite each other's binary before it is read.
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

        # Marked only once nothing is contradicted, so a ruleset settles as a
        # whole: a lockfile carrying a half-marked release would verify the
        # rest of it on some later evaluation and never report the mismatch.
        facts.update(marked)

    return errors

def download_tflint_plugins(ctx, plugins, plugin_dir):
    """Unpacks every resolved ruleset into the layout tflint loads plugins from.

    Every coordinate arrives already resolved, so this reaches no release API:
    it fetches known URLs against known hashes, which makes each archive
    content-addressed for `--repository_cache`.

    The directory is created even when nothing is declared, because the BUILD
    template exports it either way and the wrapper points `TFLINT_PLUGIN_DIR` at
    it.

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
        # accepts block = False, and putting every archive in flight at once is
        # worth staging the zip, which is deleted as soon as it is unpacked.
        archive = "tflint_plugin_{repo}_{version}.zip".format(
            repo = p["repo"],
            version = p["version"],
        )

        # The path tflint looks a plugin up under, which is where `--init` used
        # to put it: the source and version verbatim, then the binary.
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
            # allow_fail hides why: re-issue unsuppressed so Bazel's own error
            # distinguishes a checksum mismatch from a network failure.
            ctx.report_progress("Re-fetching %s to report why it failed" % p["source"])
            ctx.download(
                url = [p["download_url"]],
                sha256 = p["sha256"],
                output = s["archive"],
            )

        ctx.extract(archive = s["archive"], output = s["output"])
        ctx.delete(s["archive"])

        # tflint resolves a plugin by name, not by the repository it came from,
        # so a release whose archive holds a differently named binary would
        # install cleanly and then not be found. Say so here instead.
        binary = "%s/tflint-ruleset-%s" % (s["output"], p["name"])
        if not ctx.path(binary).exists:
            fail(("the tflint ruleset archive %s holds no 'tflint-ruleset-%s', which is " +
                  "the name tflint loads plugin \"%s\" by. It holds: %s") % (
                p["download_url"],
                p["name"],
                p["name"],
                ", ".join([f.basename for f in ctx.path(s["output"]).readdir()]),
            ))
