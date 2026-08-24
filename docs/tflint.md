# tflint

Every `tf_module` declares a `lint` test that runs tflint over the module's sources:

```sh
bazel test //tf/modules/mod-a:lint
```

It needs no `terraform init` and no provider mirror - only the tflint toolchain, whose version comes from
`tflint_version` on the `tf.download` tag.

## Configuring tflint

tflint takes its behaviour from an HCL config. rules_tf ships
[a default one](../tf/toolchains/tflint/config.hcl) that reports in `compact` format and enables most of the
built-in terraform ruleset: documented variables and outputs, a standard module structure, pinned provider and
terraform versions.

Replace it for the whole workspace with `tflint_config` on the `tf.download` tag:

```python
tf.download(
    version = "1.9.5",
    tflint_config = "//terraform:tflint.hcl",
    mirror = [...],
)
```

Or for one module, with `tflint_config` on `tf_module`:

```python
tf_module(
    name = "mod-a",
    providers = {
        "random": "hashicorp/random:3.3.2",
    },
    tf_version = ">= 1.9",
    tflint_config = "my-tflint-config.hcl",
)
```

Neither merges: the config replaces the one it overrides outright, so write yours as a copy of that one.

`tflint_extra_args` on `tf_module` passes further flags to tflint:

```python
tf_module(
    name = "mod-a",
    providers = {
        "random": "hashicorp/random:3.3.2",
    },
    tf_version = ">= 1.9",
    tflint_extra_args = ["--minimum-failure-severity=error"],
)
```

## Rulesets

Most of tflint's rules live in ruleset plugins, which tflint normally downloads the first time they are needed.
rules_tf mirrors them instead, alongside the providers, from the `plugin` blocks in the toolchain-wide config:

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

A block naming no `source` is built into the tflint binary and downloads nothing. Anything with a `source` needs a
`version`, and the source must be a `github.com/<owner>/<repo>` repository.

Only the toolchain-wide config is read for this, so a per-module config cannot introduce a ruleset of its own. It
can use one the toolchain config mirrored, by declaring the same `plugin` block.

Each ruleset's sha256 is resolved for every platform and recorded in `MODULE.bazel.lock` as extension facts, so a
lockfile written on one machine covers the rest of the team and CI, and later builds reach no release API. It is
the same mechanism as [the provider mirror's](mirror.md#where-the-resolved-mirror-is-recorded).

## Signing keys

A ruleset is only mirrored if tflint can verify the release's signature. That holds for rulesets under
`terraform-linters`, which tflint checks against its own key, and for anyone else's if the plugin block carries the
publisher's key:

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

Without one the build fails, naming the block. Where the publisher's key is unavailable,
`tflint_plugin_verification = "off"` accepts a ruleset unverified, warning about each:

```python
tf.download(
    version = "1.9.5",
    tflint_config = "//terraform:tflint.hcl",
    tflint_plugin_verification = "off",
    mirror = [...],
)
```

The hash is still pinned, so only the first resolution is taken on trust: a later fetch of different bytes fails.
Rulesets already verified stay verified.

## Running tflint yourself

`@tf_toolchains//:tflint` is the tflint binary the toolchain downloaded, which an alias makes runnable:

```python
alias(
    name = "tflint",
    actual = "@tf_toolchains//:tflint",
)
```

`bazel run //:tflint` uses the same version the lint tests do. It is the bare binary, without the toolchain's
config or its mirrored rulesets.
