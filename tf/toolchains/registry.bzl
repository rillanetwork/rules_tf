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
        client["errors"].append(
            ("failed service discovery for registry host '%s' (%s) -- the host must serve a " +
             "terraform service-discovery document") % (host, url),
        )
        bases[host] = ""
        return ""

    # Not cleaned up: module_ctx has no delete(), and these land in the
    # extension's own working directory rather than in any repo.
    doc = json.decode(ctx.read(output))

    path = doc.get("providers.v1")
    if not path:
        client["errors"].append(
            ("registry host '%s' does not advertise a provider registry: no 'providers.v1' " +
             "key in %s") % (host, url),
        )
        bases[host] = ""
        return ""

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
