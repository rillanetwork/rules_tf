"""Providers exchanged between the tf module, artifact and package rules."""

TfModuleInfo = provider(
    doc = "Contains information about a Tf module",
    fields = [
        "files",
        "deps",
        "transitive_srcs",
        "module_path",
        "calls",
    ],
)

TfArtifactInfo = provider(
    doc = "Contains information about a Tf artifact: module and package info",
    fields = [
        "module",
        "package",
    ],
)
