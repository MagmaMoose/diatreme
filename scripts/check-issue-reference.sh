#!/usr/bin/env bash
# Hold a pull request to referencing an issue (`issue-reference`, mode: ci).
#
# WHY THIS EXISTS. A team that wants every change on its main line traceable to
# an issue ("Fix null check on export endpoint #4567") can only check that
# before the merge, and what reaches the main line depends on how the pull
# request is merged:
#
#   squash, merge commit  the pull request's TITLE lands in the history (the
#                         squash commit's subject, the merge commit's body), so
#                         `title` checks that;
#   rebase                every commit lands as it is, so `commits` checks each
#                         one, apart from merge commits (updating the branch
#                         from its base adds those, and nobody writes them).
#
# Both may be asked for together (`title, commits`).
#
# A reference is anything GitHub links to an issue: `#123`, `GH-123`,
# `owner/repo#123`, or an issue URL (`.../issues/123`). A `#` straight after a
# letter or digit (`C#12`, `&#39;`) is not one.
#
# Bot branches (dependabot/, renovate/) and Diatreme's own (the promote prefix,
# merge-back/) are not checked: nobody can put an issue into what a bot or a
# release writes.
#
# Env:
#   ISSUE_REFERENCE        what to check: `title`, `commits`, or both,
#                          comma- or space-separated.
#   PR_TITLE               the pull request's title.
#   BASE_SHA, HEAD_SHA     the pull request's base and head commits; the commits
#                          checked are HEAD_SHA's that BASE_SHA does not have.
#   HEAD_REF               the pull request's head branch.
#   PROMOTE_BRANCH_PREFIX  promotion PR prefix (default `promote`).
#
# Exit codes:
#   0 - every checked part references an issue, or the branch is exempt.
#   1 - something does not, or the input is unusable.

set -euo pipefail

ISSUE_REFERENCE="${ISSUE_REFERENCE:-}"
PR_TITLE="${PR_TITLE:-}"
BASE_SHA="${BASE_SHA:-}"
HEAD_SHA="${HEAD_SHA:-}"
HEAD_REF="${HEAD_REF:-}"
PROMOTE_PREFIX="${PROMOTE_BRANCH_PREFIX:-promote}"

check_title=false
check_commits=false
for part in $(printf '%s' "${ISSUE_REFERENCE}" | tr ',' ' '); do
  case "${part}" in
    title) check_title=true ;;
    commits) check_commits=true ;;
    *)
      echo "::error::issue-reference: unknown value '${part}'. Use title, commits, or both."
      exit 1
      ;;
  esac
done
if [ "${check_title}" != "true" ] && [ "${check_commits}" != "true" ]; then
  echo "::error::issue-reference is set but names nothing to check. Use title, commits, or both."
  exit 1
fi

case "${HEAD_REF}" in
  dependabot/*|renovate/*|"${PROMOTE_PREFIX}"/*|merge-back/*)
    echo "Branch '${HEAD_REF}' is written by a bot or by Diatreme; issue references are not checked."
    exit 0
    ;;
esac

# Does this text reference an issue?
references_issue() {
  local text="$1"
  [[ "${text}" =~ (^|[^A-Za-z0-9_\&])#[0-9]+ ]] && return 0
  [[ "${text}" =~ [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+ ]] && return 0
  [[ "${text}" =~ (^|[^A-Za-z0-9])[Gg][Hh]-[0-9]+ ]] && return 0
  [[ "${text}" =~ /issues/[0-9]+ ]] && return 0
  return 1
}

FORMS="#123, GH-123, owner/repo#123 or an issue URL"
failed=false

if [ "${check_title}" == "true" ]; then
  if references_issue "${PR_TITLE}"; then
    echo "The pull request title references an issue."
  else
    echo "::error::The pull request title does not reference an issue: '${PR_TITLE}'. Add one (${FORMS}), e.g. 'Fix null check on export endpoint #4567'."
    failed=true
  fi
fi

if [ "${check_commits}" == "true" ]; then
  if [ -z "${BASE_SHA}" ] || [ -z "${HEAD_SHA}" ] \
     || ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null \
     || ! git cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null; then
    echo "::error::issue-reference: the pull request's base and head commits are not in this checkout, so its commits cannot be read."
    exit 1
  fi
  missing=()
  count=0
  while IFS= read -r -d $'\x1e' record; do
    record="${record#$'\n'}"
    [ -n "${record}" ] || continue
    sha="${record%%$'\x1f'*}"
    message="${record#*$'\x1f'}"
    count=$((count + 1))
    if ! references_issue "${message}"; then
      missing+=("${sha:0:12} ${message%%$'\n'*}")
    fi
  done < <(git log --no-merges --format=$'%H\x1f%B\x1e' "${BASE_SHA}..${HEAD_SHA}")
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "::error::${#missing[@]} of ${count} commit(s) do not reference an issue (${FORMS}):"
    for m in "${missing[@]}"; do
      echo "::error::  ${m}"
    done
    echo "Reword them (git rebase -i, then reword) and push again."
    failed=true
  else
    echo "All ${count} commit(s) reference an issue."
  fi
fi

[ "${failed}" == "false" ]
