#!/usr/bin/env bash

# Shared helpers for the //tests integration test runners.

# Copies the staged tree into a scratch directory and changes into the child
# module inside it. Copied from the root of the staged tree, not the child
# alone, because each child resolves this module through
# `local_path_override(path = "../..")`.
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

  # The repo contents cache is locked by whichever Bazel holds it, and the
  # Bazel running this test holds the default one. `common` because the runners
  # also call commands that do not accept the flag.
  cat >> .bazelrc <<RC
common --repo_contents_cache=${TEST_TMPDIR}/repo_contents_cache
RC
}

# Runs the nested Bazel in the scratch directory. The repository cache is left
# at its default, so suites reuse each other's downloads.
bit::bazel() {
  "${BIT_BAZEL_BINARY}" --output_base="${TEST_TMPDIR}/output_base" "$@"
}

# Runs `bazel run` against every target of the given rule kind.
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
