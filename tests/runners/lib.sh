#!/usr/bin/env bash

# Shared helpers for the //tests integration test runners. Sourced by a runner
# after it has initialised the Bash runfiles library, since locating the
# scratch directory utility needs rlocation.

# Copies the staged tree into a scratch directory and changes into the child
# module inside it.
#
# The files Bazel stages are symlinks back into the source tree, so whatever
# the nested Bazel writes -- MODULE.bazel.lock above all -- would otherwise be
# written through them and dirty the checkout.
#
# The copy is taken from the root of the staged tree rather than from the child
# module alone, because each child resolves this module through
# `local_path_override(path = "../..")`. That path only means anything with the
# two of them in their original relative positions.
bit::enter_scratch_dir() {
  local create_scratch_dir_path=rules_bazel_integration_test/tools/create_scratch_dir.sh
  local create_scratch_dir
  create_scratch_dir="$(rlocation "${create_scratch_dir_path}")" ||
    {
      echo >&2 "Failed to locate ${create_scratch_dir_path}"
      return 1
    }

  local staged_root
  staged_root="$(cd "${BIT_WORKSPACE_DIR}/../.." && pwd)" || return 1

  local workspace_rel_path="${BIT_WORKSPACE_DIR#"${staged_root}/"}"
  if [[ "${workspace_rel_path}" == "${BIT_WORKSPACE_DIR}" ]]; then
    echo >&2 "Expected ${BIT_WORKSPACE_DIR} to sit below ${staged_root}."
    return 1
  fi

  local scratch_dir
  scratch_dir="$("${create_scratch_dir}" \
    --workspace "${staged_root}" \
    --scratch "${TEST_TMPDIR}/workspace")"

  cd "${scratch_dir}/${workspace_rel_path}" || return 1
}

# Runs the nested Bazel in the scratch directory.
#
# The output base sits under TEST_TMPDIR so that it is discarded along with the
# test. Bazel derives a default output base from the workspace path, and the
# scratch directory is new on every run, so the default would leave a fresh
# output base behind under ~/.cache/bazel each time. The repository cache is
# left where it is, which is what lets the nested Bazel reuse packages an
# earlier suite already downloaded.
bit::bazel() {
  "${BIT_BAZEL_BINARY}" --output_base="${TEST_TMPDIR}/output_base" "$@"
}

# Runs `bazel run` against every target of the given rule kind, one invocation
# at a time. Several of the rules under test are generators whose point is the
# side effect on the source tree, so they are exercised by running them rather
# than by building them.
bit::bazel_run_kind() {
  local kind="${1}"
  local targets=()

  while IFS=$'\n' read -r target; do targets+=("${target}"); done < <(
    bit::bazel query "kind(\"${kind}\", //...)"
  )

  if [[ ${#targets[@]} -eq 0 ]]; then
    echo >&2 "No targets found of kind ${kind}."
    return 1
  fi

  for target in "${targets[@]}"; do
    echo "--- bazel run ${target}"
    bit::bazel run "${target}"
  done
}
