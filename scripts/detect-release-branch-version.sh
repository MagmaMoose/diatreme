#!/usr/bin/env bash
# Derive the release version from the release/hotfix branch HEAD merged in.
#
# WHY THIS EXISTS. In GitFlow the release branch name *states* the version:
# `release/1.15.0` releases 1.15.0. Every versioning backend this action drives
# infers the bump from commit messages instead, and that inference survives a
# merge commit but not a squash merge. "Squash and merge" collapses the
# branch's `feat:`/`fix:` commits into one commit whose body is a bullet list,
# so the `^feat:` anchors stop matching and the tool falls back to the trunk's
# default increment — a patch. The release ships as 1.14.5 instead of 1.15.0
# with every step green, and that mislabelled image is what the cluster pulls.
# GitVersion is the sharpest case (its branch config usually pins
# `main: increment: Patch` outright) but the hole is the same for any
# commit-message-driven backend.
#
# So on a stable branch we read the version out of the merge subject rather
# than out of the commits underneath it: the subject is the one part of the
# lineage a squash cannot destroy.
#
# Env:
#   SUBJECT     HEAD's commit subject. Defaults to `git log -1 --format=%s`;
#               settable so the grammars below are testable without a repo.
#   TAG_PREFIX  Tag prefix the repository releases under (e.g. "v"). Used only
#               to scope the "does this move the line forward" check. Empty
#               by default.
#
# Output:
#   Prints the derived bare version (e.g. "1.15.0") to stdout, or nothing at
#   all when no release branch is named or the derived version would not move
#   the release line forward. Callers capture stdout, so every diagnostic goes
#   to stderr.
#
# Exit codes:
#   0 - always. "Nothing derived" is a normal outcome, not a failure: the
#       caller falls through to its configured versioning tool.

set -euo pipefail

SUBJECT="${SUBJECT-$(git log -1 --format=%s HEAD 2>/dev/null || true)}"
PREFIX="${TAG_PREFIX:-}"

# A release branch, once isolated from its surrounding grammar: the GitFlow
# families GitVersion itself recognises (`^releases?[/-]`, `^hotfix(es)?[/-]`),
# an optional `v`, the version, and an optional `-slug` tail (`hotfix/1.2.3-cve`).
BRANCH_RE='^(release|releases|hotfix|hotfixes)[/-]v?([0-9]+\.[0-9]+\.[0-9]+)([^0-9].*)?$'

# Strip the remote/owner segment a merge subject carries: `org/release/1.15.0`
# and `origin/release/1.15.0` both name the branch `release/1.15.0`.
strip_owner() {
  local ref="$1"
  if [[ "${ref}" =~ ^[^/]+/(release|releases|hotfix|hotfixes)[/-] ]]; then
    printf '%s' "${ref#*/}"
  else
    printf '%s' "${ref}"
  fi
}

derived=""

# Three grammars, in descending order of precision. The first two isolate the
# branch name exactly, so they can accept any branch that *starts* with a
# release family and reject `feature/release-1.16.0-prep` outright. Only the
# third has to scan free text.

# 1. GitHub merge commit: `Merge pull request #614 from org/release/1.15.0`
if [[ "${SUBJECT}" =~ ^Merge\ pull\ request\ \#[0-9]+\ from\ ([^[:space:]]+) ]]; then
  candidate="$(strip_owner "${BASH_REMATCH[1]}")"
  [[ "${candidate}" =~ ${BRANCH_RE} ]] && derived="${BASH_REMATCH[2]}"
fi

# 2. Plain git merge: `Merge branch 'release/1.15.0' into main`, and the
#    remote-tracking variant `Merge remote-tracking branch 'origin/release/1.15.0'`.
if [ -z "${derived}" ] && [[ "${SUBJECT}" =~ ^Merge\ (remote-tracking\ )?branch\ \'([^\']+)\' ]]; then
  candidate="$(strip_owner "${BASH_REMATCH[2]}")"
  [[ "${candidate}" =~ ${BRANCH_RE} ]] && derived="${BASH_REMATCH[2]}"
fi

# 3. Squash merge: the subject is the PR title plus ` (#614)`, so there is no
#    branch field left to read — this is exactly the case that breaks the
#    commit-message backends, and the only one where free text is all we have.
#    The reference must begin at a word boundary that is NOT `/`: that keeps
#    `release: merge release/1.15.0 into main (#614)` while rejecting a branch
#    like `feature/release-1.16.0-prep`, whose version belongs to nobody.
if [ -z "${derived}" ] &&
   [[ "${SUBJECT}" =~ (^|[[:space:]\"\'\(\[])(release|releases|hotfix|hotfixes)[/-]v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
  derived="${BASH_REMATCH[3]}"
fi

if [ -z "${derived}" ]; then
  echo "No release/hotfix branch named in HEAD's subject; leaving the version to the configured tool." >&2
  echo "  subject: ${SUBJECT}" >&2
  exit 0
fi

# Only ever move the release line forward. Without this, a revert of the merge
# ("Revert \"Merge pull request #614 from org/release/1.15.0\""), a merge back
# into the trunk, or a stray mention in a PR title re-pins an already-published
# version; the tag then exists, push-release-tag.sh treats that as a no-op, and
# the push publishes nothing at all — silently. Same strict X.Y.Z filtering as
# force-bump-version.sh: a prerelease or leading-zero tag is not a baseline.
LATEST=$(git tag -l "${PREFIX}*" 2>/dev/null | while IFS= read -r tag; do
  rest="${tag#"${PREFIX}"}"
  if [[ "${rest}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    printf '%s\n' "${rest}"
  fi
done | sort -V | tail -1)

if [ -n "${LATEST}" ]; then
  highest=$(printf '%s\n%s\n' "${LATEST}" "${derived}" | sort -V | tail -1)
  if [ "${derived}" = "${LATEST}" ] || [ "${highest}" != "${derived}" ]; then
    echo "::warning::HEAD's subject names release version ${derived}, but ${PREFIX}${LATEST} is already released. Ignoring the branch name and leaving the version to the configured tool." >&2
    echo "  subject: ${SUBJECT}" >&2
    exit 0
  fi
fi

echo "Release branch names version ${derived} (from: ${SUBJECT})" >&2
echo "${derived}"
