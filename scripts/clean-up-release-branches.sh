#!/usr/bin/env bash
# After a stable release, delete the release branches of older lines that have
# nothing left to give (`release-branch-cleanup`).
#
# WHY THIS EXISTS. A release-branch flow cuts one branch per release, and the
# previous one stops mattering once its successor is live. Left alone they pile
# up, and an old `release/1.2.0` sitting next to `release/1.5.0` invites a fix
# into the wrong line. Deleting one loses nothing as long as two things hold,
# and this script checks both before it deletes anything:
#
#   - the line is OLDER than the one just released to production, by
#     major.minor. The line being released stays, and so does any newer line
#     still on its way through acceptance;
#   - the target branch (the merge-back target, else the default branch)
#     already contains its head, so no fix exists only on that branch. A line
#     whose hotfix has not been merged back is kept, with a notice.
#
# What a deleted line shipped stays reachable through its tags, and
# `mode: cut-release-branch` run on its latest tag recreates the branch to
# patch it. Only the `release/` and `releases/` families are considered, and
# only names that carry a version. A merge-back branch of a deleted line is
# deleted with it once the target contains it.
#
# Required env:
#   GH_TOKEN    token for the API calls.
#   REPO_FULL   owner/name.
#   TARGET      branch that must contain a line before it is deleted.
#   VERSION     the stable version just released, without prefix.
#
# Optional env:
#   GITHUB_OUTPUT  receives `release-branches-deleted` (a count).
#
# Exit codes:
#   0 - always, once the inputs are usable. A branch that cannot be deleted
#       (a ruleset protecting it, say) is a warning: the release is out.
#   1 - unusable inputs.

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO_FULL:?REPO_FULL is required}"
: "${TARGET:?TARGET is required}"
: "${VERSION:?VERSION is required}"

NUM='(0|[1-9][0-9]*)'
LINE_RE="^(release|releases)[/-]v?${NUM}\.${NUM}\.${NUM}([^0-9/][-A-Za-z0-9._]*)?$"

emit() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >> "${GITHUB_OUTPUT}"
  fi
}

if ! [[ "${VERSION}" =~ ^${NUM}\.${NUM}\.${NUM}$ ]]; then
  echo "release-branch-cleanup: ${VERSION} is not a stable version; nothing to clean up."
  emit release-branches-deleted 0
  exit 0
fi
V_MAJOR="${BASH_REMATCH[1]}"
V_MINOR="${BASH_REMATCH[2]}"

# Does TARGET contain this commit? compare/TARGET...sha is "behind" or
# "identical" exactly when it does. Anything unanswerable counts as no.
contained() {
  local status
  status=$(gh api "repos/${REPO_FULL}/compare/${TARGET}...$1" --jq '.status' 2>/dev/null) || return 1
  [ "${status}" == "behind" ] || [ "${status}" == "identical" ]
}

delete_branch() {
  local err
  if err=$(gh api -X DELETE "repos/${REPO_FULL}/git/refs/heads/$1" --silent 2>&1); then
    return 0
  fi
  echo "::warning::release-branch-cleanup: could not delete $1: $(head -1 <<< "${err}")"
  return 1
}

DELETED=0
while IFS=' ' read -r ref sha; do
  branch="${ref#origin/}"
  [[ "${branch}" =~ ${LINE_RE} ]] || continue
  major="${BASH_REMATCH[2]}"
  minor="${BASH_REMATCH[3]}"
  if [ "${major}" -gt "${V_MAJOR}" ] || { [ "${major}" -eq "${V_MAJOR}" ] && [ "${minor}" -ge "${V_MINOR}" ]; }; then
    continue
  fi
  if ! contained "${sha}"; then
    echo "::notice::release-branch-cleanup: keeping ${branch}: it has commits ${TARGET} does not. Merge it back first."
    continue
  fi
  if delete_branch "${branch}"; then
    echo "Deleted ${branch}, superseded by ${VERSION} and fully merged into ${TARGET}."
    DELETED=$((DELETED + 1))
    mb="merge-back/${branch//\//-}"
    mb_sha=$(git rev-parse -q --verify "refs/remotes/origin/${mb}" 2>/dev/null || true)
    if [ -n "${mb_sha}" ] && contained "${mb_sha}" && delete_branch "${mb}"; then
      echo "Deleted ${mb}."
    fi
  fi
done < <(git for-each-ref --format='%(refname:short) %(objectname)' refs/remotes/origin 2>/dev/null || true)

emit release-branches-deleted "${DELETED}"
