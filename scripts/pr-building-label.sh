#!/usr/bin/env bash
# Put `image-building-label` on a pull request while `mode: ci` builds its
# images, and take it off once every tag is pushed.
#
# WHY THIS EXISTS. A preview controller moves a pull request's preview as soon
# as it sees a new head commit, which is before that commit's image exists.
# Flux Operator's ResourceSetInputProvider keeps a pull request on its last
# exported inputs while it carries one of the provider's `spec.skip.labels`, so
# a label that is on for exactly as long as the images are missing holds the
# preview on the last commit that has one. `mode: ci` adds it before the build
# and removes it in its last step. A run that fails or is cancelled never gets
# there, and the label stays on: the new head has no image to move to.
#
# Never fails the run. The label serves the preview; the build is the product.
# Every failure (a fork's read-only token, a missing `pull-requests: write`, an
# API outage) is a warning.
#
# Loop guard. A label changed with an App token starts workflows, so a ci
# workflow that also runs on `labeled`/`unlabeled` is started again by this
# label. On a run that this label started, it is not added again, which bounds
# the chain at one extra run per change. It is still removed: a run whose
# predecessor was cancelled must not leave it on.
#
# Required env:
#   ACTION     add | remove
#   LABEL      the label name
#   GH_TOKEN, REPO_FULL, PR_NUMBER
# Optional env:
#   EVENT_ACTION  github.event.action
#   EVENT_LABEL   github.event.label.name

set -uo pipefail

warn() { echo "::warning::[image-building-label] $*"; }

ACTION="${ACTION:-}"
LABEL="${LABEL:-}"
REPO_FULL="${REPO_FULL:-}"
PR_NUMBER="${PR_NUMBER:-}"

if [ -z "${LABEL}" ] || [ -z "${REPO_FULL}" ] || [ -z "${PR_NUMBER}" ]; then
  warn "needs LABEL, REPO_FULL and PR_NUMBER; leaving the pull request's labels alone."
  exit 0
fi

case "${ACTION}" in
  add)
    case "${EVENT_ACTION:-}" in
      labeled|unlabeled)
        if [ "${EVENT_LABEL:-}" = "${LABEL}" ]; then
          warn "this run was started by '${LABEL}' being ${EVENT_ACTION}, so it does not add the label again. Remove labeled and unlabeled from the workflow's pull_request types: each change of this label starts another build."
          exit 0
        fi
        ;;
    esac
    if ERR=$(gh api -X POST "repos/${REPO_FULL}/issues/${PR_NUMBER}/labels" -f "labels[]=${LABEL}" 2>&1 >/dev/null); then
      echo "Labeled #${PR_NUMBER} '${LABEL}' until its images are pushed."
    else
      warn "could not add '${LABEL}' to #${PR_NUMBER} (${ERR//$'\n'/ }). A preview may move to this commit before its image exists. The token needs pull-requests: write."
    fi
    ;;
  remove)
    NAME=$(jq -rn --arg label "${LABEL}" '$label | @uri')
    if ERR=$(gh api -X DELETE "repos/${REPO_FULL}/issues/${PR_NUMBER}/labels/${NAME}" 2>&1 >/dev/null); then
      echo "Removed '${LABEL}' from #${PR_NUMBER}: every tag is pushed."
    elif grep -q "HTTP 404" <<< "${ERR}"; then
      echo "'${LABEL}' is not on #${PR_NUMBER}; nothing to remove."
    else
      warn "could not remove '${LABEL}' from #${PR_NUMBER} (${ERR//$'\n'/ }). Its preview stays on the last commit until a later run removes it, or someone does."
    fi
    ;;
  *)
    warn "ACTION must be add or remove, got '${ACTION}'."
    ;;
esac
exit 0
