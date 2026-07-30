# Provider registries

The toolchain builds its offline provider mirror by talking to a terraform provider registry directly. This page
covers pointing it at a registry other than the default, and authenticating against a private one.

For the mirror manifest format itself (the `mirror` / `mirror_json` attributes), see the
[README](../README.md#getting-started).

## Choosing a registry host

A mirror entry may carry an explicit registry host:

```python
tf.download(
    version = "1.9.5",
    mirror = [
        "hashicorp/random:3.3.2",                  # default host
        "mycorp.example.com/mycorp/widget:1.2.0",  # explicit host
    ],
)
```

Entries without a host default to `registry.terraform.io`, or `registry.opentofu.org` when `use_tofu = True`.

## Service discovery

For any host other than those two defaults, the provider API endpoint is located by
[terraform service discovery](https://developer.hashicorp.com/terraform/internals/remote-service-discovery):
the host must serve `https://<host>/.well-known/terraform.json` containing a `providers.v1` key, whose value is
either an absolute URL or a path relative to the host.

```json
{ "providers.v1": "/v1/providers/" }
```

The two default hosts are resolved from a built-in table, so the common case costs no extra request. Discovery
results are memoized per host, so a manifest naming many providers on one host discovers it once.

## Authenticating to a private registry

A bearer token is discovered in this order:

1. **`TF_TOKEN_<host>`**, with periods encoded as underscores - `TF_TOKEN_mycorp_example_com`. A hyphen in the
   hostname has no valid spelling in an environment variable name, so a double underscore stands in for it
   (`my-registry.example.com` → `TF_TOKEN_my__registry_example_com`).
2. **Terraform's JSON credentials file**, at `~/.terraform.d/credentials.tfrc.json`, or at `$TF_CLI_CONFIG_FILE`
   when that points at a `.json` file:

   ```json
   {
     "credentials": {
       "mycorp.example.com": { "token": "..." }
     }
   }
   ```

   The HCL `.tfrc` format is not read, as Starlark cannot parse HCL. Use the JSON form or an environment
   variable.

The credentials file is read without registering a Bazel watch, so rotating a token does not by itself
invalidate the mirror. The `TF_TOKEN_*` and `TF_CLI_CONFIG_FILE` variables are read through `ctx.getenv`, so
changing them does re-trigger a fetch.

### Where the token is sent

The token is attached to requests against the registry's own API only: service discovery and the provider
download-metadata endpoint.

Registries respond with a package URL that may point somewhere else entirely - the public registries hand back
`releases.hashicorp.com` or `github.com`. When the package host differs from the registry host, that download is
made unauthenticated, so the credential is never forwarded to a third party. A private registry that serves
packages from its own host does receive the token.

### Credentials when locking hashes

The `tf_providers_lock` target shells out to `terraform providers lock`, so that step authenticates the way
terraform does rather than the way the extension above does. The overlap covers the usual setup - `TF_TOKEN_<host>`
and `~/.terraform.d/credentials.tfrc.json` are read by both - but terraform additionally accepts the HCL `.tfrc`
credentials format and a `credentials_helper`, neither of which the extension can use. A token that only
terraform can find will lock hashes for a mirror the extension then cannot fetch.

See [mirror.md](mirror.md#verified-hashes) for what the target does with them.
