# The module mirror

Terraform installs remote modules on every `init`. There is no lock file for them, no shared cache between
working directories, and no dedupe: a module reached by two call paths is downloaded twice, and re-downloaded
the next time `.terraform` is cleared. The module mirror moves that work into Bazel, so a remote module is
resolved once, recorded in `MODULE.bazel.lock`, fetched once, and shared.

It is the module-side analogue of [the provider mirror](mirror.md), and it works the same way: coordinates are
resolved in the module extension, and the repositories that fetch them receive concrete pins.

## Declaring modules

```python
tf = use_extension("@rules_tf//tf:extensions.bzl", "tf_repositories")
tf.download(
    version = "1.9.5",
    modules = [
        "cloudposse/vpc/aws@2.1.1",
        "terraform-aws-modules/iam/aws//modules/iam-policy@~> 5.0",
        "git::https://github.com/terraform-aws-modules/terraform-aws-security-group.git?ref=v5.1.0",
    ],
)
```

As with the provider mirror, the list can live in a file instead:

```python
tf.download(
    version = "1.9.5",
    modules_json = "//terraform:modules.json",
)
```

## Source syntax

A **registry** module is written `<address>@<version>`, where the version is any constraint terraform accepts
(`2.1.1`, `~> 5.0`, `>= 5.0, < 6.0`). The address is the usual two or three parts, optionally prefixed with a
registry host, and may carry a `//subdir`:

```
cloudposse/vpc/aws@2.1.1
app.terraform.io/acme/vpc/aws@1.0.0
terraform-aws-modules/iam/aws//modules/iam-policy@~> 5.0
```

**Every other source is written verbatim**, with no `@version` suffix - a getter source carries its own ref,
and terraform rejects a `version` argument beside one:

```
git::https://github.com/acme/mod.git?ref=v1.2.0
git@github.com:acme/mod.git
s3::https://bucket.s3.amazonaws.com/mod.zip
github.com/acme/mod?ref=v1.2.0
```

Note that `github.com/...` and `bitbucket.org/...` are *not* registry addresses despite their shape: terraform's
getter detectors claim those hosts first, so they are git sources and take no version.

## How resolution works

Terraform itself does the resolving. Its source grammar spans the registry, several VCS shorthands, plain HTTP
and a handful of object stores, each with its own scheme detection, subdirectory handling and credentials;
re-implementing that in Starlark would be a standing fidelity gap. So the extension writes a synthetic root
module naming every declared entry, runs `terraform get`, and reads the closure terraform installed out of
`.terraform/modules/modules.json`.

That run happens in the **module extension**, not in the repository that fetches the modules. The answers -
each declared module's full transitive closure, and each package's download URL and hash - are recorded as
extension facts in `MODULE.bazel.lock`. A later evaluation with those facts answers from the lock file and
reaches no source at all.

The whole closure is recorded, not just the declared entry, because terraform keys nested modules by call path
and resolves them transitively. Recording the closure is what lets a manifest be rebuilt later without
re-running the tool.

## The store

Each distinct package gets its own repository, and `@tf_modules//:store` gathers them. Packages are keyed by
source and version **without** any `//subdir`, so two entries reaching different directories of one repository
share a single download.

This dedupes where terraform does not. A module reached by two call paths - very common, since community
modules often call a shared label module from several places - appears once in the store.

## Reproducibility

Each package repository reports its own verdict, because the two fetch paths make genuinely different promises:

- A package that reduces to **a single archive** is fetched against a `sha256` the extension resolved, so its
  contents are a function of its attributes alone. It reports `reproducible = True`.
- A package whose source only terraform can reach runs the tool in the repository. Terraform's output is not
  byte-stable (the same module at the same version has been observed to differ by whether it retained a `.git`
  directory), so it reports `reproducible = False`.

Both are eligible for the repo contents cache; `reproducible = False` does not by itself force a re-fetch when
the recorded inputs still match. What the pinned path buys is verification: the bytes are checked against a
recorded hash, so drift is detected.

## Checksums

Unlike a provider, a module has no publisher-signed checksum document - the module registry publishes none at
all. The `sha256` recorded for a package is therefore **observed on first fetch and pinned thereafter**. It
detects later drift; it does not attest the bytes a publisher signed. There is no module equivalent of the
provider mirror's [verified hashes](mirror.md#verified-hashes), and there cannot be until registries publish
signatures.

## How a module reaches the store

Terraform records installed modules in `.terraform/modules/modules.json`, keyed by *call path*: the chain of
names the `module` blocks were given. `validate` and `init` write that file before running terraform, so the
remote modules are already installed as far as terraform is concerned.

Call paths come from the configuration, since nothing else knows them - a Bazel dependency is a label, and the
same module may be called twice under two different names. Each `tf_module` therefore reads its own sources
with `terraform-docs` (already a toolchain here) and follows local calls into their directories, composing
keys like `amodule.sg` for a remote module called from inside a local one. Nested modules of a *remote* module
come from the closure the extension recorded, so they need no parsing at all.

A call is matched back to a mirrored entry by source. The version need not be spelled the same way in both
places: pinning `cloudposse/vpc/aws@2.1.1` in `MODULE.bazel` while a module asks for `~> 2.1` is the ordinary
case, and terraform still checks that what it finds satisfies the constraint. Mirroring several versions of one
source is refused rather than guessed at, since nothing here can choose between them.

## Unmirrored modules fail the build

A module calling a remote source the mirror does not hold fails, naming the source and pointing at
`MODULE.bazel`:

```
module_manifest: no mirrored module matches "cloudposse/vpc/aws" version "~> 2.1".
  Add it to the tf.download modules list in MODULE.bazel.
```

This happens whether or not a network is reachable. Bazel does not sandbox tests away from the network, so
without the check an undeclared module would simply be downloaded at `init` and nobody would notice the mirror
had been bypassed.

The one gap: a *generated* `.tf` file is not scanned, because generated files live under `bazel-out` rather than
beside the module's sources. Nothing in this ruleset generates module calls today - `versions.tf.json` holds
providers - but a module call written by another rule would go unseen.
