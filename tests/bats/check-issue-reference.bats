#!/usr/bin/env bats

# Behaviour coverage for scripts/check-issue-reference.sh (`issue-reference`).
#
# It has to accept every way GitHub links an issue and nothing that merely
# contains a `#`, check the part of the pull request that actually reaches the
# main line for the merge method in use (the title, the commits, or both), skip
# the merge commits that updating a branch adds, and leave bot and Diatreme
# branches alone.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/check-issue-reference.sh"

setup() {
  WORK=$(mktemp -d)
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  git init -q --initial-branch=master "${WORK}/repo"
  cd "${WORK}/repo"
  commit "initial"
  BASE=$(git rev-parse HEAD)
  git checkout -q -b feature/4567-null-check
}

teardown() {
  cd /
  rm -rf "${WORK}"
}

commit() { git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "$1"; }

check() {
  run env ISSUE_REFERENCE="$1" PR_TITLE="${TITLE:-}" BASE_SHA="${BASE}" \
    HEAD_SHA="$(git rev-parse HEAD)" HEAD_REF="${REF:-feature/4567-null-check}" "${SCRIPT}"
}

# ── title ────────────────────────────────────────────────────────────────────

@test "title: a title that references an issue passes" {
  TITLE="Fix null check on export endpoint #4567" check title
  [ "$status" -eq 0 ]
}

@test "title: a title without one fails and says what to add" {
  TITLE="Fix null check on export endpoint" check title
  [ "$status" -eq 1 ]
  [[ "$output" == *"title does not reference an issue"* ]]
  [[ "$output" == *"#123, GH-123, owner/repo#123 or an issue URL"* ]]
}

@test "every form GitHub links counts as a reference" {
  for t in "#12 fix" "Fix (#12)" "Fix, #12" "Fix GH-12" "fix gh-12" "Fix acme/app#12" \
           "Fix https://github.com/acme/app/issues/12" "[#12] fix"; do
    TITLE="${t}" check title
    [ "$status" -eq 0 ]
  done
}

@test "a # that is not an issue reference does not count" {
  for t in "Upgrade to C#12" "Escape &#39; in names" "Fix the thing" "Version 1.2 #" "Fix GH12"; do
    TITLE="${t}" check title
    [ "$status" -eq 1 ]
  done
}

# ── commits ──────────────────────────────────────────────────────────────────

@test "commits: every commit referencing an issue passes" {
  commit "Fix null check on export endpoint #4567"
  commit $'Add a test\n\nRefs #4567'
  check commits
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 2 commit(s) reference an issue"* ]]
}

@test "commits: the ones without a reference are listed" {
  commit "Fix null check on export endpoint #4567"
  commit "wip"
  commit "fix typo"
  check commits
  [ "$status" -eq 1 ]
  [[ "$output" == *"2 of 3 commit(s) do not reference an issue"* ]]
  [[ "$output" == *" wip"* ]]
  [[ "$output" == *" fix typo"* ]]
  [[ "$output" != *"Fix null check on export endpoint"* ]]
}

@test "commits: a reference in the body counts" {
  commit $'Fix null check\n\nCloses #4567'
  check commits
  [ "$status" -eq 0 ]
}

@test "commits: merge commits from updating the branch are not checked" {
  commit "Fix null check #4567"
  git checkout -q master
  commit "someone else's work #9"
  git checkout -q feature/4567-null-check
  git -c user.name=t -c user.email=t@example.com merge -q --no-edit master
  check commits
  [ "$status" -eq 0 ]
}

@test "commits: only the pull request's own commits are checked, not the base's" {
  git checkout -q master
  commit "old commit with no reference"
  BASE=$(git rev-parse HEAD)
  git checkout -q -b feature/2-x
  commit "Do the thing #2"
  REF=feature/2-x check commits
  [ "$status" -eq 0 ]
}

@test "commits: a base or head commit missing from the checkout is an error, not a pass" {
  commit "Fix #4567"
  run env ISSUE_REFERENCE=commits BASE_SHA=0123456789abcdef0123456789abcdef01234567 \
    HEAD_SHA="$(git rev-parse HEAD)" HEAD_REF=feature/4567-null-check "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"are not in this checkout"* ]]
}

# ── both, and the input ──────────────────────────────────────────────────────

@test "title and commits can be checked together" {
  commit "wip"
  TITLE="Fix null check #4567" check "title, commits"
  [ "$status" -eq 1 ]
  [[ "$output" == *"title references an issue"* ]]
  [[ "$output" == *"1 of 1 commit(s)"* ]]
}

@test "an unknown value is an error" {
  TITLE="Fix #1" check "titles"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown value 'titles'"* ]]
}

@test "a value that names nothing is an error" {
  TITLE="Fix #1" check " , "
  [ "$status" -eq 1 ]
}

@test "bot and Diatreme branches are not checked" {
  for r in dependabot/npm_and_yarn/foo-1.2.3 renovate/foo-1.x promote/staging/1.2.3-dev.1 merge-back/release-1.4.0; do
    TITLE="Bump foo" REF="${r}" check "title, commits"
    [ "$status" -eq 0 ]
  done
}

@test "a custom promote prefix is exempt too" {
  run env ISSUE_REFERENCE=title PR_TITLE="Promote" HEAD_REF=ship/prod/1.2.3 PROMOTE_BRANCH_PREFIX=ship "${SCRIPT}"
  [ "$status" -eq 0 ]
}

# ── action.yml wiring ────────────────────────────────────────────────────────

ACTION_YML="${BATS_TEST_DIRNAME}/../../action.yml"

step_head() {
  awk -v name="    - name: $1" '
    $0 == name { instep = 1; print; next }
    instep && /^    - name: / { exit }
    instep { print }
  ' "${ACTION_YML}"
}

@test "the check is opt-in, pull-request only, and skips deploy-only pull requests" {
  head=$(step_head "Check issue references")
  grep -Fq "inputs.issue-reference != ''" <<< "${head}"
  grep -Fq "github.event_name == 'pull_request'" <<< "${head}"
  grep -Fq "steps.deploy-only.outputs.deploy_only != 'true'" <<< "${head}"
}

@test "the title reaches the script through env, never the script text" {
  head=$(step_head "Check issue references")
  grep -Fq 'PR_TITLE: ${{ github.event.pull_request.title }}' <<< "${head}"
  grep -Fq 'run: "${GITHUB_ACTION_PATH}/scripts/check-issue-reference.sh"' <<< "${head}"
}

@test "issue-reference is off by default" {
  run awk '$0 == "  issue-reference:" { f = 1; next } f && /^    default:/ { print; exit }' "${ACTION_YML}"
  [ "$output" = "    default: ''" ]
}
