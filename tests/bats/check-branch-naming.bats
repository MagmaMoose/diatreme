#!/usr/bin/env bats

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/check-branch-naming.sh"

setup() {
  unset GITHUB_HEAD_REF PROMOTE_BRANCH_PREFIX EXTRA_BRANCH_PREFIXES BRANCH_NAME_PATTERNS || true
}

@test "accepts allowed TBD type prefix" {
  run env GITHUB_HEAD_REF="feat/new-thing" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"follows TBD naming convention"* ]]
}

@test "accepts every documented TBD type prefix" {
  for prefix in feat fix chore hotfix docs refactor perf test ci style build revert deploy release claude codex; do
    run env GITHUB_HEAD_REF="${prefix}/some-change" "${SCRIPT}"
    [ "$status" -eq 0 ]
  done
}

@test "accepts coding-agent branches without any extra configuration" {
  # The branch names Claude Code and Codex generate. Every repo consuming this
  # action gets one the moment an agent opens a PR, so they pass out of the box
  # rather than each repo rediscovering extra-branch-prefixes.
  run env GITHUB_HEAD_REF="claude/fix-the-thing-a1b2c3" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"follows TBD naming convention"* ]]

  run env GITHUB_HEAD_REF="codex/fix-the-thing" "${SCRIPT}"
  [ "$status" -eq 0 ]
}

@test "agent prefixes are types, not a bypass" {
  # Accepted as a TBD type, so the <type>/<description> shape still applies:
  # a bare `claude` with nothing after it is not a branch name.
  run env GITHUB_HEAD_REF="claude" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not follow TBD naming convention"* ]]
}

@test "accepts default promote/ prefix" {
  run env GITHUB_HEAD_REF="promote/staging/1.2.3-dev.1" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"follows TBD naming convention"* ]]
}

@test "accepts custom PROMOTE_BRANCH_PREFIX" {
  run env GITHUB_HEAD_REF="release/staging/1.2.3" PROMOTE_BRANCH_PREFIX="release" "${SCRIPT}"
  [ "$status" -eq 0 ]
}

@test "accepts a single EXTRA_BRANCH_PREFIXES entry" {
  run env GITHUB_HEAD_REF="spike/poc" EXTRA_BRANCH_PREFIXES="spike" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"follows TBD naming convention"* ]]
}

@test "accepts EXTRA_BRANCH_PREFIXES given as a comma/space/pipe list" {
  run env GITHUB_HEAD_REF="wip/experiment" EXTRA_BRANCH_PREFIXES="spike, wip" "${SCRIPT}"
  [ "$status" -eq 0 ]
  run env GITHUB_HEAD_REF="spike/poc" EXTRA_BRANCH_PREFIXES="spike wip" "${SCRIPT}"
  [ "$status" -eq 0 ]
  # `|` doubles as the internal delimiter the separators normalise to, so it is
  # the spelling most likely to regress unnoticed.
  run env GITHUB_HEAD_REF="wip/experiment" EXTRA_BRANCH_PREFIXES="spike|wip" "${SCRIPT}"
  [ "$status" -eq 0 ]
}

@test "tolerates a trailing slash on an extra prefix" {
  run env GITHUB_HEAD_REF="spike/poc" EXTRA_BRANCH_PREFIXES="spike/" "${SCRIPT}"
  [ "$status" -eq 0 ]
}

@test "rejects a regex metacharacter in EXTRA_BRANCH_PREFIXES" {
  # Unvalidated, '.*' would widen the alternation until every branch passes and
  # '(' would break the regex outright, rejecting valid branches with a bash
  # error. Both must fail loudly instead of quietly changing what the gate means.
  run env GITHUB_HEAD_REF="garbage/x" EXTRA_BRANCH_PREFIXES=".*" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid prefix"* ]]

  run env GITHUB_HEAD_REF="feat/ok" EXTRA_BRANCH_PREFIXES="(" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid prefix"* ]]
}

@test "does not accept a prefix outside the extras list" {
  run env GITHUB_HEAD_REF="wip/experiment" EXTRA_BRANCH_PREFIXES="spike" "${SCRIPT}"
  [ "$status" -eq 1 ]
}

@test "error message lists the resolved allowed types" {
  run env GITHUB_HEAD_REF="wip/experiment" EXTRA_BRANCH_PREFIXES="spike" "${SCRIPT}"
  [[ "$output" == *"Allowed types: "* ]]
  [[ "$output" == *"deploy"* ]]
  [[ "$output" == *"spike"* ]]
}

@test "rejects disallowed prefix" {
  run env GITHUB_HEAD_REF="wip/some-thing" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not follow TBD naming convention"* ]]
}

@test "rejects branch with no slash" {
  run env GITHUB_HEAD_REF="feature-branch" "${SCRIPT}"
  [ "$status" -eq 1 ]
}

@test "errors when GITHUB_HEAD_REF is empty" {
  run env GITHUB_HEAD_REF="" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"GITHUB_HEAD_REF is empty"* ]]
}

@test "bypasses dependabot/ branches" {
  run env GITHUB_HEAD_REF="dependabot/github_actions/actions/upload-artifact-7" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bot-generated branch"* ]]
}

@test "bypasses renovate/ branches" {
  run env GITHUB_HEAD_REF="renovate/npm-foo-1.x" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bot-generated branch"* ]]
}

@test "bot bypass only matches at start of branch name" {
  run env GITHUB_HEAD_REF="feat/add-dependabot/config" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"follows TBD naming convention"* ]]
}

# ── Diatreme's own merge-back branch ─────────────────────────────────────────

@test "accepts the merge-back/ branch Diatreme opens merge-back pull requests from" {
  run env GITHUB_HEAD_REF="merge-back/release-1.4.0" "${SCRIPT}"
  [ "$status" -eq 0 ]
}

# ── branch-name-patterns ─────────────────────────────────────────────────────

PATTERNS='feature/{issue}-{name}
hotfix/{issue}-{name}
release/{version}'

named() { run env GITHUB_HEAD_REF="$1" BRANCH_NAME_PATTERNS="${2:-${PATTERNS}}" "${SCRIPT}"; }

@test "patterns accept the names they describe" {
  for b in feature/123-search-filter hotfix/456-login-bug release/1.4.0 feature/7-x feature/12-export-csv-v2; do
    named "${b}"
    [ "$status" -eq 0 ]
  done
  [[ "$output" == *"matches 'feature/{issue}-{name}'"* ]]
}

@test "patterns refuse everything else, the built-in types included" {
  for b in feat/123-search feature/search-filter feature/123 feature/123-Search-Filter \
           feature/123--double feature/123-trailing- release/1.4 release/v1.4.0 release/1.4.0-rc1 \
           release/01.4.0 hotfix/login-bug claude/some-change feature/123-x/extra; do
    named "${b}"
    [ "$status" -eq 1 ]
  done
  [[ "$output" == *"does not match any allowed branch name"* ]]
  [[ "$output" == *"Allowed: feature/{issue}-{name}, hotfix/{issue}-{name}, release/{version}"* ]]
}

@test "patterns can be comma-separated" {
  named feature/1-a 'feature/{issue}-{name}, hotfix/{issue}-{name}'
  [ "$status" -eq 0 ]
  named hotfix/2-b 'feature/{issue}-{name},hotfix/{issue}-{name}'
  [ "$status" -eq 0 ]
}

@test "everything outside a placeholder is literal" {
  # A `.` in a pattern is a dot, not "any character".
  named release/1x4 'release/1.4'
  [ "$status" -eq 1 ]
  named release/1.4 'release/1.4'
  [ "$status" -eq 0 ]
  named 'spike/a+b' 'spike/a+b'
  [ "$status" -eq 0 ]
  named 'spike/aab' 'spike/a+b'
  [ "$status" -eq 1 ]
}

@test "* matches one path segment and ** matches any depth" {
  named deploy/acc 'deploy/*'
  [ "$status" -eq 0 ]
  named deploy/acc/v1.2.3 'deploy/*'
  [ "$status" -eq 1 ]
  named deploy/acc/v1.2.3 'deploy/**'
  [ "$status" -eq 0 ]
  named deploy/ 'deploy/*'
  [ "$status" -eq 1 ]
}

@test "an unknown placeholder is an error, not a literal" {
  named feature/123-x 'feature/{ticket}-{name}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown placeholder"* ]]
}

@test "patterns still accept Diatreme's own branches and the bots" {
  for b in promote/staging/1.2.3-dev.1 merge-back/release-1.4.0 dependabot/npm_and_yarn/foo-1.2.3 renovate/foo-1.x; do
    named "${b}"
    [ "$status" -eq 0 ]
  done
}

@test "patterns follow a custom promote prefix" {
  run env GITHUB_HEAD_REF="ship/staging/1.2.3" PROMOTE_BRANCH_PREFIX=ship BRANCH_NAME_PATTERNS="${PATTERNS}" "${SCRIPT}"
  [ "$status" -eq 0 ]
}

@test "patterns made of blanks are an error" {
  named feature/1-a $'\n , \n'
  [ "$status" -eq 1 ]
  [[ "$output" == *"holds no pattern"* ]]
}
