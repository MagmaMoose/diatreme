#!/usr/bin/env bash
# Push a release tag to origin with race-safe handling.
#
# Used by the gitversion-tag and version-override-tag steps in action.yml.
# Encapsulates the authenticated-URL resolution + tag-already-exists
# pre-check + create/push/race-recovery loop that those two steps share.
#
# Required env:
#   TAG           - the tag to publish (e.g., v1.2.3)
#   GITHUB_TOKEN  - auth token; embedded into the HTTPS remote URL
#
# Optional env:
#   MESSAGE       - annotated-tag message. If unset/empty, a lightweight
#                   tag is created instead.
#   RELEASE_NOTES - when set, emitted as the `release_notes` output ONLY on a
#                   real release (released=true) — never on a no-op/race skip.
#   GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL  - identity for `git config`; default
#                   to the github-actions bot.
#   RESUME_AT_HEAD - "true" turns an already-published TAG from a no-op into a
#                   resumed release (released=true), PROVIDED it is the tag
#                   this run would have pushed: it resolves to HEAD's commit
#                   and, when RESUME_MARKER is set, carries that line in its
#                   message. Any other TAG is then an error, never a no-op.
#                   For `promote-from`, where the release is a named, existing
#                   build rather than "whatever these commits add up to": a
#                   promotion that died after the tag was pushed has to be
#                   finishable by running it again, and a run that was asked
#                   to release one build must not report success because some
#                   other build already holds the version.
#   RESUME_MARKER - a line that must appear verbatim in the remote tag's
#                   message for it to count as this release. The commit alone
#                   is not proof: two prereleases can sit on one commit with
#                   different images behind them, and resuming the promotion
#                   of the other one would repoint a published version.
#                   Only read under RESUME_AT_HEAD; the caller is expected to
#                   put the same line in MESSAGE.
#
# Side effects:
#   - Configures git user.name / user.email only when each is not already
#     set in the local git config. A caller that pre-configures their own
#     identity is preserved.
#   - Writes `latest_tag=${TAG}` and `released=true|false` to $GITHUB_OUTPUT
#     when that variable is set (always set inside an Actions step), plus
#     `release_notes=${RELEASE_NOTES}` on a real release when RELEASE_NOTES is
#     set. The caller is responsible for any other tool-specific outputs.
#   - Writes git push stderr to a per-invocation temp file under
#     ${RUNNER_TEMP:-/tmp} and removes it on exit via a trap, so
#     concurrent invocations in the same job don't read each other's
#     diagnostics.
#
# Exit codes:
#   0 - tag is on remote (either we pushed it, or a concurrent run did)
#   1 - unsupported remote URL, push failed for a non-race reason, or, under
#       RESUME_AT_HEAD, the remote could not be asked or holds a TAG that is
#       not this release
#
# Race semantics:
#   - If the remote already has TAG when we start, we treat that as a
#     no-op release (released=false) and exit 0.
#   - If we create the tag locally and the push fails, we re-check the
#     remote. If TAG now exists, we lost a race between check and push;
#     drop the local tag and exit 0 with released=false.
#   - Otherwise we surface the first 3 lines of git push stderr and
#     exit 1 so the workflow can diagnose auth / ruleset / network issues.
#   - RESUME_AT_HEAD changes the first rule (resume, not no-op) and adds a
#     condition to the second: losing the race is still a no-op, because the
#     run that won is carrying the release through, but only when the tag
#     that won is this same release. A rival tag for a different build is an
#     error, or the run would go green having released nothing.

set -euo pipefail

: "${TAG:?TAG is required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"

# Only set git identity when the caller hasn't already configured one.
# `git config --get` exits non-zero when the key is unset.
if ! git config --get user.name >/dev/null 2>&1; then
  git config user.name "${GIT_AUTHOR_NAME:-github-actions[bot]}"
fi
if ! git config --get user.email >/dev/null 2>&1; then
  git config user.email "${GIT_AUTHOR_EMAIL:-github-actions[bot]@users.noreply.github.com}"
fi

# Read the raw remote.origin.url config rather than `git remote get-url`
# so any caller-side `insteadOf` rewrites don't change what we see — we
# want the URL the caller actually wrote, so we can synthesise a
# matching token-prefixed form. Git applies any rewrites again when it
# pushes, so the eventual target is unchanged.
REMOTE_URL=$(git config --get remote.origin.url)
if [[ "${REMOTE_URL}" =~ ^https:// ]]; then
  AUTHED_URL="https://x-access-token:${GITHUB_TOKEN}@${REMOTE_URL#https://}"
elif [[ "${REMOTE_URL}" =~ ^git@([^:]+):(.+)$ ]]; then
  AUTHED_URL="https://x-access-token:${GITHUB_TOKEN}@${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
else
  echo "::error::Unsupported git remote URL format for authenticated tag push: ${REMOTE_URL}"
  exit 1
fi

# Per-invocation stderr capture, cleaned up on exit. Two concurrent
# invocations in the same job (e.g. a matrix run) would otherwise
# read each other's diagnostics from a shared /tmp path.
PUSH_ERR=$(mktemp "${RUNNER_TEMP:-/tmp}/tag_push.err.XXXXXX")
trap 'rm -f "${PUSH_ERR}"' EXIT

emit() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >> "${GITHUB_OUTPUT}"
  fi
}

# Is the TAG already on the remote the very release this run is making? Exits
# 1 when it is not. Only called under RESUME_AT_HEAD.
#
# The tag is fetched rather than read off `ls-remote`: the marker lives in the
# tag's message, and an annotated tag is advertised by the id of the tag
# OBJECT, which says nothing on its own. FETCH_HEAD is used instead of a local
# ref so a refused tag leaves nothing behind in the clone.
require_same_release() {
  local remote_commit head_commit message
  if ! git fetch --no-tags --quiet "${AUTHED_URL}" "refs/tags/${TAG}" 2>"${PUSH_ERR}"; then
    echo "::error::Tag ${TAG} exists on remote but could not be fetched to check what it is: $(head -3 "${PUSH_ERR}" 2>/dev/null)"
    exit 1
  fi
  remote_commit=$(git rev-parse -q --verify 'FETCH_HEAD^{commit}' 2>/dev/null || true)
  head_commit=$(git rev-parse HEAD)
  if [ -z "${remote_commit}" ] || [ "${remote_commit}" != "${head_commit}" ]; then
    echo "::error::Tag ${TAG} already exists on remote at ${remote_commit:-an unreadable object}, not at ${head_commit}, the commit being released. Refusing to treat a different build as this release."
    exit 1
  fi
  if [ -n "${RESUME_MARKER:-}" ]; then
    # Only an annotated tag has a message of its own. For a lightweight tag
    # `cat-file -p` would print the COMMIT, and a commit message must not be
    # able to vouch for a tag.
    message=""
    if [ "$(git cat-file -t FETCH_HEAD 2>/dev/null || true)" == "tag" ]; then
      message=$(git cat-file -p FETCH_HEAD 2>/dev/null || true)
    fi
    if ! grep -Fxq -- "${RESUME_MARKER}" <<< "${message}"; then
      echo "::error::Tag ${TAG} already exists on remote on the commit being released, but it is not this release: its message has no '${RESUME_MARKER}' line. Refusing to take over a version that is already published."
      exit 1
    fi
  fi
}

# Resume check, asked separately from the pre-check below and strictly. There
# a query that fails reads as "absent" and the push settles it. Here that
# would walk a resumed run into `git tag` with the tag already in the clone,
# and the run would die on "tag already exists" with the real cause hidden.
if [ "${RESUME_AT_HEAD:-false}" == "true" ]; then
  if ! REMOTE_TAG=$(git ls-remote --tags "${AUTHED_URL}" "refs/tags/${TAG}" 2>"${PUSH_ERR}"); then
    echo "::error::Could not ask the remote whether tag ${TAG} exists: $(head -3 "${PUSH_ERR}" 2>/dev/null)"
    exit 1
  fi
  if grep -Fq "refs/tags/${TAG}" <<< "${REMOTE_TAG}"; then
    require_same_release
    echo "::notice::Tag ${TAG} already exists on remote on the commit being released. Resuming that release."
    emit latest_tag "${TAG}"
    emit released "true"
    if [ -n "${RELEASE_NOTES:-}" ]; then
      emit release_notes "${RELEASE_NOTES}"
    fi
    exit 0
  fi
fi

# Pre-check: a parallel run may have already published this tag.
if git ls-remote --tags "${AUTHED_URL}" "refs/tags/${TAG}" 2>/dev/null | grep -Fq "refs/tags/${TAG}"; then
  echo "::notice::Tag ${TAG} already exists on remote — a parallel run published it. Treating this run as a no-op release."
  emit latest_tag "${TAG}"
  emit released "false"
  exit 0
fi

# Create the tag (annotated when MESSAGE is provided, lightweight otherwise).
if [ -n "${MESSAGE:-}" ]; then
  git tag -a "${TAG}" -m "${MESSAGE}"
else
  git tag "${TAG}"
fi

# Push, with race recovery: if the push fails and the tag has since
# appeared on the remote, treat as a clean race loss.
if ! git push "${AUTHED_URL}" "${TAG}" 2>"${PUSH_ERR}"; then
  if git ls-remote --tags "${AUTHED_URL}" "refs/tags/${TAG}" 2>/dev/null | grep -Fq "refs/tags/${TAG}"; then
    if [ "${RESUME_AT_HEAD:-false}" == "true" ]; then
      require_same_release
    fi
    echo "::notice::Tag ${TAG} now exists on remote (parallel run won the race between check and push). Skipping."
    git tag -d "${TAG}" 2>/dev/null || true
    emit latest_tag "${TAG}"
    emit released "false"
    exit 0
  fi
  echo "::error::Failed to push tag ${TAG}: $(head -3 "${PUSH_ERR}" 2>/dev/null)"
  exit 1
fi

emit latest_tag "${TAG}"
emit released "true"
if [ -n "${RELEASE_NOTES:-}" ]; then
  emit release_notes "${RELEASE_NOTES}"
fi
