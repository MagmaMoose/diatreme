#!/usr/bin/env bash
# Does a change touch nothing but the directories in `deploy-paths`?
#
# Those are where deployments are written rather than code: the kustomize
# overlays a deploy tool (Tremvok's `gitops-pr`) moves image tags in, by pull
# request. Two callers, two consequences:
#   detect  `mode: ci` on a pull request. A deploy PR only moves tags, so there
#           is no image to build: the build and scan steps are skipped and the
#           `diatreme` check still reports.
#   guard   `mode: release` on a push. Merging a deploy PR is a deployment, not
#           a release, and cutting a version for it would publish a release that
#           opens a deploy PR for that version in turn. The workflow's push
#           trigger is meant to paths-ignore the directories; when it does not,
#           this refuses the run before anything is tagged.
#
# An empty file list, or one that cannot be read, is never "deploy only": the
# safe answer for both callers is to carry on as if deploys were off.
#
# Required env:
#   GH_TOKEN, REPO_FULL
#   DEPLOY_PATHS JSON array of directories, relative to the repository root
#   CHECK        detect | guard
#   EVENT_NAME   pull_request (with PR_NUMBER) or push (with BEFORE and AFTER)
# Optional env:
#   GITHUB_OUTPUT (receives deploy_only=true|false)

set -euo pipefail

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

# One directory per line, normalised (no leading `./`, no trailing `/`). A value
# that is not a list of relative directories stops the run: it is read before
# anything is tagged, and a typo here must not quietly disable the guard.
DEPLOY_PATHS="${DEPLOY_PATHS:-}"
jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and . != "")' \
  <<<"${DEPLOY_PATHS}" >/dev/null 2>&1 \
  || { echo "::error::deploy-paths must be a JSON array of directories, e.g. [\"k8s/overlays/acc\", \"k8s/overlays/prd\"], got: ${DEPLOY_PATHS}"; exit 1; }
paths=$(jq -r '.[] | sub("^(\\./)+"; "") | sub("/+$"; "")' <<<"${DEPLOY_PATHS}")
while IFS= read -r p; do
  case "${p}" in
    ''|/*) echo "::error::deploy-paths: '${p}' must be a directory relative to the repository root"; exit 1 ;;
  esac
  case "/${p}/" in
    */../*|*/./*) echo "::error::deploy-paths: '${p}' must not contain '.' or '..' segments"; exit 1 ;;
  esac
done <<<"${paths}"

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
  echo "::error::[deploy-paths] This push changes nothing but deploy-paths ($(printf '%s' "${paths}" | tr '\n' ' ')). Merging a deploy PR is a deployment, not a release, and releasing it would open a deploy PR for the new version in turn. Add those directories to this workflow's push paths-ignore, e.g. paths-ignore: ['$(printf '%s' "${paths}" | head -n 1)/**']. Nothing was tagged."
  exit 1
fi
