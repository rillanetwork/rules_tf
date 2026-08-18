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

**Plugin protocol versions play no part in selection.** The registry advertises which plugin protocols each
version speaks, and a constraint could in principle skip a version the toolchain's terraform cannot talk to.
Terraform itself deliberately selects on the constraint alone and fails with an explicit error rather than
silently choosing an older version (compatibility changes are supposed to arrive as major versions), and the
mirror matches that. For a version the extension locks itself (`"auto"`, on a fact miss no supplied lock file
answers), the incompatibility surfaces at resolution time: `providers lock` runs under the same terraform
release the toolchain uses and performs terraform's own protocol check. On every other path nothing speaks the
plugin protocol until the provider is first exercised - a lock file generated elsewhere carries no protocol
information, and neither does the mirror layout `init` reads.

Two entries that resolve to the same version collapse into one, so overlapping constraints are harmless.

## Where the resolved mirror is recorded

Resolution happens in the module extension, not in the download repository, so its results are visible to
bzlmod and land in `MODULE.bazel.lock` - there is no second lock file to maintain.

The record is the `facts` section, and it is worth reviewing in a diff. The extension is reproducible, which
keeps it out of `moduleExtensions` altogether, so the resolved coordinates it hands the download repository as
attributes are not written to the lockfile - the facts those attributes were derived from are.

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

A `package/` fact also carries `verified`, which answers "was this sha256 matched against a hash a publisher
signed" - see [verified hashes](#verified-hashes) below.

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

### When the registry cannot be reached

Resolution runs during module extension evaluation, which bzlmod performs for every build in the workspace, not
only for builds that touch terraform. A registry failure is therefore recorded rather than raised: the entries
that could not be resolved are passed to the download repository, which fails on them when a target actually
needs the mirror. A workspace that cannot reach its registry still builds everything else, and a lint-only
workspace - which needs no mirror at all - is unaffected.

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

Starlark cannot verify a GPG signature, so the extension imports the check instead. `terraform providers lock`
performs the full signature verification and writes the resulting package hashes into `.terraform.lock.hcl` as
`zh:` entries - and a `zh:` value is exactly the sha256 of a release zip. Check every package against those
hashes and the hash it is admitted on traces back to a signature, not to the registry's word.

### How it runs

The extension does this itself, as it resolves. A version whose recorded coordinates are not yet marked verified
sends the extension to fetch the tf binary for the host, run `providers lock` over that one version, and check
every platform's resolved sha256 against the `zh:` set that produces. The mark goes into the same `package/`
facts that hold the coordinates, so the next evaluation reads a pin that is already signature-backed and reaches
neither the registry nor the tool:

```python
tf.download(
    version = "1.9.5",
    mirror = ["hashicorp/random:3.3.2"],
)
```

Nothing else is needed - `provider_verification` defaults to `"auto"`, which is that behaviour. The lock runs
once per version, needs network access and the registry credentials described in
[registries.md](registries.md), and is then answered from `MODULE.bazel.lock` until the manifest changes. Under a
tofu toolchain it runs `tofu providers lock` against `registry.opentofu.org`.

Two consequences follow from where the result is kept:

- **Editing a recorded hash does not re-trigger the check**: facts are not an input Bazel invalidates the
  extension on. A cold resolution - a fresh checkout, or CI - always verifies what it resolves.
- **Recovering from a mismatch means discarding the record.** Delete the offending `package/` facts, resolve
  again, and compare what the extension writes back.

Editing the manifest therefore needs the registry reachable, which is what makes the lockfile diff the reviewable
artefact: a mirror entry and the signed hash admitting it land in the same commit.

### From a lock file you already have

`provider_locks` reads `zh:` hashes out of `.terraform.lock.hcl` files, which suits a repository that already
generates one for its own terraform workflow. Set `provider_verification = "files"` to check against those alone,
and run no lock command:

```sh
terraform providers lock
```

```python
tf.download(
    version = "1.9.5",
    mirror = ["hashicorp/random:3.3.2"],
    provider_locks = ["//terraform:providers.lock.hcl"],
    provider_verification = "files",
)
```

A lock file records one version per provider, while a mirror may stock several, so `provider_locks` takes a
list - one file per version. Under `"auto"` the files are consulted first and only what they leave uncovered is
locked, so the two can be combined.

Where `"auto"` treats a verified mark in `MODULE.bazel.lock` as settled, `"files"` trusts no recorded mark:
every mirrored package is checked against the supplied files on every evaluation, whatever earlier evaluations
verified or under which mode. The mode is a standing assertion that the committed lock files cover the whole
mirror. The files are read (and therefore watched) each time, so editing one re-triggers evaluation, and a
tampered hash in `MODULE.bazel.lock` is caught at the next evaluation rather than only on a cold resolution.

### What the check establishes

Lock files must come from the same tool the toolchain uses: `tofu providers lock` under `use_tofu = True`,
`terraform providers lock` otherwise. The two are not interchangeable. `registry.opentofu.org` serves packages
that OpenTofu has repackaged and re-signed under its own key, so for a given provider version the `zh:` hashes
recorded against `registry.opentofu.org/...` are disjoint from those recorded against `registry.terraform.io/...`
- a lock generated by the other tool covers nothing the mirror fetched, which is an error rather than a silent
pass.

An entry no hash covers fails the build. `provider_verification = "off"` turns that into a warning and admits the
package on the registry's word, which is what a registry publishing no signatures leaves available. The mode
makes no coverage assertion, so unlike `"files"` it treats a verified mark the way `"auto"` does: a package that
was signature-checked earlier, or that matches a supplied `provider_locks` file now, is admitted silently, and
the warning names only what was never checked against anything. A mismatch against a hash set that does cover a
package still fails, even here.

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

### How the mirror reaches a rule

The toolchain publishes the mirror as the individual files under it - a `mirror_files` filegroup - and never as
the `mirror` directory itself. A source directory is a single opaque artifact that Bazel does not expand, so
nothing in the build ever asks for the bytes inside it. That stays invisible until a repository declaring
`reproducible = True` is restored from the repo contents cache rather than fetched: Bazel then materialises only
what was actually demanded, the directory is not among it, and the `init` that reads the mirror by path at
runtime finds an empty search location. Tracked files have somewhere concrete to come from, whether they arrive
by lazy materialisation, remote execution or runfiles staging.

A path is still what `-plugin-dir` needs, and no single file names the directory those files share, so
`TfInfo.mirror_path` derives one from `mirror_versions.json`, which the download repository writes beside
`mirror/`. It is runfiles-relative, because the scripts that consume it run from the runfiles root.

A mirror holding no providers stages no `mirror/` directory at all. `TfInfo.mirror_path` is then the empty
string and the rules leave `-plugin-dir` off, rather than hand `init` a search location that does not exist.

## The generated `.terraform.lock.hcl`

A module initialised against an unpacked mirror has no lock file to read, so terraform hashes the packages it
finds, writes down what it computed, and warns that the result covers only the platform it ran on:

```
Warning: Incomplete lock file information for providers
...
The current .terraform.lock.hcl file only includes checksums for linux_amd64
```

None of that is news here. The extension resolved a package sha256 for every platform before a byte was fetched,
checked it against the signature-derived hashes, and Bazel fetched each package against the one for the host. So
each module's rundir is given a `.terraform.lock.hcl` written from those hashes, and the warning goes with it.

The document is a record rather than a constraint. Terraform can only verify a `zh:` hash against a zip, and a
mirror hands it an extracted directory, so it takes the entries as given - the check that matters ran in the
extension, as [above](#verified-hashes). It does append the `h1:` hash it computes for the running platform,
which is why the file is copied into the rundir rather than symlinked from the build output.

Every platform's hash goes into each block, since `hashes` is a set terraform matches the installed package
against: the members covering other platforms are what let one document serve every machine.

### Choosing the version

The one field that is not set-shaped is `version`: a lock file holds one per provider address. Two blocks for
one address is a hard `Duplicate provider lock` error, and a version a module's constraints exclude fails `init`
outright, so a source the mirror stocks at several versions has to be chosen between.

That choice comes from the `providers` a module and its dependencies declare - the same declarations
`versions.tf.json` is generated from - ANDed together the way terraform ANDs them across a configuration. A
source the mirror stocks once needs no declaration and is always named. A source stocked several times over,
whose declared constraints select none of them, is left out of the document entirely, so terraform reports the
conflict against the whole configuration rather than against a version this picked for it.

Providers a module does not use are harmless: `init` prunes them from the file it rewrites.
