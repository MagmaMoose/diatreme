#!/usr/bin/env bash
# The tag `mode: ci` pushes its image under.
#
# WHY THIS EXISTS. The ci build was written for pull requests and tags its
# image `pr-<N>`. Run on a push it had no number to put there, so it pushed
# `<image>:pr-`: the same tag for every push of every branch, each one silently
# overwriting the last. A branch built without a pull request (a shared
# integration branch deployed to a test environment on every merge, a feature
# branch deployed before its pull request exists) needs a tag that names the
# build, so this decides it in one place for the build and the scan:
#
#   version-override set          that version, as before
#   a pull request (PR_NUMBER)    pr-<N>, as before: release mode looks for
#                                 exactly that tag when it promotes
#   anything else (push,          <branch>-<sha7>-<commit time>
#   dispatch, merge queue, ...)
#
# `<branch>-<sha7>-<commit time>` is immutable, says where the build came from,
# and sorts. The committer time (unix seconds) is the last field, so an image
# automation policy can pick a branch's newest build numerically (Flux:
# filterTags pattern '^test-[a-f0-9]+-(?P<ts>[0-9]+)$', extract '$ts', policy
# numerical asc). It is the commit's time, not the build's, so a re-run pushes
# the same tag again instead of a second one.
#
# The branch part is the ref name lowercased, every run of characters a Docker
# tag cannot hold turned into one `-`, leading `.`/`-` dropped (a tag must start
# with a letter, digit or `_`), and cut so the whole tag fits Docker's 128
# characters.
#
# KIND=commit asks for the second tag a pull request build gets with
# `image-commit-tag`: pr-<N>-<sha7>, one per head commit, for preview
# controllers that render one deploy per commit (pr-<N> moves on every push,
# so a deploy pinned to it never rolls). sha7 comes from HEAD_SHA, the pull
# request's head, never from HEAD: on a pull request actions/checkout builds
# the merge commit, a SHA no preview controller knows.
#
# Env:
#   VERSION_OVERRIDE  the validated version-override, without `v` (empty when
#                     unset).
#   PR_NUMBER         github.event.pull_request.number (empty outside a PR).
#   REF_NAME          github.ref_name.
#   KIND              `build` (default): the tag above. `commit`: pr-<N>-<sha7>.
#   HEAD_SHA          github.event.pull_request.head.sha (KIND=commit only).
# Reads HEAD for the commit and its committer time.
#
# Output: the tag, on stdout.

set -euo pipefail

VERSION_OVERRIDE="${VERSION_OVERRIDE:-}"
PR_NUMBER="${PR_NUMBER:-}"
REF_NAME="${REF_NAME:-}"

if [ "${KIND:-build}" = "commit" ]; then
  HEAD_SHA="${HEAD_SHA:-}"
  if ! [[ "${PR_NUMBER}" =~ ^[0-9]+$ && "${HEAD_SHA}" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
    echo "::error::A commit tag needs the pull request number and head commit SHA, got '${PR_NUMBER}' and '${HEAD_SHA}'." >&2
    exit 1
  fi
  printf 'pr-%s-%s\n' "${PR_NUMBER}" "${HEAD_SHA:0:7}"
  exit 0
fi

if [ -n "${VERSION_OVERRIDE}" ]; then
  printf '%s\n' "${VERSION_OVERRIDE}"
  exit 0
fi

if [ -n "${PR_NUMBER}" ]; then
  printf 'pr-%s\n' "${PR_NUMBER}"
  exit 0
fi

SHA=$(git rev-parse --short=7 HEAD)
TIME=$(git log -1 --format=%ct HEAD)
SUFFIX="-${SHA}-${TIME}"

SLUG=$(printf '%s' "${REF_NAME}" | tr '[:upper:]' '[:lower:]' \
  | LC_ALL=C sed -E 's/[^a-z0-9._-]+/-/g; s/-+/-/g; s/^[.-]+//')
MAX=$((128 - ${#SUFFIX}))
SLUG="${SLUG:0:${MAX}}"
SLUG=$(printf '%s' "${SLUG}" | sed -E 's/[.-]+$//')
[ -n "${SLUG}" ] || SLUG="branch"

printf '%s%s\n' "${SLUG}" "${SUFFIX}"
