#!/usr/bin/env bats

# Behaviour coverage for scripts/ci-image-tag.sh, the tag `mode: ci` pushes its
# image under.
#
# The two old answers must not move: a pull request is `pr-<N>`, which release
# mode looks up when it promotes, and version-override wins over everything.
# The new one replaces the bare `pr-` a push used to get: one immutable tag per
# commit that names the branch, sorts by commit time, and is always a valid
# Docker tag whatever the branch is called.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/ci-image-tag.sh"

setup() {
  WORK=$(mktemp -d)
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  git init -q --initial-branch=master "${WORK}/repo"
  cd "${WORK}/repo"
  GIT_COMMITTER_DATE="@1760000000 +0000" \
    git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m initial
  SHA7=$(git rev-parse --short=7 HEAD)
}

teardown() {
  cd /
  rm -rf "${WORK}"
}

tag() {
  run env VERSION_OVERRIDE="${OVERRIDE:-}" PR_NUMBER="${PR:-}" REF_NAME="$1" "${SCRIPT}"
  [ "$status" -eq 0 ]
}

@test "a pull request keeps its pr-<N> tag" {
  PR=42 tag feature/123-search
  [ "$output" = "pr-42" ]
}

@test "version-override wins over the pull request and the branch" {
  OVERRIDE=3.20.0-rc.1 PR=42 tag feature/123-search
  [ "$output" = "3.20.0-rc.1" ]
  OVERRIDE=3.20.0 tag master
  [ "$output" = "3.20.0" ]
}

@test "a push is tagged after its branch, commit and commit time" {
  tag test
  [ "$output" = "test-${SHA7}-1760000000" ]
}

@test "a push is never the bare pr- it used to be" {
  tag master
  [[ "$output" != "pr-" ]]
  [[ "$output" != pr-* ]]
}

@test "slashes and other characters a tag cannot hold become single hyphens" {
  tag feature/123-Search_Filter
  [ "$output" = "feature-123-search_filter-${SHA7}-1760000000" ]
  tag 'release/1.4.0'
  [ "$output" = "release-1.4.0-${SHA7}-1760000000" ]
  tag 'weird//name@{x}'
  [ "$output" = "weird-name-x-${SHA7}-1760000000" ]
}

@test "a tag never starts with a dot or a hyphen" {
  tag '.hidden/-thing'
  [ "$output" = "hidden-thing-${SHA7}-1760000000" ]
}

@test "a name with nothing usable left falls back to branch" {
  tag '@@@'
  [ "$output" = "branch-${SHA7}-1760000000" ]
  tag ''
  [ "$output" = "branch-${SHA7}-1760000000" ]
}

@test "a long branch name is cut so the tag fits Docker's 128 characters" {
  long=$(printf 'a%.0s' $(seq 1 200))
  tag "feature/${long}"
  [ "${#output}" -le 128 ]
  [[ "$output" == *"-${SHA7}-1760000000" ]]
  [[ "$output" == feature-aaaa* ]]
}

@test "a cut never leaves a hyphen in front of the commit" {
  # 109 characters of slug fit; make the 109th a separator.
  name="$(printf 'b%.0s' $(seq 1 108))-tail"
  tag "${name}"
  [ "${#output}" -le 128 ]
  [[ "$output" != *"--${SHA7}"* ]]
}

@test "every output is a valid Docker tag" {
  for b in master test feature/1-x 'UPPER/Case' '__under' 'dots...and--dashes' 'v1.2.3' 'gh-readonly-queue/main/pr-12-0123456789abcdef'; do
    tag "${b}"
    [[ "$output" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]
  done
}

@test "the time sorts: a later commit gets a larger last field" {
  first="test-${SHA7}-1760000000"
  GIT_COMMITTER_DATE="@1760000600 +0000" \
    git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m next
  tag test
  [ "${output##*-}" -gt "${first##*-}" ]
}

@test "the same commit gets the same tag on a re-run" {
  tag test
  one="$output"
  tag test
  [ "$output" = "${one}" ]
}

# KIND=commit: the per-commit tag a pull request build also gets with
# image-commit-tag. HEAD here stands in for the merge commit actions/checkout
# builds on a pull request; the tag must come from the pull request's head.

commit_tag() {
  run env KIND=commit VERSION_OVERRIDE="${OVERRIDE:-}" PR_NUMBER="${PR:-}" HEAD_SHA="${HEAD:-}" "${SCRIPT}"
}

@test "the commit tag is the pull request head's sha7, not the merge commit's" {
  PR=42 HEAD=1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d commit_tag
  [ "$status" -eq 0 ]
  [ "$output" = "pr-42-1a2b3c4" ]
  [[ "$output" != *"${SHA7}"* ]]
}

@test "version-override does not rename the commit tag" {
  OVERRIDE=3.20.0 PR=42 HEAD=1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d commit_tag
  [ "$output" = "pr-42-1a2b3c4" ]
}

@test "a SHA-256 head commit still gives seven characters" {
  PR=7 HEAD="$(printf 'ab%.0s' $(seq 1 32))" commit_tag
  [ "$status" -eq 0 ]
  [ "$output" = "pr-7-abababa" ]
}

@test "no head commit or no number is an error, never a pr-<N>- tag" {
  PR=42 HEAD= commit_tag
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  PR= HEAD=1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d commit_tag
  [ "$status" -eq 1 ]
  PR=42 HEAD=HEAD commit_tag
  [ "$status" -eq 1 ]
}
