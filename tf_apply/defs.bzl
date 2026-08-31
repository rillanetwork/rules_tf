"""
This module provides macros and rules for initializing, planning, and applying Terraform modules using rules_tf.
"""

load("//tf_apply/rules:defs.bzl", _tf_apply = "tf_apply", _tf_backend = "tf_backend", _tf_cmd = "tf_cmd", _tf_destroy = "tf_destroy", _tf_init = "tf_init", _tf_plan = "tf_plan", _tf_vars = "tf_vars")
load("//tf_apply/rules:root.bzl", "declare_root_targets")

tf_apply = _tf_apply
tf_cmd = _tf_cmd
tf_destroy = _tf_destroy
tf_init = _tf_init
tf_plan = _tf_plan
tf_vars = _tf_vars
tf_backend = _tf_backend

def tf_root_module(
        name,
        module,
        backend,
        tfvars = {},
        tfvars_deps = {},
        output_json = False,
        tags = [],
        visibility = ["//visibility:private"]):
    """Declares the initialize, plan and apply targets for a Terraform root module.

    Use this when the root module's sources live in a different package to the
    one being declared; for the usual case where they are the same package,
    `tf_module(root = True)` declares these targets alongside the module itself.

    Args:
        name: The name of the Terraform module.
        module: The `tf_module` target to apply.
        backend: A single-key dict of `{type: config}` describing the Terraform backend.
        tfvars: A dict of Terraform input variables with arbitrary typed values (strings,
            numbers, bools, lists, and nested maps). Encoded to JSON and materialized as a
            `*.auto.tfvars.json` file, so values arrive fully typed in Terraform.
        tfvars_deps: Mapping of tfvars keys to labels; each resolves to the dependency's
            file path (relative to the module) at analysis time.
        output_json: Whether `<name>.plan` should also emit a JSON-formatted plan.
        tags: Tags to apply to the generated targets.
        visibility: Visibility of the generated targets.
    """

    declare_root_targets(
        name = name,
        module = module,
        backend = backend,
        tfvars = tfvars,
        tfvars_deps = tfvars_deps,
        output_json = output_json,
        tags = tags,
        visibility = visibility,
    )
