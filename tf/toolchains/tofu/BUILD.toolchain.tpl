package(default_visibility = ["//visibility:public"])

exports_files(
     ["mirror_versions.json"],
)

alias(
    name = "runtime",
    actual = "tofu/tofu",
    visibility = ["//visibility:public"]
)

filegroup(
    name = "mirror_files",
    srcs = glob(["mirror/**"], allow_empty = True),
)
