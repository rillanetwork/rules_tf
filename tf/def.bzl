"""Public entry point: the macros and rules a consumer loads."""

load("@rules_pkg//pkg:mappings.bzl", "pkg_files")
load("@rules_pkg//pkg:pkg.bzl", "pkg_tar")
load("@rules_tf//tf/rules:tf-gen-doc.bzl", _tf_gen_doc = "tf_gen_doc")
load("@rules_tf//tf/rules:tf-gen-versions.bzl", "tf_gen_versions")
load("@rules_tf//tf/rules:tf-lint.bzl", "tf_lint_test")
load("@rules_tf//tf/rules:tf-module.bzl", "tf_artifact", "tf_format_test", "tf_module_deps", "tf_validate_test", _tf_format = "tf_format", _tf_module = "tf_module")

srcs_exclude = [
    "**/*.bzl",
    "**/*.bazel",
    "**/WORKSPACE*",
    "**/BUILD",
    "**/.terraform/**",
    "**/.terraform.lock.hcl",
    "**/.terraform.tfstate.lock.info",
    "**/terraform.tfstate",
    "**/terraform.tfstate.*",
]

def tf_module(
        name,
        data = [],
        size = "small",
        providers = {},
        tf_version = "",
        tflint_config = None,
        tflint_extra_args = [],
        deps = [],
        experiments = [],
        visibility = ["//visibility:public"],
        tags = [],
        skip_validation = False):
    """Declares a terraform module: its sources, generated versions.tf.json, and checks.

    Besides the module itself this declares the targets around it -- `srcs`,
    `module`, `deps`, `tgz` for packaging, and the `lint`, `format` and
    `validate` tests.

    Args:
      name: name of the module target; also the base name of the tarball.
      data: extra files to include in the module beyond the globbed sources.
      size: test size for the generated lint, format and validate tests.
      providers: required providers, keyed by local alias. A value is either a
        "[hostname/]namespace/type:version" string, a bare source string for a
        builtin provider, or a dict of {"source", "version",
        "configuration_aliases"}.
      tf_version: constraint written into the module's required_version.
      tflint_config: tflint configuration to use instead of the toolchain's.
      tflint_extra_args: further arguments for the tflint invocation.
      deps: other tf modules this one sources, vendored into the tarball.
      experiments: terraform experiments to enable in versions.tf.json.
      visibility: visibility of every target declared here.
      tags: tags applied to every target declared here.
      skip_validation: skip the validate test, for a module that cannot be
        validated standalone (one taking provider configuration_aliases, say).
    """

    # Normalise provider values so tf_gen_versions sees a uniform shape:
    #   {"alias": {"source": "...", "version": "...", "configuration_aliases": [...]}}.
    #
    # Accepted value forms:
    #   "hashicorp/random:3.6.0"                    → full inline source:version
    #   "terraform.io/builtin/terraform"             → builtin provider (no version)
    #   {"source": "hashicorp/random", "version": "3.6.0"} → explicit dict
    #   {"source": "hashicorp/random", "version": "3.6.0",
    #    "configuration_aliases": ["random.a", "random.b"]} → with aliases
    normalised = {}
    for pname, pval in providers.items():
        if type(pval) == type(""):
            if "/" not in pval:
                fail("providers[%s]: value %s must be a full 'source:version' string (e.g. 'hashicorp/random:3.6.0')" % (pname, pval))
            parts = pval.split(":")
            if len(parts) == 2:
                normalised[pname] = {"source": parts[0], "version": parts[1]}
            elif len(parts) == 1:
                # Builtin provider, no version
                normalised[pname] = {"source": pval}
            else:
                fail("providers[%s]: invalid format %s, expected '[hostname/]org/type:version'" % (pname, pval))
        elif type(pval) == type({}):
            normalised[pname] = pval
        else:
            fail("providers[%s]: value must be a 'source:version' string or a config dict" % pname)

    tf_gen_versions(
        name = "gen-tf-versions",
        providers_dict_json = json.encode(normalised),
        tf_version = tf_version,
        experiments = experiments,
        visibility = visibility,
        tags = tags,
    )

    pkg_files(
        name = "srcs",
        srcs = native.glob(["**/*"], exclude = srcs_exclude) + data,
        strip_prefix = "",  # this is important to preserve directory structure
        prefix = native.package_name(),
        tags = tags,
        visibility = visibility,
    )

    _tf_module(
        name = "module",
        deps = deps,
        srcs = ":srcs",
        providers_json = json.encode(normalised),
        tags = tags,
    )

    tf_module_deps(
        name = "deps",
        mod = ":module",
        tags = tags,
    )

    tf_format_test(
        name = "format",
        size = size,
        module = ":module",
        tags = tags,
    )

    tf_lint_test(
        name = "lint",
        module = ":module",
        config = tflint_config,
        extra_args = tflint_extra_args,
        size = size,
        tags = tags,
    )

    if not skip_validation:
        tf_validate_test(
            name = "validate",
            module = ":module",
            size = size,
            tags = tags,
        )

    pkg_tar(
        name = "tgz",
        srcs = [":module", ":deps"],
        out = "{}.tar.gz".format(name),
        extension = "tar.gz",
        strip_prefix = ".",  # this is important to preserve directory structure
        tags = tags,
    )

    tf_artifact(
        name = name,
        module = ":module",
        package = ":tgz",
        visibility = ["//visibility:public"],
        tags = tags,
    )

def tf_format(name, modules, **kwargs):
    _tf_format(
        name = name,
        modules = modules,
        visibility = ["//visibility:public"],
        **kwargs
    )

def tf_gen_doc(name, modules, config = None, **kwargs):
    _tf_gen_doc(
        name = name,
        modules = modules,
        config = config,
        visibility = ["//visibility:public"],
        **kwargs
    )
