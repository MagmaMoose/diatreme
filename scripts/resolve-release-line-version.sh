#!/usr/bin/env bash
# Version a release branch from its own name.
#
# WHY THIS EXISTS. In a release-branch flow the team picks the version when it
# cuts the branch: `release/1.4.0` is the 1.4.0 release, and every build
# deployed from it before production is a candidate of that version. None of
# the versioning backends answers that question. semantic-release and
# python-semantic-release compute the version from conventional commit
# messages, so a team that writes "Fix null check on export #4567" gets no
# release at all. GitVersion reads the branch name, but what it cuts once the
# line has shipped depends on branch config the repository may not have. And a
# hotfix merged into `release/1.4.0` after v1.4.0 shipped must never be cut as
# 1.4.0 again: that version is a different, already deployed build.
#
# So the branch name is the base, and the tags already in the repository decide
# the rest:
#
#   nothing of the line released yet    X.Y.Z
#   X.Y.Z (or a later patch) released   the next free patch, X.Y.(P+1)
#   a prerelease environment            <base>-<identifier>.N, N one above the
#                                       highest of that base and identifier
#   HEAD already holds that prerelease  the same tag again, resumed: a re-run
#                                       finishes the release, never re-cuts it
#   HEAD already holds a stable tag     that tag, not resumed. Nothing new has
#   of the line                         landed since the line last shipped, and
#                                       push-release-tag.sh reports a no-op
#
# The release lines are the families GitVersion recognises (`release/`,
# `releases/`, `hotfix/`, `hotfixes/`, with `/` or `-`), an optional `v`, and a
# strict X.Y.Z. A name that carries no version (`release/next`,
# `hotfix/456-login-bug`) is not a release line, and the caller falls through
# to its configured versioning tool.
#
# Env:
#   BRANCH         The branch being released (GITHUB_REF_NAME).
#   TAG_PREFIX     Version tag prefix (`v`, `core-v`, or empty).
#   IS_PRERELEASE  "true" when the target environment is not the last one.
#   IDENTIFIER     That environment's prerelease identifier (e.g. `rc`).
#
# Output (stdout), only when BRANCH is a release line:
#   version=<version without prefix>
#   tag=<tag>
#   resume=<true|false>   push-release-tag.sh's RESUME_AT_HEAD: the tag is
#                         this commit's release, so finding it on the remote at
#                         HEAD resumes it and finding it anywhere else is an
#                         error. "false" only for the already-released no-op.
# Every diagnostic goes to stderr.
#
# Exit codes:
#   0 - always, unless the inputs are unusable. "Not a release line" is an
#       ordinary outcome with no output.
#   1 - IS_PRERELEASE is true but IDENTIFIER is empty.

set -euo pipefail

BRANCH="${BRANCH:-}"
PREFIX="${TAG_PREFIX:-}"
IS_PRERELEASE="${IS_PRERELEASE:-false}"
IDENTIFIER="${IDENTIFIER:-}"

NUM='(0|[1-9][0-9]*)'
LINE_RE="^(release|releases|hotfix|hotfixes)[/-]v?${NUM}\.${NUM}\.${NUM}([^0-9].*)?$"

if ! [[ "${BRANCH}" =~ ${LINE_RE} ]]; then
  echo "'${BRANCH}' is not a release branch with a version in its name; leaving the version to the configured tool." >&2
  exit 0
fi
MAJOR="${BASH_REMATCH[2]}"
MINOR="${BASH_REMATCH[3]}"
PATCH="${BASH_REMATCH[4]}"
LINE="${MAJOR}.${MINOR}"

if [ "${IS_PRERELEASE}" == "true" ] && [ -z "${IDENTIFIER}" ]; then
  echo "::error::release-branch-versioning: a prerelease environment needs a prerelease identifier." >&2
  exit 1
fi

result() {
  printf 'version=%s\ntag=%s\nresume=%s\n' "$1" "${PREFIX}$1" "$2"
}

# The prefix is compared as a literal string rather than handed to `git tag -l`
# as a glob, so a prefix containing `*` or `[` cannot widen the match.
strip_prefix() {
  local t="$1"
  [[ "${t}" == "${PREFIX}"* ]] || return 1
  printf '%s' "${t#"${PREFIX}"}"
}

# ── Already released at HEAD ────────────────────────────────────────────────
# A stable tag of this line on HEAD means the commit is in production already
# (a promotion tags the candidate's own commit). Cutting the next patch here
# would publish a new version of identical code.
while IFS= read -r t; do
  [ -n "${t}" ] || continue
  rest=$(strip_prefix "${t}") || continue
  if [[ "${rest}" =~ ^${MAJOR}\.${MINOR}\.${NUM}$ ]]; then
    echo "::notice::HEAD is already released as ${t}; nothing has landed on ${BRANCH} since, so there is nothing to release." >&2
    result "${rest}" "false"
    exit 0
  fi
done < <(git tag --points-at HEAD 2>/dev/null || true)

# ── The base version ────────────────────────────────────────────────────────
HIGHEST=""
while IFS= read -r t; do
  rest=$(strip_prefix "${t}") || continue
  if [[ "${rest}" =~ ^${MAJOR}\.${MINOR}\.${NUM}$ ]]; then
    p="${BASH_REMATCH[1]}"
    if [ -z "${HIGHEST}" ] || [ "${p}" -gt "${HIGHEST}" ]; then
      HIGHEST="${p}"
    fi
  fi
done < <(git tag -l 2>/dev/null || true)

if [ -z "${HIGHEST}" ] || [ "${HIGHEST}" -lt "${PATCH}" ]; then
  BASE="${LINE}.${PATCH}"
  echo "${BRANCH}: ${BASE} is not released yet." >&2
else
  BASE="${LINE}.$((HIGHEST + 1))"
  echo "${BRANCH}: ${PREFIX}${LINE}.${HIGHEST} is already released, so this line's next version is ${BASE}." >&2
fi

if [ "${IS_PRERELEASE}" != "true" ]; then
  result "${BASE}" "true"
  exit 0
fi

# ── The prerelease number ───────────────────────────────────────────────────
# Re-running a release that died after its tag was pushed must finish that
# release, not cut the next number on the same commit.
while IFS= read -r t; do
  rest=$(strip_prefix "${t}") || continue
  if [[ "${rest}" == "${BASE}-${IDENTIFIER}."* ]] && [[ "${rest#"${BASE}-${IDENTIFIER}."}" =~ ^${NUM}$ ]]; then
    echo "HEAD already holds ${t}; resuming that release." >&2
    result "${rest}" "true"
    exit 0
  fi
done < <(git tag --points-at HEAD 2>/dev/null || true)

N=0
while IFS= read -r t; do
  rest=$(strip_prefix "${t}") || continue
  [[ "${rest}" == "${BASE}-${IDENTIFIER}."* ]] || continue
  n="${rest#"${BASE}-${IDENTIFIER}."}"
  if [[ "${n}" =~ ^${NUM}$ ]] && [ "${n}" -gt "${N}" ]; then
    N="${n}"
  fi
done < <(git tag -l 2>/dev/null || true)

result "${BASE}-${IDENTIFIER}.$((N + 1))" "true"
