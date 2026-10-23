#!/usr/bin/env bash
# Give a pull request head its commit tag when its `mode: ci` build was skipped.
#
# WHY THIS EXISTS. With `image-commit-tag`, every pull request head gets an
# image tagged pr-<N>-<sha7>, and a preview controller deploys that tag. A head
# whose build is skipped (a pull request that changes nothing outside
# `deploy-paths`) builds nothing, so its preview would point at a tag that was
# never pushed. Instead, the image the pull request's last build pushed
# (pr-<N>) is retagged for the new head. Nothing is rebuilt.
#
# A pull request that was never built has no pr-<N>. That is a warning, not a
# failure: there is no image for this head and nothing here can make one. Any
# other failed retag is an error, because the commit tag then cannot be
# promised and the run must not report this head as ready.
#
# The retag is `docker buildx imagetools create`, which keeps a multi-arch
# manifest list whole. GHE Packages fails it with a referrers-index parse
# error; then, as in `Promote images`, it falls back to pull/tag/push, which
# keeps only the runner's platform.
#
# Required env:
#   SOURCE_REFS  newline-separated refs at the build's tag, one per image,
#                e.g. ghcr.io/org/app:pr-12. Blank lines are ignored.
#   COMMIT_TAG   the tag to add, e.g. pr-12-1a2b3c4.
# Optional env:
#   GITHUB_OUTPUT  receives image-commit-tag=<COMMIT_TAG> once every image has it.
#
# Exit codes:
#   0  every image got the tag, or there was no pr-<N> to give it (warned).
#   1  a retag failed, or SOURCE_REFS named no image.

set -euo pipefail

: "${COMMIT_TAG:?COMMIT_TAG is required}"
SOURCE_REFS="${SOURCE_REFS:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERDICT=$(mktemp)
ERR=$(mktemp)
trap 'rm -f "${VERDICT}" "${ERR}"' EXIT

CHECKED=0
MISSING=0
while IFS= read -r src; do
  [ -n "${src}" ] || continue
  CHECKED=$((CHECKED + 1))
  # The repository is the ref without its digest and tag; a registry port
  # (host:5000/app) has a `/` after its colon, so it stays.
  repo="${src%%@*}"
  [[ "${repo##*/}" != *:* ]] || repo="${repo%:*}"
  dest="${repo}:${COMMIT_TAG}"

  : > "${VERDICT}"
  if ! IMAGE_REF="${src}" VERDICT_FILE="${VERDICT}" "${SCRIPT_DIR}/probe-image-tag.sh" \
     && [ "$(cat "${VERDICT}")" = "absent" ]; then
    echo "::warning::${src} does not exist, so this pull request has no image to tag ${dest}. A preview of this commit has nothing to run until a change outside deploy-paths builds one."
    MISSING=$((MISSING + 1))
    continue
  fi

  if docker buildx imagetools create --tag "${dest}" "${src}" 2>"${ERR}"; then
    echo "Tagged ${src} as ${dest}."
    continue
  fi
  DETAIL=$(head -n 5 "${ERR}" | tr '\n' ' ')
  if grep -q "failed to decode referrers index" "${ERR}"; then
    echo "::warning::imagetools retag failed on a referrers-index parse (likely GHE Packages). Falling back to docker pull/tag/push: a multi-arch image keeps only the runner's platform under ${dest}."
    if docker pull "${src}" && docker tag "${src}" "${dest}" && docker push "${dest}"; then
      echo "Tagged ${src} as ${dest} via pull/tag/push."
      continue
    fi
    DETAIL="see the docker pull/tag/push output above"
  fi
  echo "::error::Could not tag ${src} as ${dest} (${DETAIL:-no error output}). This head has no commit tag, so the run fails instead of reporting it ready."
  exit 1
done <<< "${SOURCE_REFS}"

if [ "${CHECKED}" -eq 0 ]; then
  echo "::error::No image ref could be derived to tag ${COMMIT_TAG}."
  exit 1
fi

if [ "${MISSING}" -eq 0 ] && [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "image-commit-tag=${COMMIT_TAG}" >> "${GITHUB_OUTPUT}"
fi
