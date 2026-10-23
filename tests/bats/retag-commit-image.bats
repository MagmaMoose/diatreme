#!/usr/bin/env bats

# scripts/retag-commit-image.sh: a pull request whose `mode: ci` build was
# skipped (deploy-paths) still gets its commit tag, from the pr-<N> image its
# last build pushed. The real probe-image-tag.sh runs against a docker stub.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/retag-commit-image.sh"

setup() {
  STATE="${BATS_TEST_TMPDIR}/state"
  mkdir -p "${STATE}" "${BATS_TEST_TMPDIR}/bin"
  : > "${STATE}/present"
  : > "${STATE}/calls.log"
  export STATE
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
  : > "${GITHUB_OUTPUT}"

  # docker: `imagetools inspect` knows the refs listed in ${STATE}/present
  # (or fails with ${STATE}/inspect-error); `imagetools create` fails with
  # ${STATE}/create-error when it exists. Every write is logged.
  cat > "${BATS_TEST_TMPDIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "buildx imagetools inspect "*)
    if [ -f "${STATE}/inspect-error" ]; then cat "${STATE}/inspect-error" >&2; exit 1; fi
    if grep -Fxq "$4" "${STATE}/present"; then printf 'sha256:%064d\n' 1; exit 0; fi
    echo "ERROR: $4: not found" >&2; exit 1 ;;
  "buildx imagetools create "*)
    echo "docker $*" >> "${STATE}/calls.log"
    if [ -f "${STATE}/create-error" ]; then cat "${STATE}/create-error" >&2; exit 1; fi ;;
  *) echo "docker $*" >> "${STATE}/calls.log" ;;
esac
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/docker"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export COMMIT_TAG=pr-12-1a2b3c4
}

retag() { SOURCE_REFS="$(printf '%s\n' "$@")" run "${SCRIPT}"; }

@test "a skipped build still gets a commit tag: pr-<N> is retagged, never rebuilt" {
  printf '%s\n' ghcr.io/acme/app:pr-12 ghcr.io/acme/worker:pr-12 > "${STATE}/present"
  retag ghcr.io/acme/app:pr-12 ghcr.io/acme/worker:pr-12
  [ "$status" -eq 0 ]
  grep -Fxq "docker buildx imagetools create --tag ghcr.io/acme/app:pr-12-1a2b3c4 ghcr.io/acme/app:pr-12" "${STATE}/calls.log"
  grep -Fxq "docker buildx imagetools create --tag ghcr.io/acme/worker:pr-12-1a2b3c4 ghcr.io/acme/worker:pr-12" "${STATE}/calls.log"
  if grep -Eq ' (build|bake) ' "${STATE}/calls.log"; then echo "rebuilt"; false; fi
  grep -Fxq "image-commit-tag=pr-12-1a2b3c4" "${GITHUB_OUTPUT}"
}

@test "a pull request with no pr-<N> yet warns and does not fail" {
  retag ghcr.io/acme/app:pr-12
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::ghcr.io/acme/app:pr-12 does not exist"* ]]
  [ ! -s "${STATE}/calls.log" ]
  [ ! -s "${GITHUB_OUTPUT}" ]
}

@test "a retag that fails is an error, so the head is never reported ready without its tag" {
  echo ghcr.io/acme/app:pr-12 > "${STATE}/present"
  echo "ERROR: unauthorized: write access denied" > "${STATE}/create-error"
  retag ghcr.io/acme/app:pr-12
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::Could not tag ghcr.io/acme/app:pr-12 as ghcr.io/acme/app:pr-12-1a2b3c4"*"unauthorized"* ]]
  [ ! -s "${GITHUB_OUTPUT}" ]
}

@test "GHE's referrers-index failure falls back to pull/tag/push" {
  echo ghcr.io/acme/app:pr-12 > "${STATE}/present"
  echo "ERROR: failed to decode referrers index: invalid character '<'" > "${STATE}/create-error"
  retag ghcr.io/acme/app:pr-12
  [ "$status" -eq 0 ]
  grep -Fxq "docker pull ghcr.io/acme/app:pr-12" "${STATE}/calls.log"
  grep -Fxq "docker tag ghcr.io/acme/app:pr-12 ghcr.io/acme/app:pr-12-1a2b3c4" "${STATE}/calls.log"
  grep -Fxq "docker push ghcr.io/acme/app:pr-12-1a2b3c4" "${STATE}/calls.log"
  grep -Fxq "image-commit-tag=pr-12-1a2b3c4" "${GITHUB_OUTPUT}"
}

@test "a registry that would not say is left to the retag" {
  echo "ERROR: unexpected status from HEAD request: 503 Service Unavailable" > "${STATE}/inspect-error"
  retag ghcr.io/acme/app:pr-12
  [ "$status" -eq 0 ]
  grep -Fq "imagetools create --tag ghcr.io/acme/app:pr-12-1a2b3c4" "${STATE}/calls.log"
}

@test "a registry port and a digest stay out of the tag" {
  printf '%s\n' localhost:5000/acme/app:pr-12 "ghcr.io/acme/app:pr-12@sha256:$(printf '%064d' 1)" > "${STATE}/present"
  retag localhost:5000/acme/app:pr-12 "ghcr.io/acme/app:pr-12@sha256:$(printf '%064d' 1)"
  [ "$status" -eq 0 ]
  grep -Fq -- "--tag localhost:5000/acme/app:pr-12-1a2b3c4 " "${STATE}/calls.log"
  grep -Fq -- "--tag ghcr.io/acme/app:pr-12-1a2b3c4 " "${STATE}/calls.log"
}

@test "no image ref at all is an error" {
  retag ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
}
