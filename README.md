# Tf Rules

The Tf rules are useful to validate, lint and format terraform code.

They can typically be used in a terraform monorepo of modules to lint, run validation tests, auto generate documentation and enforce the consistency of Tf and providers versions across all modules.

# Why "Tf" and not "Terraform"

Because now you can either use "tofu" or "terraform" binary.

## Getting Started

To import rules_tf in your project, you first need to add it to your `MODULE.bazel` file:

```python
bazel_dep(name = "rules_tf", version = "0.0.9")
# git_override(
#     module_name = "rules_tf",
#     remote      = "https://github.com/yanndegat/rules_tf",
#     commit      = "...",
# )

tf = use_extension("@rules_tf//tf:extensions.bzl", "tf_repositories", dev_dependency = True)
tf.download(
    version = "1.9.5",
    tflint_version = "0.53.0",
    tfdoc_version = "0.19.0",
    use_tofu = False,
    mirror = [
        "hashicorp/random:3.3.2",
        "hashicorp/null:3.1.1",
        # The same provider may appear multiple times with different versions.
        # Modules then pick whichever version they require via their own
        # `tf_providers_versions` target / required_providers block.
        # "hashicorp/random:3.6.0",
    ]
)

# Alternatively, load the provider list from a JSON file:
# tf.download(
#     version = "1.9.5",
#     mirror_json = "//terraform:providers.json",
# )

# Switch to tofu
# tf = use_extension("@rules_tf//tf:extensions.bzl", "tf_repositories")
# tf.download(
#    version = "1.6.0",
#    use_tofu = True,
#    mirror = [
#        "hashicorp/random:3.3.2",
#        "hashicorp/null:3.1.1",
#    ]
# )

use_repo(tf, "tf_toolchains")
register_toolchains(
    "@tf_toolchains//:all",
    dev_dependency = True,
)
```

### Externalizing the provider list with `mirror_json`

Instead of listing providers inline in `MODULE.bazel`, you can maintain them in a
standalone JSON file and reference it with `mirror_json`:

```json
// terraform/providers.json
[
    "hashicorp/random:3.3.2",
    "hashicorp/null:3.1.1"
]
```

```python
tf.download(
    version = "1.9.5",
    mirror_json = "//terraform:providers.json",
)
```

The JSON file must contain an array of strings in the same
`"[hostname/]namespace/type:version"` format used by the inline `mirror` attribute.
This is useful when the provider list is generated or shared across multiple
repositories.

### Using Tf rules

Once you've imported the rule set, you can then load the tf rules in your `BUILD` files with:

```python
load("@rules_tf//tf:def.bzl", "tf_module")

tf_module(
    name = "root-mod-a",
    providers = {
        "random": "hashicorp/random:3.3.2",
        "null":   "hashicorp/null:3.1.1",
    },
    tf_version = ">= 1.9",
    deps = [
        "//tf/modules/mod-a",
    ],
)
```

Each entry in the `providers` dict maps a local alias to a `"source:version"` string.
The same provider source can appear in different modules at different versions —
as long as every version is listed in the `mirror` of your `tf.download()` tag.

#### Provider Configuration Aliases

For providers that need multiple configurations (e.g. multi-region), use the
dict form with `configuration_aliases`:

```python
tf_module(
    name = "multi-provider-module",
    providers = {
        "random": {
            "source": "hashicorp/random",
            "version": "3.3.2",
            "configuration_aliases": ["random.primary", "random.secondary"],
        },
        "aws": {
            "source": "hashicorp/aws",
            "version": "5.0.0",
            "configuration_aliases": ["aws.us_east_1", "aws.us_west_2"],
        },
    },
    tf_version = ">= 1.9",
)
```

#### Skipping Validation for Nested Modules

Modules that use provider configuration aliases are designed to be nested (called by other modules) and cannot be validated standalone because they don't have concrete provider configurations. For these modules, use `skip_validation = True`:

```python
# Nested module with provider aliases - cannot validate standalone
tf_module(
    name = "multi-region-module",
    providers = {
        "aws": {
            "source": "hashicorp/aws",
            "version": "5.0.0",
            "configuration_aliases": ["aws.us_east_1", "aws.us_west_2"],
        },
    },
    tf_version = ">= 1.9",
    skip_validation = True,
)

# Root module that uses the nested module - can validate
tf_module(
    name = "root-module",
    providers = {
        "aws": "hashicorp/aws:5.0.0",
    },
    tf_version = ">= 1.9",
    deps = ["//tf/modules/multi-region-module"],
)
```

This is necessary because Terraform cannot validate a module that declares configuration aliases without having concrete provider configurations passed to it from a parent module.

### Using prebuilt binaries

To ensure a consistent binary version across the team, you can create an alias to the prebuilt binaries:

```python
# Likewise for tofu, tfdoc, and tflint.
alias(
    name = "terraform",
    actual = "@tf_toolchains//:terraform",
)
```

And you can use `bazel run //:terraform` which uses the same version as configured in your `MODULE.bazel`.

## Using Tf Modules

1. Using custom tflint config file

```python
load("@rules_tf//tf:def.bzl", "tf_module")

filegroup(
    name = "tflint-custom-config",
    srcs = [
        "my-tflint-config.hcl",
    ],
)

tf_module(
    name = "mod-a",
    providers = {
        "random": "hashicorp/random:3.3.2",
    },
    tf_version = ">= 1.9",
    tflint_config = ":tflint-custom-config",
)
```

1. Generating versions.tf.json files

Terraform linter by default requires that all providers used by a module
are versioned. It is possible to generate a versions.tf.json file by running
a dedicated target:

```python
load("@rules_tf//tf:def.bzl", "tf_module")

tf_module(
    name = "root-mod-a",
    providers = {
        "random": "hashicorp/random:3.3.2",
    },
    tf_version = ">= 1.9",
    deps = [
        "//tf/modules/mod-a",
    ],
)
```

``` bash
bazel run //path/to/root-mod-a:gen-tf-versions
```

or generate all files of a workspace:

``` bash
bazel cquery 'kind(tf_gen_versions, //...)' --output files | xargs -n1 bash
```

1. Generating terraform doc files

It is possible to generate a README.md file by running
a dedicated target for terraform modules:

```python
load("@rules_tf//tf:def.bzl", "tf_gen_doc")

tf_gen_doc(
    name = "tfgendoc",
    modules = ["//{}/{}".format(package_name(), m) for m in subpackages(include = ["**/*.tf"])],
)
```

and run the following command to generate docs for all sub packages.

``` bash
bazel run //path/to:tfgendoc
```

It is also possible to customize terraform docs config:

```python
load("@rules_tf//tf:def.bzl", "tf_gen_doc")

filegroup(
    name = "tfdoc-config",
    srcs = [
        "my-tfdoc-config.yaml",
    ],
)

tf_gen_doc(
    name   = "custom-tfgendoc",
    modules = ["//{}/{}".format(package_name(), m) for m in subpackages(include = ["**/*.tf"])],
    config = ":tfdoc-config",
)
```

1. Formatting terraform files

It is possible to format terraform files by running a dedicated target:

```python
load("@rules_tf//tf:def.bzl", "tf_format")


tf_format(
    name = "tffmt",
    modules = ["//{}/{}".format(package_name(), m) for m in subpackages(include = ["**/*.tf"])],
)
```

and run the following command to generate docs for all sub packages.

``` bash
bazel run //path/to:tffmt
```
