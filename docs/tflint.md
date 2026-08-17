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
      "sha256": "..."
    },
    "tflint_plugin/github.com/terraform-linters/tflint-ruleset-aws/0.48.0/linux_amd64": {
      "sha256": "..."
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

A ruleset is pinned by a hash read from its release's `checksums.txt`. That is the release host's word, not a
publisher's signature, which makes it weaker than the provider mirror's
[verified hashes](mirror.md#verified-hashes) and weaker than the signature check `tflint --init` makes against a
config's `signing_key`. Closing that gap is tracked in `TODO.md`.

In the meantime a compromised release would be caught only after the fact: once a hash is recorded, a later fetch
of different bytes fails, so the exposure is to the first resolution rather than to every build. Reviewing the
`tflint_plugin/` facts in a lockfile diff is worth the same attention as reviewing the `package/` ones.
