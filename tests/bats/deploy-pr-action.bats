#!/usr/bin/env bats

# Deploy PRs as action.yml wires them: the inputs, where the new steps sit in
# the run, what gates them, and what the inline `Open deploy PR` block hands
# the helper. The helpers have their own suites (deploy-targets,
# open-deploy-pr, promote-deploy-pr, check-deploy-only-change).
#
# Blocks are pulled out of action.yml with awk, as in promote-from.bats, so the
# suite runs wherever bats does.

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
ACTION_YML="${REPO_ROOT}/action.yml"

run_block() {
  awk -v name="    - name: $1" '
    $0 == name { instep = 1; next }
    instep && !inrun && /^    - name: / { exit }
    instep && !inrun && /^      run: \|$/ { inrun = 1; next }
    inrun {
      if ($0 ~ /[^ ]/) { match($0, /^ */); if (RLENGTH < 8) exit }
      print substr($0, 9)
    }
  ' "${ACTION_YML}"
}

step_head() {
  awk -v name="    - name: $1" '
    $0 == name { instep = 1; print; next }
    instep && (/^    - name: / || /^      run: /) { exit }
    instep { print }
  ' "${ACTION_YML}"
}

step_line() { grep -n -- "^    - name: $1\$" "${ACTION_YML}" | cut -d: -f1; }

input_default() {
  awk -v key="  $1:" '
    $0 == key { in_input = 1; next }
    in_input && /^  [a-z]/ { exit }
    in_input && /^    default:/ { sub(/^    default: */, ""); print; exit }
  ' "${ACTION_YML}"
}

setup() {
  WORK="${BATS_TEST_TMPDIR}/work"
  mkdir -p "${WORK}/action/scripts"
  cp "${REPO_ROOT}/scripts/deploy-targets.sh" "${WORK}/action/scripts/"
  # The helper, replaced by a stub that records what it was handed.
  cat > "${WORK}/action/scripts/open-deploy-pr.sh" <<'EOF'
#!/usr/bin/env bash
for v in OVERLAY BASE_BRANCH IMAGES TAG NEXT_OVERLAY SOURCE_NOTE BRANCH_PREFIX; do
  printf '%s=%s\n' "${v}" "${!v:-}"
done > "${CALLED}"
EOF
  chmod +x "${WORK}/action/scripts/open-deploy-pr.sh"
  export CALLED="${WORK}/called.env" GITHUB_ACTION_PATH="${WORK}/action"
  export GITHUB_OUTPUT="${WORK}/output"
  : > "${GITHUB_OUTPUT}"
}

called() { grep -E "^$1=" "${CALLED}" | cut -d= -f2-; }

run_open_deploy_pr() {
  run_block "Open deploy PR" > "${WORK}/block.sh"
  [ -s "${WORK}/block.sh" ] || { echo "no run block for Open deploy PR"; return 1; }
  run env \
    GH_TOKEN=t REPO_FULL=octo/app SERVER_URL=https://ghe.example REF_NAME=master \
    DEPLOY_PR_TARGETS='{"prod": ["k8s/overlays/acc", "k8s/overlays/prd"]}' \
    ENVIRONMENTS='["dev", "staging", "prod"]' \
    INPUT_DEPLOY_PR_BASE="" BRANCH_PREFIX=deploy INPUT_CREATE_RELEASE=true \
    DETECT_ENV=prod NORMALIZE_TAG=v1.2.19 PROMOTE_OUTCOME=success \
    RELEASED_REPOSITORIES='["containers.example/octo/app","containers.example/octo/worker"]' \
    "$@" bash "${WORK}/block.sh"
}

@test "the three inputs exist, off by default" {
  [ "$(input_default deploy-pr-targets)" = "''" ]
  [ "$(input_default deploy-pr-base)" = "''" ]
  [ "$(input_default deploy-pr-branch-prefix)" = "'deploy'" ]
}

@test "deploy-promote is a documented mode and gets an App token" {
  grep -qE '^        deploy-promote +Run on a `pull_request` `closed` event' "${ACTION_YML}"
  step_head "Request public GitHub App token" | grep -qF "inputs.mode == 'deploy-promote'"
}

@test "deploy-promote does not check out" {
  step_head "Checkout" | grep -qxF "      if: inputs.mode != 'deploy-promote'"
}

@test "the targets are validated before anything else reads them" {
  [ "$(step_line 'Validate deploy PR targets')" -lt "$(step_line 'Resolve promote source')" ]
  [ "$(step_line 'Validate deploy PR targets')" -lt "$(step_line 'Detect deploy-only change')" ]
}

@test "every ci image step skips a deploy-only pull request" {
  for s in "Set up QEMU" "Set up Docker Buildx (CI)" "Log in to container registry (CI)" \
           "Build and push pr-<N>" "Install Trivy" "Scan image and report"; do
    step_head "${s}" | grep -qF "steps.deploy-only.outputs.deploy_only != 'true'" \
      || { echo "not gated: ${s}"; false; }
  done
  [ "$(step_line 'Detect deploy-only change')" -lt "$(step_line 'Set up QEMU')" ]
}

@test "the release guard runs before a version is resolved" {
  [ "$(step_line 'Deploy overlay guard')" -gt "$(step_line 'Release actor allowlist')" ]
  [ "$(step_line 'Deploy overlay guard')" -lt "$(step_line 'Resolve release version')" ]
  step_head "Deploy overlay guard" | grep -qF "github.event_name == 'push'"
  step_head "Deploy overlay guard" | grep -qF "CHECK: guard"
}

@test "the deploy PR opens after the images and the GitHub Release" {
  [ "$(step_line 'Open deploy PR')" -gt "$(step_line 'Promote images')" ]
  [ "$(step_line 'Open deploy PR')" -gt "$(step_line 'Publish GitHub Release')" ]
  step_head "Open deploy PR" | grep -qF "steps.normalize.outputs.released == 'true'"
}

@test "Promote images reports the repositories it promoted" {
  run_block "Promote images" | grep -qF 'echo "repositories=$(jq -c'
}

@test "the deploy-pr output reads both modes' steps" {
  grep -qF 'value: ${{ steps.deploy-pr.outputs.url || steps.deploy-promote.outputs.url }}' "${ACTION_YML}"
}

@test "a release hands every promoted image, at the release tag, to the first overlay" {
  run_open_deploy_pr
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(called OVERLAY)" = "k8s/overlays/acc" ]
  [ "$(called BASE_BRANCH)" = "master" ]
  [ "$(called TAG)" = "v1.2.19" ]
  [ "$(called NEXT_OVERLAY)" = "prd" ]
  [ "$(called IMAGES)" = '{"containers.example/octo/app":"v1.2.19","containers.example/octo/worker":"v1.2.19"}' ]
  [ "$(called SOURCE_NOTE)" = 'Released as [`v1.2.19`](https://ghe.example/octo/app/releases/tag/v1.2.19).' ]
}

@test "deploy-pr-base wins over the branch the release ran on" {
  run_open_deploy_pr INPUT_DEPLOY_PR_BASE=main REF_NAME=hotfix/1.2.19
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(called BASE_BRANCH)" = "main" ]
}

@test "without a GitHub Release the note links the tag" {
  run_open_deploy_pr INPUT_CREATE_RELEASE=false
  [ "$(called SOURCE_NOTE)" = 'Released as [`v1.2.19`](https://ghe.example/octo/app/tree/v1.2.19).' ]
}

@test "a release in an environment with no overlay opens nothing" {
  run_open_deploy_pr DETECT_ENV=staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"names no overlay for staging"* ]]
  [ ! -f "${CALLED}" ]
}

@test "no promoted image, or a failed promote, opens nothing" {
  run_open_deploy_pr RELEASED_REPOSITORIES='[]'
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"*"promoted no image"* ]]
  [ ! -f "${CALLED}" ]
  run_open_deploy_pr PROMOTE_OUTCOME=failure
  [ "$status" -eq 0 ]
  [ ! -f "${CALLED}" ]
}
