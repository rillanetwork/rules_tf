# tflint rulesets

Plugins are an important part of tflint's design, and have most of the rules. They're usually downloaded when they're
first needed. When using rules_tf, you can declare the tflint rulesets you want to use in the toolchain, and the module 
extension will mirror them alongside the providers.

For the per-module `tflint_config` attribute on the lint rules themselves, see the [README](../README.md#using-tf-rules)

## Declaring a ruleset

`tflint_config` on the `tf.download` tag sets the toolchain-wide tflint config, and the ruleset plugins that config
declares are mirrored alongside the providers:

```python
tf.download(
    version = "1.9.5",
    tflint_config = "//terraform:tflint.hcl",
    mirror = [...],
)
```

```hcl
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.48.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
```

A `plugin` block naming no `source` is bundled into the tflint binary and downloads nothing, which is what
`plugin "terraform"` above is. For anything carrying a `source`:

- A `version` is mandatory. Without one there is no release to pin.
- The source must be a `github.com/<owner>/<repo>` repository, which is the only form tflint publishes releases
  under.
- `enabled = false` still mirrors the ruleset. That matches `tflint --init`, and it means toggling a rule set on
  later needs no re-fetch.

Both requirements are enforced when the config is read, with a message naming the offending block.

## Per-module overrides are invisible here

Individual modules may override the config with their own `tflint_config` attribute on the lint rule. Those
overrides are not seen by the module extension: only the toolchain-wide config above decides which rulesets are
downloaded. A module-level config that enables a ruleset the toolchain config never declared will fail at lint
time, because the plugin was never mirrored.

## Where the resolved rulesets are recorded

A declared ruleset is pinned the way a provider package is. The module extension reads the release's
`checksums.txt`, resolves a sha256 for every platform the toolchain runs on, and records them as extension facts in
`MODULE.bazel.lock`:

```json
"facts": {
  "@@rules_tf+//tf:extensions.bzl%tf_repositories": {
    "tflint_plugin/github.com/terraform-linters/tflint-ruleset-aws/0.48.0/darwin_arm64": {
      "sha256": "...",
      "verified": true
    },
    "tflint_plugin/github.com/terraform-linters/tflint-ruleset-aws/0.48.0/linux_amd64": {
      "sha256": "...",
      "verified": true
    }
  }
}
```

Every platform is resolved from the one checksum document, so a lockfile written on one machine covers the rest of
a team and CI - the same reason the provider mirror resolves them all. See
[mirror.md](mirror.md#where-the-resolved-mirror-is-recorded) for how that record behaves, since it is the same
mechanism.

The toolchain then fetches the archive against the host's hash and unpacks it where tflint looks a plugin up, so
the download repository reaches no release API and can declare itself reproducible: a cold output base links it
from the repo contents cache instead of fetching it again.

## What the pin is worth

`verified` above says the sha256 next to it was read from a `checksums.txt` whose PGP signature tflint
checked. That is the same standing the provider mirror's [verified hashes](mirror.md#verified-hashes) have, and
it is what `tflint --init` gave before the rulesets were pinned: the key built into tflint for
`terraform-linters` rulesets, or the `signing_key` the plugin block carries for anyone else's.

Making the check is the module extension's job, and it happens once, when a ruleset's facts are first minted.
`--init` is run over the toolchain-wide config as written, which is what puts a `signing_key` in front of
tflint. Exiting 0 is not taken as an answer on its own: `--init` verifies a copy of the document it fetched
itself, so what ties that to the recorded hashes is the binary. The archive the recorded hash pins is fetched
and unpacked, and it must hold the same binary `--init` installed; the recorded hashes are then checked against
the signed document, every platform's and not just the host's. A hash the document contradicts fails the build
rather than being quietly replaced.

Thereafter the recorded mark answers the question, so a second evaluation runs no tflint and reaches no release.
A lockfile written before this check existed carries no marks, and verifies once before settling.

## Rulesets tflint cannot check

tflint verifies against its own key only for rulesets under `terraform-linters`. Anyone else's needs a
`signing_key` in the plugin block:

```hcl
plugin "custom" {
  enabled = true
  version = "1.2.3"
  source  = "github.com/acme/tflint-ruleset-custom"

  signing_key = <<-KEY
  -----BEGIN PGP PUBLIC KEY BLOCK-----
  ...
  -----END PGP PUBLIC KEY BLOCK-----
  KEY
}
```

Without one, `tflint --init` installs the ruleset with a warning and still exits 0, so a build that treated that
as verification would be recording a signature check nobody made. Such a ruleset fails instead, naming the
block. Where the publisher's key genuinely is not to be had, `tflint_plugin_verification = "off"` on the
`tf.download` tag admits rulesets on the release host's word and warns about each:

```python
tf.download(
    version = "1.9.5",
    tflint_config = "//terraform:tflint.hcl",
    tflint_plugin_verification = "off",
    mirror = [...],
)
```

That leaves the pin worth what it was worth before: a compromised release is caught only after the fact, since
once a hash is recorded a later fetch of different bytes fails. The exposure is to the first resolution rather
than to every build, and reviewing the `tflint_plugin/` facts in a lockfile diff is worth the same attention as
reviewing the `package/` ones.

Rulesets a recorded mark already covers are unaffected by the setting: `off` narrows what must be checked, and
never unmarks anything.

## Failures are deferred

A ruleset that cannot be resolved or cannot be verified fails the targets that lint, not the whole workspace.
Extension evaluation is not lazy, so failing at resolution time would break every build in a repository,
including ones that touch no terraform. The messages are carried into the tflint download repository instead and
raised there, which is the first point a build has actually asked for tflint.
