#!/usr/bin/env bash
# Cut `release/X.Y.Z` from the commit the workflow runs on (`mode: cut-release-branch`).
#
# WHY THIS EXISTS. In a release-branch flow the release starts when the team
# cuts the branch and names it after the version it decided on. Done by hand,
# that is one typo away from `release/1.4`, `release/v1.4.0-rc1` or a version
# that already shipped, and every one of those still starts the release
# workflow: `release-branch-versioning: branch` then either finds no version in
# the name and hands the run to a versioning tool, or cuts a candidate of a
# number nobody meant. So the cut goes through here, where the name is built
# from a validated X.Y.Z and the version is checked against what already
# shipped before the branch exists:
#
#   - a version already released, or not above the newest stable release, is
#     refused, unless the workflow runs on a stable tag of that same line:
#     that is a line being reopened to patch what it shipped (its old branch
#     was cleaned up), and the patch will be cut as the next free version;
#   - a branch that already exists on another commit is refused, because a
#     release branch is cut once; one already on this commit is a re-run, and
#     succeeds without touching anything.
#
# The branch is created through the API with the resolved token. With a GitHub
# App token (the default `auth-mode: public-app`) that push starts the
# repository's release workflow on the new branch, which cuts the first
# candidate. A branch created with GITHUB_TOKEN starts nothing, so that case
# gets a warning naming the manual step.
#
# Required env:
#   GH_TOKEN         token used for the API calls (steps.auth.outputs.token).
#   REPO_FULL        owner/name.
#   VERSION_INPUT    the version to cut (`version-override`), X.Y.Z or vX.Y.Z.
#
# Optional env:
#   TAG_PREFIX       version tag prefix (`v`, `core-v`, or empty).
#   REF_NAME         the ref the workflow runs on (github.ref_name).
#   DEFAULT_BRANCH   the repository's default branch.
#   TOKEN_SOURCE     steps.auth.outputs.source (public-app, private-app,
#                    github-token).
#   GITHUB_OUTPUT    receives `release-branch` and `release-branch-sha`.
#
# Exit codes:
#   0 - the branch exists on HEAD (created now, or by an earlier run).
#   1 - refused or failed; nothing was created.

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO_FULL:?REPO_FULL is required}"

PREFIX="${TAG_PREFIX:-}"
REF_NAME="${REF_NAME:-}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-}"
TOKEN_SOURCE="${TOKEN_SOURCE:-}"

fail() {
  echo "::error::cut-release-branch: $1"
  exit 1
}

emit() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >> "${GITHUB_OUTPUT}"
  fi
}

# A version pasted into a workflow_dispatch box routinely carries a stray space.
RAW="${VERSION_INPUT:-}"
RAW="${RAW#"${RAW%%[![:space:]]*}"}"
RAW="${RAW%"${RAW##*[![:space:]]}"}"
[ -n "${RAW}" ] || fail "version-override is required: it is the version the release branch is cut for, e.g. 1.4.0."

NUM='(0|[1-9][0-9]*)'
VERSION="${RAW#v}"
if [[ "${VERSION}" =~ ^${NUM}\.${NUM}\.${NUM}-.+$ ]]; then
  fail "'${RAW}' carries a prerelease part. A release branch is named after the release number only (release/${VERSION%%-*}); the candidates cut from it get their -rc.N themselves."
fi
if ! [[ "${VERSION}" =~ ^${NUM}\.${NUM}\.${NUM}$ ]]; then
  fail "'${RAW}' is not a version. Expected major.minor.patch, e.g. 1.4.0."
fi
MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
BRANCH="release/${VERSION}"
HEAD_SHA=$(git rev-parse HEAD)

# ── What already shipped ────────────────────────────────────────────────────
# Stable tags only, under this prefix, compared literally (a prefix holding
# `*` must not widen the match) and in SemVer order.
STABLE=""
REOPENS=""
while IFS= read -r t; do
  [[ "${t}" == "${PREFIX}"* ]] || continue
  rest="${t#"${PREFIX}"}"
  [[ "${rest}" =~ ^${NUM}\.${NUM}\.${NUM}$ ]] || continue
  STABLE="${STABLE}${rest}"$'\n'
done < <(git tag -l)
while IFS= read -r t; do
  [[ "${t}" == "${PREFIX}"* ]] || continue
  rest="${t#"${PREFIX}"}"
  if [[ "${rest}" =~ ^${MAJOR}\.${MINOR}\.${NUM}$ ]]; then
    REOPENS="${t}"
  fi
done < <(git tag --points-at HEAD)

HIGHEST=$(printf '%s' "${STABLE}" | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)

if [ -n "${REOPENS}" ]; then
  echo "HEAD is ${REOPENS}: reopening the ${MAJOR}.${MINOR} line to patch it. Its next candidate is cut once a fix lands."
else
  if printf '%s' "${STABLE}" | grep -Fxq "${VERSION}"; then
    fail "${PREFIX}${VERSION} is already released. Pick the next version for a new release, or run this workflow on a ${PREFIX}${MAJOR}.${MINOR}.x tag to reopen that line for a patch."
  fi
  if [ -n "${HIGHEST}" ]; then
    TOP=$(printf '%s\n%s\n' "${HIGHEST}" "${VERSION}" | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
    if [ "${TOP}" != "${VERSION}" ]; then
      fail "${VERSION} is not above ${PREFIX}${HIGHEST}, the newest release. A new release branch takes a higher version; to patch an older line, run this workflow on that line's latest ${PREFIX}X.Y.Z tag."
    fi
  fi
  if [ -n "${DEFAULT_BRANCH}" ] && [ -n "${REF_NAME}" ] && [ "${REF_NAME}" != "${DEFAULT_BRANCH}" ]; then
    echo "::warning::Cutting ${BRANCH} from '${REF_NAME}', not from the default branch '${DEFAULT_BRANCH}'. A release branch normally starts from the default branch."
  fi
fi

# ── The branch ──────────────────────────────────────────────────────────────
# Where the branch points now, or nothing. `gh api` exits non-zero on a 404,
# which is the answer for a branch that does not exist; any other failure is
# not an answer, and returns 2 with the reason on stderr so the caller stops
# rather than reading it as "absent".
existing_sha() {
  local out
  if out=$(gh api "repos/${REPO_FULL}/git/ref/heads/${BRANCH}" --jq '.object.sha' 2>&1); then
    printf '%s' "${out}"
    return 0
  fi
  if grep -q "HTTP 404" <<< "${out}"; then
    return 0
  fi
  head -1 <<< "${out}" >&2
  return 2
}

LOOKUP_ERR=$(mktemp)
trap 'rm -f "${LOOKUP_ERR}"' EXIT

if ! CURRENT=$(existing_sha 2>"${LOOKUP_ERR}"); then
  fail "could not check whether ${BRANCH} exists: $(cat "${LOOKUP_ERR}")"
fi
if [ -n "${CURRENT}" ]; then
  if [ "${CURRENT}" == "${HEAD_SHA}" ]; then
    echo "::notice::${BRANCH} already exists on ${HEAD_SHA:0:12}, the commit this run would cut it from. Nothing to do."
    emit release-branch "${BRANCH}"
    emit release-branch-sha "${HEAD_SHA}"
    exit 0
  fi
  fail "${BRANCH} already exists on ${CURRENT:0:12}. A release branch is cut once; fixes reach it through pull requests from hotfix branches. To start over, delete ${BRANCH} first."
fi

if ! ERR=$(gh api -X POST "repos/${REPO_FULL}/git/refs" \
     -f ref="refs/heads/${BRANCH}" -f sha="${HEAD_SHA}" --silent 2>&1); then
  # Lost a race with a concurrent run, or a real refusal?
  CURRENT=$(existing_sha 2>/dev/null) || CURRENT=""
  if [ "${CURRENT}" == "${HEAD_SHA}" ]; then
    echo "::notice::${BRANCH} was created on ${HEAD_SHA:0:12} by a concurrent run."
  else
    fail "could not create ${BRANCH}: $(head -1 <<< "${ERR}"). The token needs contents: write, and a ruleset that restricts creating release/* branches has to let the Diatreme App (or your own App) bypass it."
  fi
else
  echo "Created ${BRANCH} on ${HEAD_SHA:0:12}."
fi

if [ "${TOKEN_SOURCE}" == "github-token" ]; then
  echo "::warning::${BRANCH} was created with GITHUB_TOKEN, and a push made with that token starts no workflow. Run your release workflow on ${BRANCH} by hand to cut its first candidate, or use a GitHub App token (auth-mode: public-app, the default)."
fi

emit release-branch "${BRANCH}"
emit release-branch-sha "${HEAD_SHA}"
