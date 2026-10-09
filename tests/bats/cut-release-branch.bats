#!/usr/bin/env bats

# Behaviour coverage for scripts/cut-release-branch.sh (`mode: cut-release-branch`).
#
# The branch is the release: once `release/X.Y.Z` exists the release workflow
# cuts candidates from it. So the script has to refuse every version that is
# not a new release (already shipped, not above the newest, carrying a
# prerelease part) before anything is created, still let a shipped line be
# reopened from its own tag for a patch, and be safe to re-run.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/cut-release-branch.sh"

setup() {
  WORK=$(mktemp -d)
  BIN="${WORK}/bin"
  mkdir -p "${BIN}"
  export GITHUB_OUTPUT="${WORK}/output"
  export STUB_GH_LOG="${WORK}/gh.log"
  : > "${GITHUB_OUTPUT}"; : > "${STUB_GH_LOG}"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  # STUB_BRANCH_SHA: where the branch already points (unset: 404).
  # STUB_LOOKUP_ERR: a lookup failure that is not a 404.
  # STUB_CREATE_ERR: makes the create call fail with that message;
  # STUB_BRANCH_SHA_AFTER: where the branch points once the create failed.
  cat > "${BIN}/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "${STUB_GH_LOG}"
if [ "$1" == "api" ] && [ "$2" == "-X" ] && [ "$3" == "POST" ]; then
  if [ -n "${STUB_CREATE_ERR:-}" ]; then
    echo "${STUB_CREATE_ERR}" >&2
    [ -z "${STUB_BRANCH_SHA_AFTER:-}" ] || echo "${STUB_BRANCH_SHA_AFTER}" > "${STUB_GH_LOG}.after"
    exit 1
  fi
  exit 0
fi
if [ "$1" == "api" ]; then
  if [ -f "${STUB_GH_LOG}.after" ]; then cat "${STUB_GH_LOG}.after"; exit 0; fi
  if [ -n "${STUB_LOOKUP_ERR:-}" ]; then echo "${STUB_LOOKUP_ERR}" >&2; exit 1; fi
  if [ -n "${STUB_BRANCH_SHA:-}" ]; then echo "${STUB_BRANCH_SHA}"; exit 0; fi
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
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

  unset STUB_BRANCH_SHA STUB_LOOKUP_ERR STUB_CREATE_ERR STUB_BRANCH_SHA_AFTER || true
}

teardown() {
  cd /
  rm -rf "${WORK}"
}

commit() { git commit --allow-empty -q -m "$1"; }
out() { grep -E "^$1=" "${GITHUB_OUTPUT}" | tail -n 1 | cut -d= -f2-; }
created() { grep -q -- "-X POST repos/acme/app/git/refs" "${STUB_GH_LOG}"; }

cut_branch() {
  run env GH_TOKEN=t REPO_FULL=acme/app TAG_PREFIX="${PREFIX-v}" VERSION_INPUT="$1" \
    REF_NAME="${REF:-master}" DEFAULT_BRANCH=master TOKEN_SOURCE="${SOURCE:-public-app}" "${SCRIPT}"
}

@test "a new version is cut from HEAD as release/X.Y.Z" {
  git tag v1.3.2
  commit "features"
  cut_branch 1.4.0
  [ "${status}" -eq 0 ]
  created
  grep -q "ref=refs/heads/release/1.4.0" "${STUB_GH_LOG}"
  grep -q "sha=$(git rev-parse HEAD)" "${STUB_GH_LOG}"
  [ "$(out release-branch)" = "release/1.4.0" ]
  [ "$(out release-branch-sha)" = "$(git rev-parse HEAD)" ]
}

@test "the first release of a repository can be cut" {
  cut_branch 0.1.0
  [ "${status}" -eq 0 ]
  created
}

@test "a v prefix and stray whitespace on the input are tolerated" {
  cut_branch "  v1.4.0 "
  [ "${status}" -eq 0 ]
  [ "$(out release-branch)" = "release/1.4.0" ]
}

@test "a prerelease part is refused: the branch carries the release number only" {
  cut_branch 1.4.0-rc1
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"release/1.4.0"* ]]
  refute_created
}

@test "something that is not a version is refused" {
  for v in "" 1.4 1.4.0.1 release/1.4.0 01.4.0 latest; do
    cut_branch "${v}"
    [ "${status}" -eq 1 ]
  done
  refute_created
}

@test "a version already released is refused" {
  git tag v1.4.0
  commit "more work"
  cut_branch 1.4.0
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"v1.4.0 is already released"* ]]
  refute_created
}

@test "a version not above the newest release is refused" {
  git tag v1.5.0
  commit "more work"
  cut_branch 1.4.9
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not above v1.5.0"* ]]
  refute_created
}

@test "versions are compared numerically, not as text" {
  git tag v1.9.0
  commit "more work"
  cut_branch 1.10.0
  [ "${status}" -eq 0 ]
  created
}

@test "prereleases do not count as releases" {
  git tag v1.4.0-rc.1
  commit "the 1.4.0 branch was abandoned"
  cut_branch 1.4.0
  [ "${status}" -eq 0 ]
  created
}

@test "a shipped line is reopened from its own tag for a patch" {
  git tag v1.4.0
  commit "hotfix"
  git tag v1.4.1
  git checkout -q v1.4.1
  git tag v1.5.0 master   # a newer line shipped since
  REF=v1.4.1 cut_branch 1.4.0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"reopening the 1.4 line"* ]]
  created
  [[ "${output}" != *"not from the default branch"* ]]
}

@test "a tag of another line does not reopen this one" {
  git tag v1.3.2
  git tag v1.4.0 "$(git rev-parse HEAD)"
  commit "work"
  git tag v1.3.3
  cut_branch 1.4.0
  [ "${status}" -eq 1 ]
  refute_created
}

@test "a branch already on HEAD is a re-run and changes nothing" {
  export STUB_BRANCH_SHA
  STUB_BRANCH_SHA=$(git rev-parse HEAD)
  cut_branch 1.4.0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already exists"* ]]
  refute_created
  [ "$(out release-branch)" = "release/1.4.0" ]
}

@test "a branch already on another commit is refused" {
  export STUB_BRANCH_SHA=0123456789abcdef0123456789abcdef01234567
  cut_branch 1.4.0
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"already exists on 0123456789ab"* ]]
  refute_created
}

@test "a lookup that fails for another reason stops the run" {
  export STUB_LOOKUP_ERR="gh: Bad credentials (HTTP 401)"
  cut_branch 1.4.0
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"could not check"*"HTTP 401"* ]]
  refute_created
}

@test "losing the create race to a run on the same commit is fine" {
  export STUB_CREATE_ERR="gh: Reference already exists (HTTP 422)"
  export STUB_BRANCH_SHA_AFTER
  STUB_BRANCH_SHA_AFTER=$(git rev-parse HEAD)
  cut_branch 1.4.0
  [ "${status}" -eq 0 ]
  [ "$(out release-branch)" = "release/1.4.0" ]
}

@test "a refused create explains what the token needs" {
  export STUB_CREATE_ERR="gh: Resource not accessible by integration (HTTP 403)"
  cut_branch 1.4.0
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"contents: write"* ]]
  [ -z "$(out release-branch)" ]
}

@test "a branch created with GITHUB_TOKEN warns that no workflow will start" {
  SOURCE=github-token cut_branch 1.4.0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"starts no workflow"* ]]
}

@test "cutting from a branch other than the default one warns" {
  REF=feature/12-thing cut_branch 1.4.0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"not from the default branch"* ]]
}

@test "only tags under the prefix count" {
  git tag core-v2.0.0
  commit "work"
  PREFIX=v cut_branch 1.4.0
  [ "${status}" -eq 0 ]
  created
}

refute_created() {
  if created; then
    echo "a branch was created"
    return 1
  fi
}
