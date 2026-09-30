#!/usr/bin/env bats

# Behaviour coverage for scripts/verify-promote-from-images.sh, the preflight
# that refuses a promotion whose source image is not in the registry BEFORE
# the stable tag is cut.
#
# `docker` is stubbed per ref. A file under ${STUB_DIR}/imagetools/ holds what
# `docker buildx imagetools inspect` answers for that ref: a digest means the
# image is there, a line starting `ERR:` is printed to stderr with exit 1, and
# no file at all is a plain "not found". `docker manifest inspect` succeeds
# only for refs that have a file under ${STUB_DIR}/manifest/.
#
# The line this suite holds is that only a DEFINITE absence stops the run. A
# registry that would not answer is a warning, because the retag that follows
# settles it either way; failing on a shrug would block every promotion on a
# registry the probe cannot read.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/verify-promote-from-images.sh"

DIGEST='sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
APP='ghcr.io/acme/app:v1.5.0-rc.3'
WORKER='ghcr.io/acme/worker:v1.5.0-rc.3'

setup() {
  WORK=$(mktemp -d)
  BIN="${WORK}/bin"
  export STUB_DIR="${WORK}/registry"
  export STUB_LOG="${WORK}/stub.log"
  mkdir -p "${BIN}" "${STUB_DIR}/imagetools" "${STUB_DIR}/manifest"
  : > "${STUB_LOG}"

  cat > "${BIN}/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "${STUB_LOG}"
key() { printf '%s' "$1" | tr '/:' '__'; }
if [ "$1 $2 $3" = "buildx imagetools inspect" ]; then
  file="${STUB_DIR}/imagetools/$(key "$4")"
  if [ ! -f "${file}" ]; then
    echo "ERROR: $4: not found" >&2
    exit 1
  fi
  reply=$(cat "${file}")
  case "${reply}" in
    ERR:*) echo "${reply#ERR:}" >&2; exit 1 ;;
    *) printf '%s' "${reply}" ;;
  esac
  exit 0
fi
if [ "$1 $2" = "manifest inspect" ]; then
  file="${STUB_DIR}/manifest/$(key "$3")"
  [ -f "${file}" ] || { echo "no such manifest: $3" >&2; exit 1; }
  reply=$(cat "${file}")
  case "${reply}" in
    ERR:*) echo "${reply#ERR:}" >&2; exit 1 ;;
  esac
  echo '{"schemaVersion": 2}'
  exit 0
fi
echo "unexpected docker call: $*" >&2
exit 99
EOF
  chmod +x "${BIN}/docker"
  export PATH="${BIN}:${PATH}"
}

teardown() {
  rm -rf "${WORK}"
}

# A bare `! cmd` only fails a bats test when it is the last line of it.
refute() {
  if "$@"; then
    echo "expected to fail, but succeeded: $*"
    return 1
  fi
}

key() { printf '%s' "$1" | tr '/:' '__'; }
imagetools_has() { printf '%s' "${2:-${DIGEST}}" > "${STUB_DIR}/imagetools/$(key "$1")"; }
manifest_has() { printf '%s' "${2:-}" > "${STUB_DIR}/manifest/$(key "$1")"; }

# ── present ──────────────────────────────────────────────────────────────────

@test "every source image present passes" {
  imagetools_has "${APP}"
  imagetools_has "${WORKER}"
  run env SOURCE_REFS="${APP}"$'\n'"${WORKER}"$'\n' "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all 2 source image(s) are in the registry"* ]]
  [[ "$output" != *"::error::"* ]]
}

@test "blank lines between refs are ignored" {
  imagetools_has "${APP}"
  run env SOURCE_REFS=$'\n'"${APP}"$'\n\n' "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all 1 source image(s)"* ]]
}

@test "the check reads manifests only: nothing is pulled, tagged or pushed" {
  imagetools_has "${APP}"
  run env SOURCE_REFS="${APP}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  refute grep -Eq "docker (pull|tag|push)|imagetools create" "${STUB_LOG}"
}

# ── absent: the hard stop ────────────────────────────────────────────────────

@test "a source image that is not in the registry stops the promotion" {
  run env SOURCE_REFS="${APP}" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::promote-from: 1 of 1 source image(s) are not in the registry: ${APP}"* ]]
  [[ "$output" == *"Nothing was tagged or released"* ]]
}

@test "one missing image out of several stops the promotion and is named" {
  imagetools_has "${APP}"
  run env SOURCE_REFS="${APP}"$'\n'"${WORKER}" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 of 2 source image(s) are not in the registry: ${WORKER}"* ]]
}

@test "every missing image is listed, not just the first" {
  run env SOURCE_REFS="${APP}"$'\n'"${WORKER}" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"2 of 2 source image(s) are not in the registry: ${APP} ${WORKER}"* ]]
}

@test "an absent verdict is confirmed against the plain manifest API first" {
  # A registry that answers the buildx client with a 404 for an image that
  # pulls fine must not be able to block a promotion on its own.
  manifest_has "${APP}"
  run env SOURCE_REFS="${APP}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"confirmed by docker manifest inspect"* ]]
  grep -Fq "docker manifest inspect ${APP}" "${STUB_LOG}"
}

@test "absence has to be said twice: an outage on a tag containing 404 is not a missing image" {
  # The probe reads any reply holding `404` as absent, and this error echoes
  # the URL. Believing it would tell the operator to cut a new prerelease
  # because a registry was down.
  ref='ghcr.io/acme/app:v1.404.0-rc.1'
  imagetools_has "${ref}" "ERR:ERROR: unexpected status from HEAD request to https://ghcr.io/v2/acme/app/manifests/v1.404.0-rc.1: 503 Service Unavailable"
  manifest_has "${ref}" "ERR:received unexpected HTTP status: 503 Service Unavailable"
  run env SOURCE_REFS="${ref}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::verify-promote-from-images: ${ref} looked absent to one registry client and the other could not confirm it"* ]]
  [[ "$output" == *"503 Service Unavailable"* ]]
  [[ "$output" != *"::error::"* ]]
}

@test "a second client that cannot answer leaves the ref undetermined" {
  manifest_has "${APP}" "ERR:unauthorized: authentication required"
  run env SOURCE_REFS="${APP}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 of 1 source image(s) could not be checked"* ]]
}

# ── unknown: warned about, never fatal ───────────────────────────────────────

@test "a registry that would not answer is a warning, not a stop" {
  imagetools_has "${APP}" "ERR:ERROR: unexpected status from HEAD request: 503 Service Unavailable"
  run env SOURCE_REFS="${APP}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::probe-image-tag: could not determine whether ${APP} exists"* ]]
  [[ "$output" == *"1 of 1 source image(s) could not be checked"* ]]
}

@test "an undetermined ref is left to the retag, not second-guessed" {
  imagetools_has "${APP}" "ERR:ERROR: unauthorized: authentication required"
  run env SOURCE_REFS="${APP}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  refute grep -q "docker manifest inspect" "${STUB_LOG}"
}

@test "a missing image still stops the run when another could not be checked" {
  imagetools_has "${APP}" "ERR:ERROR: unauthorized: authentication required"
  run env SOURCE_REFS="${APP}"$'\n'"${WORKER}" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 of 2 source image(s) are not in the registry: ${WORKER}"* ]]
}

# ── nothing to check ─────────────────────────────────────────────────────────

@test "no refs at all is an error, not a pass" {
  # A promotion that was meant to carry images but derived none would
  # otherwise sail through with nothing verified.
  run env SOURCE_REFS="" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no source image could be derived"* ]]
  [ ! -s "${STUB_LOG}" ]
}
