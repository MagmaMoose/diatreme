#!/usr/bin/env bash
# Turn `promote-from` into a release: the prerelease tag to promote, the commit
# it sits on, and the stable version it becomes.
#
# WHY THIS EXISTS. Every other release path decides two things a promotion must
# not. It computes a version from commits, and it goes looking for an image to
# match. "Ship the build QA signed off" is neither of those: the version is
# already written in the tag that was tested (`v1.5.0-rc.3` becomes `v1.5.0`),
# and the artifact is the one already in the registry under that tag. The
# closest existing path, a later environment in `deployment-model: tbd`, picks
# the NEWEST prerelease of the previous environment, tags whatever commit the
# workflow happens to run on, and rebuilds when the retag fails. Each of those
# can release something nobody tested:
#
#   newest, not named   QA signs off rc.3, a fix lands and cuts rc.4, and rc.4
#                       is what ships.
#   tag on branch HEAD  the stable tag names a commit the image was not built
#                       from, so `git checkout v1.5.0` is not what is running.
#   rebuild on failure  a registry hiccup turns a promotion into a fresh build
#                       carrying the stable tag.
#
# So the caller names the prerelease, and this script answers everything that
# follows from the name before anything is written:
#
#   - the tag exists, is a prerelease, and is from the channel that feeds
#     production (a `-dev.N` build is one typo away from an `-rc.N` one);
#   - the commit it points at, which the caller checks out so that the stable
#     tag, the package build and the bake file are all the prerelease's own;
#   - the stable tag is either free, or is this same promotion: on that commit,
#     and recording this prerelease in its message (`Promoted-From: <tag>`).
#     That second case is a promotion that died half way, and re-running it
#     finishes the job. Any other stable tag is a build already released under
#     that version, on another commit or from another prerelease on the same
#     one, and that is never overwritten;
#   - nothing else in the run would rebuild the artifact or attest it to the
#     wrong commit (a `container` package build, npm provenance);
#   - which stable tag came before it, so the GitHub Release lists what changed
#     since the last stable version rather than since the prerelease it was
#     promoted from (an empty list);
#   - whether it is the highest stable version. A fix promoted on an older
#     release line (1.4.3 after 1.5.0 is out) must not drag `:latest` backwards.
#
# It reads local refs only. The action's checkout fetches every tag, so there
# is no API call to fail and nothing here needs a token.
#
# Required env:
#   PROMOTE_FROM  - the prerelease tag, with or without TAG_PREFIX
#                   (`v1.5.0-rc.3` or `1.5.0-rc.3`).
#
# Optional env:
#   TAG_PREFIX              - version tag prefix (`v`, `core-v`, or empty).
#   VERSION_OVERRIDE,       - the two other ways to pin a version. Either one
#   FORCE_BUMP                set alongside PROMOTE_FROM is an error.
#   ENVIRONMENTS,           - the caller's environment list and identifier map.
#   PRERELEASE_IDENTIFIERS    Used to name the channel that feeds production:
#                             the identifier of the environment before the
#                             last one. An empty ENVIRONMENTS skips that
#                             check; one that does not parse is an error.
#   PUBLISH_PACKAGE,        - the caller's package-publishing inputs, to
#   PACKAGE_ECOSYSTEM,        refuse the two combinations described at the
#   NPM_PROVENANCE            check below.
#   GITHUB_SHA              - the commit the workflow was started on.
#   GITHUB_OUTPUT           - receives the outputs below.
#
# Outputs:
#   source_tag    - the prerelease tag, prefix included.
#   commit        - the commit it resolves to.
#   version, tag  - the stable version and its tag (`1.5.0`, `v1.5.0`).
#   previous_tag  - highest stable tag below `version`, or empty on a first
#                   stable release.
#   tag_latest    - "true" when `version` is the highest stable version.
#   marker        - the `Promoted-From: <tag>` line for the stable tag's
#                   message, which is what a later run resumes on.
#
# Exit codes:
#   0 - resolved; the outputs are written.
#   1 - the promotion must not go ahead. Nothing has been written anywhere.

set -euo pipefail

PROMOTE_FROM="${PROMOTE_FROM:-}"
TAG_PREFIX="${TAG_PREFIX:-}"
VERSION_OVERRIDE="${VERSION_OVERRIDE:-}"
FORCE_BUMP="${FORCE_BUMP:-}"
ENVIRONMENTS="${ENVIRONMENTS:-}"
PRERELEASE_IDENTIFIERS="${PRERELEASE_IDENTIFIERS:-}"

fail() {
  echo "::error::promote-from: $1"
  exit 1
}

emit() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >> "${GITHUB_OUTPUT}"
  fi
}

# A tag pasted into a workflow_dispatch box routinely arrives with a trailing
# space or newline, and "tag 'v1.5.0-rc.3 ' does not exist" is a miserable
# thing to debug.
PROMOTE_FROM="${PROMOTE_FROM#"${PROMOTE_FROM%%[![:space:]]*}"}"
PROMOTE_FROM="${PROMOTE_FROM%"${PROMOTE_FROM##*[![:space:]]}"}"

[ -n "${PROMOTE_FROM}" ] || fail "PROMOTE_FROM is required."

# The version of a promotion is not a choice: it is the prerelease's own, minus
# the prerelease part. A second instruction can only disagree with it.
if [ -n "${VERSION_OVERRIDE}" ]; then
  fail "cannot be combined with version-override. The stable version comes from the tag being promoted; set only one."
fi
if [ -n "${FORCE_BUMP}" ]; then
  fail "cannot be combined with force-bump. The stable version comes from the tag being promoted; set only one."
fi

# ── The name ─────────────────────────────────────────────────────────────────
# Accept the tag as it appears in git, or the bare version. Whatever is left
# after the prefix must be a SemVer prerelease.
REST="${PROMOTE_FROM#"${TAG_PREFIX}"}"
EXAMPLE="${TAG_PREFIX}1.5.0-rc.3"

if [[ "${REST}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "'${PROMOTE_FROM}' is already a stable version. Pass the prerelease to promote, e.g. ${EXAMPLE}."
fi
if ! [[ "${REST}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)-([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)$ ]]; then
  fail "'${PROMOTE_FROM}' is not a prerelease tag under tag-prefix '${TAG_PREFIX}'. Expected something like ${EXAMPLE}."
fi

VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
PRERELEASE="${BASH_REMATCH[4]}"
IDENTIFIER="${PRERELEASE%%.*}"
SOURCE_TAG="${TAG_PREFIX}${REST}"
TAG="${TAG_PREFIX}${VERSION}"

# ── The channel ──────────────────────────────────────────────────────────────
# `environments` is in promotion order and its last entry is production, so the
# entry before it is the one whose builds are meant to be promoted. Hold the
# source to that environment's identifier. Without this a `-dev.7` typed where
# `-rc.7` was meant ships a development build as stable, and both tags exist,
# so nothing else would object.
#
# An environment with no entry in the identifier map is cut as `rc`: that is
# the default `Detect environment` applies when it tags a prerelease, so it is
# the identifier those builds actually carry. A single-environment list has no
# previous channel and is left alone.
#
# Both inputs are checked for shape here rather than left to `Detect
# environment`, which never parses the identifier map on a stable run. A guard
# that quietly switched itself off on a typo would be worse than none.
if [ -n "${ENVIRONMENTS}" ]; then
  IDS="${PRERELEASE_IDENTIFIERS}"
  [ -n "${IDS}" ] || IDS='{}'
  if ! jq -en --argjson envs "${ENVIRONMENTS}" '$envs | type == "array"' >/dev/null 2>&1; then
    fail "environments is not a JSON array: ${ENVIRONMENTS}"
  fi
  if ! jq -en --argjson ids "${IDS}" '$ids | type == "object"' >/dev/null 2>&1; then
    fail "prerelease-identifiers is not a JSON object: ${IDS}"
  fi
  PREV_ENV=$(jq -rn --argjson envs "${ENVIRONMENTS}" '$envs | if length >= 2 then .[-2] else empty end')
  STABLE_ENV=$(jq -rn --argjson envs "${ENVIRONMENTS}" '$envs | .[-1] // empty')
  if [ -n "${PREV_ENV}" ]; then
    EXPECTED=$(jq -rn --argjson ids "${IDS}" --arg e "${PREV_ENV}" '$ids[$e] // "rc"')
    # A candidate numbered without the dot (`1.5.0-rc4`, which is how a team
    # that types its versions into version-override often writes them) is the
    # same channel as `-rc.4`: the identifier is the channel's, followed by
    # nothing but its number. Compared as strings, so an identifier that
    # holds a regex metacharacter cannot widen the match.
    TRAILING="${IDENTIFIER##*[!0-9]}"
    CHANNEL="${IDENTIFIER}"
    if [ -n "${TRAILING}" ] && [ "${TRAILING}" != "${IDENTIFIER}" ]; then
      CHANNEL="${IDENTIFIER%"${TRAILING}"}"
    fi
    if [ "${IDENTIFIER}" != "${EXPECTED}" ] && [ "${CHANNEL}" != "${EXPECTED}" ]; then
      fail "'${SOURCE_TAG}' is a '${IDENTIFIER}' prerelease, but only '${EXPECTED}' prereleases are promoted to stable: '${EXPECTED}' is the identifier of '${PREV_ENV}', the environment before '${STABLE_ENV}' in environments. Promote a ${TAG_PREFIX}${VERSION}-${EXPECTED}.N tag instead."
    fi
  fi
fi

# ── The commit ───────────────────────────────────────────────────────────────
SOURCE_COMMIT=$(git rev-parse -q --verify "refs/tags/${SOURCE_TAG}^{commit}" 2>/dev/null || true)
if [ -z "${SOURCE_COMMIT}" ]; then
  # The likeliest cause is a mistyped number, so say which ones do exist.
  SIBLINGS=$(git tag -l --sort=v:refname 2>/dev/null | while IFS= read -r t; do
    [[ "${t}" == "${TAG_PREFIX}${VERSION}-"* ]] && printf '%s ' "${t}"
  done || true)
  if [ -n "${SIBLINGS}" ]; then
    fail "tag '${SOURCE_TAG}' does not exist in this repository. Prereleases of ${VERSION}: ${SIBLINGS% }."
  fi
  fail "tag '${SOURCE_TAG}' does not exist in this repository, and ${VERSION} has no prerelease tags at all. Check that tag-prefix ('${TAG_PREFIX}') is the one the prerelease was cut with."
fi

# ── What else this run would publish ─────────────────────────────────────────
# Two package settings would quietly undo what a promotion is for, and both
# are knowable now.
#
# `package-ecosystem: container` does not retag anything: it runs `docker
# build` and pushes `<name>:<version>`. On a promotion that is a fresh image
# under the stable version, the one thing promote-from exists to rule out.
#
# `npm-provenance` has npm attest the package to the commit the WORKFLOW was
# started on. The package is built from the prerelease's commit, so started
# from a branch that has moved on, the attestation would name a commit the
# package did not come from. Started from the prerelease tag itself the two
# are the same commit and it is fine.
if [ "${PUBLISH_PACKAGE:-false}" == "true" ]; then
  if [ "${PACKAGE_ECOSYSTEM:-}" == "container" ]; then
    fail "cannot be combined with publish-package and package-ecosystem: container. That path builds a fresh image and pushes it under the stable version, and a promotion must ship the image that was tested. Let Diatreme promote the image instead (docker-bake.hcl or a Dockerfile), or turn publish-package off for this run."
  fi
  if [ "${PACKAGE_ECOSYSTEM:-}" == "npm" ] && [ "${NPM_PROVENANCE:-false}" == "true" ] \
     && [ "${GITHUB_SHA:-}" != "${SOURCE_COMMIT}" ]; then
    fail "npm-provenance would attest the package to commit ${GITHUB_SHA:0:12}, the commit this workflow was started on, but it is built from ${SOURCE_COMMIT:0:12}, the commit of ${SOURCE_TAG}. Start the workflow from the ${SOURCE_TAG} tag so the two agree, or turn npm-provenance off for this run."
  fi
fi

# ── The stable tag ───────────────────────────────────────────────────────────
# The line a promotion writes into the stable tag's message, and looks for
# when it finds that tag already there.
MARKER="Promoted-From: ${SOURCE_TAG}"

TARGET_COMMIT=$(git rev-parse -q --verify "refs/tags/${TAG}^{commit}" 2>/dev/null || true)
if [ -n "${TARGET_COMMIT}" ]; then
  if [ "${TARGET_COMMIT}" != "${SOURCE_COMMIT}" ]; then
    fail "${TAG} already exists on commit ${TARGET_COMMIT:0:12}, but ${SOURCE_TAG} is commit ${SOURCE_COMMIT:0:12}. A different build was already released as ${TAG}, and a published stable version is never moved. Cut a new version, or delete the ${TAG} tag and its GitHub Release first if it was tagged by mistake."
  fi

  # Same commit is not yet the same promotion. Two prereleases can sit on one
  # commit (re-running a prerelease release cuts rc.4 where rc.3 already is)
  # with different images behind them, and an ordinary release may have cut
  # this version there. Resuming either would repoint a published image. So
  # the tag has to say which prerelease it was promoted from, and only an
  # annotated tag has a message of its own to say it in.
  RECORDED=""
  if [ "$(git cat-file -t "refs/tags/${TAG}" 2>/dev/null || true)" == "tag" ]; then
    RECORDED=$(git cat-file -p "refs/tags/${TAG}" | sed -n 's/^Promoted-From: //p' | tail -n 1)
  fi
  if [ -z "${RECORDED}" ]; then
    fail "${TAG} already exists on the commit of ${SOURCE_TAG}, and it was not cut by a promotion (its tag has no Promoted-From line). That version is already released, so there is nothing to promote."
  fi
  if [ "${RECORDED}" != "${SOURCE_TAG}" ]; then
    fail "${TAG} was already promoted from ${RECORDED}. ${SOURCE_TAG} sits on the same commit but is a separate image, and promoting it would repoint a published version. Cut a new version."
  fi
  echo "::notice::promote-from: ${TAG} was already promoted from ${SOURCE_TAG}. Resuming that promotion: every remaining step is repeated, and the ones that already landed change nothing."
fi

# ── Its neighbours ───────────────────────────────────────────────────────────
# Every stable version under this prefix, this one included, in SemVer order.
# The prefix is compared as a literal string rather than handed to `git tag -l`
# as a glob, so a prefix containing `*` or `[` cannot widen the match.
STABLE_VERSIONS=""
while IFS= read -r t; do
  [[ "${t}" == "${TAG_PREFIX}"* ]] || continue
  rest="${t#"${TAG_PREFIX}"}"
  if [[ "${rest}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    STABLE_VERSIONS="${STABLE_VERSIONS}${rest}"$'\n'
  fi
done < <(git tag -l)

SORTED=$(printf '%s%s\n' "${STABLE_VERSIONS}" "${VERSION}" | LC_ALL=C sort -u -t. -k1,1n -k2,2n -k3,3n)
PREVIOUS_VERSION=$(printf '%s\n' "${SORTED}" | awk -v v="${VERSION}" '$0 == v { print prev; exit } { prev = $0 }')
HIGHEST_VERSION=$(printf '%s\n' "${SORTED}" | tail -n 1)

PREVIOUS_TAG=""
[ -z "${PREVIOUS_VERSION}" ] || PREVIOUS_TAG="${TAG_PREFIX}${PREVIOUS_VERSION}"

TAG_LATEST="false"
if [ "${HIGHEST_VERSION}" == "${VERSION}" ]; then
  TAG_LATEST="true"
else
  echo "::notice::promote-from: ${TAG} is not the highest stable version (${TAG_PREFIX}${HIGHEST_VERSION} is), so the :latest image tag is left where it is."
fi

echo "Promoting ${SOURCE_TAG} (${SOURCE_COMMIT:0:12}) to ${TAG}."
echo "Previous stable tag: ${PREVIOUS_TAG:-none}"

emit source_tag "${SOURCE_TAG}"
emit commit "${SOURCE_COMMIT}"
emit version "${VERSION}"
emit tag "${TAG}"
emit previous_tag "${PREVIOUS_TAG}"
emit tag_latest "${TAG_LATEST}"
emit marker "${MARKER}"
