#!/usr/bin/env bats

# `deploy-paths` as action.yml wires it: off by default, the ci image steps
# skip a deploy-only pull request, and the release guard runs before a version
# is resolved. The check itself has its own suite (check-deploy-only-change).
#
# Grep- and awk-based, as in promote-from.bats, so the suite runs wherever
# bats does.

ACTION_YML="${BATS_TEST_DIRNAME}/../../action.yml"

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

@test "deploy-paths is off by default" {
  [ "$(input_default deploy-paths)" = "''" ]
}

@test "every ci image step skips a deploy-only pull request" {
  for s in "Set up QEMU" "Set up Docker Buildx (CI)" "Log in to container registry (CI)" \
           "Build and push pr-<N>" "Install Trivy" "Scan image and report"; do
    step_head "${s}" | grep -qF "steps.deploy-only.outputs.deploy_only != 'true'" \
      || { echo "not gated: ${s}"; false; }
  done
  [ "$(step_line 'Detect deploy-only change')" -lt "$(step_line 'Set up QEMU')" ]
  step_head "Detect deploy-only change" | grep -qF "inputs.deploy-paths != ''"
}

@test "the release guard runs on a push, before a version is resolved" {
  [ "$(step_line 'Deploy-paths guard')" -gt "$(step_line 'Release actor allowlist')" ]
  [ "$(step_line 'Deploy-paths guard')" -lt "$(step_line 'Resolve release version')" ]
  step_head "Deploy-paths guard" | grep -qF "github.event_name == 'push'"
  step_head "Deploy-paths guard" | grep -qF "CHECK: guard"
}

@test "opening deploy PRs is Tremvok's now: no deploy PR inputs or mode remain" {
  ! grep -qE '^  deploy-pr-(targets|base|branch-prefix):' "${ACTION_YML}" || { echo "a deploy-pr input is back"; false; }
  ! grep -qF "inputs.mode == 'deploy-promote'" "${ACTION_YML}" || { echo "mode deploy-promote is back"; false; }
}
