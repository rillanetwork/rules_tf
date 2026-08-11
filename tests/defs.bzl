"""Helpers for declaring the integration test suites over the child modules."""

load("@bazel_binaries//:defs.bzl", "bazel_binaries")
load(
    "@rules_bazel_integration_test//bazel_integration_test:defs.bzl",
    "bazel_integration_test",
    "integration_test_utils",
)

# These suites drive a nested Bazel that downloads toolchain binaries and
# provider packages from the public registries, so they need the network, and
# their result says nothing about the inputs Bazel can see. On top of the
# framework's own defaults, which keep them out of `//...` and stop two of them
# running at once.
_TAGS = integration_test_utils.DEFAULT_INTEGRATION_TEST_TAGS + [
    "requires-network",
    "no-remote-cache",
    # What these assert is partly a property of the registries rather than of
    # the inputs Bazel hashed, so a cached pass could hide drift that has
    # already happened.
    "external",
]

def tf_integration_test(name, workspace_path, test_runner, bazel_cmds = None):
    """Declares an integration test over one of the child modules under tests/.

    Args:
        name: Name of the test target.
        workspace_path: Path of the child module, relative to this package.
        test_runner: Label of the runner binary that drives the nested Bazel.
        bazel_cmds: Commands for //tests/runners:bazel_suite to run, in order.
            Passed through the environment because the macro below builds the
            test's args itself.
    """
    bazel_integration_test(
        name = name,
        bazel_binaries = bazel_binaries,
        # Every child module resolves this one through a local_path_override,
        # so they are all bound to the version this module declares compatible.
        bazel_version = bazel_binaries.versions.current,
        env = {"TF_BAZEL_CMDS": "\n".join(bazel_cmds)} if bazel_cmds else {},
        tags = _TAGS,
        test_runner = test_runner,
        # Downloading a toolchain and a set of providers on a cold cache takes
        # considerably longer than the default timeout allows.
        timeout = "eternal",
        workspace_files = integration_test_utils.glob_workspace_files(workspace_path) + [
            "//:local_repository_files",
        ],
        workspace_path = workspace_path,
    )
