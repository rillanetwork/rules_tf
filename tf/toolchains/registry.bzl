"""Talking to a terraform provider registry: discovery, credentials, and the client.

Everything here is about reaching a registry host rather than about what is
asked of it. The client is a plain dict rather than a struct so that its
memoized discovery and credential lookups can be filled in place, and it works
over either a `module_ctx` or a `repository_ctx`: the extension resolves the
mirror with it, and the download repository builds one solely to authenticate a
package fetch.
"""

# The registry an unqualified source resolves against, keyed by use_tofu. Read
# by the module extension and stamped into each toolchain, so the lock target
# addresses providers exactly as the mirror did.
DEFAULT_REGISTRY = {
    True: "registry.opentofu.org",
    False: "registry.terraform.io",
}

# Service-discovery results for the two default registries. Seeding them keeps
# the common case free of an extra `.well-known` round trip per build; every
# other host is discovered for real by `providers_base_url`.
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

    Args:
      ctx: a `module_ctx` or `repository_ctx` to make requests through.

    Returns:
      The client, as a mutable dict.
    """
    return {
        "ctx": ctx,
        "bases": dict(_KNOWN_PROVIDER_REGISTRIES),
        "tokens": {},
        # Registry failures are collected rather than fatal, so an unrelated
        # build in a workspace that cannot reach the registry still loads. See
        # `resolve_providers`.
        "errors": [],
    }

def url_host(url):
    """Returns the host component of url, port included.

    Args:
      url: an absolute URL.

    Returns:
      The host, or the whole string when it carries no scheme or path.
    """
    return url.split("://", 1)[-1].split("/", 1)[0]

def resolve_url(base, ref):
    """Resolves a URL reference against the document it was read from.

    The subset of RFC 3986 section 5 a registry response can contain: an
    absolute URL passes through, a scheme-relative or host-relative reference
    adopts the base's scheme or authority, and a relative path is merged
    against the base document's directory, dot-segments removed. `base` is the
    URL the document was requested from; a redirect is invisible here
    (`ctx.download` never reports the final URL), so a host that redirects and
    then answers with relative references resolves against the wrong base --
    absolute references always work.

    Args:
      base: absolute URL of the document holding the reference.
      ref: the reference, absolute or relative.

    Returns:
      The resolved absolute URL.
    """
    if ref.startswith("http://") or ref.startswith("https://"):
        return ref

    scheme, _, rest = base.partition("://")
    if ref.startswith("//"):
        return scheme + ":" + ref

    authority, _, base_path = rest.partition("/")
    base_path = base_path.partition("?")[0].partition("#")[0]

    # The reference's query and fragment ride along untouched; dot-segment
    # removal applies to the path alone.
    suffix = ""
    for sep in ["?", "#"]:
        if sep in ref:
            ref, _, tail = ref.partition(sep)
            suffix = sep + tail
            break

    if ref.startswith("/"):
        merged = ref
    else:
        # Resolution is against the document's directory, so its last
        # component drops off.
        directory = base_path.rsplit("/", 1)[0] if "/" in base_path else ""
        merged = "/%s/%s" % (directory, ref) if directory else "/" + ref

    segments = []
    for segment in merged.split("/"):
        if segment == ".":
            continue
        if segment == "..":
            # The leading empty segment is the root, which ".." cannot climb
            # past.
            if len(segments) > 1:
                segments.pop()
            continue
        segments.append(segment)

    return "%s://%s%s%s" % (scheme, authority, "/".join(segments), suffix)

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

def hcl_credentials_token(text, host):
    """Reads `credentials "<host>" { token = "..." }` from a terraform CLI config.

    Only that block shape is understood, not general HCL, which is the same
    narrow-subset approach provider_locks.bzl takes to lock files.

    Args:
      text: contents of a `.terraformrc`-style CLI configuration file.
      host: registry hostname whose credentials block is wanted.

    Returns:
      The token, or "" when the file carries no block for that host.
    """
    in_block = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped == "" or stripped.startswith("#") or stripped.startswith("//"):
            continue

        if in_block:
            if stripped.startswith("}"):
                in_block = False
            elif stripped.startswith("token"):
                parts = stripped.split("\"")
                if len(parts) >= 2:
                    return parts[1]
            continue

        if stripped.startswith("credentials "):
            parts = stripped.split("\"")
            if len(parts) >= 2 and parts[1] == host:
                # The whole block may be written on one line.
                if len(parts) >= 4 and "token" in parts[2]:
                    return parts[3]
                in_block = True

    return ""

def _credentials_file_paths(ctx):
    """CLI configuration files that may carry a `credentials` block for a host."""
    path = ctx.getenv("TF_CLI_CONFIG_FILE")
    if path:
        return [path]

    home = ctx.getenv("HOME")
    if not home:
        return []

    # `terraform login` writes the JSON form; a hand-maintained CLI config is
    # HCL. Both are read, in that order.
    return [
        home + "/.terraform.d/credentials.tfrc.json",
        home + "/.terraformrc",
    ]

def _credentials_file_token(ctx, host):
    """Reads a host token from terraform's CLI config, in either JSON or HCL form."""
    for path in _credentials_file_paths(ctx):
        p = ctx.path(path)
        if not p.exists:
            continue

        # watch = "no": the file lives outside the workspace, and rotating a
        # credential should not by itself invalidate the mirror.
        text = ctx.read(p, watch = "no")

        if path.endswith(".json"):
            creds = json.decode(text).get("credentials", {})
            token = creds.get(host, {}).get("token", "")
        else:
            token = hcl_credentials_token(text, host)

        if token:
            return token

    return ""

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

def providers_base_url(client, host):
    """Returns host's providers.v1 API base URL, via remote service discovery.

    Args:
      client: the registry client from `new_registry_client`, which memoizes the
        result so a manifest naming several providers on one host discovers once.
      host: registry hostname to discover.

    Returns:
      The base URL, with a trailing slash, or "" when the host cannot be
      discovered -- in which case the reason is recorded on the client.
    """
    return _service_base_url(client, host, "providers.v1", "provider registry")

def modules_base_url(client, host):
    """Returns host's modules.v1 API base URL, via remote service discovery.

    A host may serve one registry and not the other, so the two are discovered
    and memoized separately even though one document advertises both.

    Args:
      client: the registry client from `new_registry_client`.
      host: registry hostname to discover.

    Returns:
      The base URL, with a trailing slash, or "" when the host cannot be
      discovered -- in which case the reason is recorded on the client.
    """
    return _service_base_url(client, host, "modules.v1", "module registry")

def _service_base_url(client, host, service, label):
    """Returns host's base URL for one discovery service.

    Args:
      client: the registry client from `new_registry_client`, which memoizes per
        (service, host) so a manifest naming several entries on one host
        discovers once.
      host: registry hostname to discover.
      service: the discovery document key, e.g. "providers.v1".
      label: how the service is named in an error message.

    Returns:
      The base URL, with a trailing slash, or "" when the host cannot be
      discovered.
    """
    bases = client["bases"]
    memo_key = "%s/%s" % (service, host)
    if memo_key in bases:
        return bases[memo_key]

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
        client["errors"].append(
            ("failed service discovery for registry host '%s' (%s) -- the host must serve a " +
             "terraform service-discovery document") % (host, url),
        )
        bases[memo_key] = ""
        return ""

    # Not cleaned up: module_ctx has no delete(), and these land in the
    # extension's own working directory rather than in any repo.
    doc = json.decode(ctx.read(output))

    path = doc.get(service)
    if not path:
        client["errors"].append(
            "registry host '%s' does not advertise a %s: no '%s' key in %s" % (
                host,
                label,
                service,
                url,
            ),
        )
        bases[memo_key] = ""
        return ""

    # The advertised path may be an absolute URL, or a reference relative to the
    # discovery document itself -- "v1/providers/" resolves under
    # /.well-known/, the way any document-relative reference would.
    base = resolve_url(url, path)

    if not base.endswith("/"):
        base += "/"

    bases[memo_key] = base
    return base
