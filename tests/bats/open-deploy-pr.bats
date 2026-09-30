#!/usr/bin/env bats

# open-deploy-pr.sh against a stubbed GitHub: which pull request it opens,
# refreshes, supersedes or declines to open, and exactly what it commits.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/open-deploy-pr.sh"
IMG="containers.example/octo/app"

load deploy-pr-stub

setup() {
  command -v yq >/dev/null || skip "yq not installed"
  deploy_pr_stub_setup
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
  : > "${GITHUB_OUTPUT}"
  export GH_TOKEN=fake REPO_FULL=octo/app OVERLAY=k8s/overlays/acc BASE_BRANCH=master
  export IMAGES="{\"${IMG}\":\"v1.2.19\"}" TAG=v1.2.19
  stub_branch master base-sha
  stub_file k8s/overlays/acc/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base
images:
  - name: ${IMG}
    newTag: v1.2.18 # {"\$imagepolicy": "flux-system:acc-app:tag"}
  - name: docker.io/library/redis
    newTag: "7.4"
EOF
}

refute() {
  if "$@"; then echo "expected to fail, but succeeded: $*"; return 1; fi
}

@test "opens a PR that moves only the newTag value, comment and layout intact" {
  run "${SCRIPT}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  grep -qx 'POST repos/octo/app/git/refs' "${STATE}/writes.log"
  grep -q 'gh api -X POST repos/octo/app/git/refs -f ref=refs/heads/deploy/acc/v1.2.19 -f sha=base-sha' "${STATE}/calls.log"
  [ "$(jq -r .branch "${STATE}/put.json")" = "deploy/acc/v1.2.19" ]
  [ "$(jq -r .sha "${STATE}/put.json")" = "blob-base-sha" ]
  [ "$(jq -r .message "${STATE}/put.json")" = "chore(deploy): v1.2.19 to acc" ]

  put_content > "${BATS_TEST_TMPDIR}/after"
  stub_file_copy="${STATE}/files/k8s/overlays/acc/kustomization.yaml"
  # Exactly one line differs, and it is the tag with its marker still on it.
  run diff "${stub_file_copy}" "${BATS_TEST_TMPDIR}/after"
  [ "$(printf '%s\n' "$output" | grep -c '^[<>]')" -eq 2 ]
  grep -qF '    newTag: v1.2.19 # {"$imagepolicy": "flux-system:acc-app:tag"}' "${BATS_TEST_TMPDIR}/after"
  grep -qF '    newTag: "7.4"' "${BATS_TEST_TMPDIR}/after"

  [ "$(output_of result)" = "created" ]
  [ "$(output_of number)" = "42" ]
  [ "$(output_of url)" = "${STUB_PR_URL}" ]
  grep -q "gh pr create --repo octo/app --base master --head deploy/acc/v1.2.19 --title chore(deploy): v1.2.19 to acc" "${STATE}/calls.log"
  grep -qF "| \`${IMG}\` | \`v1.2.18\` | \`v1.2.19\` |" "${STATE}/body.md"
}

@test "keeps the quoting style of the value" {
  export IMAGES='{"docker.io/library/redis":"7.4.1"}' TAG=7.4.1
  run "${SCRIPT}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  put_content | grep -qF '    newTag: "7.4.1"'
}

@test "matches an entry by newName when it has one" {
  stub_file k8s/overlays/acc/kustomization.yaml <<EOF
images:
  - name: app
    newName: ${IMG}
    newTag: v1.2.18
EOF
  run "${SCRIPT}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  put_content | grep -qF '    newTag: v1.2.19'
  put_content | grep -qF '  - name: app'
}

@test "the body names the next overlay and the source when given" {
  NEXT_OVERLAY=prd SOURCE_NOTE="Released as v1.2.19." run "${SCRIPT}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'Released as v1.2.19.' "${STATE}/body.md"
  grep -qF 'When it merges, Diatreme opens the same change for **prd**.' "${STATE}/body.md"
}

@test "an overlay that already runs the tag gets no PR, and an older open one is closed" {
  export IMAGES="{\"${IMG}\":\"v1.2.18\"}" TAG=v1.2.18
  cat > "${STATE}/prs.json" <<'EOF'
[{"number":7,"headRefName":"deploy/acc/v1.2.17","url":"u7"},
 {"number":8,"headRefName":"deploy/acc/v1.2.20","url":"u8"},
 {"number":9,"headRefName":"feature/x","url":"u9"}]
EOF
  run "${SCRIPT}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_of result)" = "unchanged" ]
  [ ! -f "${STATE}/writes.log" ]
  grep -q 'gh pr close 7 --repo octo/app --delete-branch' "${STATE}/calls.log"
  refute grep -q 'gh pr close 8' "${STATE}/calls.log"
  refute grep -q 'gh pr close 9' "${STATE}/calls.log"
}

@test "a new tag supersedes the open PR for an older one" {
  cat > "${STATE}/prs.json" <<'EOF'
[{"number":7,"headRefName":"deploy/acc/v1.2.18","url":"u7"},
 {"number":5,"headRefName":"deploy/prd/v1.2.17","url":"u5"}]
EOF
  run "${SCRIPT}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_of result)" = "created" ]
  grep -q 'gh pr close 7 --repo octo/app --delete-branch --comment Superseded by #42' "${STATE}/calls.log"
  refute grep -q 'gh pr close 5' "${STATE}/calls.log"
}

@test "a re-run for the same tag refreshes the open PR instead of opening another" {
  echo '[{"number":11,"headRefName":"deploy/acc/v1.2.19","url":"u11"}]' > "${STATE}/prs.json"
  run "${SCRIPT}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_of result)" = "refreshed" ]
  [ "$(output_of number)" = "11" ]
  grep -q 'gh pr edit 11 --repo octo/app --title chore(deploy): v1.2.19 to acc' "${STATE}/calls.log"
  refute grep -q 'gh pr create' "${STATE}/calls.log"
  [ ! -f "${STATE}/writes.log" ]
}

@test "an open PR for a newer tag wins: nothing is opened" {
  echo '[{"number":12,"headRefName":"deploy/acc/v1.2.20","url":"u12"}]' > "${STATE}/prs.json"
  run "${SCRIPT}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_of result)" = "skipped" ]
  [ ! -f "${STATE}/writes.log" ]
  refute grep -q 'gh pr close' "${STATE}/calls.log"
}

@test "never proposes a tag older than the overlay runs" {
  export IMAGES="{\"${IMG}\":\"v1.2.10\"}" TAG=v1.2.10
  run "${SCRIPT}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_of result)" = "skipped" ]
  [ ! -f "${STATE}/writes.log" ]
}

@test "a leftover branch with no open PR is deleted and made again" {
  stub_branch deploy/acc/v1.2.19 stale-sha
  run "${SCRIPT}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'DELETE repos/octo/app/git/refs/heads/deploy/acc/v1.2.19' "${STATE}/writes.log"
  grep -qx 'POST repos/octo/app/git/refs' "${STATE}/writes.log"
}

@test "an image the overlay does not list is left out with a warning" {
  export IMAGES="{\"${IMG}\":\"v1.2.19\",\"containers.example/octo/worker\":\"v1.2.19\"}"
  run "${SCRIPT}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"::warning::"*"no images[] entry for containers.example/octo/worker"* ]]
  put_content | grep -qF '    newTag: v1.2.19'
}

@test "an overlay that lists none of the images is an error" {
  export IMAGES='{"containers.example/octo/other":"v1.2.19"}'
  run "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"*"none of: containers.example/octo/other"* ]]
  [ ! -f "${STATE}/writes.log" ]
}

@test "a digest-pinned entry is refused: the digest would outrank the tag" {
  stub_file k8s/overlays/acc/kustomization.yaml <<EOF
images:
  - name: ${IMG}
    newTag: v1.2.18
    digest: sha256:0000000000000000000000000000000000000000000000000000000000000000
EOF
  run "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"pins ${IMG} by digest"* ]]
  [ ! -f "${STATE}/writes.log" ]
}

@test "an entry without newTag is refused" {
  stub_file k8s/overlays/acc/kustomization.yaml <<EOF
images:
  - name: ${IMG}
    newName: ${IMG}-mirror
EOF
  export IMAGES="{\"${IMG}-mirror\":\"v1.2.19\"}"
  run "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no newTag to move"* ]]
}

@test "a flow-style entry is refused rather than half-edited" {
  stub_file k8s/overlays/acc/kustomization.yaml <<EOF
images: [{name: ${IMG}, newTag: v1.2.18}]
EOF
  run "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"only a block-style 'newTag: <tag>' line is supported"* ]]
  [ ! -f "${STATE}/writes.log" ]
}

@test "finds kustomization.yml when there is no kustomization.yaml" {
  mv "${STATE}/files/k8s/overlays/acc/kustomization.yaml" "${STATE}/files/k8s/overlays/acc/kustomization.yml"
  run "${SCRIPT}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'PUT repos/octo/app/contents/k8s/overlays/acc/kustomization.yml' "${STATE}/writes.log"
}

@test "an overlay with no kustomization file is an error" {
  export OVERLAY=k8s/overlays/nowhere
  run "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no kustomization.yaml"*"in k8s/overlays/nowhere"* ]]
}

@test "a tag that is not a valid image tag is refused before anything is read" {
  export TAG='v1/2'
  run "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a valid image tag"* ]]
  refute grep -q 'gh api' "${STATE}/calls.log"
}

@test "honours a custom branch prefix and a trailing slash on the overlay" {
  BRANCH_PREFIX=ops/deploy/ OVERLAY=k8s/overlays/acc/ run "${SCRIPT}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r .branch "${STATE}/put.json")" = "ops/deploy/acc/v1.2.19" ]
}
