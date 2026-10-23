#!/usr/bin/env bats

# `image-commit-tag` and `image-building-label` as action.yml wires them: off
# by default, the label on before the build and off only after every push, and
# a skipped build retagged for the pull request head. The scripts have their
# own suites (ci-image-tag, ci-image-build, retag-commit-image,
# pr-building-label).
#
# Grep- and awk-based, as in deploy-paths-action.bats, so the suite runs
# wherever bats does.

ACTION_YML="${BATS_TEST_DIRNAME}/../../action.yml"

step_head() {
  awk -v name="    - name: $1" '
    $0 == name { instep = 1; print; next }
    instep && (/^    - name: / || /^      run: /) { exit }
    instep { print }
  ' "${ACTION_YML}"
}

step_line() { grep -n -- "^    - name: $1\$" "${ACTION_YML}" | cut -d: -f1; }

step_if() { step_head "$1" | grep -E '^      if: ' | sed 's/^      if: //'; }

input_default() {
  awk -v key="  $1:" '
    $0 == key { in_input = 1; next }
    in_input && /^  [a-z]/ { exit }
    in_input && /^    default:/ { sub(/^    default: */, ""); print; exit }
  ' "${ACTION_YML}"
}

@test "both features are off by default" {
  [ "$(input_default image-commit-tag)" = "'false'" ]
  [ "$(input_default image-building-label)" = "''" ]
}

@test "the building label comes off only after every tag is pushed" {
  add=$(step_line 'Add building label')
  remove=$(step_line 'Remove building label')
  [ -n "${add}" ] && [ -n "${remove}" ]
  for s in "Build and push CI image" "Tag skipped build for the pull request head"; do
    [ "${add}" -lt "$(step_line "${s}")" ] || { echo "label added after: ${s}"; false; }
    [ "${remove}" -gt "$(step_line "${s}")" ] || { echo "label removed before: ${s}"; false; }
  done
  # After the scan too, so a gated image does not release the preview, and
  # the last ci step: the next step is release mode's first.
  [ "${remove}" -gt "$(step_line 'Scan image and report')" ]
  next=$(awk -v from="${remove}" 'NR > from && /^    - name: / { sub(/^    - name: /, ""); print; exit }' "${ACTION_YML}")
  [ "${next}" = "Detect environment" ]
}

@test "a failed or cancelled run leaves the building label on" {
  # No status function: GitHub skips the step once an earlier one failed or
  # the run was cancelled. always(), failure() or cancelled() would let it run.
  cond=$(step_if 'Remove building label')
  [ -n "${cond}" ]
  if grep -Eq 'always\(\)|failure\(\)|cancelled\(\)|success\(\)' <<< "${cond}"; then
    echo "removal runs after a failure: ${cond}"; false
  fi
  # A step that swallows its own failure would let the removal run after it.
  if grep -q 'continue-on-error' "${ACTION_YML}"; then echo "a step continues on error"; false; fi
}

@test "the label steps run on a pull request with the input set, with the resolved token" {
  for s in "Add building label" "Remove building label"; do
    cond=$(step_if "${s}")
    grep -Fq "inputs.mode == 'ci'" <<< "${cond}"
    grep -Fq "inputs.image-building-label != ''" <<< "${cond}"
    grep -Fq "github.event_name == 'pull_request'" <<< "${cond}"
    step_head "${s}" | grep -Fq 'GH_TOKEN: ${{ steps.auth.outputs.token }}'
  done
  step_head "Add building label" | grep -Fq 'EVENT_LABEL: ${{ github.event.label.name }}'
  step_head "Add building label" | grep -Fq 'ACTION: add'
  step_head "Remove building label" | grep -Fq 'ACTION: remove'
}

@test "a skipped build is retagged only for a deploy-only pull request with image-commit-tag" {
  cond=$(step_if 'Tag skipped build for the pull request head')
  grep -Fq "inputs.image-commit-tag == 'true'" <<< "${cond}"
  grep -Fq "steps.deploy-only.outputs.deploy_only == 'true'" <<< "${cond}"
  step_head 'Tag skipped build for the pull request head' | grep -Fq 'id: retag-commit'
  # The retag needs buildx and the registry login, which a deploy-only pull
  # request otherwise skips.
  for s in "Set up Docker Buildx (CI)" "Log in to container registry (CI)"; do
    step_if "${s}" | grep -Fq "(steps.deploy-only.outputs.deploy_only != 'true' || inputs.image-commit-tag == 'true')" \
      || { echo "not available to the retag: ${s}"; false; }
    [ "$(step_line "${s}")" -lt "$(step_line 'Tag skipped build for the pull request head')" ]
  done
}
