#!/usr/bin/env bash
# Open, refresh or retire the deploy pull request for one kustomize overlay.
#
# A deploy PR moves `newTag` for the given images in one overlay's
# kustomization file, on a branch of its own: `<prefix>/<overlay>/<tag>`.
# Merging it is the deployment, because the overlay is what the cluster's
# GitOps controller applies.
#
# One open deploy PR per overlay:
#   - a PR for another tag is closed as superseded, and its branch deleted;
#   - a re-run for the same tag refreshes the open PR's title and body;
#   - an overlay that already runs the tag gets no PR, and open PRs for an
#     older tag are closed, since merging them would roll it back;
#   - an open PR for a NEWER tag is left alone and nothing is opened: two
#     promotions can race, and the older one must not replace the newer.
#
# The commit is written with the contents API on a branch created at the base
# tip. An existing PR branch is never reset: GitHub marks a pull request as
# merged the moment its head points at a commit the base already contains, so
# resetting an open PR's branch to the base, to commit on top of it, closes the
# PR as merged with nothing in it. A new tag gets a new branch instead.
#
# Required env:
#   GH_TOKEN       contents: write and pull-requests: write. An App token, so
#                  the PR starts the repository's workflows (a PR opened with
#                  GITHUB_TOKEN starts none, and its required checks never run).
#   REPO_FULL      owner/repo
#   OVERLAY        overlay directory, relative to the repository root
#   BASE_BRANCH    branch the deploy PR targets
#   IMAGES         JSON object, image repository -> tag to set
#   TAG            the tag the PR is named after (branch and title)
# Optional env:
#   BRANCH_PREFIX  default "deploy"
#   NEXT_OVERLAY   name of the overlay whose PR opens when this one merges
#   SOURCE_NOTE    one markdown line saying where the tag comes from
#   GITHUB_OUTPUT  receives url, number and result
#                  (created | refreshed | unchanged | skipped)
#
# Exit codes: 0 done (including nothing to do), 1 bad input or a failed call.

set -euo pipefail

log()  { echo "[deploy-pr] $*"; }
note() { echo "::notice::[deploy-pr] $*"; }
warn() { echo "::warning::[deploy-pr] $*"; }
err()  { echo "::error::[deploy-pr] $*"; exit 1; }

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO_FULL:?REPO_FULL is required}"
: "${OVERLAY:?OVERLAY is required}"
: "${BASE_BRANCH:?BASE_BRANCH is required}"
: "${IMAGES:?IMAGES is required}"
: "${TAG:?TAG is required}"

PREFIX="${BRANCH_PREFIX:-deploy}"
PREFIX="${PREFIX%/}"
OVERLAY="${OVERLAY#./}"
OVERLAY="${OVERLAY%/}"
NAME="${OVERLAY##*/}"
BRANCH="${PREFIX}/${NAME}/${TAG}"
TITLE="chore(deploy): ${TAG} to ${NAME}"

# The Docker tag grammar. It also keeps every tag safe inside the sed
# replacement below, which it is spliced into.
TAG_RE='^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$'
[[ "${TAG}" =~ ${TAG_RE} ]] || err "'${TAG}' is not a valid image tag"
jq -e 'type == "object" and length > 0 and all(.[]; type == "string")' \
  <<<"${IMAGES}" >/dev/null 2>&1 \
  || err "IMAGES must be a non-empty JSON object from image repository to tag, got: ${IMAGES}"
while IFS= read -r t; do
  [[ "${t}" =~ ${TAG_RE} ]] || err "'${t}' is not a valid image tag"
done < <(jq -r '.[]' <<<"${IMAGES}")

emit() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT}"
  fi
}

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# `sort -V` puts 1.2.3 before 1.2.3-rc.1, the reverse of SemVer. Tags in one
# overlay's chain share a channel, so it only ever compares like with like.
version_gt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

# yq prints CRLF on Windows runners.
yqv() { yq "$@" | tr -d '\r'; }

# set_tag FILE REPO TAG: point the images[] entry for REPO at TAG, touching
# nothing but the value on its newTag line, so a trailing comment (a Flux
# `$imagepolicy` marker, say) and the file's layout survive.
# Returns 0 on success (already at TAG included), 3 when the file has no entry
# for REPO, 1 on an entry it will not move.
set_tag() {
  local file="$1" repo="$2" tag="$3" sel count line
  sel='(.images // [])[] | select((.newName // .name) == strenv(DEPLOY_REPO))'
  export DEPLOY_REPO="${repo}"
  count=$(yqv "[${sel}] | length" "${file}")
  [ "${count}" != "0" ] || return 3
  if [ "${count}" != "1" ]; then
    echo "::error::[deploy-pr] ${file} has ${count} images[] entries for ${repo}; expected one"
    return 1
  fi
  if [ "$(yqv "${sel} | has(\"digest\")" "${file}")" = "true" ]; then
    echo "::error::[deploy-pr] ${file} pins ${repo} by digest, which outranks newTag; remove the digest to deploy by tag"
    return 1
  fi
  if [ "$(yqv "${sel} | has(\"newTag\")" "${file}")" != "true" ]; then
    echo "::error::[deploy-pr] the images[] entry for ${repo} in ${file} has no newTag to move"
    return 1
  fi
  line=$(yqv "${sel} | .newTag | line" "${file}")
  sed -E "${line}s/^([[:space:]]*(-[[:space:]]+)?newTag:[[:space:]]*)([\"']?)[A-Za-z0-9_][A-Za-z0-9._-]*([\"']?)/\\1\\3${tag}\\4/" \
    "${file}" > "${file}.new"
  mv "${file}.new" "${file}"
  if [ "$(yqv "${sel} | .newTag" "${file}")" != "${tag}" ]; then
    echo "::error::[deploy-pr] could not rewrite newTag for ${repo} on line ${line} of ${file}; only a block-style 'newTag: <tag>' line is supported"
    return 1
  fi
}

# ── Read the overlay at the base tip ────────────────────────────────────────
BASE_SHA=$(gh api "repos/${REPO_FULL}/git/ref/heads/${BASE_BRANCH}" --jq '.object.sha') \
  || err "cannot read branch ${BASE_BRANCH} of ${REPO_FULL}"
[ -n "${BASE_SHA}" ] || err "branch ${BASE_BRANCH} of ${REPO_FULL} has no commit"

FILE=""
for f in kustomization.yaml kustomization.yml Kustomization; do
  if gh api "repos/${REPO_FULL}/contents/${OVERLAY}/${f}?ref=${BASE_SHA}" > "${WORK}/file.json" 2>/dev/null; then
    FILE="${OVERLAY}/${f}"
    break
  fi
done
[ -n "${FILE}" ] || err "no kustomization.yaml, kustomization.yml or Kustomization in ${OVERLAY} on ${BASE_BRANCH}"
BLOB_SHA=$(jq -r '.sha' "${WORK}/file.json")
jq -r '.content' "${WORK}/file.json" | base64 --decode > "${WORK}/before"
cp "${WORK}/before" "${WORK}/after"

# ── Move the tags ────────────────────────────────────────────────────────────
: > "${WORK}/changes.tsv"
matched=0
while IFS=$'\t' read -r repo tag; do
  old=$(DEPLOY_REPO="${repo}" yqv '(.images // [])[] | select((.newName // .name) == strenv(DEPLOY_REPO)) | .newTag' "${WORK}/after")
  rc=0
  set_tag "${WORK}/after" "${repo}" "${tag}" || rc=$?
  case "${rc}" in
    0) matched=$((matched + 1))
       [ "${old}" = "${tag}" ] || printf '%s\t%s\t%s\n' "${repo}" "${old}" "${tag}" >> "${WORK}/changes.tsv" ;;
    3) warn "${FILE} has no images[] entry for ${repo}; it is left out of this deploy" ;;
    *) exit 1 ;;
  esac
done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"${IMAGES}")

[ "${matched}" -gt 0 ] \
  || err "${FILE} has an images[] entry for none of: $(jq -r 'keys | join(", ")' <<<"${IMAGES}"). Its entries: $(yqv '[(.images // [])[] | (.newName // .name)] | join(", ")' "${WORK}/before")"

# ── Open deploy PRs for this overlay ────────────────────────────────────────
gh pr list --repo "${REPO_FULL}" --state open --base "${BASE_BRANCH}" --limit 100 \
  --json number,headRefName,url > "${WORK}/prs.json"
jq -c --arg p "${PREFIX}/${NAME}/" \
  '[.[] | select(.headRefName | startswith($p)) | . + {tag: (.headRefName | ltrimstr($p))}]' \
  "${WORK}/prs.json" > "${WORK}/open.json"

close_pr() {
  local number="$1" why="$2"
  log "closing #${number}: ${why}"
  gh pr close "${number}" --repo "${REPO_FULL}" --delete-branch --comment "${why}" >/dev/null \
    || warn "could not close #${number}"
}

if [ ! -s "${WORK}/changes.tsv" ]; then
  note "${OVERLAY} already runs ${TAG} on ${BASE_BRANCH}; no deploy PR needed"
  while IFS=$'\t' read -r number tag; do
    if ! version_gt "${tag}" "${TAG}"; then
      close_pr "${number}" "Closed by Diatreme: \`${OVERLAY}\` already runs \`${TAG}\` on \`${BASE_BRANCH}\`, so merging this would change nothing or roll it back."
    fi
  done < <(jq -r '.[] | "\(.number)\t\(.tag)"' "${WORK}/open.json")
  emit result unchanged
  exit 0
fi

# A deploy PR only ever moves an overlay forward. One that runs something newer
# was changed by hand (a hotfix straight to prd, say), and proposing the older
# tag would roll that back.
downgrades=$(while IFS=$'\t' read -r repo old new; do
    if version_gt "${old}" "${new}"; then printf '%s (%s, not %s) ' "${repo}" "${old}" "${new}"; fi
  done < "${WORK}/changes.tsv")
if [ -n "${downgrades}" ]; then
  note "${OVERLAY} on ${BASE_BRANCH} already runs a newer tag for ${downgrades}; not proposing ${TAG}"
  emit result skipped
  exit 0
fi

newer=$(jq -r --arg t "${TAG}" '.[] | select(.tag != $t) | "\(.number)\t\(.tag)"' "${WORK}/open.json" \
  | while IFS=$'\t' read -r number tag; do
      if version_gt "${tag}" "${TAG}"; then printf '#%s (%s) ' "${number}" "${tag}"; fi
    done)
if [ -n "${newer}" ]; then
  note "an open deploy PR for ${NAME} already proposes a newer tag: ${newer}; not opening one for ${TAG}"
  emit result skipped
  exit 0
fi

# ── The body ────────────────────────────────────────────────────────────────
{
  printf 'Deploys `%s` to **%s** by moving `%s`:\n\n' "${TAG}" "${NAME}" "${FILE}"
  printf '| Image | Now | After merge |\n| --- | --- | --- |\n'
  while IFS=$'\t' read -r repo old new; do
    printf '| `%s` | `%s` | `%s` |\n' "${repo}" "${old:-none}" "${new}"
  done < "${WORK}/changes.tsv"
  printf '\n'
  if [ -n "${SOURCE_NOTE:-}" ]; then
    printf '%s\n\n' "${SOURCE_NOTE}"
  fi
  printf 'Merging this is the deployment.'
  if [ -n "${NEXT_OVERLAY:-}" ]; then
    printf ' When it merges, Diatreme opens the same change for **%s**.' "${NEXT_OVERLAY}"
  fi
  printf '\n\n<sub>Opened by Diatreme. A newer tag for %s replaces this pull request, and its branch belongs to Diatreme: push changes to a branch of your own.</sub>\n' "${NAME}"
} > "${WORK}/body.md"

supersede_others() {
  local keep="$1" other
  while IFS= read -r other; do
    close_pr "${other}" "Superseded by #${keep} (\`${TAG}\`)."
  done < <(jq -r --arg b "${BRANCH}" '.[] | select(.headRefName != $b) | .number' "${WORK}/open.json")
}

same=$(jq -r --arg b "${BRANCH}" 'first(.[] | select(.headRefName == $b) | .number) // empty' "${WORK}/open.json")
if [ -n "${same}" ]; then
  gh pr edit "${same}" --repo "${REPO_FULL}" --title "${TITLE}" --body-file "${WORK}/body.md" >/dev/null
  url=$(jq -r --arg b "${BRANCH}" 'first(.[] | select(.headRefName == $b) | .url)' "${WORK}/open.json")
  log "refreshed #${same}: ${url}"
  supersede_others "${same}"
  emit url "${url}"
  emit number "${same}"
  emit result refreshed
  exit 0
fi

# ── A branch of its own, at the base tip ────────────────────────────────────
# A branch left over without an open PR (an earlier run that failed after
# pushing it, or a PR someone closed) is deleted and made again: with no open
# PR on it, removing it cannot close anything.
if gh api "repos/${REPO_FULL}/git/ref/heads/${BRANCH}" >/dev/null 2>&1; then
  log "deleting leftover branch ${BRANCH}"
  gh api -X DELETE "repos/${REPO_FULL}/git/refs/heads/${BRANCH}" >/dev/null
fi
gh api -X POST "repos/${REPO_FULL}/git/refs" \
  -f ref="refs/heads/${BRANCH}" -f sha="${BASE_SHA}" >/dev/null \
  || err "cannot create branch ${BRANCH}"

# The contents API commits as the token's identity, and GitHub signs commits
# an App makes this way, which a signed-commits rule on the base requires.
jq -n --arg message "${TITLE}" --arg branch "${BRANCH}" --arg sha "${BLOB_SHA}" \
  --arg content "$(base64 < "${WORK}/after" | tr -d '\n')" \
  '{message: $message, content: $content, sha: $sha, branch: $branch}' > "${WORK}/put.json"
gh api -X PUT "repos/${REPO_FULL}/contents/${FILE}" --input "${WORK}/put.json" >/dev/null \
  || err "cannot commit ${FILE} to ${BRANCH}"

url=$(gh pr create --repo "${REPO_FULL}" --base "${BASE_BRANCH}" --head "${BRANCH}" \
  --title "${TITLE}" --body-file "${WORK}/body.md") \
  || err "cannot open the deploy PR for ${BRANCH}"
url=$(printf '%s\n' "${url}" | tail -n 1)
number="${url##*/}"
gh pr edit "${number}" --repo "${REPO_FULL}" --add-label deploy >/dev/null 2>&1 || true
log "opened #${number}: ${url}"

supersede_others "${number}"
emit url "${url}"
emit number "${number}"
emit result created
