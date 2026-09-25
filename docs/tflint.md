# tflint

Every `tf_module` declares a `lint` test that runs tflint over the module's sources:

```sh
bazel test //tf/modules/mod-a:lint
```

It needs no `terraform init` and no provider mirror - only the tflint toolchain, whose version comes from
`tflint_version` on the `tf.download` tag.

## Configuring tflint

tflint takes its behaviour from an HCL config. 
rules_tf ships [a default one](../tf/toolchains/tflint/config.hcl) that reports in `compact` format 
and enables most of the built-in terraform ruleset.
You can replace it with `tflint_config` on the `tf.download` tag or `tf_module` declaration:

```python
tf.download(
    version = "1.9.5",
    tflint_config = "//terraform:tflint.hcl",
    mirror = [...],
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

Each ruleset's sha256 is resolved for every platform and recorded in `MODULE.bazel.lock` as extension facts.

## Release Signatures

If you include a signing key in the plugin block, the ruleset will verify any mirrored plugins against the release's 
signature, and fail if it doesn't validate:
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

If the publisher's key is unavailable, you can disable verification with `tflint_plugin_verification = "off"` on 
the `tf.download` tag. (The hash is still pinned, so only the first resolution is taken on trust.)

## Running tflint yourself

`@tf_toolchains//:tflint` is the tflint binary, and you can use an alias to make it easily runnable:

```python
alias(
    name = "tflint",
    actual = "@tf_toolchains//:tflint",
)
```
