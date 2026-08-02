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
    },
    "verified/registry.terraform.io/hashicorp/random/3.1.3": {
      "zh": ["bcf7806b...", "..."]
    }
  }
}
```

A `resolve/` fact answers "which version does this constraint select"; a `package/` fact answers "where does
this version live and what does it hash to". Together they are everything the extension would otherwise ask the
registry, which is why it declares `reproducible = True`: a second evaluation defines exactly the same
repositories with no network access at all. Since packages are content-addressed by sha256, a warm
`--repository_cache` then serves the whole mirror offline.

A `verified/` fact answers "which hashes for this version survived a signature check", and is written by the
`tf_providers_lock` target rather than by resolution - see [verified hashes](#verified-hashes) below.

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

Coordinates are recorded for every platform a toolchain can run on - `linux_amd64`, `linux_arm64`,
`darwin_amd64`, `darwin_arm64` - not only for the host. One build therefore writes a lockfile that serves every
machine on the team, which is the property terraform gets from a multi-platform `.terraform.lock.hcl`.

Only the host's package is downloaded. The others cost one small metadata request each, issued together with the
host's, so covering four platforms is not four times the work. A platform a given provider does not publish is
simply left unrecorded rather than failing the build.

This matters more than it first appears: were only the host resolved, the next machine to build would append its
own platform's facts, and a repository that gates CI on a clean working tree would fail on the resulting
`MODULE.bazel.lock` diff.

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
`.terraform.lock.hcl` as `zh:` entries - and a `zh:` value is exactly the sha256 of a release zip. Check every
package against those hashes and the hash it is admitted on traces back to a signature, not to the registry's
word.

There are two ways to supply them.

### Recorded in the lockfile (recommended)

`tf_providers_lock` runs the lock command over the resolved manifest and merges what it verified into the same
`MODULE.bazel.lock` that already holds the coordinates, as `verified/` facts. There is then no second file to
keep in step with the manifest:

```python
load("@rules_tf//tf:def.bzl", "tf_providers_lock")

tf_providers_lock(name = "providers_lock")
```

```sh
bazel run //:providers_lock       # re-run whenever the manifest changes, and commit the diff
bazel run //:providers_lock -- --check   # CI gate: fails if the recorded hashes are not current
```

The target takes the manifest from the resolved toolchain, so a constraint is locked against the version the
extension actually selected. It needs network access, and the registry credentials described in
[registries.md](registries.md); it runs the lock command once per version set, since a dependency lock holds one
version per provider. Under a tofu toolchain it runs `tofu providers lock` against `registry.opentofu.org`, which
is not interchangeable with the terraform one - see below.

Set `provider_locks_strict = True` to require that every mirror entry is covered:

```python
tf.download(
    version = "1.9.5",
    mirror = ["hashicorp/random:3.3.2"],
    provider_locks_strict = True,
)
```

Two consequences of the hashes living in the lockfile are worth knowing:

- **A newly resolved package is verified as it is resolved**, which is the case that matters, but *editing* the
  recorded hashes does not by itself re-trigger the check: facts are not an input Bazel invalidates the
  extension on. A cold resolution - a fresh checkout, or CI - always verifies.
- **Bootstrapping is ordered.** With `provider_locks_strict = True` and no hashes recorded yet, the extension
  fails before the target can run. Record the hashes first, then turn on strict. The same applies to recovering
  from a genuine mismatch: delete the offending `verified/` fact, re-run the target, and compare what it writes.

### From a lock file you already have

`provider_locks` reads `zh:` hashes out of `.terraform.lock.hcl` files directly, which suits a repository that
already generates one for its own terraform workflow:

```sh
terraform providers lock
```

```python
tf.download(
    version = "1.9.5",
    mirror = ["hashicorp/random:3.3.2"],
    provider_locks = ["//terraform:providers.lock.hcl"],
    provider_locks_strict = True,
)
```

A lock file records one version per provider, while a mirror may stock several, so `provider_locks` takes a
list - one file per version set. Hashes from files and from facts are merged, so the two can be combined.

### What the check establishes

Generate hashes with the same tool the toolchain uses: `tofu providers lock` under `use_tofu = True`,
`terraform providers lock` otherwise. The two are not interchangeable. `registry.opentofu.org` serves packages
that OpenTofu has repackaged and re-signed under its own key, so for a given provider version the `zh:` hashes
recorded against `registry.opentofu.org/...` are disjoint from those recorded against `registry.terraform.io/...`
- a lock generated by the other tool covers nothing the mirror fetched, and under
`provider_locks_strict = True` that is an error rather than a silent pass.

Entries with no verified hash are reported: a warning by default, since partial coverage is expected of a mirror
locked by hand, or an error under `provider_locks_strict = True`.

`zh:` hashes cover every platform's package, and the lock does not say which hash belongs to which platform - a
single signed `SHA256SUMS` document is where they all come from, which is also why one run of the lock command
covers every platform. The check is therefore membership in that set: a package is admitted if it is *a* signed
release of that provider version. An attacker controlling the registry could still redirect one platform's URL to
another platform's (genuinely signed) package - a broken build, not an avenue for unsigned code.

## What is mirrored

Only the host platform's packages are fetched, matching the host-scoped toolchain repository - coordinates are
recorded for all four, as [above](#multiple-platforms). Providers are stored unpacked,
in the layout `mirror/<host>/<namespace>/<type>/<version>/<os>_<arch>/`, which lets downstream `init` symlink a
plugin into each module's `.terraform/providers/` rather than extracting a fresh copy per target.

The same source may appear at several versions; each is fetched independently, so they coexist in the mirror.
Modules then select whichever version they require through their own `required_providers` block.
