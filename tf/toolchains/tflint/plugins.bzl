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
reproducible. It does verify the release's checksum document against the
signing key the config names, which fetching by hash does not; the hash a
lockfile records is the registry's word by way of GitHub, not a publisher's
signature. Restoring that check means running `--init` once, in the extension,
at the point a fact is first minted -- the shape `fetch_lock_tool` already uses
for providers.
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
      One {"name", "source", "version", "repo"} dict per declared ruleset, in
      the order the config declares them. Fails on a block that names a source
      without a version, or one whose source is not a GitHub repository: both
      are configs `tflint --init` would reject too, and failing here says which
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
            continue

        if current == None:
            if line.startswith("plugin ") and line.endswith("{"):
                current = {"name": _quoted_value(line), "source": "", "version": ""}
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
        if sep and key.strip() in ["source", "version"]:
            current[key.strip()] = _quoted_value(value)

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
            "sha256": p["sha256"],
            "download_url": _RELEASE_URL_TEMPLATE.format(
                source = p["source"],
                version = p["version"],
                file = _ARCHIVE_TEMPLATE.format(repo = p["repo"], os = os, arch = arch),
            ),
        })

    return resolved, new_facts, errors

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
