#!/usr/bin/env bash
# Does a change touch nothing but the overlays in `deploy-pr-targets`?
#
# Two callers, two consequences:
#   detect  `mode: ci` on a pull request. A deploy PR only moves tags, so there
#           is no image to build: the build and scan steps are skipped and the
#           `diatreme` check still reports.
#   guard   `mode: release` on a push. Merging a deploy PR is a deployment, not
#           a release, and cutting a version for it would open a deploy PR for
#           that version in turn. The workflow's push trigger is meant to
#           paths-ignore the overlays; when it does not, this refuses the run
#           before anything is tagged.
#
# An empty file list, or one that cannot be read, is never "deploy only": the
# safe answer for both callers is to carry on as if deploys were off.
#
# Required env:
#   GH_TOKEN, REPO_FULL, DEPLOY_PR_TARGETS
#   CHECK        detect | guard
#   EVENT_NAME   pull_request (with PR_NUMBER) or push (with BEFORE and AFTER)
# Optional env:
#   ENVIRONMENTS, GITHUB_OUTPUT (receives deploy_only=true|false)

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO_FULL:?REPO_FULL is required}"
: "${CHECK:?CHECK is required (detect or guard)}"
: "${EVENT_NAME:?EVENT_NAME is required}"

emit() {
  echo "Deploy-only change: $1"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "deploy_only=$1" >> "${GITHUB_OUTPUT}"
  fi
}

paths=$("${HERE}/deploy-targets.sh" paths)

files=""
case "${EVENT_NAME}" in
  pull_request)
    : "${PR_NUMBER:?PR_NUMBER is required for a pull_request}"
    files=$(gh api "repos/${REPO_FULL}/pulls/${PR_NUMBER}/files?per_page=100" --paginate \
      --jq '.[] | .filename, (.previous_filename // empty)' 2>/dev/null) || files=""
    ;;
  push)
    # A new branch has no `before` to compare with.
    if [ -n "${BEFORE:-}" ] && [ -n "${AFTER:-}" ] && ! [[ "${BEFORE}" =~ ^0+$ ]]; then
      # compare lists at most 300 files; a change that size is not a deploy.
      files=$(gh api "repos/${REPO_FULL}/compare/${BEFORE}...${AFTER}" \
        --jq 'if (.files | length) >= 300 then empty else (.files[] | .filename, (.previous_filename // empty)) end' \
        2>/dev/null) || files=""
    fi
    ;;
esac

deploy_only=false
if [ -n "${files}" ]; then
  deploy_only=true
  while IFS= read -r file; do
    [ -n "${file}" ] || continue
    inside=false
    while IFS= read -r p; do
      case "${file}" in "${p}"/*) inside=true; break ;; esac
    done <<<"${paths}"
    if [ "${inside}" != "true" ]; then
      deploy_only=false
      break
    fi
  done <<<"${files}"
fi
emit "${deploy_only}"

if [ "${CHECK}" = "guard" ] && [ "${deploy_only}" = "true" ]; then
  echo "::error::[deploy-pr] This push changes nothing but deploy overlays ($(printf '%s' "${paths}" | tr '\n' ' ')). Merging a deploy PR is a deployment, not a release, and releasing it would open a deploy PR for the new version in turn. Add the overlays to this workflow's push paths-ignore, e.g. paths-ignore: ['$(printf '%s' "${paths}" | head -n 1)/**']. Nothing was tagged."
  exit 1
fi
