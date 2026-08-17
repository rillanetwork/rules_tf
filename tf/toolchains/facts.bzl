"""The keys under which the module extension's learned facts are persisted.

An extension's facts are what bzlmod writes into `MODULE.bazel.lock`, so these
keys are the schema of that record. They live apart from the code that fills
them because both the mirror resolution and the verification pass address the
same entries.

Fact keys are unversioned, and changing the shape of one (or of its value) is
therefore a breaking change to any lockfile already carrying them. Do it by
adopting `module_extension(facts_version = ...)`, which invalidates the old
facts for us -- and note that raises the Bazel floor to 9.2.
"""

def resolve_fact_key(host, namespace, provider_type, spec):
    """Fact key under which a constraint's selected version is remembered.

    Args:
      host: registry hostname the provider resolves against.
      namespace: the provider's namespace.
      provider_type: the provider's type.
      spec: the constraint as written in the manifest.

    Returns:
      The fact key.
    """
    return "resolve/{host}/{ns}/{type}/{spec}".format(
        host = host,
        ns = namespace,
        type = provider_type,
        spec = spec,
    )

def package_fact_key(host, namespace, provider_type, version, platform):
    """Fact key under which one platform's package coordinates are remembered.

    The value carries `download_url`, `sha256`, and `verified` once that sha256
    has been matched against a signature-verified hash. A recorded package is
    therefore its own pin: the mirror fetches against the sha256, and the flag
    says the sha256 is one a publisher signed rather than one a registry
    asserted.

    Args:
      host: registry hostname the provider resolves against.
      namespace: the provider's namespace.
      provider_type: the provider's type.
      version: the concrete version the package holds.
      platform: the platform the package is built for, as "<os>_<arch>".

    Returns:
      The fact key.
    """
    return "package/{host}/{ns}/{type}/{version}/{platform}".format(
        host = host,
        ns = namespace,
        type = provider_type,
        version = version,
        platform = platform,
    )

def tool_fact_key(tool, version, platform):
    """Fact key under which one platform's tool release sha256 is remembered.

    Args:
      tool: the tool's name, as its release archive spells it.
      version: the release the sha256 covers.
      platform: the platform the release is built for, as "<os>_<arch>".

    Returns:
      The fact key.
    """
    return "tool/{tool}/{version}/{platform}".format(
        tool = tool,
        version = version,
        platform = platform,
    )

def tflint_plugin_fact_key(source, version, platform):
    """Fact key under which one platform's tflint ruleset sha256 is remembered.

    Kept apart from `tool_fact_key` because a ruleset is addressed by its source
    repository rather than by a bare name: two rulesets may share a plugin name
    across owners, and the source is what the release URL is built from.

    Args:
      source: the plugin's source, as the config's `source` attribute spells it.
      version: the release the sha256 covers.
      platform: the platform the release is built for, as "<os>_<arch>".

    Returns:
      The fact key.
    """
    return "tflint_plugin/{source}/{version}/{platform}".format(
        source = source,
        version = version,
        platform = platform,
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
