#!/usr/bin/env bats

# Behaviour coverage for scripts/resolve-release-line-version.sh, which versions
# a release branch from its own name (`release-branch-versioning: branch`).
#
# What matters: the branch names the version until that version ships, a fix
# landing on a line that already shipped gets the next patch rather than the
# shipped number again, a re-run resumes the candidate it already cut instead of
# cutting another on the same commit, and a branch that names no version is left
# to the versioning tool.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/resolve-release-line-version.sh"

setup() {
  WORK=$(mktemp -d)
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  git -C "${WORK}" init --initial-branch=master repo >/dev/null
  REPO="${WORK}/repo"
  cd "${REPO}"
  commit "initial"
}

teardown() {
  rm -rf "${WORK}"
}

commit() {
  git -c user.name=tester -c user.email=t@example.com commit --allow-empty -q -m "$1"
}

# resolve <branch> [is_prerelease] [identifier] [prefix]
resolve() {
  run env BRANCH="$1" IS_PRERELEASE="${2:-true}" IDENTIFIER="${3-rc}" TAG_PREFIX="${4-v}" "${SCRIPT}"
}

field() { printf '%s\n' "${output}" | sed -n "s/^$1=//p"; }

@test "a new release branch cuts the first candidate of the version it names" {
  resolve release/1.4.0
  [ "${status}" -eq 0 ]
  [ "$(field version)" = "1.4.0-rc.1" ]
  [ "$(field tag)" = "v1.4.0-rc.1" ]
  [ "$(field resume)" = "true" ]
}

@test "the candidate number counts up from the highest one of that version" {
  git tag v1.4.0-rc.1
  commit "fix"
  git tag v1.4.0-rc.2
  commit "another fix"
  resolve release/1.4.0
  [ "$(field version)" = "1.4.0-rc.3" ]
}

@test "candidate numbers compare numerically, not as text" {
  git tag v1.4.0-rc.9
  commit "fix"
  git tag v1.4.0-rc.10
  commit "another fix"
  resolve release/1.4.0
  [ "$(field version)" = "1.4.0-rc.11" ]
}

@test "a fix on a line that shipped is the next patch, not the shipped version" {
  git tag v1.4.0-rc.1
  git tag v1.4.0
  commit "hotfix"
  resolve release/1.4.0
  [ "$(field version)" = "1.4.1-rc.1" ]
}

@test "the next patch follows the highest patch already released on the line" {
  git tag v1.4.0
  commit "hotfix one"
  git tag v1.4.1-rc.1
  git tag v1.4.1
  commit "hotfix two"
  resolve release/1.4.0
  [ "$(field version)" = "1.4.2-rc.1" ]
}

@test "a second fix before the first one ships is the next candidate of the same patch" {
  git tag v1.4.0
  commit "hotfix one"
  git tag v1.4.1-rc.1
  commit "hotfix two"
  resolve release/1.4.0
  [ "$(field version)" = "1.4.1-rc.2" ]
}

@test "patches released on another line do not move this one" {
  git tag v1.3.7
  git tag v1.5.0
  resolve release/1.4.0
  [ "$(field version)" = "1.4.0-rc.1" ]
}

@test "a branch naming a patch above what was released keeps its own number" {
  git tag v1.4.0
  git tag v1.4.1
  commit "next"
  resolve release/1.4.3
  [ "$(field version)" = "1.4.3-rc.1" ]
}

@test "a line reopened at its last release cuts nothing until a fix lands" {
  git tag v1.4.0
  commit "hotfix one"
  git tag v1.4.1
  resolve release/1.4.0
  [ "$(field version)" = "1.4.1" ]
  [ "$(field resume)" = "false" ]
  commit "hotfix two"
  resolve release/1.4.0
  [ "$(field version)" = "1.4.2-rc.1" ]
}

@test "a re-run on the commit that already holds the candidate resumes it" {
  git tag v1.4.0-rc.1
  commit "fix"
  git tag v1.4.0-rc.2
  resolve release/1.4.0
  [ "$(field version)" = "1.4.0-rc.2" ]
  [ "$(field resume)" = "true" ]
}

@test "a commit already promoted to stable releases nothing new" {
  git tag v1.4.0-rc.1
  git tag v1.4.0
  resolve release/1.4.0
  [ "$(field version)" = "1.4.0" ]
  [ "$(field resume)" = "false" ]
  [[ "${output}" == *"already released as v1.4.0"* ]]
}

@test "a stable environment cuts the version itself" {
  resolve release/2.0.0 false ""
  [ "$(field version)" = "2.0.0" ]
  [ "$(field resume)" = "true" ]
}

@test "a stable environment cuts the next patch once the version shipped" {
  git tag v2.0.0
  commit "hotfix"
  resolve release/2.0.0 false ""
  [ "$(field version)" = "2.0.1" ]
}

@test "the identifier of the environment is used" {
  resolve release/1.4.0 true beta
  [ "$(field version)" = "1.4.0-beta.1" ]
}

@test "candidates of another identifier do not count" {
  git tag v1.4.0-beta.4
  commit "fix"
  resolve release/1.4.0 true rc
  [ "$(field version)" = "1.4.0-rc.1" ]
}

@test "the GitFlow branch families are release lines" {
  resolve releases/1.4.0
  [ "$(field version)" = "1.4.0-rc.1" ]
  resolve hotfix/1.4.1
  [ "$(field version)" = "1.4.1-rc.1" ]
  resolve release-1.4.0
  [ "$(field version)" = "1.4.0-rc.1" ]
  resolve release/v1.4.0
  [ "$(field version)" = "1.4.0-rc.1" ]
}

@test "a branch that names no version is left to the versioning tool" {
  for b in master test release/next hotfix/456-login-bug feature/release-1.4.0 release/1.4 release/01.4.0; do
    resolve "${b}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ] || [[ "${output}" != *"version="* ]]
  done
}

@test "an empty prefix works" {
  git tag 1.4.0
  commit "hotfix"
  resolve release/1.4.0 true rc ""
  [ "$(field version)" = "1.4.1-rc.1" ]
  [ "$(field tag)" = "1.4.1-rc.1" ]
}

@test "tags under another prefix belong to another package" {
  git tag core-v1.4.0
  resolve release/1.4.0 true rc v
  [ "$(field version)" = "1.4.0-rc.1" ]
}

@test "a prefix with glob characters is matched literally" {
  git tag v1.4.0
  resolve release/1.4.0 true rc "*"
  [ "$(field version)" = "1.4.0-rc.1" ]
}

@test "a prerelease environment without an identifier is an error" {
  resolve release/1.4.0 true ""
  [ "${status}" -eq 1 ]
}
