# The provider mirror

The toolchain pre-fetches a set of providers into an offline filesystem mirror, which downstream
`terraform init -plugin-dir=<mirror>` then resolves against without touching the network. This page covers the
version syntax of the mirror manifest and how the resolved contents are published.

For the `mirror` / `mirror_json` attributes themselves see the [README](../README.md#getting-started); for
non-default and authenticated registries see [registries.md](registries.md).

## Version syntax

Each manifest entry is `[hostname/]namespace/type:version`, where `version` is either an exact pin or a
constraint.

### Exact pins

```
hashicorp/random:3.6.0
hashicorp/aws:6.0.0-beta1
```

Full semver, so a `-prerelease` and `+build` suffix are both accepted. Pinning is the recommended form: the
mirror's contents are then a pure function of the manifest, so they cannot change without a change to the code.

### Constraints

```
hashicorp/tls:>= 4.0.0, < 4.0.5
hashicorp/random:~> 3.1.0
```

Terraform's operators are supported - `=`, `!=`, `>`, `>=`, `<`, `<=` and `~>` - with commas meaning AND. A bare
version means `=`. Each constraint is resolved against the registry's published version list, and the **highest**
satisfying version is mirrored.

`~>` pins every component to the left of the rightmost one written and lets that one increment, exactly as
terraform defines it. Note that this makes the two- and three-component forms behave differently:

| Constraint  | Resolves within    |
|-------------|--------------------|
| `~> 3.1.0`  | `>= 3.1.0, < 3.2.0` |
| `~> 3.1`    | `>= 3.1.0, < 4.0.0` |

**Prereleases are never selected by a constraint.** `~> 3.0` will not pick `3.7.0-alpha1`. This matches
terraform, and means a prerelease can only reach the mirror through an exact pin.

Two entries that resolve to the same version collapse into one, so overlapping constraints are harmless.

## Where the resolved mirror is recorded

Resolution happens in the module extension, not in the download repository, so its results are visible to
bzlmod and land in `MODULE.bazel.lock` - there is no second lock file to maintain.

Two things are recorded there, and both are worth reviewing in a diff.

**The concrete coordinates**, as attributes of the generated download repository:

```json
"attributes": {
  "version": "1.9.5", "os": "linux", "arch": "amd64",
  "providers_json": "[{\"source\":\"hashicorp/random\",\"version\":\"3.1.3\", ...}]"
}
```

**The registry's answers**, as extension facts:

```json
"facts": {
  "@@rules_tf+//tf:extensions.bzl%tf_repositories": {
    "resolve/registry.terraform.io/hashicorp/random/~> 3.1.0": {"version": "3.1.3"},
    "package/registry.terraform.io/hashicorp/random/3.1.3/linux_amd64": {
      "download_url": "https://releases.hashicorp.com/...linux_amd64.zip",
      "sha256": "bcf7806b..."
    }
  }
}
```

A `resolve/` fact answers "which version does this constraint select"; a `package/` fact answers "where does
this version live and what does it hash to". Together they are everything the extension would otherwise ask the
registry, which is why it declares `reproducible = True`: a second evaluation defines exactly the same
repositories with no network access at all. Since packages are content-addressed by sha256, a warm
`--repository_cache` then serves the whole mirror offline.

The toolchain repository also writes `mirror_versions.json`, the resolved `source@version` list, which is what
it publishes as `TfInfo.mirror_versions` for rules to consume.

### Pins versus constraints

A constraint would otherwise let the mirror drift with no change to the manifest: the same commit could produce
a different mirror tomorrow. The `resolve/` fact prevents that - once a constraint has selected a version, that
selection is held by the lockfile and reused.

Refresh deliberately:

```sh
bazel mod deps --lockfile_mode=refresh
```

Pinning is still the clearer form, since the manifest then says outright what the mirror holds.

### Multiple platforms

Only the host platform is resolved on any given run, but coordinates already recorded for the other platforms
are carried through untouched. Building on each host in turn therefore accumulates one lockfile covering them
all - the property terraform gets from a multi-platform `.terraform.lock.hcl`.

### Enforcement

Under the default `--lockfile_mode=update` Bazel will re-resolve and rewrite the lockfile when the manifest
changes. To make an unexpected change an error rather than a silent update, build with:

```sh
bazel test --lockfile_mode=error //...
```

### What this does and does not protect

Recording the sha256 closes the window in which a registry could report a different checksum for a version you
already built against. It does not establish that the checksum was ever the *right* one - for that, see verified
hashes below.

## Verified hashes

The mirror is built by talking to the registry API directly, so by default a package's sha256 is whatever the
registry says it is. `terraform init` did better: it verified the registry's `SHA256SUMS` signature against
public keys **compiled into the terraform binary** ("HashiCorp Security" and "HashiCorp Security (Terraform
Partner Signing)"), a trust root that does not depend on the registry's answer. Losing that matters for
`hashicorp/*` and partner providers, where an attacker who could forge TLS to the registry, or compromise it,
could otherwise substitute a package unnoticed.

Starlark cannot verify a GPG signature, so that check cannot be reproduced here. It can, however, be *imported*.
`terraform providers lock` performs the full signature verification and writes the resulting package hashes into
`.terraform.lock.hcl` as `zh:` entries - and a `zh:` value is exactly the sha256 of a release zip. Point
`provider_locks` at such a file and every package hash is checked against it before a byte is fetched:

```sh
terraform providers lock -platform=linux_amd64 -platform=darwin_arm64
```

```python
tf.download(
    version = "1.9.5",
    mirror = ["hashicorp/random:3.3.2"],
    provider_locks = ["//terraform:providers.lock.hcl"],
    provider_locks_strict = True,
)
```

The hash a package is admitted on then traces back to a signature check, not to the registry's word.

Generate the lock with the same tool the toolchain uses: `tofu providers lock` under `use_tofu = True`,
`terraform providers lock` otherwise. The two are not interchangeable. `registry.opentofu.org` serves packages
that OpenTofu has repackaged and re-signed under its own key, so for a given provider version the `zh:` hashes
recorded against `registry.opentofu.org/...` are disjoint from those recorded against `registry.terraform.io/...`
- a lock generated by the other tool covers nothing the mirror fetched, and under
`provider_locks_strict = True` that is an error rather than a silent pass.

A lock file records one version per provider, while a mirror may stock several, so `provider_locks` takes a
list - generate one file per version set. Entries with no matching `source@version` are reported: a warning by
default, since partial coverage is expected of a multi-version mirror, or an error under
`provider_locks_strict = True`.

`zh:` hashes cover every platform's package, and the lock does not say which hash belongs to which platform. The
check is therefore membership in that set: a package is admitted if it is *a* signed release of that provider
version. An attacker controlling the registry could still redirect one platform's URL to another platform's
(genuinely signed) package - a broken build, not an avenue for unsigned code.

## What is mirrored

Only the host platform is fetched, matching the host-scoped toolchain repository. Providers are stored unpacked,
in the layout `mirror/<host>/<namespace>/<type>/<version>/<os>_<arch>/`, which lets downstream `init` symlink a
plugin into each module's `.terraform/providers/` rather than extracting a fresh copy per target.

The same source may appear at several versions; each is fetched independently, so they coexist in the mirror.
Modules then select whichever version they require through their own `required_providers` block.
