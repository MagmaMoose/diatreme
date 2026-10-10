#!/usr/bin/env bats

# Behaviour coverage for the two steps that run after a stable release from a
# release branch: scripts/merge-back-release-branch.sh
# (`release-branch-merge-back`) and scripts/clean-up-release-branches.sh
# (`release-branch-cleanup`).
#
# The merge-back must find the right release branch from what was released,
# open its pull request from a merge-back branch and never from the release
# branch itself (whose "Update branch" button would pull unreleased work into
# what production builds), and stay idempotent. The cleanup must delete only
# older lines the target already contains, and keep everything else.

MERGE_BACK="${BATS_TEST_DIRNAME}/../../scripts/merge-back-release-branch.sh"
CLEANUP="${BATS_TEST_DIRNAME}/../../scripts/clean-up-release-branches.sh"

setup() {
  WORK=$(mktemp -d)
  BIN="${WORK}/bin"
  mkdir -p "${BIN}"
  export GITHUB_OUTPUT="${WORK}/output"
  export STUB_GH_LOG="${WORK}/gh.log"
  export STUB_REFS="${WORK}/refs"          # one file per remote branch: its sha
  export STUB_COMPARE="${WORK}/compare"    # one file per compare A...B: its status
  mkdir -p "${STUB_REFS}" "${STUB_COMPARE}"
  : > "${GITHUB_OUTPUT}"; : > "${STUB_GH_LOG}"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  cat > "${BIN}/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "${STUB_GH_LOG}"
key() { printf '%s' "$1" | tr '/' '_'; }
if [ "$1" == "api" ]; then
  case "$2 $3" in
    "-X POST")
      case "$4" in
        */git/refs)
          ref=""; sha=""
          for a in "$@"; do case "$a" in ref=refs/heads/*) ref="${a#ref=refs/heads/}" ;; sha=*) sha="${a#sha=}" ;; esac; done
          [ -z "${STUB_CREATE_FAIL:-}" ] || { echo "${STUB_CREATE_FAIL}" >&2; exit 1; }
          echo "${sha}" > "${STUB_REFS}/$(key "${ref}")"; exit 0 ;;
        */merges)
          [ -z "${STUB_MERGE_FAIL:-}" ] || { echo "${STUB_MERGE_FAIL}" >&2; exit 1; }
          exit 0 ;;
      esac ;;
    "-X PATCH") exit 0 ;;
    "-X DELETE")
      ref="${4#*/git/refs/heads/}"
      case " ${STUB_DELETE_FAIL:-} " in *" ${ref} "*) echo "gh: Cannot delete (HTTP 422)" >&2; exit 1 ;; esac
      rm -f "${STUB_REFS}/$(key "${ref}")"; exit 0 ;;
  esac
  case "$2" in
    */git/ref/heads/*)
      f="${STUB_REFS}/$(key "${2#*/git/ref/heads/}")"
      [ -f "${f}" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
      cat "${f}"; exit 0 ;;
    */compare/*)
      f="${STUB_COMPARE}/$(key "${2#*/compare/}")"
      [ -f "${f}" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
      cat "${f}"; exit 0 ;;
    repos/acme/app)
      echo "${STUB_ALLOW_MERGE:-true}"; exit 0 ;;
  esac
fi
if [ "$1 $2" == "pr list" ]; then printf '%s' "${STUB_PR_EXISTING:-}"; exit 0; fi
if [ "$1 $2" == "pr create" ]; then
  for a in "$@"; do printf '%s\n' "$a"; done > "${STUB_GH_LOG}.pr"
  echo "https://github.com/acme/app/pull/77"; exit 0
fi
exit 0
EOF
  chmod +x "${BIN}/gh"
  export PATH="${BIN}:${PATH}"

  git init --initial-branch=master "${WORK}/repo" >/dev/null
  cd "${WORK}/repo"
  git config user.name tester
  git config user.email t@example.com
  commit "initial"
  unset STUB_CREATE_FAIL STUB_MERGE_FAIL STUB_DELETE_FAIL STUB_ALLOW_MERGE STUB_PR_EXISTING || true
}

teardown() {
  cd /
  rm -rf "${WORK}"
}

commit() { git commit --allow-empty -q -m "$1"; }
out() { grep -E "^$1=" "${GITHUB_OUTPUT}" | tail -n 1 | cut -d= -f2-; }
key() { printf '%s' "$1" | tr '/' '_'; }

# remote <branch> <sha>: the branch exists on the remote, and in the clone's
# remote-tracking refs as actions/checkout leaves them.
remote() {
  echo "$2" > "${STUB_REFS}/$(key "$1")"
  git update-ref "refs/remotes/origin/$1" "$2"
}
# compare <base> <head> <status>
compare() { echo "$3" > "${STUB_COMPARE}/$(key "$1...$2")"; }

merge_back() {
  run env GH_TOKEN=t REPO_FULL=acme/app TARGET="${TARGET_BRANCH:-master}" \
    VERSION="$1" TAG="v$1" REF_NAME="${REF:-master}" PROMOTE_SOURCE_COMMIT="${SOURCE:-}" "${MERGE_BACK}"
}

clean_up() {
  run env GH_TOKEN=t REPO_FULL=acme/app TARGET="${TARGET_BRANCH:-master}" VERSION="$1" "${CLEANUP}"
}

# A commit on the merge-back branch that the release branch does not have, as
# resolving a conflict there leaves.
conflict_resolution() {
  git checkout -q -b resolution "${C0}"
  commit "resolve conflict"
  git rev-parse HEAD
  git checkout -q -
}

opened_pr() { [ -f "${STUB_GH_LOG}.pr" ]; }
refute() { if "$@"; then echo "expected to fail: $*"; return 1; fi; }

# A release line with one hotfix on it: release/1.4.0 was cut at C0, v1.4.0
# promoted there, a fix landed (C1) and was promoted as v1.4.1.
hotfixed_line() {
  C0=$(git rev-parse HEAD)
  commit "hotfix"
  C1=$(git rev-parse HEAD)
  git checkout -q master 2>/dev/null || true
  remote release/1.4.0 "${C1}"
  remote master "${C0}"
  compare master "${C1}" ahead
}

# ── merge-back: which branch ─────────────────────────────────────────────────

@test "a promotion finds the release branch that holds the promoted commit" {
  hotfixed_line
  SOURCE="${C1}" merge_back 1.4.1
  [ "${status}" -eq 0 ]
  grep -q "ref=refs/heads/merge-back/release-1.4.0" "${STUB_GH_LOG}"
  grep -q "sha=${C1}" "${STUB_GH_LOG}"
  opened_pr
  grep -qx -- "--head" "${STUB_GH_LOG}.pr"
  grep -qx "merge-back/release-1.4.0" "${STUB_GH_LOG}.pr"
  grep -qx "master" "${STUB_GH_LOG}.pr"
  [ "$(out merge-back-pr)" = "https://github.com/acme/app/pull/77" ]
}

@test "the pull request never comes from the release branch itself" {
  hotfixed_line
  SOURCE="${C1}" merge_back 1.4.1
  run grep -A1 -x -- "--head" "${STUB_GH_LOG}.pr"
  [[ "${output}" != *$'\n'"release/1.4.0" ]]
}

@test "the pull request asks for a merge commit and names the release" {
  hotfixed_line
  SOURCE="${C1}" merge_back 1.4.1
  grep -q "Create a merge commit" "${STUB_GH_LOG}.pr"
  grep -q "Merge release/1.4.0 into master" "${STUB_GH_LOG}.pr"
  grep -q "v1.4.1" "${STUB_GH_LOG}.pr"
}

@test "a run on the release branch itself uses that branch" {
  hotfixed_line
  REF=release/1.4.0 merge_back 1.4.1
  [ "${status}" -eq 0 ]
  opened_pr
}

@test "of several release branches holding the commit, the one of the released line wins" {
  hotfixed_line
  remote release/1.5.0 "${C1}"   # cut later from a main line that already had C1
  remote release/1.3.0 "${C0}"
  SOURCE="${C1}" merge_back 1.4.1
  grep -q "ref=refs/heads/merge-back/release-1.4.0" "${STUB_GH_LOG}"
}

@test "a release that did not come from a release branch is left alone" {
  merge_back 1.4.1
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"was not released from a release branch"* ]]
  refute opened_pr
}

@test "a prerelease is not merged back" {
  hotfixed_line
  REF=release/1.4.0 merge_back 1.4.1-rc.1
  [ "${status}" -eq 0 ]
  refute opened_pr
}

@test "a release branch the target already contains has nothing to merge back" {
  hotfixed_line
  compare master "${C1}" behind
  SOURCE="${C1}" merge_back 1.4.1
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already contains"* ]]
  refute opened_pr
  refute grep -q -- "-X POST" "${STUB_GH_LOG}"
}

# ── merge-back: the branch it opens from ────────────────────────────────────

@test "an open merge-back pull request is reused, not duplicated" {
  hotfixed_line
  remote merge-back/release-1.4.0 "${C1}"
  export STUB_PR_EXISTING="https://github.com/acme/app/pull/70"
  SOURCE="${C1}" merge_back 1.4.1
  [ "${status}" -eq 0 ]
  refute opened_pr
  [ "$(out merge-back-pr)" = "https://github.com/acme/app/pull/70" ]
}

@test "a merge-back branch behind the release branch is moved forward" {
  hotfixed_line
  remote merge-back/release-1.4.0 "${C0}"
  compare "${C0}" "${C1}" ahead
  SOURCE="${C1}" merge_back 1.4.1
  grep -q -- "-X PATCH repos/acme/app/git/refs/heads/merge-back/release-1.4.0 -f sha=${C1} -F force=false" "${STUB_GH_LOG}"
  refute grep -q "repos/acme/app/merges" "${STUB_GH_LOG}"
}

@test "a merge-back branch with commits of its own gets the release branch merged in" {
  hotfixed_line
  resolution=$(conflict_resolution)
  remote merge-back/release-1.4.0 "${resolution}"
  compare "${resolution}" "${C1}" diverged
  SOURCE="${C1}" merge_back 1.4.1
  grep -q -- "-X POST repos/acme/app/merges -f base=merge-back/release-1.4.0 -f head=${C1}" "${STUB_GH_LOG}"
  refute grep -q -- "-X PATCH" "${STUB_GH_LOG}"
}

@test "a merge-back branch that cannot absorb the release branch warns and still reports" {
  hotfixed_line
  resolution=$(conflict_resolution)
  remote merge-back/release-1.4.0 "${resolution}"
  compare "${resolution}" "${C1}" diverged
  export STUB_MERGE_FAIL="gh: Merge conflict (HTTP 409)"
  SOURCE="${C1}" merge_back 1.4.1
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"::warning::"*"never the other way round"* ]]
}

@test "a merge-back branch that cannot be created is a warning, not a failed release" {
  hotfixed_line
  export STUB_CREATE_FAIL="gh: Resource not accessible by integration (HTTP 403)"
  SOURCE="${C1}" merge_back 1.4.1
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"::warning::"*"by hand"* ]]
  refute opened_pr
}

@test "a repository that forbids merge commits is warned about, in the log and the pull request" {
  hotfixed_line
  export STUB_ALLOW_MERGE=false
  SOURCE="${C1}" merge_back 1.4.1
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"does not allow merge commits"* ]]
  grep -q "does not allow merge commits" "${STUB_GH_LOG}.pr"
}

@test "the target branch is configurable" {
  hotfixed_line
  remote develop "${C0}"
  compare develop "${C1}" diverged
  TARGET_BRANCH=develop SOURCE="${C1}" merge_back 1.4.1
  grep -qx "develop" "${STUB_GH_LOG}.pr"
}

# ── cleanup ──────────────────────────────────────────────────────────────────

@test "older lines the target contains are deleted" {
  C0=$(git rev-parse HEAD)
  remote release/1.2.0 "${C0}"
  remote release/1.3.0 "${C0}"
  compare master "${C0}" behind
  clean_up 1.4.0
  [ "${status}" -eq 0 ]
  grep -q -- "-X DELETE repos/acme/app/git/refs/heads/release/1.2.0" "${STUB_GH_LOG}"
  grep -q -- "-X DELETE repos/acme/app/git/refs/heads/release/1.3.0" "${STUB_GH_LOG}"
  [ "$(out release-branches-deleted)" = "2" ]
}

@test "the released line and newer lines are kept" {
  C0=$(git rev-parse HEAD)
  remote release/1.4.0 "${C0}"
  remote release/1.5.0 "${C0}"
  remote release/2.0.0 "${C0}"
  compare master "${C0}" behind
  clean_up 1.4.1
  refute grep -q -- "-X DELETE" "${STUB_GH_LOG}"
  [ "$(out release-branches-deleted)" = "0" ]
}

@test "versions compare numerically" {
  C0=$(git rev-parse HEAD)
  remote release/1.9.0 "${C0}"
  remote release/1.10.0 "${C0}"
  compare master "${C0}" behind
  clean_up 1.10.0
  grep -q "heads/release/1.9.0" "${STUB_GH_LOG}"
  refute grep -q "heads/release/1.10.0" "${STUB_GH_LOG}"
}

@test "a line with commits the target lacks is kept, with a notice" {
  C0=$(git rev-parse HEAD)
  commit "unmerged hotfix"
  C1=$(git rev-parse HEAD)
  remote release/1.3.0 "${C1}"
  compare master "${C1}" ahead
  clean_up 1.4.0
  refute grep -q -- "-X DELETE" "${STUB_GH_LOG}"
  [[ "${output}" == *"keeping release/1.3.0"* ]]
}

@test "a comparison that cannot be made keeps the branch" {
  C0=$(git rev-parse HEAD)
  remote release/1.3.0 "${C0}"
  clean_up 1.4.0
  refute grep -q -- "-X DELETE" "${STUB_GH_LOG}"
}

@test "branches outside the release families, or without a version, are never touched" {
  C0=$(git rev-parse HEAD)
  for b in hotfix/1.0.0 feature/1-x release/next master test merge-back/release-1.0.0; do
    remote "${b}" "${C0}"
  done
  compare master "${C0}" behind
  clean_up 1.4.0
  refute grep -q -- "-X DELETE" "${STUB_GH_LOG}"
}

@test "a deleted line takes its merged merge-back branch with it" {
  C0=$(git rev-parse HEAD)
  remote release/1.3.0 "${C0}"
  remote merge-back/release-1.3.0 "${C0}"
  compare master "${C0}" behind
  clean_up 1.4.0
  grep -q "heads/merge-back/release-1.3.0" "${STUB_GH_LOG}"
}

@test "a branch that cannot be deleted is a warning and the rest go on" {
  C0=$(git rev-parse HEAD)
  remote release/1.2.0 "${C0}"
  remote release/1.3.0 "${C0}"
  compare master "${C0}" behind
  export STUB_DELETE_FAIL="release/1.2.0"
  clean_up 1.4.0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"::warning::"*"could not delete release/1.2.0"* ]]
  [ "$(out release-branches-deleted)" = "1" ]
}

@test "a prerelease cleans nothing up" {
  C0=$(git rev-parse HEAD)
  remote release/1.2.0 "${C0}"
  compare master "${C0}" behind
  clean_up 1.4.0-rc.1
  [ "${status}" -eq 0 ]
  refute grep -q -- "-X DELETE" "${STUB_GH_LOG}"
}

@test "a run on another line's release branch does not pick that branch" {
  hotfixed_line
  remote release/1.5.0 "${C1}"
  REF=release/1.5.0 SOURCE="${C1}" merge_back 1.4.1
  grep -q "ref=refs/heads/merge-back/release-1.4.0" "${STUB_GH_LOG}"
  refute grep -q "merge-back/release-1.5.0" "${STUB_GH_LOG}"
}
