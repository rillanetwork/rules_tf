TfModuleInfo = provider(
    doc = "Contains information about a Tf module",
    fields = [
        "files",
        "deps",
        "transitive_srcs",
        "module_path",
    ],
)

TfArtifactInfo = provider(
    doc = "Contains information about a Tf artifact: module and package info",
    fields = [
        "module",
        "package",
    ],
)
