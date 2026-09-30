#!/usr/bin/env bats

# `promote-from` end to end, as far as that goes without a runner: how
# action.yml wires the input through, and what the inline steps it touches do
# with it.
#
# The scripts behind it have their own suites (resolve-promote-from,
# verify-promote-from-images, push-release-tag). What is left is the part that
# lives in action.yml itself, and that is where the promises are kept or
# broken: a promotion retags and NEVER rebuilds, targets the stable
# environment whatever the branch says, resumes instead of no-opping, and
# leaves `:latest` alone on an older release line. Those are checked by
# running the real `run:` blocks against stubs rather than by grepping for the
# lines that are supposed to implement them.
#
# A block is pulled out of action.yml with awk, not a YAML parser, so the suite
# runs wherever bats does (see action-script-refs.bats for why Ruby is avoided).

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
ACTION_YML="${REPO_ROOT}/action.yml"

IMG="ghcr.io/acme/app"

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

# Run a step's block with the environment given as NAME=value arguments.
run_step() {
  local name="$1"; shift
  run_block "${name}" > "${WORK}/block.sh"
  [ -s "${WORK}/block.sh" ] || { echo "no run block found for step: ${name}"; return 1; }
  run env "$@" bash "${WORK}/block.sh"
}

out() { grep -E "^$1=" "${GITHUB_OUTPUT}" | tail -n 1 | cut -d= -f2-; }

# A bare `! cmd` only fails a bats test when it is the last line of it, so a
# negative assertion in the middle of a test would pass whatever happened.
refute() {
  if "$@"; then
    echo "expected to fail, but succeeded: $*"
    return 1
  fi
}

setup() {
  WORK=$(mktemp -d)
  BIN="${WORK}/bin"
  mkdir -p "${BIN}"
  export GITHUB_OUTPUT="${WORK}/output"
  export STUB_LOG="${WORK}/docker.log"
  export STUB_GH_LOG="${WORK}/gh.log"
  export STUB_BAKE_JSON="${WORK}/bake.json"
  : > "${GITHUB_OUTPUT}"; : > "${STUB_LOG}"; : > "${STUB_GH_LOG}"
  echo '{"target":{"app":{"tags":["ghcr.io/acme/app:1.5.0"]}}}' > "${STUB_BAKE_JSON}"

  # The registry as the stub sees it: one file per ref under STUB_DIGESTS
  # holding its digest. A ref with no file is "not found".
  export STUB_DIGESTS="${WORK}/digests"
  mkdir -p "${STUB_DIGESTS}"

  # STUB_CREATE_ERR fails `imagetools create`; with STUB_CREATE_FAIL_MATCH it
  # fails only the calls whose arguments contain that text.
  cat > "${BIN}/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "${STUB_LOG}"
case "$*" in
  "buildx bake "*"--print") cat "${STUB_BAKE_JSON}" ;;
  "buildx imagetools create "*)
    if [ -n "${STUB_CREATE_ERR:-}" ]; then
      case "$*" in
        *"${STUB_CREATE_FAIL_MATCH:-}"*)
          echo "${STUB_CREATE_ERR}" >&2
          exit 1
          ;;
      esac
    fi
    ;;
  "buildx imagetools inspect "*)
    file="${STUB_DIGESTS}/$(printf '%s' "$4" | tr '/:' '__')"
    if [ ! -f "${file}" ]; then
      echo "ERROR: $4: not found" >&2
      exit 1
    fi
    cat "${file}"
    ;;
  "pull "*) exit "${STUB_PULL_STATUS:-0}" ;;
esac
exit 0
EOF

  cat > "${BIN}/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "${STUB_GH_LOG}"
case "$1 $2" in
  "release view") exit "${STUB_RELEASE_VIEW_STATUS:-1}" ;;
  "release create") exit 0 ;;
  "api "*) printf '%s' "${STUB_GH_API_OUT:-}" ;;
esac
exit 0
EOF
  chmod +x "${BIN}/docker" "${BIN}/gh"
  export PATH="${BIN}:${PATH}"

  # A stand-in action root whose scripts only record how they were called.
  STUB_ACTION="${WORK}/action"
  mkdir -p "${STUB_ACTION}/scripts"
  export STUB_SCRIPT_LOG="${WORK}/scripts.log"
  : > "${STUB_SCRIPT_LOG}"
  # `tr -d '\r'`: jq on Windows writes CRLF, which a `while read` loop over
  # its output keeps. Runners are Linux; this only keeps the suite usable on a
  # Windows checkout.
  for s in verify-promote-from-images push-release-tag detect-release-branch-version sign-image; do
    cat > "${STUB_ACTION}/scripts/${s}.sh" <<'EOF'
#!/usr/bin/env bash
{
  echo "called: $(basename "$0")"
  echo "SOURCE_REFS=${SOURCE_REFS:-}"
  echo "TAG=${TAG:-}"
  echo "MESSAGE=${MESSAGE:-}"
  echo "RESUME_AT_HEAD=${RESUME_AT_HEAD:-}"
  echo "RESUME_MARKER=${RESUME_MARKER:-}"
} | tr -d '\r' >> "${STUB_SCRIPT_LOG}"
EOF
    chmod +x "${STUB_ACTION}/scripts/${s}.sh"
  done
}

teardown() {
  rm -rf "${WORK}"
}

# ── Promote images ───────────────────────────────────────────────────────────

# The step's whole environment for a stable release of v1.5.0, as a promotion
# of v1.5.0-rc.3 that owns :latest. Tests override what they are about.
promote_env() {
  printf '%s\n' \
    "GITHUB_ACTION_PATH=${REPO_ROOT}" \
    GH_TOKEN=fake BAKE_GITHUB_TOKEN= \
    NORMALIZE_VERSION=1.5.0 NORMALIZE_TAG=v1.5.0 \
    DETECT_ENV=prod DETECT_IS_PRERELEASE=false \
    INPUT_DEPLOYMENT_MODEL=tbd \
    'INPUT_ENVIRONMENTS=["dev","staging","prod"]' \
    'INPUT_PRERELEASE_IDENTIFIERS={"dev":"dev","staging":"rc"}' \
    INPUT_TAG_PREFIX=v OWNER=Acme INPUT_IMAGE_NAME=app STRATEGY=dockerfile \
    INPUT_REGISTRY=ghcr.io INPUT_PLATFORMS= INPUT_BAKE_FILE=docker-bake.hcl \
    INPUT_BAKE_TARGET=default INPUT_DOCKERFILE=Dockerfile \
    INPUT_IMAGE_SKIP_EXISTING=false REPO_FULL=acme/app \
    PROMOTE_SOURCE_TAG=v1.5.0-rc.3 PROMOTE_TAG_LATEST=true
}

promote_images() {
  local args=()
  while IFS= read -r line; do args+=("${line}"); done < <(promote_env)
  run_step "Promote images" "${args[@]}" "$@"
}

rebuilt() { grep -Eq "buildx build|buildx bake .*--push" "${STUB_LOG}"; }

@test "a promotion retags the named prerelease and moves :latest" {
  promote_images
  [ "$status" -eq 0 ]
  grep -Fxq "docker buildx imagetools create --tag ${IMG}:v1.5.0 --tag ${IMG}:latest ${IMG}:v1.5.0-rc.3" "${STUB_LOG}"
  [ "$(out promoted_count)" = "1" ]
  [ "$(out rebuilt_count)" = "0" ]
  refute rebuilt
}

@test "a promotion never searches for a source: no API call is made" {
  # Neither the pr-<N> lookup nor the newest-prerelease lookup may run. The
  # second is the one that ships rc.4 when rc.3 was signed off.
  promote_images
  [ "$status" -eq 0 ]
  [ ! -s "${STUB_GH_LOG}" ]
}

@test "a promotion ignores the deployment model when picking its source" {
  # Under bbd every environment would otherwise go looking for a pr-<N> image.
  promote_images INPUT_DEPLOYMENT_MODEL=bbd
  [ "$status" -eq 0 ]
  grep -Fq "${IMG}:v1.5.0-rc.3" "${STUB_LOG}"
  [ ! -s "${STUB_GH_LOG}" ]
  refute grep -q "pr-" "${STUB_LOG}"
}

@test "a promotion on an older release line leaves :latest alone" {
  promote_images NORMALIZE_VERSION=1.4.3 NORMALIZE_TAG=v1.4.3 \
    PROMOTE_SOURCE_TAG=v1.4.3-rc.1 PROMOTE_TAG_LATEST=false
  [ "$status" -eq 0 ]
  grep -Fxq "docker buildx imagetools create --tag ${IMG}:v1.4.3 ${IMG}:v1.4.3-rc.1" "${STUB_LOG}"
  refute grep -q ":latest" "${STUB_LOG}"
  [ "$(out promoted_count)" = "1" ]
}

@test "a promotion whose retag fails is an error, never a rebuild" {
  promote_images STUB_CREATE_ERR="ERROR: unauthorized: authentication required"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::promote-from: could not retag ${IMG}:v1.5.0-rc.3 as ${IMG}:v1.5.0"* ]]
  [[ "$output" == *"unauthorized: authentication required"* ]]
  [[ "$output" == *"A promotion never rebuilds"* ]]
  [[ "$output" != *"Fresh build fallback"* ]]
  refute rebuilt
}

@test "a promotion takes the pull/tag/push fallback on a referrers-index error" {
  # The registry this fallback exists for is exactly where promotions that
  # skip a release branch's rebuild are wanted most.
  promote_images STUB_CREATE_ERR="failed to decode referrers index: invalid character '<'"
  [ "$status" -eq 0 ]
  grep -Fxq "docker pull ${IMG}:v1.5.0-rc.3" "${STUB_LOG}"
  grep -Fxq "docker tag ${IMG}:v1.5.0-rc.3 ${IMG}:v1.5.0" "${STUB_LOG}"
  grep -Fxq "docker push ${IMG}:v1.5.0" "${STUB_LOG}"
  grep -Fxq "docker push ${IMG}:latest" "${STUB_LOG}"
  [ "$(out promoted_count)" = "1" ]
  refute rebuilt
}

@test "the pull/tag/push fallback also leaves :latest alone on an older line" {
  promote_images PROMOTE_TAG_LATEST=false \
    STUB_CREATE_ERR="failed to decode referrers index: invalid character '<'"
  [ "$status" -eq 0 ]
  grep -Fxq "docker push ${IMG}:v1.5.0" "${STUB_LOG}"
  refute grep -q ":latest" "${STUB_LOG}"
}

@test "a promotion whose fallback also fails is an error, never a rebuild" {
  promote_images STUB_PULL_STATUS=1 \
    STUB_CREATE_ERR="failed to decode referrers index: invalid character '<'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::promote-from: could not retag"* ]]
  [[ "$output" == *"see the docker pull/tag/push output above"* ]]
  refute rebuilt
}

@test "a promotion retags every bake target from the same source tag" {
  echo '{"target":{"app":{"tags":["ghcr.io/acme/app:1.5.0"]},"worker":{"tags":["ghcr.io/acme/worker:1.5.0"]}}}' > "${STUB_BAKE_JSON}"
  promote_images STRATEGY=bake
  [ "$status" -eq 0 ]
  grep -Fxq "docker buildx imagetools create --tag ghcr.io/acme/app:v1.5.0 --tag ghcr.io/acme/app:latest ghcr.io/acme/app:v1.5.0-rc.3" "${STUB_LOG}"
  grep -Fxq "docker buildx imagetools create --tag ghcr.io/acme/worker:v1.5.0 --tag ghcr.io/acme/worker:latest ghcr.io/acme/worker:v1.5.0-rc.3" "${STUB_LOG}"
  [ "$(out promoted_count)" = "2" ]
  refute rebuilt
}

@test "one failed target of several stops the promotion, with no rebuild" {
  # The first target lands, the second does not. The run has to stop there,
  # not rebuild the one that failed and carry on.
  echo '{"target":{"app":{"tags":["ghcr.io/acme/app:1.5.0"]},"worker":{"tags":["ghcr.io/acme/worker:1.5.0"]}}}' > "${STUB_BAKE_JSON}"
  promote_images STRATEGY=bake STUB_CREATE_ERR="ERROR: 503 Service Unavailable" \
    STUB_CREATE_FAIL_MATCH="acme/worker"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Promoted ghcr.io/acme/app:v1.5.0-rc.3"* ]]
  [[ "$output" == *"::error::promote-from: could not retag ghcr.io/acme/worker:v1.5.0-rc.3"* ]]
  [ -z "$(out promoted_count)" ]
  refute rebuilt
}

# ── image-skip-existing: what a resumed promotion leans on ──────────────────

DIGEST_A='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
DIGEST_B='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

registry_has() { printf '%s' "$2" > "${STUB_DIGESTS}/$(printf '%s' "$1" | tr '/:' '__')"; }

@test "a resumed promotion skips an image that already landed" {
  registry_has "${IMG}:v1.5.0-rc.3" "${DIGEST_A}"
  registry_has "${IMG}:v1.5.0" "${DIGEST_A}"
  registry_has "${IMG}:latest" "${DIGEST_A}"
  promote_images INPUT_IMAGE_SKIP_EXISTING=true
  [ "$status" -eq 0 ]
  [ "$(out skipped_count)" = "1" ]
  [ "$(out promoted_count)" = "0" ]
  refute grep -q "imagetools create" "${STUB_LOG}"
}

@test "the skip gate does not wait for :latest on an older release line" {
  # :latest belongs to 1.5.0 there and is meant to stay put, so requiring it
  # to match would redo the 1.4.3 retag on every run for ever.
  registry_has "${IMG}:v1.4.3-rc.1" "${DIGEST_A}"
  registry_has "${IMG}:v1.4.3" "${DIGEST_A}"
  registry_has "${IMG}:latest" "${DIGEST_B}"
  promote_images INPUT_IMAGE_SKIP_EXISTING=true NORMALIZE_VERSION=1.4.3 NORMALIZE_TAG=v1.4.3 \
    PROMOTE_SOURCE_TAG=v1.4.3-rc.1 PROMOTE_TAG_LATEST=false
  [ "$status" -eq 0 ]
  [ "$(out skipped_count)" = "1" ]
  refute grep -q "imagetools create" "${STUB_LOG}"
}

@test "the skip gate still repairs :latest when the promotion owns it" {
  registry_has "${IMG}:v1.5.0-rc.3" "${DIGEST_A}"
  registry_has "${IMG}:v1.5.0" "${DIGEST_A}"
  registry_has "${IMG}:latest" "${DIGEST_B}"
  promote_images INPUT_IMAGE_SKIP_EXISTING=true
  [ "$status" -eq 0 ]
  [ "$(out skipped_count)" = "0" ]
  grep -Fxq "docker buildx imagetools create --tag ${IMG}:v1.5.0 --tag ${IMG}:latest ${IMG}:v1.5.0-rc.3" "${STUB_LOG}"
}

@test "the skip gate never skips a stable tag that holds a different image" {
  registry_has "${IMG}:v1.5.0-rc.3" "${DIGEST_A}"
  registry_has "${IMG}:v1.5.0" "${DIGEST_B}"
  registry_has "${IMG}:latest" "${DIGEST_B}"
  promote_images INPUT_IMAGE_SKIP_EXISTING=true
  [ "$status" -eq 0 ]
  [ "$(out skipped_count)" = "0" ]
  [ "$(out promoted_count)" = "1" ]
}

@test "without promote-from the skip gate still requires :latest on a stable release" {
  registry_has "${IMG}:v1.5.0-rc.3" "${DIGEST_A}"
  registry_has "${IMG}:v1.5.0" "${DIGEST_A}"
  registry_has "${IMG}:latest" "${DIGEST_B}"
  promote_images INPUT_IMAGE_SKIP_EXISTING=true PROMOTE_SOURCE_TAG= PROMOTE_TAG_LATEST= \
    STUB_GH_API_OUT=v1.5.0-rc.3
  [ "$status" -eq 0 ]
  [ "$(out skipped_count)" = "0" ]
  grep -Fxq "docker buildx imagetools create --tag ${IMG}:v1.5.0 --tag ${IMG}:latest ${IMG}:v1.5.0-rc.3" "${STUB_LOG}"
}

# ── the same step, without promote-from: nothing may have moved ─────────────

@test "without promote-from a stable later-environment retag still tags :latest" {
  promote_images PROMOTE_SOURCE_TAG= PROMOTE_TAG_LATEST= STUB_GH_API_OUT=v1.5.0-rc.3
  [ "$status" -eq 0 ]
  grep -Fxq "docker buildx imagetools create --tag ${IMG}:v1.5.0 --tag ${IMG}:latest ${IMG}:v1.5.0-rc.3" "${STUB_LOG}"
  grep -q "matching-refs/tags/v1.5.0-rc." "${STUB_GH_LOG}"
}

@test "without promote-from a failed retag still falls back to a fresh build" {
  promote_images PROMOTE_SOURCE_TAG= PROMOTE_TAG_LATEST= STRATEGY=bake \
    STUB_GH_API_OUT=v1.5.0-rc.3 STUB_CREATE_ERR="ERROR: 503 Service Unavailable"
  [ "$status" -eq 0 ]
  [[ "$output" == *"falling back to fresh build"* ]]
  rebuilt
  [ "$(out rebuilt_count)" = "1" ]
}

@test "without promote-from a prerelease retag still leaves :latest alone" {
  promote_images PROMOTE_SOURCE_TAG= PROMOTE_TAG_LATEST= STUB_GH_API_OUT=v1.5.0-dev.4 \
    NORMALIZE_VERSION=1.5.0-rc.1 NORMALIZE_TAG=v1.5.0-rc.1 \
    DETECT_ENV=staging DETECT_IS_PRERELEASE=true
  [ "$status" -eq 0 ]
  grep -Fxq "docker buildx imagetools create --tag ${IMG}:v1.5.0-rc.1 ${IMG}:v1.5.0-dev.4" "${STUB_LOG}"
  refute grep -q ":latest" "${STUB_LOG}"
}

# ── Detect environment ───────────────────────────────────────────────────────

detect_env() {
  run_step "Detect environment" \
    INPUT_DEPLOYMENT_MODEL=bbd \
    'INPUT_BRANCH_MAP={"master":"dev","release/*":"staging"}' \
    INPUT_ENVIRONMENT= \
    'INPUT_ENVIRONMENTS=["dev","staging","prod"]' \
    'INPUT_PRERELEASE_IDENTIFIERS={"dev":"dev","staging":"rc"}' \
    INPUT_PROMOTE_BRANCH_PREFIX=promote \
    GITHUB_REF_NAME=release/1.5.0 GITHUB_HEAD_REF= \
    PROMOTE_SOURCE_TAG=v1.5.0-rc.3 "$@"
}

@test "a promotion targets the stable environment, whatever the branch maps to" {
  # Started from release/1.5.0, which bbd maps to the prerelease environment.
  detect_env
  [ "$status" -eq 0 ]
  [ "$(out environment)" = "prod" ]
  [ "$(out is_prerelease)" = "false" ]
  [ -z "$(out prerelease_identifier)" ]
}

@test "a promotion needs no branch-map entry for the branch it was started on" {
  detect_env GITHUB_REF_NAME=some/unmapped-branch
  [ "$status" -eq 0 ]
  [ "$(out environment)" = "prod" ]
}

@test "a promotion under tbd needs no environment input" {
  detect_env INPUT_DEPLOYMENT_MODEL=tbd INPUT_BRANCH_MAP=
  [ "$status" -eq 0 ]
  [ "$(out environment)" = "prod" ]
}

@test "an explicit environment that is not the stable one is an error" {
  detect_env INPUT_DEPLOYMENT_MODEL=tbd INPUT_ENVIRONMENT=staging
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::promote-from: a promotion always releases the stable version, to 'prod'"* ]]
  [ ! -s "${GITHUB_OUTPUT}" ]
}

@test "an explicit environment naming the stable one is accepted" {
  detect_env INPUT_DEPLOYMENT_MODEL=tbd INPUT_ENVIRONMENT=prod
  [ "$status" -eq 0 ]
  [ "$(out environment)" = "prod" ]
}

@test "without promote-from the branch map still decides the environment" {
  detect_env PROMOTE_SOURCE_TAG=
  [ "$status" -eq 0 ]
  [ "$(out environment)" = "staging" ]
  [ "$(out is_prerelease)" = "true" ]
  [ "$(out prerelease_identifier)" = "rc" ]
}

# ── Resolve release version ──────────────────────────────────────────────────

@test "the version is the promoted prerelease's, and no tool is consulted" {
  run_step "Resolve release version" \
    "GITHUB_ACTION_PATH=${STUB_ACTION}" \
    PROMOTE_VERSION=1.5.0 PROMOTE_TAG=v1.5.0 PROMOTE_SOURCE_TAG=v1.5.0-rc.3 \
    EXPLICIT_VERSION= EXPLICIT_TAG= INPUT_RELEASE_BRANCH_VERSIONING=auto \
    INPUT_FORCE_BUMP= DETECT_IS_PRERELEASE=false TAG_PREFIX=v
  [ "$status" -eq 0 ]
  [ "$(out version)" = "1.5.0" ]
  [ "$(out tag)" = "v1.5.0" ]
  [ "$(out source)" = "promote-from" ]
  # A stable run with release-branch-versioning on would otherwise read the
  # version off HEAD's merge subject.
  refute grep -q "detect-release-branch-version" "${STUB_SCRIPT_LOG}"
}

# ── Create version-override release tag ──────────────────────────────────────

@test "a promotion's tag records its source and is pushed in resume mode" {
  run_step "Create version-override release tag" \
    "GITHUB_ACTION_PATH=${STUB_ACTION}" GITHUB_TOKEN=fake \
    OVERRIDE_VERSION=1.5.0 OVERRIDE_TAG=v1.5.0 "PROMOTE_MARKER=Promoted-From: v1.5.0-rc.3"
  [ "$status" -eq 0 ]
  grep -Fxq "TAG=v1.5.0" "${STUB_SCRIPT_LOG}"
  grep -Fxq "RESUME_AT_HEAD=true" "${STUB_SCRIPT_LOG}"
  grep -Fxq "RESUME_MARKER=Promoted-From: v1.5.0-rc.3" "${STUB_SCRIPT_LOG}"
  # The marker is a line of its own in the message, which is how a later run
  # (and push-release-tag.sh's resume check) finds it.
  grep -Fxq "MESSAGE=chore(release): v1.5.0" "${STUB_SCRIPT_LOG}"
  grep -Fxq "Promoted-From: v1.5.0-rc.3" "${STUB_SCRIPT_LOG}"
}

@test "every other pinned version keeps its tag message and the no-op on an existing tag" {
  run_step "Create version-override release tag" \
    "GITHUB_ACTION_PATH=${STUB_ACTION}" GITHUB_TOKEN=fake \
    OVERRIDE_VERSION=1.5.0 OVERRIDE_TAG=v1.5.0 PROMOTE_MARKER=
  [ "$status" -eq 0 ]
  grep -Fxq "MESSAGE=chore(release): v1.5.0" "${STUB_SCRIPT_LOG}"
  grep -Fxq "RESUME_AT_HEAD=false" "${STUB_SCRIPT_LOG}"
  grep -Fxq "RESUME_MARKER=" "${STUB_SCRIPT_LOG}"
  refute grep -q "Promoted-From" "${STUB_SCRIPT_LOG}"
}

# ── Sign released images: provenance must not name the wrong commit ─────────

sign_images() {
  run_step "Sign released images (cosign)" \
    "GITHUB_ACTION_PATH=${STUB_ACTION}" \
    OWNER=Acme INPUT_IMAGE_NAME=app STRATEGY=dockerfile INPUT_REGISTRY=ghcr.io \
    INPUT_PLATFORMS= INPUT_BAKE_FILE=docker-bake.hcl INPUT_BAKE_TARGET=default \
    BAKE_GITHUB_TOKEN= NORMALIZE_VERSION=1.5.0 NORMALIZE_TAG=v1.5.0 "$@"
}

SHA_RC='1111111111111111111111111111111111111111'
SHA_TIP='2222222222222222222222222222222222222222'

@test "a promotion started from another commit is signed but warned that it is not attested" {
  sign_images PROMOTE_COMMIT="${SHA_RC}" WORKFLOW_SHA="${SHA_TIP}"
  [ "$status" -eq 0 ]
  grep -Fxq "called: sign-image.sh" "${STUB_SCRIPT_LOG}"
  [[ "$output" == *"::warning::promote-from: the image is signed, but no SLSA build provenance is attested"* ]]
  [[ "$output" == *"${SHA_TIP}"* ]]
}

@test "a promotion started from the prerelease's own commit gets no such warning" {
  sign_images PROMOTE_COMMIT="${SHA_RC}" WORKFLOW_SHA="${SHA_RC}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"::warning::"* ]]
}

@test "an ordinary release gets no such warning" {
  sign_images PROMOTE_COMMIT= WORKFLOW_SHA="${SHA_TIP}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"::warning::"* ]]
}

@test "provenance is attested only when the workflow commit is the promoted commit" {
  step_head "Attest build provenance (SLSA)" \
    | grep -Fq "(steps.promote-source.outputs.commit == '' || steps.promote-source.outputs.commit == github.sha)"
}

# ── Verify promote source images ─────────────────────────────────────────────

verify_images() {
  run_step "Verify promote source images" \
    "GITHUB_ACTION_PATH=${STUB_ACTION}" \
    OWNER=Acme INPUT_IMAGE_NAME=app INPUT_REGISTRY=ghcr.io INPUT_PLATFORMS= \
    INPUT_BAKE_FILE=docker-bake.hcl INPUT_BAKE_TARGET=default BAKE_GITHUB_TOKEN= \
    PROMOTE_VERSION=1.5.0 PROMOTE_SOURCE_TAG=v1.5.0-rc.3 "$@"
}

@test "the preflight checks the Dockerfile image at the source tag" {
  verify_images STRATEGY=dockerfile
  [ "$status" -eq 0 ]
  grep -Fxq "SOURCE_REFS=${IMG}:v1.5.0-rc.3" "${STUB_SCRIPT_LOG}"
}

@test "the preflight checks every bake repository once, at the source tag" {
  # Two targets pushing to one repository are one image to check.
  echo '{"target":{"app":{"tags":["ghcr.io/acme/app:1.5.0"]},"app-debug":{"tags":["ghcr.io/acme/app:1.5.0"]},"worker":{"tags":["ghcr.io/acme/worker:1.5.0"]}}}' > "${STUB_BAKE_JSON}"
  verify_images STRATEGY=bake
  [ "$status" -eq 0 ]
  [ "$(grep -c "v1.5.0-rc.3" "${STUB_SCRIPT_LOG}")" -eq 2 ]
  grep -Fq "ghcr.io/acme/app:v1.5.0-rc.3" "${STUB_SCRIPT_LOG}"
  grep -Fxq "ghcr.io/acme/worker:v1.5.0-rc.3" "${STUB_SCRIPT_LOG}"
}

# ── Publish GitHub Release ───────────────────────────────────────────────────

publish_release() {
  run_step "Publish GitHub Release" \
    GH_TOKEN=fake NORMALIZE_TAG=v1.5.0 NORMALIZE_RELEASE_NOTES= \
    DETECT_IS_PRERELEASE=false PROMOTE_TAG_LATEST=true "$@"
}

@test "a promoted release lists changes since the previous stable tag" {
  publish_release PROMOTE_PREVIOUS_TAG=v1.4.2
  [ "$status" -eq 0 ]
  grep -Fxq "gh release create v1.5.0 --title v1.5.0 --generate-notes --notes-start-tag v1.4.2" "${STUB_GH_LOG}"
}

@test "a first stable release has no start tag to pin" {
  publish_release PROMOTE_PREVIOUS_TAG=
  [ "$status" -eq 0 ]
  grep -Fxq "gh release create v1.5.0 --title v1.5.0 --generate-notes" "${STUB_GH_LOG}"
}

@test "a fix promoted on an older release line is not marked the latest release" {
  publish_release NORMALIZE_TAG=v1.4.3 PROMOTE_PREVIOUS_TAG=v1.4.2 PROMOTE_TAG_LATEST=false
  [ "$status" -eq 0 ]
  grep -Fxq "gh release create v1.4.3 --title v1.4.3 --generate-notes --notes-start-tag v1.4.2 --latest=false" "${STUB_GH_LOG}"
}

@test "without promote-from the release is published exactly as before" {
  publish_release PROMOTE_PREVIOUS_TAG= PROMOTE_TAG_LATEST=
  [ "$status" -eq 0 ]
  grep -Fxq "gh release create v1.5.0 --title v1.5.0 --generate-notes" "${STUB_GH_LOG}"

  : > "${STUB_GH_LOG}"
  publish_release NORMALIZE_TAG=v1.5.0-rc.1 DETECT_IS_PRERELEASE=true \
    PROMOTE_PREVIOUS_TAG= PROMOTE_TAG_LATEST=
  [ "$status" -eq 0 ]
  grep -Fxq "gh release create v1.5.0-rc.1 --title v1.5.0-rc.1 --generate-notes --prerelease" "${STUB_GH_LOG}"
}

# ── wiring ───────────────────────────────────────────────────────────────────

@test "promote-from is an optional input that defaults to empty" {
  block=$(awk '/^  promote-from:$/ { on = 1; next } on && /^  [a-z]/ { exit } on { print }' "${ACTION_YML}")
  [ -n "${block}" ]
  echo "${block}" | grep -Fxq "    required: false"
  echo "${block}" | grep -Fxq "    default: ''"
}

@test "the promoted-from output reports the resolved source tag" {
  grep -A 2 -E "^  promoted-from:$" "${ACTION_YML}" \
    | grep -Fq 'value: ${{ steps.promote-source.outputs.source_tag }}'
}

@test "only the resolve step reads the raw promote-from input" {
  # Every later step gates on what the resolver accepted. A step reading the
  # raw input again could act on a value the resolver had already refused.
  [ "$(grep -c 'inputs\.promote-from' "${ACTION_YML}")" -eq 2 ]
  step_head "Resolve promote source" | grep -Fq "if: inputs.mode == 'release' && inputs.promote-from != ''"
  step_head "Resolve promote source" | grep -Fq 'PROMOTE_FROM: ${{ inputs.promote-from }}'
}

@test "the resolver is told what else the run would publish" {
  # It refuses a container package build and mismatched npm provenance, and it
  # can only do that before anything is written if it is handed the inputs.
  head=$(step_head "Resolve promote source")
  echo "${head}" | grep -Fq 'PUBLISH_PACKAGE: ${{ inputs.publish-package }}'
  echo "${head}" | grep -Fq 'PACKAGE_ECOSYSTEM: ${{ inputs.package-ecosystem }}'
  echo "${head}" | grep -Fq 'NPM_PROVENANCE: ${{ inputs.npm-provenance }}'
}

@test "the job summary is told whether the image promote failed" {
  step_head "Write job summary" | grep -Fq 'PROMOTE_OUTCOME: ${{ steps.promote-images.outcome }}'
}

@test "the workspace moves to the prerelease's commit before anything reads it" {
  # The stable tag, the bake file and a published package all come from the
  # tree, so the second checkout has to precede the image-name resolver.
  step_head "Checkout promote source" | grep -Fq 'ref: ${{ steps.promote-source.outputs.commit }}'
  resolve=$(grep -n -- "- name: Resolve promote source" "${ACTION_YML}" | cut -d: -f1)
  checkout=$(grep -n -- "- name: Checkout promote source" "${ACTION_YML}" | cut -d: -f1)
  image=$(grep -n -- "- name: Resolve image name" "${ACTION_YML}" | cut -d: -f1)
  [ "${resolve}" -lt "${checkout}" ]
  [ "${checkout}" -lt "${image}" ]
}

@test "both checkouts are pinned to the same actions/checkout commit" {
  [ "$(grep -c 'uses: actions/checkout@' "${ACTION_YML}")" -eq 2 ]
  [ "$(grep -oE 'uses: actions/checkout@[0-9a-f]{40}' "${ACTION_YML}" | sort -u | wc -l | tr -d ' ')" -eq 1 ]
}

@test "the image preflight runs after the guardrails and before the tag is cut" {
  allow=$(grep -n -- "- name: Release actor allowlist" "${ACTION_YML}" | cut -d: -f1)
  verify=$(grep -n -- "- name: Verify promote source images" "${ACTION_YML}" | cut -d: -f1)
  tag=$(grep -n -- "- name: Create version-override release tag" "${ACTION_YML}" | cut -d: -f1)
  [ "${allow}" -lt "${verify}" ]
  [ "${verify}" -lt "${tag}" ]
}

@test "the preflight derives repositories exactly as the scan and signing do" {
  # Three consumers of one derivation: if they drift, a promotion checks one
  # set of images, then signs and inventories another.
  count=$(grep -cF "jq -r '.target[].tags[0] // empty | split(\":\")[0]' | sort -u" "${ACTION_YML}")
  [ "${count}" -eq 3 ]
}

@test "version files are not written on a promotion" {
  step_head "Inject version into tracked file" | grep -Fq "steps.promote-source.outputs.source_tag == '' &&"
}

# ── the scripts, chained the way the steps chain them ───────────────────────
# resolve-promote-from.sh names a commit, the second checkout moves HEAD onto
# it, and push-release-tag.sh tags HEAD. Each half is covered on its own; this
# is the contract between them, which is the actual promise: the stable tag
# ends up on the commit the prerelease was built from, not on the branch tip.

@test "the stable tag lands on the prerelease's commit, and a re-run resumes" {
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  BARE="${WORK}/origin.git"
  CLONE="${WORK}/clone"
  git init --bare --initial-branch=main "${BARE}" >/dev/null
  git -C "${WORK}" init --initial-branch=main clone >/dev/null
  cd "${CLONE}"
  git config user.name tester
  git config user.email t@example.com
  # push-release-tag.sh only accepts https:// or git@ remotes; see its suite.
  git remote add origin "https://example.invalid/origin.git"
  git config --add "url.${BARE}.insteadOf" "https://example.invalid/origin.git"
  git config --add "url.${BARE}.insteadOf" "https://x-access-token:fake@example.invalid/origin.git"

  git commit --allow-empty -m "one" >/dev/null
  git tag -a v1.5.0-rc.3 -m "chore(release): v1.5.0-rc.3"
  # A second candidate on the same commit, as a re-run of the prerelease
  # release would cut: same source, a separate image.
  git tag -a v1.5.0-rc.4 -m "chore(release): v1.5.0-rc.4"
  RC3=$(git rev-parse HEAD)
  git commit --allow-empty -m "two: the branch moved on after QA signed off" >/dev/null
  git push -q origin main v1.5.0-rc.3 v1.5.0-rc.4

  # The two scripts as the steps run them, the tag message built the way
  # `Create version-override release tag` builds it.
  promote_once() {
    : > "${GITHUB_OUTPUT}"
    TAG_PREFIX=v PROMOTE_FROM="$1" "${REPO_ROOT}/scripts/resolve-promote-from.sh" || return 1
    git checkout -q --detach "$(out commit)"
    GITHUB_TOKEN=fake TAG="$(out tag)" \
      MESSAGE="chore(release): $(out tag)"$'\n\n'"$(out marker)" \
      RESUME_AT_HEAD=true RESUME_MARKER="$(out marker)" \
      "${REPO_ROOT}/scripts/push-release-tag.sh"
  }

  run promote_once v1.5.0-rc.3
  [ "$status" -eq 0 ]
  [ "$(out released)" = "true" ]
  [ "$(git -C "${BARE}" rev-parse 'v1.5.0^{commit}')" = "${RC3}" ]
  [ "$(git -C "${BARE}" rev-parse 'v1.5.0^{commit}')" != "$(git -C "${BARE}" rev-parse main)" ]
  git -C "${BARE}" cat-file -p v1.5.0 | grep -Fxq "Promoted-From: v1.5.0-rc.3"

  # The same promotion again, as after a run that died on the retag. A fresh
  # checkout has the tag locally, exactly as actions/checkout would fetch it.
  git checkout -q main
  git fetch -q --tags origin
  run promote_once v1.5.0-rc.3
  [ "$status" -eq 0 ]
  [[ "$output" == *"Resuming"* ]]
  [ "$(out released)" = "true" ]
  [ "$(git -C "${BARE}" rev-parse 'v1.5.0^{commit}')" = "${RC3}" ]

  # The other candidate on that commit is not the same promotion. Letting it
  # "resume" would repoint the published v1.5.0 image at rc.4's build.
  git checkout -q main
  run promote_once v1.5.0-rc.4
  [ "$status" -ne 0 ]
  [[ "$output" == *"v1.5.0 was already promoted from v1.5.0-rc.3"* ]]
  [ -z "$(out released)" ]
  git -C "${BARE}" cat-file -p v1.5.0 | grep -Fxq "Promoted-From: v1.5.0-rc.3"
}
