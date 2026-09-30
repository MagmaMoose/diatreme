#!/usr/bin/env bats

# check-deploy-only-change.sh: when a change counts as nothing but deploy
# overlays, for the ci build skip (detect) and the release refusal (guard).

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/check-deploy-only-change.sh"

load deploy-pr-stub

setup() {
  deploy_pr_stub_setup
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
  : > "${GITHUB_OUTPUT}"
  export GH_TOKEN=fake REPO_FULL=octo/app CHECK=detect
  export DEPLOY_PR_TARGETS='{"prod": ["k8s/overlays/acc", "k8s/overlays/prd"]}'
}

pr_files() { printf '%s\n' "$@" | jq -R '{filename: .}' | jq -s . > "${STATE}/pr-files.json"; }

@test "a pull request inside the overlays is deploy-only" {
  pr_files k8s/overlays/acc/kustomization.yaml k8s/overlays/prd/kustomization.yaml
  EVENT_NAME=pull_request PR_NUMBER=5 run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(output_of deploy_only)" = "true" ]
}

@test "one file outside the overlays makes it an ordinary change" {
  pr_files k8s/overlays/acc/kustomization.yaml src/Program.cs
  EVENT_NAME=pull_request PR_NUMBER=5 run "${SCRIPT}"
  [ "$(output_of deploy_only)" = "false" ]
}

@test "a sibling directory that only shares a prefix does not count" {
  pr_files k8s/overlays/accounting/kustomization.yaml
  EVENT_NAME=pull_request PR_NUMBER=5 run "${SCRIPT}"
  [ "$(output_of deploy_only)" = "false" ]
}

@test "a rename out of an overlay counts its old path too" {
  echo '[{"filename": "k8s/overlays/acc/patch.yaml", "previous_filename": "k8s/base/patch.yaml"}]' > "${STATE}/pr-files.json"
  EVENT_NAME=pull_request PR_NUMBER=5 run "${SCRIPT}"
  [ "$(output_of deploy_only)" = "false" ]
}

@test "no files, or files that cannot be read, is never deploy-only" {
  echo '[]' > "${STATE}/pr-files.json"
  EVENT_NAME=pull_request PR_NUMBER=5 run "${SCRIPT}"
  [ "$(output_of deploy_only)" = "false" ]
  rm "${STATE}/pr-files.json"
  : > "${GITHUB_OUTPUT}"
  EVENT_NAME=pull_request PR_NUMBER=5 run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(output_of deploy_only)" = "false" ]
}

@test "a push is compared from before to after" {
  echo '{"files": [{"filename": "k8s/overlays/prd/kustomization.yaml"}]}' > "${STATE}/compare.json"
  EVENT_NAME=push BEFORE=aaa AFTER=bbb run "${SCRIPT}"
  [ "$(output_of deploy_only)" = "true" ]
  grep -q 'gh api repos/octo/app/compare/aaa...bbb' "${STATE}/calls.log"
}

@test "a new branch has nothing to compare with" {
  echo '{"files": [{"filename": "k8s/overlays/prd/kustomization.yaml"}]}' > "${STATE}/compare.json"
  EVENT_NAME=push BEFORE=0000000000000000000000000000000000000000 AFTER=bbb run "${SCRIPT}"
  [ "$(output_of deploy_only)" = "false" ]
}

@test "guard refuses a push that changes nothing but the overlays" {
  echo '{"files": [{"filename": "k8s/overlays/acc/kustomization.yaml"}]}' > "${STATE}/compare.json"
  CHECK=guard EVENT_NAME=push BEFORE=aaa AFTER=bbb run "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"*"paths-ignore"*"Nothing was tagged."* ]]
}

@test "guard lets an ordinary push through" {
  echo '{"files": [{"filename": "src/Program.cs"}]}' > "${STATE}/compare.json"
  CHECK=guard EVENT_NAME=push BEFORE=aaa AFTER=bbb run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(output_of deploy_only)" = "false" ]
}
