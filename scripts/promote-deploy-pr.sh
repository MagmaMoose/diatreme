#!/usr/bin/env bash
# `mode: deploy-promote`: when a deploy PR merges, propose the same tags for
# the overlay that follows it in `deploy-pr-targets`.
#
# Meant for a `pull_request` `closed` event. A pull request that was closed
# without merging, or whose head is not `<prefix>/<overlay>/<tag>` for an
# overlay in deploy-pr-targets, is ignored, and so is the last overlay in its
# list, since nothing follows it. None of those is an error: the same workflow
# receives every closed pull request in the repository. Nor is an empty
# deploy-pr-targets: a workflow shared across repositories can route every
# closed pull request here, and a repository that has not opted in has
# nothing to promote.
#
# What is promoted is what the merge changed, read from the merged overlay
# itself: its images[] tags at the merge commit against the merge commit's
# first parent. That is what the overlay runs now, a reviewer's edit on the
# branch included, and nothing else: an image the PR did not move is not
# carried along.
#
# Required env:
#   GH_TOKEN, REPO_FULL   as for open-deploy-pr.sh
# Optional env:
#   DEPLOY_PR_TARGETS     the deploy-pr-targets input; empty turns this off
#   ENVIRONMENTS          the environments input, to validate against
#   BRANCH_PREFIX         default "deploy"
#   PR_NUMBER             the pull request; read from GITHUB_EVENT_PATH if empty
#   GITHUB_EVENT_PATH     the event payload
#   GITHUB_OUTPUT         receives what open-deploy-pr.sh emits

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

note() { echo "::notice::[deploy-promote] $*"; }
warn() { echo "::warning::[deploy-promote] $*"; }
err()  { echo "::error::[deploy-promote] $*"; exit 1; }

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO_FULL:?REPO_FULL is required}"
if [ -z "${DEPLOY_PR_TARGETS:-}" ]; then
  note "deploy-pr-targets is empty, so deploy PRs are off here; nothing to promote"
  exit 0
fi
"${HERE}/deploy-targets.sh" validate

PREFIX="${BRANCH_PREFIX:-deploy}"
PREFIX="${PREFIX%/}"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

if [ -n "${PR_NUMBER:-}" ]; then
  gh api "repos/${REPO_FULL}/pulls/${PR_NUMBER}" > "${WORK}/pr.json" \
    || err "cannot read pull request #${PR_NUMBER}"
elif [ -n "${GITHUB_EVENT_PATH:-}" ] && jq -e '.pull_request' "${GITHUB_EVENT_PATH}" >/dev/null 2>&1; then
  jq '.pull_request' "${GITHUB_EVENT_PATH}" > "${WORK}/pr.json"
else
  err "mode deploy-promote runs on a pull_request event, or needs pr-number"
fi

number=$(jq -r '.number' "${WORK}/pr.json")
merged=$(jq -r '.merged // false' "${WORK}/pr.json")
head=$(jq -r '.head.ref' "${WORK}/pr.json")
base=$(jq -r '.base.ref' "${WORK}/pr.json")
merge_sha=$(jq -r '.merge_commit_sha // empty' "${WORK}/pr.json")

if [ "${merged}" != "true" ]; then
  note "#${number} was not merged; nothing to promote"
  exit 0
fi
case "${head}" in
  "${PREFIX}"/*/*) ;;
  *) note "#${number} (${head}) is not a deploy PR; nothing to promote"; exit 0 ;;
esac
rest="${head#"${PREFIX}"/}"
name="${rest%%/*}"

source_overlay=$("${HERE}/deploy-targets.sh" path "${name}")
if [ -z "${source_overlay}" ]; then
  warn "#${number} came from ${head}, but deploy-pr-targets has no overlay called '${name}'; nothing to promote"
  exit 0
fi
next_overlay=$("${HERE}/deploy-targets.sh" next "${name}")
if [ -z "${next_overlay}" ]; then
  note "${source_overlay} is the last overlay in its list; nothing to promote"
  exit 0
fi
after_next=$("${HERE}/deploy-targets.sh" next "${next_overlay##*/}")
[ -n "${merge_sha}" ] || err "#${number} is merged but has no merge commit"

parent=$(gh api "repos/${REPO_FULL}/commits/${merge_sha}" --jq '.parents[0].sha') \
  || err "cannot read merge commit ${merge_sha}"

# The overlay's images at a commit, as {repository: tag}. An overlay that did
# not exist yet reads as no images.
images_at() {
  local f
  for f in kustomization.yaml kustomization.yml Kustomization; do
    if gh api "repos/${REPO_FULL}/contents/${source_overlay}/${f}?ref=$1" --jq '.content' > "${WORK}/b64" 2>/dev/null; then
      base64 --decode < "${WORK}/b64" \
        | yq -o=json -I=0 '[(.images // [])[] | select(has("newTag")) | {"key": (.newName // .name), "value": (.newTag | tostring)}] | from_entries' \
        | tr -d '\r'
      return 0
    fi
  done
  echo '{}'
}

before=$(images_at "${parent}")
after=$(images_at "${merge_sha}")
changed=$(jq -cn --argjson b "${before}" --argjson a "${after}" '$a | with_entries(select($b[.key] != .value))')

if [ "$(jq 'length' <<<"${changed}")" = "0" ]; then
  warn "#${number} merged without moving an image tag in ${source_overlay}; nothing to promote"
  exit 0
fi

# One tag names the PR. A release moves every image to the same tag; should
# a reviewer have left them apart, the newest one names it.
tag=$(jq -r '.[]' <<<"${changed}" | sort -V | tail -n 1)
echo "Promoting ${changed} from ${source_overlay} (#${number}) to ${next_overlay}"

OVERLAY="${next_overlay}" \
BASE_BRANCH="${base}" \
IMAGES="${changed}" \
TAG="${tag}" \
BRANCH_PREFIX="${PREFIX}" \
NEXT_OVERLAY="${after_next##*/}" \
SOURCE_NOTE="**${name}** runs it since #${number} merged." \
  "${HERE}/open-deploy-pr.sh"
