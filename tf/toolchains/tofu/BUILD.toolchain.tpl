package(default_visibility = ["//visibility:public"])

alias(
    name = "runtime",
    actual = "tofu/tofu",
    visibility = ["//visibility:public"]
)

# The individual files, never the `mirror` source directory: Bazel never expands a
# source directory, so its contents are not staged for the `tofu init -plugin-dir=`
# that reads them by path at runtime.
filegroup(
    name = "mirror_files",
    srcs = glob(["mirror/**"], allow_empty = True),
)

exports_files(
     ["mirror_versions.json"],
)
