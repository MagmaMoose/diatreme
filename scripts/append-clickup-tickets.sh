#!/usr/bin/env bash
# scripts/append-clickup-tickets.sh
# Appends a "## ClickUp tickets" section to the GitHub Release notes
# (and to the auto-opened promotion PR body when one exists).
#
# Tickets are extracted from commit messages in the release range and
# from the descriptions of PRs whose numbers appear in those commits.
#
# Required env:
#   GH_TOKEN                  — token with read access to repo + PRs and
#                               write access to releases + PRs
#   OWNER                     — github.repository_owner
#   REPO                      — github.event.repository.name
#   TAG                       — the tag just released (with v-prefix)
#
# Optional env:
#   PRERELEASE_IDENTIFIER     — '', 'dev', 'rc', etc. Used to bound the
#                               previous-tag lookup so each channel's
#                               release notes only show tickets new to
#                               that channel.
#
# Exits 0 on success or when there's nothing to do.
# Never fails the workflow — failure to enrich notes shouldn't block a
# release.

set -uo pipefail

CLICKUP_RX='https://app\.clickup\.com/t/[A-Za-z0-9_-]+'

case "${PRERELEASE_IDENTIFIER:-}" in
  dev)  PATTERN='-dev\.' ;;
  rc)   PATTERN='-rc\.'  ;;
  '')   PATTERN='^v[0-9]+\.[0-9]+\.[0-9]+$' ;;
  *)    PATTERN="-${PRERELEASE_IDENTIFIER}\." ;;
esac

PREV_TAG=$(git tag --sort=-v:refname \
  | grep -E -- "${PATTERN}" \
  | grep -Fxv "${TAG}" \
  | head -1 || true)

if [ -z "${PREV_TAG}" ]; then
  RANGE="${TAG}"
  echo "No previous tag for this channel; scanning ${TAG} alone."
else
  RANGE="${PREV_TAG}..${TAG}"
  echo "Scanning ${RANGE} for ClickUp ticket references."
fi

PR_NUMS=$(git log "${RANGE}" --pretty=format:"%s%n%b" 2>/dev/null \
  | grep -oE '#[0-9]+' | tr -d '#' | sort -u || true)

TICKETS_FILE=$(mktemp)
trap 'rm -f "${TICKETS_FILE}" /tmp/release-notes.md /tmp/pr-body.md' EXIT

{
  git log "${RANGE}" --pretty=format:"%H%n%s%n%b" 2>/dev/null || true
  for num in ${PR_NUMS}; do
    gh pr view "${num}" --json body --jq '.body' 2>/dev/null || true
  done
} | grep -oE "${CLICKUP_RX}" | sort -u > "${TICKETS_FILE}"

COUNT=$(wc -l < "${TICKETS_FILE}" | tr -d ' ')
if [ "${COUNT}" -eq 0 ]; then
  echo "No ClickUp tickets referenced in ${RANGE}."
  exit 0
fi
echo "Found ${COUNT} ClickUp ticket(s):"
cat "${TICKETS_FILE}"

# GitHub Release notes
#
# Skipped when the section is already there, as append-github-projects.sh does
# for its own. A resumed `promote-from` run reaches this step a second time for
# a release that already exists, and appending again would list every ticket
# twice.
CURRENT_BODY=$(gh release view "${TAG}" --json body --jq '.body' 2>/dev/null || true)
if echo "${CURRENT_BODY}" | grep -q "^## ClickUp tickets"; then
  echo "Release notes for ${TAG} already contain a ClickUp section; skipping."
else
  {
    printf '%s\n\n## ClickUp tickets\n\n' "${CURRENT_BODY}"
    sed 's/^/- /' "${TICKETS_FILE}"
  } > /tmp/release-notes.md
  if gh release edit "${TAG}" --notes-file /tmp/release-notes.md; then
    echo "Appended ClickUp section to release ${TAG}."
  else
    echo "::warning::Could not edit release notes for ${TAG} — continuing."
  fi
fi

# Promotion PR body, if one was just opened for this version
PROMO_PR=$(gh pr list \
  --state open \
  --search "head:promote/ ${TAG#v} in:title" \
  --json number \
  --jq '.[0].number // empty' 2>/dev/null || true)
if [ -n "${PROMO_PR}" ]; then
  CURRENT_PR_BODY=$(gh pr view "${PROMO_PR}" --json body --jq '.body' 2>/dev/null || true)
  {
    printf '%s\n\n## ClickUp tickets\n\n' "${CURRENT_PR_BODY}"
    sed 's/^/- /' "${TICKETS_FILE}"
  } > /tmp/pr-body.md
  if gh pr edit "${PROMO_PR}" --body-file /tmp/pr-body.md; then
    echo "Appended ClickUp section to promotion PR #${PROMO_PR}."
  else
    echo "::warning::Could not edit PR #${PROMO_PR} body — continuing."
  fi
fi
