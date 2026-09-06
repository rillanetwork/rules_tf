"""Reading and resolving the sha256 of a tool's release archive.

Every tool this ruleset downloads -- terraform, tofu, tflint, tfdoc -- publishes
a SHA256SUMS document alongside its release. Reading one is shared by all four;
resolving one ahead of the download, so the fetch is pinned by an attribute
rather than by a second request, is what the tf toolchains additionally need.
"""

load(":facts.bzl", "MIRROR_PLATFORMS", "tool_fact_key")

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

DEFAULT_ARCHIVE_TEMPLATE = "{tool}_{version}_{os}_{arch}.zip"

def resolve_tool_sha256(
        ctx,
        tool,
        version,
        os,
        arch,
        facts,
        sha256sums_template,
        archive_template = DEFAULT_ARCHIVE_TEMPLATE):
    """Resolves the tool release's sha256, so the download repo is given it rather than fetching it.

    Every byte that repository fetches is then pinned by an attribute, which is
    what lets it declare itself reproducible and be served from the repo
    contents cache.

    Resolved for every platform in `MIRROR_PLATFORMS`, for the reason the
    package coordinates are: one lockfile then covers every machine in a team.

    Args:
      ctx: the module extension's `module_ctx`.
      tool: the tool's name, which names both its archive and its facts.
      version: the release to resolve.
      os: the host operating system, in the release's spelling.
      arch: the host architecture, in the release's spelling.
      facts: the previously persisted fact table, `module_ctx.facts`.
      sha256sums_template: the release's SHA256SUMS URL, taking `{version}`.
      archive_template: the archive's name as its SHA256SUMS document spells it,
        taking `{tool}`, `{version}`, `{os}` and `{arch}`. The four tools all
        name theirs differently -- terraform and tofu carry the version,
        tflint does not, terraform-docs joins the platform with dashes -- so the
        naming is the caller's to state.

    Returns:
      A (sha256, facts, error) tuple: sha256 is the host's, facts is the table
      to hand back, and error is None or a message for the caller to defer.
    """
    platform = "%s_%s" % (os, arch)

    wanted = list(MIRROR_PLATFORMS)
    if platform not in wanted:
        wanted.append(platform)

    # A hit on the host's key answers the question the download repo asks; the
    # other platforms' keys are re-emitted so they survive, since an extension's
    # facts are replaced wholesale by what it returns.
    remembered = facts.get(tool_fact_key(tool, version, platform))
    if remembered:
        kept = {}
        for p in wanted:
            r = facts.get(tool_fact_key(tool, version, p))
            if r:
                kept[tool_fact_key(tool, version, p)] = r
        return remembered["sha256"], kept, None

    url = sha256sums_template.format(version = version)
    output = "%s_%s_sha256sums" % (tool, version)
    if not ctx.download(url = [url], output = output, allow_fail = True).success:
        return "", {}, "failed to fetch the %s %s SHA256SUMS from %s" % (tool, version, url)

    shasums = ctx.read(output)
    new_facts = {}
    for p in wanted:
        p_os, _, p_arch = p.partition("_")
        sha256 = get_sha256sum(shasums, archive_template.format(
            tool = tool,
            version = version,
            os = p_os,
            arch = p_arch,
        ))
        if sha256:
            new_facts[tool_fact_key(tool, version, p)] = {"sha256": sha256}

    host = new_facts.get(tool_fact_key(tool, version, platform))
    if not host:
        return "", new_facts, "no sha256 for %s in %s" % (
            archive_template.format(tool = tool, version = version, os = os, arch = arch),
            url,
        )

    return host["sha256"], new_facts, None
