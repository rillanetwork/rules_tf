"""Unit tests for the semver comparator and constraint solver.

These run at analysis time and reach no registry, which is the point: the solver
is otherwise only exercised end to end by the integration workspaces, where a
regression surfaces as "the wrong version was mirrored" rather than as a failing
assertion.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    ":semver.bzl",
    "parse_version_constraint",
    "select_matching_version",
)

_AVAILABLE = ["3.1.0", "3.1.9", "3.2.0", "3.9.0", "4.0.0", "4.0.4", "4.0.5"]

def _pessimistic_operator_test_impl(ctx):
    env = unittest.begin(ctx)

    # '~>' pins every component to the left of the rightmost one written, so the
    # two- and three-component forms bound different components. This is the
    # part of terraform's syntax most easily got wrong.
    asserts.equals(env, "3.1.9", select_matching_version(_AVAILABLE, "~> 3.1.0"))
    asserts.equals(env, "3.9.0", select_matching_version(_AVAILABLE, "~> 3.1"))
    asserts.equals(env, "3.9.0", select_matching_version(_AVAILABLE, "~> 3"))

    return unittest.end(env)

def _comparison_operators_test_impl(ctx):
    env = unittest.begin(ctx)

    # The highest satisfying version, not the first or the last offered.
    asserts.equals(env, "4.0.5", select_matching_version(_AVAILABLE, ">= 3.2.0"))
    asserts.equals(env, "3.1.0", select_matching_version(_AVAILABLE, "< 3.1.9"))
    asserts.equals(env, "3.2.0", select_matching_version(_AVAILABLE, "<= 3.2.0"))
    asserts.equals(env, "3.2.0", select_matching_version(_AVAILABLE, "3.2.0"))
    asserts.equals(env, "3.2.0", select_matching_version(_AVAILABLE, "= 3.2.0"))

    # Commas mean AND, and '!=' subtracts from what the others admit.
    asserts.equals(env, "4.0.4", select_matching_version(_AVAILABLE, ">= 4.0.0, < 4.0.5"))
    asserts.equals(env, "3.1.0", select_matching_version(_AVAILABLE, ">= 3.1.0, < 3.2.0, != 3.1.9"))

    return unittest.end(env)

def _prerelease_selection_test_impl(ctx):
    env = unittest.begin(ctx)

    # Never selected by a constraint, matching terraform: a prerelease reaches
    # the mirror only through an exact pin.
    asserts.equals(env, "3.6.0", select_matching_version(["3.6.0", "3.7.0-alpha1"], ">= 3.0.0"))
    asserts.equals(env, "", select_matching_version(["3.7.0-alpha1"], "~> 3.7"))

    # A prerelease may still appear in a bound, where it ranks below the release
    # it qualifies -- so 4.0.0 satisfies '>= 4.0.0-beta1'.
    asserts.equals(env, "4.0.0", select_matching_version(["4.0.0"], ">= 4.0.0-beta1"))
    asserts.equals(env, "", select_matching_version(["4.0.0"], "< 4.0.0-beta1"))

    return unittest.end(env)

def _unsatisfiable_and_malformed_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, "", select_matching_version(_AVAILABLE, ">= 5.0.0"))
    asserts.equals(env, "", select_matching_version([], "~> 3.1"))

    # A spec that does not parse selects nothing rather than everything; the
    # caller reports it as an unsatisfied constraint.
    asserts.equals(env, "", select_matching_version(_AVAILABLE, "not-a-version"))
    asserts.equals(env, None, parse_version_constraint("~> "))
    asserts.equals(env, None, parse_version_constraint("3.1.0, "))

    return unittest.end(env)

_pessimistic_operator_test = unittest.make(_pessimistic_operator_test_impl)
_comparison_operators_test = unittest.make(_comparison_operators_test_impl)
_prerelease_selection_test = unittest.make(_prerelease_selection_test_impl)
_unsatisfiable_and_malformed_test = unittest.make(_unsatisfiable_and_malformed_test_impl)

def semver_test_suite(name = "semver_test"):
    """Declares the semver tests.

    Args:
      name: the suite's name.
    """
    unittest.suite(
        name,
        _pessimistic_operator_test,
        _comparison_operators_test,
        _prerelease_selection_test,
        _unsatisfiable_and_malformed_test,
    )
