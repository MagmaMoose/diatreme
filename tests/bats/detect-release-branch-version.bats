#!/usr/bin/env bats

# Behaviour coverage for scripts/detect-release-branch-version.sh — the helper
# that reads the release version out of HEAD's merge subject when a squash
# merge has destroyed the commit-message signal the versioning backends rely
# on.
#
# Two halves matter equally here. It must FIRE on every merge subject GitHub
# and git actually produce for a release branch, because the bug it fixes ships
# a wrong version with every step green. And it must NOT fire on a subject that
# merely mentions a version, because a false positive pins a release to a
# number nobody chose — the same class of silent failure, pointed the other way.
#
# Success cases capture stdout (stderr silenced), mirroring the `VERSION=$(...)`
# callsite in action.yml: stdout carries exactly the version, or nothing.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/detect-release-branch-version.sh"

setup() {
  WORK=$(mktemp -d)
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  git -C "${WORK}" init --initial-branch=main repo >/dev/null
  REPO="${WORK}/repo"
  git -C "${REPO}" -c user.name=tester -c user.email=t@example.com \
    commit --allow-empty -m "initial" >/dev/null
  cd "${REPO}"
}

teardown() {
  rm -rf "${WORK}"
}

tag() { git -C "${REPO}" tag "$1"; }

# Derived version for a subject, with stderr dropped.
derived() {
  env SUBJECT="$1" TAG_PREFIX="${2-v}" "${SCRIPT}" 2>/dev/null
}

# ── Grammar 1: GitHub merge commit ────────────────────────────────────────

@test "derives from a GitHub merge-commit subject" {
  [ "$(derived 'Merge pull request #614 from acme/release/1.15.0')" = "1.15.0" ]
}

@test "derives from a merge-commit subject with a trailing branch description" {
  [ "$(derived 'Merge pull request #700 from acme/hotfix/1.14.9-cve-2026-1234')" = "1.14.9" ]
}

@test "accepts the plural branch families GitVersion also recognises" {
  [ "$(derived 'Merge pull request #12 from acme/releases/2.0.0')" = "2.0.0" ]
  [ "$(derived 'Merge pull request #13 from acme/hotfixes-2.0.1')" = "2.0.1" ]
}

@test "accepts a v-prefixed branch version" {
  [ "$(derived 'Merge pull request #14 from acme/release/v3.1.0')" = "3.1.0" ]
}

# ── Grammar 2: plain git merge ────────────────────────────────────────────

@test "derives from a plain git merge subject" {
  [ "$(derived "Merge branch 'release/1.15.0' into main")" = "1.15.0" ]
}

@test "derives from a remote-tracking merge subject" {
  [ "$(derived "Merge remote-tracking branch 'origin/release/1.15.0'")" = "1.15.0" ]
}

# ── Grammar 3: squash merge (the case the bug is about) ───────────────────

@test "derives from a squash-merge subject, which is just the PR title" {
  # GitHub replaces the branch field with the PR title plus ` (#N)`, so the
  # branch name survives only as free text. This is the exact shape of #614.
  [ "$(derived 'release: merge release/1.15.0 into main (#614)')" = "1.15.0" ]
}

@test "derives from a squash-merge subject that opens with the branch name" {
  [ "$(derived 'release/1.15.0 (#614)')" = "1.15.0" ]
}

# ── Non-matches: a version mentioned is not a version chosen ──────────────

@test "ignores a release-shaped segment inside another branch family" {
  # `feature/release-1.16.0-prep` names no release. The version in it belongs
  # to nobody, and pinning to it would cut 1.16.0 off a feature branch.
  [ -z "$(derived 'Merge pull request #620 from acme/feature/release-1.16.0-prep')" ]
}

@test "ignores an ordinary conventional commit" {
  [ -z "$(derived 'fix(api): reject an empty payload')" ]
}

@test "ignores a subject with no version at all" {
  [ -z "$(derived 'Merge pull request #9 from acme/release/candidate')" ]
}

# ── The forward guard ─────────────────────────────────────────────────────

@test "ignores a version that is already released" {
  # The revert-the-merge case. Without this the tag already exists,
  # push-release-tag.sh treats that as a no-op, and the push publishes
  # nothing at all — silently.
  tag v1.15.0
  [ -z "$(derived 'release: merge release/1.15.0 into main (#614)')" ]
}

@test "ignores a version behind the latest stable tag" {
  # A hotfix branch merged back into the trunk after a later release: the
  # version it names is history, and the tool should compute the next one.
  tag v1.15.0
  [ -z "$(derived 'Merge pull request #700 from acme/hotfix/1.14.9')" ]
}

@test "derives a version ahead of the latest stable tag" {
  tag v1.14.4
  [ "$(derived 'Merge pull request #614 from acme/release/1.15.0')" = "1.15.0" ]
}

@test "sorts the ceiling by version, not lexically" {
  tag v1.9.0
  tag v1.10.0
  [ -z "$(derived 'Merge pull request #1 from acme/release/1.10.0')" ]
  [ "$(derived 'Merge pull request #2 from acme/release/1.11.0')" = "1.11.0" ]
}

@test "a prerelease tag is not a ceiling" {
  # `release/1.15.0` cut v1.15.0-rc.3 on the way in; that is the same release,
  # not a later one, so the stable tag must still be derivable.
  tag v1.14.4
  tag v1.15.0-rc.3
  [ "$(derived 'Merge pull request #614 from acme/release/1.15.0')" = "1.15.0" ]
}

@test "derives in a repository with no tags yet" {
  [ "$(derived 'Merge pull request #1 from acme/release/0.1.0')" = "0.1.0" ]
}

@test "honours a non-v tag prefix when reading the ceiling" {
  # Scoped like every other tag lookup in this action: another package's
  # v-prefixed tags must not become this package's ceiling.
  tag v9.9.9
  tag core-1.2.0
  [ "$(derived 'Merge pull request #1 from acme/release/1.3.0' 'core-')" = "1.3.0" ]
  [ -z "$(derived 'Merge pull request #2 from acme/release/1.1.0' 'core-')" ]
}

# ── Callsite contract ─────────────────────────────────────────────────────

@test "exits 0 when nothing is derived" {
  # "No release branch here" is the common case on a trunk, not a failure:
  # the action falls through to its configured versioning tool.
  run env SUBJECT='chore: tidy up' TAG_PREFIX=v "${SCRIPT}"
  [ "$status" -eq 0 ]
}

@test "reads HEAD's subject when SUBJECT is unset" {
  git -C "${REPO}" -c user.name=tester -c user.email=t@example.com \
    commit --allow-empty -m "Merge pull request #614 from acme/release/1.15.0" >/dev/null
  [ "$(env TAG_PREFIX=v "${SCRIPT}" 2>/dev/null)" = "1.15.0" ]
}
