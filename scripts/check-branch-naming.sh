#!/usr/bin/env bash
set -euo pipefail

branch="${GITHUB_HEAD_REF:-}"
PROMOTE_PREFIX="${PROMOTE_BRANCH_PREFIX:-promote}"

# Baseline TBD types plus the common operational prefixes teams reach for
# (deploy/, release/, build/, revert/). The check is meant to keep branch
# names sane, not to police a minimal Conventional-Commit set, so the default
# leans permissive. Repos that need more can widen it without editing this
# script via EXTRA_BRANCH_PREFIXES (action input `extra-branch-prefixes`).
#
# claude/ and codex/ are the branch names coding agents create for themselves,
# and they are here as TYPES rather than in the bot bypass below on purpose.
# The bypass exists for branches that cannot be named (dependabot encodes an
# ecosystem and a version in its ref); an agent branch is an ordinary
# <type>/<description> and the rest of the rule should still hold for it. A
# bypass would also accept `claude` with no slash at all.
default_prefixes="feat|fix|chore|hotfix|docs|refactor|perf|test|ci|style|build|revert|deploy|release|claude|codex"

# EXTRA_BRANCH_PREFIXES accepts a comma-, space-, or pipe-separated list.
# Normalise any of those separators to a single `|` and trim empties so the
# alternation stays well-formed no matter how the caller spelled the list.
extra="$(printf '%s' "${EXTRA_BRANCH_PREFIXES:-}" | tr -s ' \t\n,|' '|')"
extra="${extra#|}"
extra="${extra%|}"

# Each token lands verbatim inside an ERE alternation, so a stray metacharacter
# silently changes what the gate means: '.*' accepts every branch, and '(' makes
# `[[ =~ ]]` reject even valid ones with a raw bash error. A trailing '/' is the
# natural way to spell a prefix, so tolerate it; reject anything else loudly.
if [[ -n "${extra}" ]]; then
  IFS='|' read -r -a extra_tokens <<< "${extra}"
  clean=()
  for tok in "${extra_tokens[@]}"; do
    tok="${tok%/}"
    if [[ ! "${tok}" =~ ^[A-Za-z0-9_-]+$ ]]; then
      echo "::error::extra-branch-prefixes contains an invalid prefix '${tok}'; use only letters, digits, '_' or '-'."
      exit 1
    fi
    clean+=("${tok}")
  done
  extra="$(IFS='|'; printf '%s' "${clean[*]}")"
fi

# merge-back/ is the branch Diatreme opens a release branch's merge-back pull
# request from (`release-branch-merge-back`). Like the promote prefix it is
# Diatreme's own, so its own check must never refuse it.
prefixes="${default_prefixes}|${PROMOTE_PREFIX}|merge-back"
if [[ -n "${extra}" ]]; then
  prefixes="${prefixes}|${extra}"
fi
allowed="^(${prefixes})/"

# Bot-generated PR branches follow each bot's own naming convention
# (e.g. `dependabot/github_actions/actions/upload-artifact-7`,
# `renovate/npm-foo-1.x`) and do not fit the TBD <type>/<description>
# shape. Skip the check rather than trying to bend the regex around them.
bot_prefixes="^(dependabot|renovate)/"

if [[ -z "${branch}" ]]; then
  echo "::error::GITHUB_HEAD_REF is empty; branch naming can only be checked on pull_request events."
  exit 1
fi

if [[ "${branch}" =~ ${bot_prefixes} ]]; then
  echo "Branch '${branch}' is a bot-generated branch; skipping TBD naming check."
  exit 0
fi

# ── branch-name-patterns: the team's own convention, instead of the types ──
# Each pattern is a whole branch name with placeholders, matched anchored at
# both ends. Everything outside a placeholder is literal: the pattern is turned
# into a regex here, character by character, so a `.` or `+` in it cannot
# silently widen the check the way a raw regex would.
#
#   {issue}    an issue number: digits
#   {version}  major.minor.patch, no leading zeros
#   {name}     lowercase words joined by single hyphens: search-filter
#   *          anything within one path segment (no `/`), at least one char
#   **         anything at all, `/` included
#
# Diatreme's own branches (the promote prefix and merge-back/) and the bots are
# accepted whatever the patterns say.
pattern_to_regex() {
  local p="$1" re="" c
  while [[ -n "${p}" ]]; do
    case "${p}" in
      '{issue}'*)   re+='[0-9]+'; p="${p#'{issue}'}"; continue ;;
      '{version}'*) re+='(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'; p="${p#'{version}'}"; continue ;;
      '{name}'*)    re+='[a-z0-9]+(-[a-z0-9]+)*'; p="${p#'{name}'}"; continue ;;
      '**'*)        re+='.+'; p="${p#'**'}"; continue ;;
      '*'*)         re+='[^/]+'; p="${p#'*'}"; continue ;;
      '{'*)
        echo "::error::branch-name-patterns: unknown placeholder in '$1'. Use {issue}, {version} or {name}." >&2
        return 1
        ;;
    esac
    c="${p:0:1}"
    p="${p:1}"
    case "${c}" in
      '.'|'^'|'$'|'+'|'?'|'('|')'|'['|']'|'}'|'|'|'\') re+="\\${c}" ;;
      *) re+="${c}" ;;
    esac
  done
  printf '^%s$' "${re}"
}

if [[ -n "${BRANCH_NAME_PATTERNS:-}" ]]; then
  if [[ "${branch}" =~ ^(${PROMOTE_PREFIX}|merge-back)/ ]]; then
    echo "Branch '${branch}' is a Diatreme branch; accepted."
    exit 0
  fi
  patterns=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "${line}" ]] && patterns+=("${line}")
  done < <(printf '%s\n' "${BRANCH_NAME_PATTERNS}" | tr ',' '\n')
  if [[ "${#patterns[@]}" -eq 0 ]]; then
    echo "::error::branch-name-patterns is set but holds no pattern."
    exit 1
  fi
  for pat in "${patterns[@]}"; do
    regex=$(pattern_to_regex "${pat}") || exit 1
    if [[ "${branch}" =~ ${regex} ]]; then
      echo "Branch '${branch}' matches '${pat}'."
      exit 0
    fi
  done
  echo "::error::Branch '${branch}' does not match any allowed branch name."
  echo "::error::Allowed: $(IFS=','; printf '%s' "${patterns[*]}" | sed 's/,/, /g')"
  exit 1
fi

if [[ "${branch}" =~ ${allowed} ]]; then
  echo "Branch '${branch}' follows TBD naming convention."
else
  echo "::error::Branch '${branch}' does not follow TBD naming convention."
  echo "::error::Expected format: <type>/<description>"
  echo "::error::Allowed types: ${prefixes//|/, }"
  exit 1
fi
