# Tf Rules

> **Note:** This is a significant fork of [yanndegat/rules_tf](https://github.com/yanndegat/rules_tf)
> with additions including multi-version provider mirrors, `mirror_json` support,
> inline provider declarations, and rules to init/plan/apply root modules
> (absorbed from the former `rules_tf_apply` module). Requires Bazel 9 or later.

The Tf rules are useful to validate, lint, format, plan and apply terraform code.

They can typically be used in a terraform monorepo of modules to lint, run validation tests, auto generate documentation and enforce the consistency of Tf and providers versions across all modules.

# Why "Tf" and not "Terraform"

Because now you can either use "tofu" or "terraform" binary.

## Requirements

**Bazel 9 or later**, enforced by `bazel_compatibility = [">=9.0.0"]`. The provider mirror resolves in a module
extension and records what it resolved to as extension facts in `MODULE.bazel.lock`; `module_ctx.facts` does not
exist on Bazel 8. See [docs/mirror.md](docs/mirror.md#where-the-resolved-mirror-is-recorded).

## Getting Started

To import rules_tf in your project, you first need to add it to your `MODULE.bazel` file:

```python
bazel_dep(name = "rules_tf", version = "1.0.0")
git_override(
    module_name = "rules_tf",
    remote      = "https://github.com/rillanetwork/rules_tf",
    tag         = "v1.0.0",
    # Or pin to an exact commit for immutability:
    # commit    = "...",
)

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

Each `mirror` entry pins an exact version (`hashicorp/random:3.6.0`) or gives a constraint
(`hashicorp/random:~> 3.1.0`, `hashicorp/tls:>= 4.0.0, < 4.0.5`) resolved against the registry when the mirror is
built. Pinning is recommended - see [docs/mirror.md](docs/mirror.md) for the version syntax, the prerelease rule,
and how the resolved set is published.

Resolution happens in the module extension, so the version a constraint selected and each package's URL and
sha256 are recorded in `MODULE.bazel.lock` - as repository attributes and as extension facts. There is no second
lock file to maintain, constraints do not drift between builds, and a subsequent build makes no registry calls
at all. See [docs/mirror.md](docs/mirror.md#where-the-resolved-mirror-is-recorded).

A package can be admitted on a signature-verified hash rather than on the registry's word. `bazel run` a
`tf_providers_lock` target and it records, in that same `MODULE.bazel.lock`, the `zh:` hashes that
`terraform providers lock` verified against the signing keys compiled into the terraform binary; every mirrored
package is then checked against them. `provider_locks` accepts a `.terraform.lock.hcl` directly instead. See
[docs/mirror.md](docs/mirror.md#verified-hashes).

### Custom and private registries

Mirror entries may name a registry host other than the default (`registry.terraform.io`, or
`registry.opentofu.org` when `use_tofu = True`), including authenticated private registries. See
[docs/registries.md](docs/registries.md).

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
The same provider source can appear in different modules at different versions -
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

## Applying Tf Root Modules

The `tf_root_module` macro (absorbed from the former `rules_tf_apply` module) provides rules to initialize, plan, and apply Terraform root modules using Bazel. This effectively enables using tools like bazel-diff to selectively apply changes to Terraform modules only when necessary.

Pair it with a `tf_module` in the same `BUILD.bazel` file:

```python
load("@rules_tf//tf:def.bzl", "tf_module")
load("@rules_tf//tf_apply:defs.bzl", "tf_root_module")

tf_module(
    name = "vpc",
    providers = {
        "aws": "hashicorp/aws:6.43.0",
    },
    tf_version = "1.12.2",
)

tf_root_module(
    name = "vpc",
    module = ":vpc",
    backend = {
        "s3": {
            "bucket": "my-terraform-state",
            "key": "vpc.tfstate",
            "region": "us-west-2",
        },
    },
    tfvars = {
        "environment": "staging",
        "azs": ["us-west-2a", "us-west-2b"],
        "enable_flow_logs": True,
        "max_nat_gateways": 3,
        "tags": {"team": "platform"},
    },
    tags = ["module:vpc"],
)
```

`tfvars` accepts arbitrary typed Starlark values - strings, numbers, bools, lists, and nested maps. The whole dict is JSON-encoded and materialized as a `*.auto.tfvars.json` file, which Terraform loads natively with full typing, so a `list(string)` or `bool` variable receives a correctly-typed value rather than a quoted string.

This synthesizes run targets for each phase of the terraform lifecycle:

```bash
bazel run //path/to:vpc.init
bazel run //path/to:vpc.plan
bazel run //path/to:vpc.apply     # applies the plan written by .plan
bazel run //path/to:vpc.destroy   # plans a destroy; .apply consumes it
bazel run //path/to:vpc.tf -- <subcommand>
```

Running these generates a `bazel-tf` directory at the root of the workspace that must be gitignored. This directory contains the Terraform state and plan files generated by each of the phases.

`backend` takes a single-key dict of `{type: config}` and renders a `*.bazel.backend.tf.generated` file; `tfvars` (and label-keyed `tfvars_deps`) render a `*.bazel.auto.tfvars.json.generated` file. Pass `output_json = True` to also write `plan.tfplan.json` next to the binary plan.

### Destroying a Module

`<name>.destroy` mirrors `.plan` - it runs `terraform plan -destroy` and writes the destroy plan to `bazel-tf/<module>/plan.tfplan`. The subsequent `<name>.apply` then consumes that plan exactly like a forward apply, preserving the same review-then-execute workflow:

```bash
bazel run //path/to:vpc.init
bazel run //path/to:vpc.destroy   # writes a destroy plan to bazel-tf/<mod>/plan.tfplan
# review the plan output, then:
bazel run //path/to:vpc.apply     # consumes the destroy plan and tears down
```

`.destroy` is purely a planning step - nothing is actually destroyed until `.apply` runs against the destroy plan. Note that `.destroy` overwrites `plan.tfplan` (same as `.plan` does), so the last plan written is the one `.apply` will execute.

### Passing Additional Arguments

You can pass additional Terraform arguments using Bazel's `--` syntax:

```bash
# Target specific resources
bazel run //path/to:vpc.plan -- --target module.web --target module.api

# Plan with custom options
bazel run //path/to:vpc.plan -- -refresh=false -parallelism=10
```

Any arguments passed after `--` are forwarded directly to the underlying Terraform command.

### Running Other Terraform Subcommands

For terraform subcommands without a dedicated target (`state`, `import`, `taint`, `output`, `refresh`, `show`, ...), `tf_root_module` exposes a generic `<name>.tf` target that forwards all arguments to `terraform -chdir=<module>`:

```bash
# Read-only commands
bazel run //path/to:vpc.tf -- state list
bazel run //path/to:vpc.tf -- output

# Show a plan that was previously generated
bazel run //path/to:vpc.plan
bazel run //path/to:vpc.tf -- show plan.tfplan

# Import existing infrastructure
bazel run //path/to:vpc.tf -- import aws_iam_role.example example-role

# Destroy (auto-approve is deliberately not implicit - pass it explicitly)
bazel run //path/to:vpc.tf -- destroy -auto-approve -target=null_resource.x
```

Unlike `.apply`, the `.tf` target adds no implicit flags (no `-auto-approve`, no `-input=false`, no plan file). The caller is responsible for whatever terraform needs. This keeps destructive operations opt-in rather than baked into the target.

## Shipped tools

Two versioned `py_binary` tools ship with this ruleset so consuming repos share one implementation of terraform module enumeration and fan-out orchestration. A change to affected-detection or the artifact schema lands here once and every consumer inherits it on the next pin bump.

### `@rules_tf//tools:list_modules`

Enumerates `tf_root_module` targets (via `kind(tf_plan, <query_path>)`) and emits a JSON matrix describing each one:

```bash
BASE_REF=origin/main bazel run @rules_tf//tools:list_modules -- //terraform/...
```

Each row: `{"package", "module_package", "name", "skip", "affected"}`.

- `skip` is true when the module's `tf_plan` target is tagged `deploy:manual`.
- `affected` is true when the module's transitive bazel deps include a file changed between `BASE_REF` (env) and `HEAD`. With `BASE_REF` unset, every module is `affected` (the full list).
- `module_package` is where the rendered terraform working dir lives - equal to `package` unless the root points `module =` at a shared module elsewhere.

This output is **cloud-neutral by design**: it carries module identity plus the skip/affected classification and nothing tenant-specific. A consumer that keys CI off deployment topology (an account per module, say) decorates these rows with its own fields from its own path convention - the ruleset does not own any tenant's cloud/account layout.

### `@rules_tf//tools:run`

Fans out `init`/`plan`/`apply` over the modules under a query, in-process:

```bash
bazel run @rules_tf//tools:run -- //terraform/... init plan \
  [--extra_var_file vars.tfvars] [--plan_artifacts_dir out/]
```

With `--plan_artifacts_dir` (and `plan` among the actions) it copies each module's `plan.tfplan.json` to `<package>--<name>.json`, writes an error envelope for failed plans, and emits a `modules.json` matrix - best-effort reporting that never fails the run.
