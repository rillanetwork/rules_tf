"""Reading and resolving the sha256 of a tool's release archive.

Every tool this ruleset downloads -- terraform, tofu, tflint, tfdoc -- publishes
a SHA256SUMS document alongside its release. Reading one is shared by all four;
resolving one ahead of the download, so the fetch is pinned by an attribute
rather than by a second request, is what the tf toolchains additionally need.

A hash read out of that document is only as good as the document, which arrives
over HTTPS and is otherwise the release host's word. terraform and OpenTofu both
sign theirs, so where a signature exists it is checked here, against the keys
vendored in `//tf/toolchains/openpgp:keys.bzl`, at the point the hash is first
recorded. tflint signs only with cosign keyless and terraform-docs publishes no
signature at all; both are admitted with a warning rather than failed, since no
setting could make either verify.
"""

load("//tf/toolchains/openpgp:bytes.bzl", "latin1_to_bytes")
load("//tf/toolchains/openpgp:keys.bzl", "PUBLISHER_KEYS")
load("//tf/toolchains/openpgp:openpgp.bzl", "verify_detached")
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

def verify_sha256sums(ctx, tool, version, document, signature_url, output):
    """Checks a checksum document against its publisher's detached signature.

    Args:
      ctx: the module extension's `module_ctx`.
      tool: the tool's name, for the messages.
      version: the release being resolved, for the messages.
      document: the checksum document, as read off disk.
      signature_url: where the detached signature is published.
      output: a scratch path to fetch the signature to.

    Returns:
      A (verified, error) tuple. An error means the check could not be made or
      did not pass, and no hash from this document should be trusted.
    """
    if not ctx.download(url = [signature_url], output = output, allow_fail = True).success:
        return False, "failed to fetch the %s %s SHA256SUMS signature from %s" % (
            tool,
            version,
            signature_url,
        )

    signature = latin1_to_bytes(ctx.read(output))

    verified, _, error = verify_detached(signature, latin1_to_bytes(document), PUBLISHER_KEYS)
    if not verified:
        return False, "the %s %s SHA256SUMS signature did not verify: %s" % (tool, version, error)

    return True, None

def warn_unsigned_tool(tool, version):
    """Warns for a tool release pinned on the release host's word alone.

    Args:
      tool: the tool's name.
      version: the release the warning is about.
    """

    # Left unmarked, so the check is retried rather than silently settled.
    print(("rules_tf: no signature check covers %s %s. Its release is pinned by a hash read " +
           "from a checksum document the publisher does not sign with OpenPGP, which is the " +
           "release host's word rather than a publisher's signature.") %
          (tool, version))  # buildifier: disable=print

def resolve_tool_sha256(
        ctx,
        tool,
        version,
        os,
        arch,
        facts,
        sha256sums_template,
        archive_template = DEFAULT_ARCHIVE_TEMPLATE,
        signature_template = None,
        verification = "auto"):
    """Resolves the tool release's sha256, so the download repo is given it rather than fetching it.

    Every byte that repository fetches is then pinned by an attribute, which is
    what lets it declare itself reproducible and be served from the repo
    contents cache.

    Resolved for every platform in `MIRROR_PLATFORMS`, for the reason the
    package coordinates are: one lockfile then covers every machine in a team.

    Where the publisher signs its checksum document, the signature is checked
    before any hash is read out of it, and the resulting facts carry a `verified`
    mark. Because one document covers every platform, verifying it once settles
    every platform's hash at the same time.

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
      signature_template: the detached OpenPGP signature's URL, taking
        `{version}`, or None for a publisher that does not sign with OpenPGP.
      verification: "auto" to check a signature where one is published, "off" to
        take every release on the release host's word.

    Returns:
      A struct with `sha256` (the host's), `facts` (the table to hand back),
      `error` (None or a message for the caller to defer), `verified` (True when
      a publisher's signature covered the hashes) and `minted` (True when the
      hashes were resolved here rather than read back from the lockfile).
    """
    platform = "%s_%s" % (os, arch)

    wanted = list(MIRROR_PLATFORMS)
    if platform not in wanted:
        wanted.append(platform)

    signed = signature_template != None and verification != "off"

    # A hit on the host's key answers the question the download repo asks; the
    # other platforms' keys are re-emitted so they survive, since an extension's
    # facts are replaced wholesale by what it returns.
    #
    # A remembered hash that no signature covered is re-resolved rather than
    # returned, so a lockfile written before verification existed verifies once
    # and then settles. A missing mark therefore reads as unverified, which is
    # what keeps this from needing a facts_version bump.
    remembered = facts.get(tool_fact_key(tool, version, platform))
    if remembered and (remembered.get("verified") or not signed):
        kept = {}
        for p in wanted:
            r = facts.get(tool_fact_key(tool, version, p))
            if r:
                kept[tool_fact_key(tool, version, p)] = r
        return struct(
            sha256 = remembered["sha256"],
            facts = kept,
            error = None,
            verified = remembered.get("verified", False),
            minted = False,
        )

    url = sha256sums_template.format(version = version)
    output = "%s_%s_sha256sums" % (tool, version)
    if not ctx.download(url = [url], output = output, allow_fail = True).success:
        return struct(
            sha256 = "",
            facts = {},
            error = "failed to fetch the %s %s SHA256SUMS from %s" % (tool, version, url),
            verified = False,
            minted = True,
        )

    shasums = ctx.read(output)

    verified = False
    if signed:
        verified, error = verify_sha256sums(
            ctx,
            tool,
            version,
            shasums,
            signature_template.format(version = version),
            output + ".sig",
        )
        if error:
            # No hash from an unverified document is recorded: a fact minted
            # here would be believed by every later evaluation.
            return struct(sha256 = "", facts = {}, error = error, verified = False, minted = True)

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
            entry = {"sha256": sha256}
            if verified:
                entry["verified"] = True
            new_facts[tool_fact_key(tool, version, p)] = entry

    host = new_facts.get(tool_fact_key(tool, version, platform))
    if not host:
        return struct(
            sha256 = "",
            facts = new_facts,
            error = "no sha256 for %s in %s" % (
                archive_template.format(tool = tool, version = version, os = os, arch = arch),
                url,
            ),
            verified = verified,
            minted = True,
        )

    return struct(
        sha256 = host["sha256"],
        facts = new_facts,
        error = None,
        verified = verified,
        minted = True,
    )
