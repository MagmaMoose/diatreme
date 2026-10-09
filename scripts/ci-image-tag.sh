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
# Env:
#   VERSION_OVERRIDE  the validated version-override, without `v` (empty when
#                     unset).
#   PR_NUMBER         github.event.pull_request.number (empty outside a PR).
#   REF_NAME          github.ref_name.
# Reads HEAD for the commit and its committer time.
#
# Output: the tag, on stdout.

set -euo pipefail

VERSION_OVERRIDE="${VERSION_OVERRIDE:-}"
PR_NUMBER="${PR_NUMBER:-}"
REF_NAME="${REF_NAME:-}"

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
