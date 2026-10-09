#!/usr/bin/env bats

# The release-branch flow as action.yml wires it: `release-branch-versioning:
# branch`, `mode: cut-release-branch`, `release-branch-merge-back` and
# `release-branch-cleanup`. The scripts behind them have their own suites
# (resolve-release-line-version, cut-release-branch, release-line-housekeeping);
# this one runs the real `run:` blocks of the inline steps against stubs and
# reads the step conditions, because that is where the promises are kept: an
# explicit version still outranks the branch name, a release-line tag is pushed
# in resume mode, and the housekeeping only ever follows a stable release.

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
ACTION_YML="${REPO_ROOT}/action.yml"

# The `run: |` block of the named composite step, de-indented.
run_block() {
  awk -v name="    - name: $1" '
    $0 == name { instep = 1; next }
    instep && !inrun && /^    - name: / { exit }
    instep && !inrun && /^      run: \|$/ { inrun = 1; next }
    inrun {
      if ($0 ~ /[^ ]/) { match($0, /^ */); if (RLENGTH < 8) exit }
      print substr($0, 9)
    }
  ' "${ACTION_YML}"
}

# Everything a step declares before its `run:` (name, id, if, env, with).
step_head() {
  awk -v name="    - name: $1" '
    $0 == name { instep = 1; print; next }
    instep && (/^    - name: / || /^      run: /) { exit }
    instep { print }
  ' "${ACTION_YML}"
}

run_step() {
  local name="$1"; shift
  run_block "${name}" > "${WORK}/block.sh"
  [ -s "${WORK}/block.sh" ] || { echo "no run block found for step: ${name}"; return 1; }
  run env "$@" bash "${WORK}/block.sh"
}

out() { grep -E "^$1=" "${GITHUB_OUTPUT}" | tail -n 1 | cut -d= -f2-; }

refute() {
  if "$@"; then
    echo "expected to fail, but succeeded: $*"
    return 1
  fi
}

setup() {
  WORK=$(mktemp -d)
  export GITHUB_OUTPUT="${WORK}/output"
  : > "${GITHUB_OUTPUT}"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  # A stand-in action root: the real release-line resolver, and stubs that
  # record how push-release-tag and the merge-subject detector were called.
  STUB_ACTION="${WORK}/action"
  mkdir -p "${STUB_ACTION}/scripts"
  cp "${REPO_ROOT}/scripts/resolve-release-line-version.sh" "${STUB_ACTION}/scripts/"
  export STUB_SCRIPT_LOG="${WORK}/scripts.log"
  : > "${STUB_SCRIPT_LOG}"
  for s in push-release-tag detect-release-branch-version; do
    cat > "${STUB_ACTION}/scripts/${s}.sh" <<'EOF'
#!/usr/bin/env bash
{
  echo "called: $(basename "$0")"
  echo "TAG=${TAG:-}"
  echo "RESUME_AT_HEAD=${RESUME_AT_HEAD:-}"
} >> "${STUB_SCRIPT_LOG}"
EOF
    chmod +x "${STUB_ACTION}/scripts/${s}.sh"
  done

  git init -q --initial-branch=master "${WORK}/repo"
  cd "${WORK}/repo"
  git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m initial
}

teardown() {
  cd /
  rm -rf "${WORK}"
}

# Resolve release version, for a run on <branch> in an `rc` environment.
resolve_version() {
  local branch="$1"; shift
  run_step "Resolve release version" \
    "GITHUB_ACTION_PATH=${STUB_ACTION}" \
    PROMOTE_VERSION= PROMOTE_TAG= PROMOTE_SOURCE_TAG= EXPLICIT_VERSION= EXPLICIT_TAG= \
    INPUT_RELEASE_BRANCH_VERSIONING=branch INPUT_FORCE_BUMP= \
    DETECT_IS_PRERELEASE=true DETECT_IDENTIFIER=rc TAG_PREFIX=v \
    "RELEASE_BRANCH=${branch}" "$@"
}

# ── Resolve release version ──────────────────────────────────────────────────

@test "branch: a run on a release branch is versioned from its name" {
  resolve_version release/1.4.0
  [ "$status" -eq 0 ]
  [ "$(out version)" = "1.4.0-rc.1" ]
  [ "$(out tag)" = "v1.4.0-rc.1" ]
  [ "$(out source)" = "release-line" ]
  [ "$(out resume)" = "true" ]
}

@test "branch: a hotfix on a shipped line gets the next patch" {
  git tag v1.4.0
  git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m hotfix
  resolve_version release/1.4.0
  [ "$(out version)" = "1.4.1-rc.1" ]
}

@test "branch: a commit already released is passed on without resume, so nothing is re-released" {
  git tag v1.4.0
  resolve_version release/1.4.0
  [ "$(out version)" = "1.4.0" ]
  [ "$(out resume)" = "false" ]
}

@test "branch: a branch with no version in its name goes to the versioning tool" {
  resolve_version test
  [ "$status" -eq 0 ]
  [ -z "$(out version)" ]
  [ "$(out source)" = "tool" ]
}

@test "branch: off a release branch, a stable run still reads the merge subject as auto does" {
  resolve_version master DETECT_IS_PRERELEASE=false DETECT_IDENTIFIER=
  [ "$status" -eq 0 ]
  grep -q "called: detect-release-branch-version.sh" "${STUB_SCRIPT_LOG}"
}

@test "auto leaves a prerelease run on a release branch to the tool, as before" {
  resolve_version release/1.4.0 INPUT_RELEASE_BRANCH_VERSIONING=auto
  [ "$status" -eq 0 ]
  [ -z "$(out version)" ]
  [ "$(out source)" = "tool" ]
}

@test "off never versions from the branch" {
  resolve_version release/1.4.0 INPUT_RELEASE_BRANCH_VERSIONING=off
  [ -z "$(out version)" ]
}

@test "version-override outranks the branch name" {
  resolve_version release/1.4.0 EXPLICIT_VERSION=1.4.0-rc7 EXPLICIT_TAG=v1.4.0-rc7
  [ "$(out version)" = "1.4.0-rc7" ]
  [ "$(out source)" = "version-override" ]
  [ "$(out resume)" = "false" ]
}

@test "force-bump outranks the branch name" {
  resolve_version release/1.4.0 INPUT_FORCE_BUMP=minor
  [ -z "$(out version)" ]
  [ "$(out source)" = "tool" ]
}

@test "a promotion outranks the branch name" {
  resolve_version release/1.4.0 PROMOTE_VERSION=1.4.0 PROMOTE_TAG=v1.4.0 PROMOTE_SOURCE_TAG=v1.4.0-rc.2
  [ "$(out version)" = "1.4.0" ]
  [ "$(out source)" = "promote-from" ]
}

# ── Create version-override release tag ──────────────────────────────────────

@test "a release-line tag is pushed in resume mode" {
  run_step "Create version-override release tag" \
    "GITHUB_ACTION_PATH=${STUB_ACTION}" GITHUB_TOKEN=fake \
    OVERRIDE_VERSION=1.4.0-rc.1 OVERRIDE_TAG=v1.4.0-rc.1 OVERRIDE_RESUME=true PROMOTE_MARKER=
  [ "$status" -eq 0 ]
  grep -Fxq "TAG=v1.4.0-rc.1" "${STUB_SCRIPT_LOG}"
  grep -Fxq "RESUME_AT_HEAD=true" "${STUB_SCRIPT_LOG}"
}

@test "an already-released commit is pushed without resume, which makes it a no-op" {
  run_step "Create version-override release tag" \
    "GITHUB_ACTION_PATH=${STUB_ACTION}" GITHUB_TOKEN=fake \
    OVERRIDE_VERSION=1.4.0 OVERRIDE_TAG=v1.4.0 OVERRIDE_RESUME=false PROMOTE_MARKER=
  grep -Fxq "RESUME_AT_HEAD=false" "${STUB_SCRIPT_LOG}"
}

# ── Wiring ───────────────────────────────────────────────────────────────────

@test "the cut runs only in its own mode, and gets an App token" {
  step_head "Cut release branch" | grep -Fq "if: inputs.mode == 'cut-release-branch'"
  step_head "Request public GitHub App token" | grep -Fq "inputs.mode == 'cut-release-branch'"
  step_head "Cut release branch" | grep -Fq 'GH_TOKEN: ${{ steps.auth.outputs.token }}'
  step_head "Cut release branch" | grep -Fq 'TOKEN_SOURCE: ${{ steps.auth.outputs.source }}'
}

@test "nothing that builds, tags or releases runs in cut-release-branch mode" {
  # Every step other than auth, checkout, the cut and the summary is gated on
  # a mode the cut is not.
  command -v ruby >/dev/null || skip "ruby not available"
  run ruby -ryaml -e '
    steps = YAML.load_file(ARGV[0])["runs"]["steps"]
    allowed = ["Resolve GH_HOST for the gh CLI", "Generate private GitHub App token",
               "Request public GitHub App token", "Resolve GitHub auth token", "Checkout",
               "Cut release branch", "Write job summary", "Checkout promote source"]
    steps.each do |s|
      next if allowed.include?(s["name"])
      cond = s["if"].to_s
      unless cond =~ /inputs\.mode == .(ci|release|enable-auto-merge)./ || cond.include?("steps.projects-move-scope")
        puts "ungated: #{s["name"]}"
      end
    end' "${ACTION_YML}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "merge-back and cleanup follow only a stable, published release" {
  for s in "Merge release branch back" "Clean up superseded release branches"; do
    head=$(step_head "${s}")
    grep -Fq "inputs.mode == 'release'" <<< "${head}"
    grep -Fq "steps.normalize.outputs.released == 'true'" <<< "${head}"
    grep -Fq "steps.detect-env.outputs.is_prerelease == 'false'" <<< "${head}"
  done
  step_head "Merge release branch back" | grep -Fq "inputs.release-branch-merge-back != ''"
  step_head "Clean up superseded release branches" | grep -Fq "inputs.release-branch-cleanup == 'true'"
}

@test "housekeeping runs after the GitHub Release is published" {
  line() { grep -n -- "    - name: $1\$" "${ACTION_YML}" | cut -d: -f1; }
  [ "$(line 'Publish GitHub Release')" -lt "$(line 'Merge release branch back')" ]
  [ "$(line 'Merge release branch back')" -lt "$(line 'Clean up superseded release branches')" ]
}

@test "@default resolves to the repository's default branch" {
  mkdir -p "${WORK}/bin"
  printf '#!/usr/bin/env bash\necho "TARGET=${TARGET}"\n' > "${STUB_ACTION}/scripts/merge-back-release-branch.sh"
  printf '#!/usr/bin/env bash\necho "TARGET=${TARGET}"\n' > "${STUB_ACTION}/scripts/clean-up-release-branches.sh"
  chmod +x "${STUB_ACTION}/scripts/"*.sh
  run_step "Merge release branch back" "GITHUB_ACTION_PATH=${STUB_ACTION}" \
    TARGET_INPUT=@default DEFAULT_BRANCH=trunk REPO_FULL=acme/app
  [ "$output" = "TARGET=trunk" ]
  run_step "Merge release branch back" "GITHUB_ACTION_PATH=${STUB_ACTION}" \
    TARGET_INPUT=master DEFAULT_BRANCH=trunk REPO_FULL=acme/app
  [ "$output" = "TARGET=master" ]
  # Cleanup without a merge-back target checks against the default branch.
  run_step "Clean up superseded release branches" "GITHUB_ACTION_PATH=${STUB_ACTION}" \
    TARGET_INPUT= DEFAULT_BRANCH=trunk REPO_FULL=acme/app
  [ "$output" = "TARGET=trunk" ]
}

@test "a default branch that cannot be resolved is a warning, not a failed release" {
  mkdir -p "${WORK}/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "${WORK}/bin/gh"
  chmod +x "${WORK}/bin/gh"
  for s in "Merge release branch back" "Clean up superseded release branches"; do
    run_step "${s}" "GITHUB_ACTION_PATH=${STUB_ACTION}" "PATH=${WORK}/bin:${PATH}" \
      TARGET_INPUT=@default DEFAULT_BRANCH= REPO_FULL=acme/app
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::"*"could not resolve the default branch"* ]]
  done
}
