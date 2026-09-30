#!/usr/bin/env bash
# Read the `deploy-pr-targets` input: which kustomize overlays a release is
# deployed to, and in what order.
#
# The input is a JSON object from an environment in `environments` to the
# overlay directories its releases go to, in promotion order:
#
#   {"prod": ["k8s/overlays/acc", "k8s/overlays/prd"]}
#
# A release in `prod` opens the deploy PR for `k8s/overlays/acc`; merging that
# one opens the PR for `k8s/overlays/prd`. An overlay is named by its last path
# segment (`acc`, `prd`), and that name is what the deploy PR branch carries
# (`deploy/acc/v1.2.3`), so a name may appear only once across the whole object:
# a merged `deploy/prd/...` branch has to lead back to exactly one overlay.
#
# Usage:
#   deploy-targets.sh validate        exit 1 with an ::error:: on a bad value
#   deploy-targets.sh first <env>     the first overlay for <env>, or nothing
#   deploy-targets.sh path <name>     the overlay called <name>, or nothing
#   deploy-targets.sh next <name>     the overlay after <name>, or nothing
#   deploy-targets.sh paths           every overlay, one per line
#
# Every command but `validate` validates first, so a caller never acts on a
# value that `validate` would have refused.
#
# Required env:
#   DEPLOY_PR_TARGETS  the input, as JSON
# Optional env:
#   ENVIRONMENTS       JSON array of environment names; every key must be one

set -euo pipefail

err() { echo "::error::deploy-pr-targets: $*" >&2; exit 1; }

TARGETS="${DEPLOY_PR_TARGETS:-}"

# One overlay per line as `<env>\t<index>\t<path>`, paths normalised (no
# trailing slash, no leading `./`), in the object's own order.
flatten() {
  printf '%s' "${TARGETS}" | jq -r '
    to_entries[] | .key as $env
    | .value | to_entries[]
    | "\($env)\t\(.key)\t\(.value | sub("^(\\./)+"; "") | sub("/+$"; ""))"'
}

validate() {
  [ -n "${TARGETS}" ] || err "is empty"
  printf '%s' "${TARGETS}" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || err "must be a JSON object from environment to a list of overlay directories, got: ${TARGETS}"
  printf '%s' "${TARGETS}" | jq -e 'length > 0' >/dev/null \
    || err "names no environment"

  local bad
  bad=$(printf '%s' "${TARGETS}" | jq -r '
    to_entries[]
    | select((.value | type) != "array" or (.value | length) == 0
             or any(.value[]; (type != "string") or (. == "")))
    | .key')
  [ -z "${bad}" ] || err "the value for '${bad%%$'\n'*}' must be a non-empty list of overlay directories"

  if [ -n "${ENVIRONMENTS:-}" ]; then
    local unknown
    unknown=$(jq -rn --argjson t "${TARGETS}" --argjson e "${ENVIRONMENTS}" \
      '[$t | keys[] | select(. as $k | $e | index($k) | not)] | join(", ")')
    [ -z "${unknown}" ] || err "names environment(s) not in environments: ${unknown} (environments: ${ENVIRONMENTS})"
  fi

  local path dup
  while IFS=$'\t' read -r _ _ path; do
    case "${path}" in
      ''|/*) err "overlay '${path}' must be a directory relative to the repository root" ;;
    esac
    case "/${path}/" in
      */../*|*/./*) err "overlay '${path}' must not contain '.' or '..' segments" ;;
    esac
  done < <(flatten)

  # sort | uniq -d rather than an associative array: macOS runners ship bash 3.2.
  dup=$(flatten | cut -f3 | sort | uniq -d | head -n 1)
  [ -z "${dup}" ] || err "overlay '${dup}' is listed twice"
  dup=$(flatten | cut -f3 | sed 's#.*/##' | sort | uniq -d | head -n 1)
  [ -z "${dup}" ] \
    || err "more than one overlay is called '${dup}'; the name is what the deploy PR branch carries, so it has to be unique"
}

cmd="${1:-}"
case "${cmd}" in
  validate)
    validate
    ;;
  first)
    validate
    env_name="${2:?usage: deploy-targets.sh first <env>}"
    flatten | awk -F'\t' -v e="${env_name}" '$1 == e && $2 == 0 { print $3; exit }'
    ;;
  path|next)
    validate
    name="${2:?usage: deploy-targets.sh ${cmd} <name>}"
    flatten | awk -F'\t' -v n="${name}" -v cmd="${cmd}" '
      {
        base = $3; sub(/.*\//, "", base)
        if (found && $1 == env) { print $3; exit }
        if (found) exit
        if (base == n) {
          if (cmd == "path") { print $3; exit }
          found = 1; env = $1
        }
      }'
    ;;
  paths)
    validate
    flatten | cut -f3
    ;;
  *)
    echo "usage: deploy-targets.sh validate|first <env>|path <name>|next <name>|paths" >&2
    exit 2
    ;;
esac
