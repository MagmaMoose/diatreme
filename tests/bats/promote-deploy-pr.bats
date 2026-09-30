#!/usr/bin/env bats

# promote-deploy-pr.sh (mode: deploy-promote): which closed pull requests it
# acts on, and what it carries to the next overlay. The PR it opens goes
# through the real open-deploy-pr.sh against the same stub.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/promote-deploy-pr.sh"
IMG="containers.example/octo/app"

load deploy-pr-stub

setup() {
  command -v yq >/dev/null || skip "yq not installed"
  deploy_pr_stub_setup
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
  : > "${GITHUB_OUTPUT}"
  export GH_TOKEN=fake REPO_FULL=octo/app
  export DEPLOY_PR_TARGETS='{"prod": ["k8s/overlays/acc", "k8s/overlays/prd"]}'
  export ENVIRONMENTS='["dev", "staging", "prod"]'
  export GITHUB_EVENT_PATH="${BATS_TEST_TMPDIR}/event.json"
  stub_branch master base-sha
  echo '{"parents":[{"sha":"before-sha"}]}' > "${STATE}/commit.json"

  # acc before and after the merge: the app moved, redis did not.
  stub_file k8s/overlays/acc/kustomization.yaml before-sha <<EOF
images:
  - name: ${IMG}
    newTag: v1.2.18
  - name: docker.io/library/redis
    newTag: "7.4"
EOF
  stub_file k8s/overlays/acc/kustomization.yaml merge-sha <<EOF
images:
  - name: ${IMG}
    newTag: v1.2.19
  - name: docker.io/library/redis
    newTag: "7.4"
EOF
  stub_file k8s/overlays/prd/kustomization.yaml <<EOF
images:
  - name: ${IMG}
    newTag: v1.2.18
  - name: docker.io/library/redis
    newTag: "7.2"
EOF
  merged_event deploy/acc/v1.2.19
}

merged_event() {
  cat > "${GITHUB_EVENT_PATH}" <<EOF
{"pull_request": {"number": 31, "merged": ${2:-true}, "head": {"ref": "$1"},
 "base": {"ref": "master"}, "merge_commit_sha": "merge-sha"}}
EOF
}

refute() {
  if "$@"; then echo "expected to fail, but succeeded: $*"; return 1; fi
}

@test "a merged acc deploy PR opens the prd one with what the merge moved" {
  run "${SCRIPT}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r .branch "${STATE}/put.json")" = "deploy/prd/v1.2.19" ]
  put_content | grep -qF '    newTag: v1.2.19'
  # redis was not part of the merge, so prd keeps its own.
  put_content | grep -qF '    newTag: "7.2"'
  grep -qF '**acc** runs it since #31 merged.' "${STATE}/body.md"
  [ "$(output_of result)" = "created" ]
}

@test "the PR it opens names what follows prd, when something does" {
  export DEPLOY_PR_TARGETS='{"prod": ["k8s/overlays/acc", "k8s/overlays/prd", "k8s/overlays/dr"]}'
  run "${SCRIPT}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'opens the same change for **dr**' "${STATE}/body.md"
}

@test "a pull request closed without merging is ignored" {
  merged_event deploy/acc/v1.2.19 false
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"was not merged"* ]]
  [ ! -f "${STATE}/writes.log" ]
}

@test "a pull request that is not a deploy PR is ignored" {
  merged_event feature/login
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not a deploy PR"* ]]
  merged_event deploy/acc
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not a deploy PR"* ]]
  [ ! -f "${STATE}/writes.log" ]
}

@test "the last overlay has nothing to promote to" {
  merged_event deploy/prd/v1.2.19
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is the last overlay"* ]]
  [ ! -f "${STATE}/writes.log" ]
}

@test "a deploy branch for an overlay the targets do not name is a warning" {
  merged_event deploy/qa/v1.2.19
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"*"no overlay called 'qa'"* ]]
}

@test "a merge that moved no tag promotes nothing" {
  stub_file k8s/overlays/acc/kustomization.yaml merge-sha < "${STATE}/files@before-sha/k8s/overlays/acc/kustomization.yaml"
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"without moving an image tag"* ]]
  [ ! -f "${STATE}/writes.log" ]
}

@test "pr-number is read through the API when the event has no pull request" {
  echo '{}' > "${GITHUB_EVENT_PATH}"
  jq '.pull_request' <<<'{"pull_request": {"number": 31, "merged": true, "head": {"ref": "deploy/acc/v1.2.19"}, "base": {"ref": "master"}, "merge_commit_sha": "merge-sha"}}' > "${STATE}/pr.json"
  PR_NUMBER=31 run "${SCRIPT}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q 'gh api repos/octo/app/pulls/31' "${STATE}/calls.log"
  [ "$(jq -r .branch "${STATE}/put.json")" = "deploy/prd/v1.2.19" ]
}

@test "no pull request and no pr-number is an error" {
  echo '{}' > "${GITHUB_EVENT_PATH}"
  run "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"runs on a pull_request event, or needs pr-number"* ]]
}

@test "without deploy-pr-targets it is a no-op, so a shared workflow can always route here" {
  DEPLOY_PR_TARGETS='' run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"deploy PRs are off here"* ]]
  [ ! -f "${STATE}/writes.log" ]
}

@test "a custom branch prefix is recognised" {
  merged_event ops/deploy/acc/v1.2.19
  BRANCH_PREFIX=ops/deploy run "${SCRIPT}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r .branch "${STATE}/put.json")" = "ops/deploy/prd/v1.2.19" ]
  refute grep -q 'is not a deploy PR' <<<"$output"
}
