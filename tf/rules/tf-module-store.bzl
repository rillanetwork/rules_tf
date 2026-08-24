"""The store of mirrored terraform modules, as a build target.

The module extension declares one repository per mirrored package and this
target gathers them, turning what the extension learned into something a rule
can point terraform at.

Its job is to know where each package actually lands. A package lives in its own
repository, and runfiles place an external repository under its *canonical*
name, which the store repository cannot know when it writes its own BUILD file.
Resolving that here, from the labels themselves, is what keeps the recorded
paths ones that exist at run time.
"""

load("@rules_tf//tf/rules:providers.bzl", "TfModuleStoreInfo")

# Directory each package repository holds its module under, matching the
# download repository's layout.
PACKAGE_DIR = "module"

# Fields are separated by a unit separator rather than a tab. A closure's root
# member has an empty relative key, and tab is IFS whitespace, so `read` would
# collapse the empty field and shift every value one place left -- silently
# dropping the module the entry was declared for while keeping its children.
FIELD = "\037"

def _package_dir(target):
    """Returns the runfiles-relative directory holding one package's files.

    Args:
      target: the package repository's file group.

    Returns:
      The directory, as a runfiles-relative path.
    """

    # An external repository's runfiles path is its canonical name, which is
    # what the label carries and what the generated BUILD file could not.
    return "../%s/%s" % (target.label.workspace_name, PACKAGE_DIR)

def _impl(ctx):
    entries = json.decode(ctx.attr.entries_json)
    dirs = {key: _package_dir(t) for key, t in ctx.attr.packages.items()}

    # One table, resolved once here rather than by every module that reads it.
    # `E` rows let a module's call be matched to a declared entry; `M` rows are
    # that entry's closure, each already pointing at the package holding it.
    lines = []
    for spec, entry in sorted(entries.items()):
        lines.append(FIELD.join(["E", spec, entry["source"]]))

        for module in entry["modules"]:
            directory = dirs.get(module["store_key"])
            if not directory:
                fail("the module store has no package for %s, needed by %s" % (
                    module["store_key"],
                    spec,
                ))

            if module["subdir"]:
                directory = "%s/%s" % (directory, module["subdir"])

            lines.append(FIELD.join([
                "M",
                spec,
                module["key"],
                module["source"],
                module["version"],
                directory,
            ]))

    table = ctx.actions.declare_file("%s.store.tsv" % ctx.label.name)
    ctx.actions.write(table, "".join([line + "\n" for line in lines]))

    files = depset(
        [table],
        transitive = [t.files for t in ctx.attr.packages.values()],
    )

    return [
        DefaultInfo(files = files),
        TfModuleStoreInfo(table = table, files = files),
    ]

tf_module_store_info = rule(
    implementation = _impl,
    doc = "Gathers the mirrored module packages and records where each one lands.",
    attrs = {
        "packages": attr.string_keyed_label_dict(
            allow_files = True,
            doc = "Each package's file group, keyed by its store key.",
        ),
        "entries_json": attr.string(
            doc = "JSON object mapping each declared module entry to its source and the " +
                  "closure terraform resolved for it, as the extension recorded them.",
        ),
    },
)
