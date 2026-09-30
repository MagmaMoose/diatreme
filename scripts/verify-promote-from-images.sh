#!/usr/bin/env bash
# Check that every image a `promote-from` run is about to retag is in the
# registry, BEFORE the stable tag is cut.
#
# WHY THIS EXISTS. A promotion has no rebuild to fall back on: the point is to
# ship the artifact that was tested, so a source image that is not there is a
# hard stop. The only question is when the run finds out. The retag sits after
# the git tag in the step order, so without this check a missing image is
# discovered with `v1.5.0` already pushed and nothing behind it, and the way
# out is deleting a release tag by hand. Asking first means the run fails with
# nothing written: no tag, no image, no GitHub Release.
#
# A prerelease tag with no image is not exotic. Its release run pushed the git
# tag and then failed to build, a registry retention policy cleaned it up, or
# one target of a multi-image repository never landed.
#
# Only a definite "not there" stops the run. A registry that would not answer
# (an outage, an expired credential, a client too old for the probe) is warned
# about and let through, because the retag that follows settles it either way
# and fails the run itself if the image really is unreachable. Failing here on
# a shrug would block promotions on any registry the probe cannot read.
#
# "Not there" has to be said twice. `probe-image-tag.sh` asks through
# `docker buildx imagetools`, and a registry that serves plain Distribution V2
# but mishandles a newer endpoint can answer that client with a 404 for an
# image that pulls fine; the promote step already carries a pull/tag/push
# fallback for one such registry. So an absent verdict is put to
# `docker manifest inspect`, which speaks only the manifest API. If that finds
# the image, it is there. If that also says not found, it is missing. If it
# fails some other way, nobody knows, and it joins the warned-about cases.
#
# What follows from "only a definite absence stops the run": this check cannot
# promise that a missing image is always caught before the tag. A registry
# that answers a missing repository with 401 is, from here, a registry that
# would not say. The retag then fails after the tag is pushed. Where the cause
# can be fixed, running the promotion again finishes it; where the image is
# really gone, the stable tag is left to be deleted by hand.
#
# Required env:
#   SOURCE_REFS - newline-separated, fully-qualified refs to check, e.g.
#                 ghcr.io/acme/app:v1.5.0-rc.3. Blank lines are ignored.
#
# Exit codes:
#   0 - every ref is present, or could not be determined.
#   1 - at least one ref is definitely absent, or SOURCE_REFS named none.

set -euo pipefail

SOURCE_REFS="${SOURCE_REFS:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERDICT_TMP=$(mktemp)
trap 'rm -f "${VERDICT_TMP}"' EXIT

CHECKED=0
UNKNOWN=0
MISSING=()

while IFS= read -r ref; do
  [ -n "${ref}" ] || continue
  CHECKED=$((CHECKED + 1))

  : > "${VERDICT_TMP}"
  if IMAGE_REF="${ref}" VERDICT_FILE="${VERDICT_TMP}" "${SCRIPT_DIR}/probe-image-tag.sh"; then
    continue
  fi

  if [ "$(cat "${VERDICT_TMP}")" != "absent" ]; then
    # The probe has already printed the reason as a warning.
    UNKNOWN=$((UNKNOWN + 1))
    continue
  fi

  STATUS=0
  DETAIL=$(docker manifest inspect "${ref}" 2>&1 >/dev/null) || STATUS=$?
  if [ "${STATUS}" -eq 0 ]; then
    echo "verify-promote-from-images: ${ref} is in the registry (confirmed by docker manifest inspect)."
    continue
  fi

  # The second client has to say "not there" in its own words as well. The
  # probe reads absence generously (any reply containing `404` or `not found`),
  # which costs its other caller one warning and would cost this one a
  # promotion: an outage on a tag like `v1.404.0-rc.1` is not a missing image.
  # No bare status code in this pattern for that reason.
  if printf '%s' "${DETAIL}" | grep -qiE 'no such manifest|manifest unknown|manifest_unknown|name unknown|name_unknown|not found'; then
    MISSING+=("${ref}")
    continue
  fi
  DETAIL="${DETAIL//$'\n'/ }"
  echo "::warning::verify-promote-from-images: ${ref} looked absent to one registry client and the other could not confirm it (${DETAIL:-no error output}). Leaving it to the retag."
  UNKNOWN=$((UNKNOWN + 1))
done <<< "${SOURCE_REFS}"

if [ "${CHECKED}" -eq 0 ]; then
  echo "::error::promote-from: no source image could be derived to check. Nothing was tagged or released."
  exit 1
fi

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "::error::promote-from: ${#MISSING[@]} of ${CHECKED} source image(s) are not in the registry: ${MISSING[*]}. A promotion retags the image that was tested and never rebuilds it, so there is nothing to promote. Nothing was tagged or released. Cut a new prerelease and promote that one."
  exit 1
fi

if [ "${UNKNOWN}" -gt 0 ]; then
  echo "verify-promote-from-images: ${UNKNOWN} of ${CHECKED} source image(s) could not be checked; the retag will settle them."
else
  echo "verify-promote-from-images: all ${CHECKED} source image(s) are in the registry."
fi
