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

## Pins versus constraints

A constraint is convenient but lets the mirror's contents drift with no change to the manifest: the same commit
can produce a different mirror tomorrow, which is a reproducibility hazard and invalidates Bazel's repository
cache when it happens.

The resolved set is therefore recorded, so drift is at least observable. After a fetch the toolchain repository
contains:

- `mirror_versions.json` - the resolved `source@version` list as JSON.
- `mirror_versions.bzl` - the same list as `MIRROR_VERSIONS`, which is what the toolchain publishes as
  `TfInfo.mirror_versions` for rules to consume.

Both are written *after* resolution, so they name the concrete versions the mirror actually holds - never the
constraint that was written in `MODULE.bazel`.

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
