#!/usr/bin/env bash
# After a stable release from a release branch, open the pull request that
# merges that branch back into the main line (`release-branch-merge-back`).
#
# WHY THIS EXISTS. In a release-branch flow a hotfix lands on the release
# branch, because that branch is what production runs, and reaches the main
# line afterwards by merging the release branch into it: a regular merge, so
# the main line carries the fix's own commits and every later release contains
# it. Done by hand that step is easy to forget, and the obvious way to do it is
# the dangerous one. A pull request straight from `release/1.4.0` offers
# "Update branch" and "Resolve conflicts", and both commit the main line INTO
# the release branch: from then on the next hotfix candidate ships unreleased
# work from the main line. So the pull request comes from a branch of its own,
# `merge-back/release-1.4.0`, that starts at the release branch's head.
# Conflicts are resolved there, and the release branch keeps building exactly
# what is deployed.
#
# It runs after a stable release, which is the moment the line's fixes are in
# production, and finds the release branch from what was released:
#
#   - a run on the release branch itself (a release branch mapped straight to
#     the stable environment): that branch;
#   - a `promote-from` run: the release branch of the same major.minor that
#     contains the promoted commit (when several do, the highest one not
#     above the released version).
#
# Anything else is not a release-line release and is left alone, as is a
# release branch whose head the target already contains (a release with no
# hotfixes has nothing to bring back). Every run is idempotent: the
# merge-back branch is created once and moved forward when the release branch
# gains more commits, and one pull request stays open for it.
#
# Required env:
#   GH_TOKEN       token for the API calls (steps.auth.outputs.token). An App
#                  token, so the pull request starts the repository's checks.
#   REPO_FULL      owner/name.
#   TARGET         branch to merge back into (already resolved from @default).
#   VERSION        the stable version just released, without prefix.
#
# Optional env:
#   TAG                    the released tag, for the pull request text.
#   REF_NAME               the branch the workflow ran on (github.ref_name).
#   PROMOTE_SOURCE_COMMIT  the promoted commit (steps.promote-source.outputs.commit).
#   GITHUB_OUTPUT          receives `merge-back-pr` (the pull request URL).
#
# Exit codes:
#   0 - the pull request is open, or there was nothing to merge back. A
#       problem after the release (a conflict the merge-back branch cannot
#       absorb, a refused API call) is a warning: the release itself is out.
#   1 - unusable inputs.

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO_FULL:?REPO_FULL is required}"
: "${TARGET:?TARGET is required}"
: "${VERSION:?VERSION is required}"

TAG="${TAG:-${VERSION}}"
REF_NAME="${REF_NAME:-}"
PROMOTE_SOURCE_COMMIT="${PROMOTE_SOURCE_COMMIT:-}"

NUM='(0|[1-9][0-9]*)'
# The tail is held to characters that are safe in an API path, since the
# branch name ends up in one.
LINE_RE="^(release|releases|hotfix|hotfixes)[/-]v?${NUM}\.${NUM}\.${NUM}([^0-9/][-A-Za-z0-9._]*)?$"

emit() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >> "${GITHUB_OUTPUT}"
  fi
}

warn() {
  echo "::warning::release-branch-merge-back: $1"
}

if ! [[ "${VERSION}" =~ ^${NUM}\.${NUM}\.${NUM}$ ]]; then
  echo "release-branch-merge-back: ${VERSION} is not a stable version; nothing to merge back."
  exit 0
fi
V_MAJOR="${BASH_REMATCH[1]}"
V_MINOR="${BASH_REMATCH[2]}"
V_PATCH="${BASH_REMATCH[3]}"

# ── The release branch ──────────────────────────────────────────────────────
BRANCH=""
if [[ "${REF_NAME}" =~ ${LINE_RE} ]] && [ "${BASH_REMATCH[2]}" == "${V_MAJOR}" ] && [ "${BASH_REMATCH[3]}" == "${V_MINOR}" ]; then
  BRANCH="${REF_NAME}"
fi
if [ -z "${BRANCH}" ] && [ -n "${PROMOTE_SOURCE_COMMIT}" ]; then
  BEST_PATCH=""
  while IFS= read -r ref; do
    candidate="${ref#origin/}"
    [[ "${candidate}" =~ ${LINE_RE} ]] || continue
    [ "${BASH_REMATCH[2]}" == "${V_MAJOR}" ] && [ "${BASH_REMATCH[3]}" == "${V_MINOR}" ] || continue
    p="${BASH_REMATCH[4]}"
    [ "${p}" -le "${V_PATCH}" ] || continue
    if [ -z "${BEST_PATCH}" ] || [ "${p}" -gt "${BEST_PATCH}" ]; then
      BEST_PATCH="${p}"
      BRANCH="${candidate}"
    fi
  done < <(git branch -r --contains "${PROMOTE_SOURCE_COMMIT}" --format='%(refname:short)' 2>/dev/null || true)
fi

if [ -z "${BRANCH}" ]; then
  echo "release-branch-merge-back: ${TAG} was not released from a release branch; nothing to merge back."
  exit 0
fi
if [ "${BRANCH}" == "${TARGET}" ]; then
  echo "release-branch-merge-back: ${BRANCH} is the merge-back target itself; nothing to do."
  exit 0
fi

# ── Anything to bring back? ─────────────────────────────────────────────────
# compare/A...B says how B relates to A: "behind" or "identical" means A
# already contains B.
compare_status() {
  gh api "repos/${REPO_FULL}/compare/$1...$2" --jq '.status' 2>/dev/null
}

RELEASE_HEAD=$(gh api "repos/${REPO_FULL}/git/ref/heads/${BRANCH}" --jq '.object.sha' 2>/dev/null) || RELEASE_HEAD=""
if [ -z "${RELEASE_HEAD}" ]; then
  warn "could not read the head of ${BRANCH}; no merge-back pull request was opened."
  exit 0
fi

if ! STATUS=$(compare_status "${TARGET}" "${RELEASE_HEAD}"); then
  warn "could not compare ${BRANCH} with ${TARGET}; no merge-back pull request was opened."
  exit 0
fi
case "${STATUS}" in
  behind|identical)
    echo "release-branch-merge-back: ${TARGET} already contains everything on ${BRANCH}; nothing to merge back."
    exit 0
    ;;
esac

# ── The merge-back branch ───────────────────────────────────────────────────
MB="merge-back/${BRANCH//\//-}"
MB_HEAD=$(gh api "repos/${REPO_FULL}/git/ref/heads/${MB}" --jq '.object.sha' 2>/dev/null) || MB_HEAD=""

if [ -z "${MB_HEAD}" ]; then
  if ! ERR=$(gh api -X POST "repos/${REPO_FULL}/git/refs" \
       -f ref="refs/heads/${MB}" -f sha="${RELEASE_HEAD}" --silent 2>&1); then
    warn "could not create ${MB}: $(head -1 <<< "${ERR}"). Merge ${BRANCH} into ${TARGET} by hand, with a merge commit."
    exit 0
  fi
  echo "Created ${MB} on ${RELEASE_HEAD:0:12}."
elif [ "${MB_HEAD}" != "${RELEASE_HEAD}" ]; then
  MB_STATUS=$(compare_status "${MB_HEAD}" "${RELEASE_HEAD}") || MB_STATUS=""
  case "${MB_STATUS}" in
    behind|identical)
      echo "${MB} already contains ${BRANCH}."
      ;;
    ahead)
      # Nothing but release commits on it yet: move it forward.
      if ! ERR=$(gh api -X PATCH "repos/${REPO_FULL}/git/refs/heads/${MB}" \
           -f sha="${RELEASE_HEAD}" -F force=false --silent 2>&1); then
        warn "could not move ${MB} to ${RELEASE_HEAD:0:12}: $(head -1 <<< "${ERR}")"
      else
        echo "Moved ${MB} forward to ${RELEASE_HEAD:0:12}."
      fi
      ;;
    *)
      # It carries commits of its own, a conflict resolution most likely, so
      # the release branch's new commits are merged into it.
      if ! ERR=$(gh api -X POST "repos/${REPO_FULL}/merges" -f base="${MB}" -f head="${RELEASE_HEAD}" \
           -f commit_message="Merge ${BRANCH} into ${MB}" --silent 2>&1); then
        warn "could not bring ${BRANCH}'s new commits into ${MB}: $(head -1 <<< "${ERR}"). Merge ${BRANCH} into ${MB} by hand; never the other way round."
      else
        echo "Merged ${BRANCH} into ${MB}."
      fi
      ;;
  esac
fi

# ── The pull request ────────────────────────────────────────────────────────
EXISTING=$(gh pr list --repo "${REPO_FULL}" --head "${MB}" --base "${TARGET}" --state open \
  --json url --jq '.[0].url // empty' 2>/dev/null) || EXISTING=""
if [ -n "${EXISTING}" ]; then
  echo "Merge-back pull request already open: ${EXISTING}"
  emit merge-back-pr "${EXISTING}"
  exit 0
fi

MERGE_COMMITS=$(gh api "repos/${REPO_FULL}" --jq '.allow_merge_commit' 2>/dev/null) || MERGE_COMMITS=""
NOTE=""
if [ "${MERGE_COMMITS}" == "false" ]; then
  NOTE=$'\n\n'"> This repository does not allow merge commits. Allow them (Settings → General → Pull Requests), or this branch's history cannot reach \`${TARGET}\` as it is."
  warn "this repository does not allow merge commits, so ${MB} cannot be merged into ${TARGET} as a merge commit."
fi

BODY="Merges \`${BRANCH}\` into \`${TARGET}\`, so what was released from it (up to \`${TAG}\`) is in every release cut from \`${TARGET}\` from now on.

**Merge it with \"Create a merge commit\".** A merge commit carries the release branch's history into \`${TARGET}\`. A squash or rebase copies the changes instead, and the next merge-back from this line replays them.

This pull request comes from \`${MB}\`, which starts at \`${BRANCH}\`. Resolve any conflict with \`${TARGET}\` here, never on \`${BRANCH}\`: the release branch has to keep building exactly what is deployed. Diatreme moves this branch forward when another fix is released from \`${BRANCH}\`.${NOTE}"

if ! URL=$(gh pr create --repo "${REPO_FULL}" --base "${TARGET}" --head "${MB}" \
     --title "Merge ${BRANCH} into ${TARGET}" --body "${BODY}" 2>&1); then
  warn "could not open the merge-back pull request: $(tail -1 <<< "${URL}"). Open one from ${MB} into ${TARGET} by hand."
  exit 0
fi
URL=$(tail -1 <<< "${URL}")
echo "Opened merge-back pull request: ${URL}"
emit merge-back-pr "${URL}"
