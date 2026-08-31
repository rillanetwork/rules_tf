"""Declaration of the terraform lifecycle targets that surround a root module.

Shared by the `tf_root_module` macro and by `tf_module(root = True)`, which are
two spellings of the same set of targets: the first for a root module whose
sources live in another package, the second for the common case where the root
module is the package it is declared in.
"""

load("//tf_apply/rules:defs.bzl", "tf_apply", "tf_backend", "tf_cmd", "tf_destroy", "tf_init", "tf_plan", "tf_vars")

def declare_root_targets(
        name,
        module,
        backend,
        tfvars = {},
        tfvars_deps = {},
        output_json = False,
        tags = [],
        visibility = ["//visibility:private"]):
    """Declares the `.init`, `.plan`, `.destroy`, `.apply` and `.tf` targets for a root module.

    Also declares the `.tfvars` and `.backend` targets they consume.

    Args:
      name: prefix every declared target is suffixed onto.
      module: label of the `tf_module` to operate on.
      backend: a single-key dict of `{type: config}` describing the Terraform backend.
      tfvars: a dict of Terraform input variables with arbitrary typed values (strings,
        numbers, bools, lists, and nested maps). Encoded to JSON and materialized as a
        `*.auto.tfvars.json` file, so values arrive fully typed in Terraform.
      tfvars_deps: mapping of tfvars keys to labels; each resolves to the dependency's
        file path (relative to the module) at analysis time.
      output_json: whether `<name>.plan` should also emit a JSON-formatted plan.
      tags: tags to apply to the generated targets.
      visibility: visibility of the generated targets.
    """
    if not backend:
        fail("backend must be a single-key dict of {type: config}; a root module cannot be declared without one")
    if len(backend.keys()) > 1:
        fail("backend must have exactly one backend type, got %s" % sorted(backend.keys()))

    backend_type = backend.keys()[0]

    tf_vars(
        name = "{}.tfvars".format(name),
        name_prefix = name,
        module = module,
        tfvars_deps = tfvars_deps,
        tfvars = json.encode(tfvars),
        visibility = visibility,
    )

    tf_backend(
        name = "{}.backend".format(name),
        name_prefix = name,
        type = backend_type,
        config = backend[backend_type],
        visibility = visibility,
    )

    common = {
        "module": module,
        "tfvars": ":{}.tfvars".format(name),
        "backend": ":{}.backend".format(name),
        "tags": tags,
        "visibility": visibility,
    }

    tf_init(name = "{}.init".format(name), **common)
    tf_plan(name = "{}.plan".format(name), output_json = output_json, **common)
    tf_destroy(name = "{}.destroy".format(name), **common)
    tf_apply(name = "{}.apply".format(name), **common)
    tf_cmd(name = "{}.tf".format(name), **common)
