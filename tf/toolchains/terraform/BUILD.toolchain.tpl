package(default_visibility = ["//visibility:public"])

alias(
    name = "runtime",
    actual = "terraform/terraform",
    visibility = ["//visibility:public"]
)

# The mirror is exposed as its individual files, never as the `mirror` source
# directory. A source directory is one opaque artifact Bazel never expands, so
# nothing asks for the bytes inside it, and a repo restored from the repo
# contents cache arrives without the directory at all -- leaving the
# `terraform init -plugin-dir=` that reads it by path at runtime with nothing.
filegroup(
    name = "mirror_files",
    srcs = glob(["mirror/**"], allow_empty = True),
)

exports_files(
     ["mirror_versions.json"],
)
