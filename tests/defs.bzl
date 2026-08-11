"""Helpers for declaring the integration test suites over the child modules."""

load("@bazel_binaries//:defs.bzl", "bazel_binaries")
load(
    "@rules_bazel_integration_test//bazel_integration_test:defs.bzl",
    "bazel_integration_test",
    "integration_test_utils",
)

_TAGS = integration_test_utils.DEFAULT_INTEGRATION_TEST_TAGS + [
    "requires-network",
    "no-remote-cache",
    "external",
]

def tf_integration_test(name, workspace_path, test_runner, bazel_cmds = None):
    """Declares an integration test over one of the child modules under tests/.

    Args:
        name: Name of the test target.
        workspace_path: Path of the child module, relative to this package.
        test_runner: Label of the runner binary that drives the nested Bazel.
        bazel_cmds: Commands for //tests/runners:bazel_suite to run, in order.
    """
    bazel_integration_test(
        name = name,
        bazel_binaries = bazel_binaries,
        bazel_version = bazel_binaries.versions.current,
        env = {"TF_BAZEL_CMDS": "\n".join(bazel_cmds)} if bazel_cmds else {},
        tags = _TAGS,
        test_runner = test_runner,
        timeout = "long",
        workspace_files = integration_test_utils.glob_workspace_files(workspace_path) + [
            "//:local_repository_files",
        ],
        workspace_path = workspace_path,
    )
