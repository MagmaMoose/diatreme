#!/usr/bin/env bats

# scripts/pr-building-label.sh: `image-building-label` goes on a pull request
# before `mode: ci` builds and comes off once every tag is pushed, and no
# label failure ever fails the build.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/pr-building-label.sh"

setup() {
  STATE="${BATS_TEST_TMPDIR}/state"
  mkdir -p "${STATE}" "${BATS_TEST_TMPDIR}/bin"
  : > "${STATE}/calls.log"
  export STATE

  # gh: logs every call; fails with ${STATE}/gh-error when it exists.
  cat > "${BATS_TEST_TMPDIR}/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "${STATE}/calls.log"
if [ -f "${STATE}/gh-error" ]; then cat "${STATE}/gh-error" >&2; exit 1; fi
echo '[]'
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export GH_TOKEN=fake REPO_FULL=acme/app PR_NUMBER=12 LABEL=deploy/preview-building
  export EVENT_ACTION=synchronize EVENT_LABEL=
}

@test "the label goes on the pull request before the build" {
  ACTION=add run "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fxq "gh api -X POST repos/acme/app/issues/12/labels -f labels[]=deploy/preview-building" "${STATE}/calls.log"
}

@test "the label comes off by its URL-encoded name" {
  ACTION=remove run "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fxq "gh api -X DELETE repos/acme/app/issues/12/labels/deploy%2Fpreview-building" "${STATE}/calls.log"
}

@test "a label the token cannot change never fails the build" {
  echo "gh: Resource not accessible by integration (HTTP 403)" > "${STATE}/gh-error"
  for action in add remove; do
    ACTION="${action}" run "${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::[image-building-label]"*"HTTP 403"* ]]
  done
  ACTION=add PR_NUMBER= run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  ACTION=bogus run "${SCRIPT}"
  [ "$status" -eq 0 ]
}

@test "a label that is already off is not a warning" {
  echo "gh: Label does not exist (HTTP 404)" > "${STATE}/gh-error"
  ACTION=remove run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"::warning::"* ]]
}

@test "a run started by its own label does not add it again, so it cannot loop" {
  for event in labeled unlabeled; do
    : > "${STATE}/calls.log"
    ACTION=add EVENT_ACTION="${event}" EVENT_LABEL=deploy/preview-building run "${SCRIPT}"
    [ "$status" -eq 0 ]
    [ ! -s "${STATE}/calls.log" ]
    [[ "$output" == *"::warning::"*"Remove labeled and unlabeled"* ]]
  done
  # It still comes off, or a cancelled predecessor would leave it on for good.
  ACTION=remove EVENT_ACTION=labeled EVENT_LABEL=deploy/preview-building run "${SCRIPT}"
  grep -Fq "gh api -X DELETE" "${STATE}/calls.log"
}

@test "another label's event is an ordinary run" {
  ACTION=add EVENT_ACTION=labeled EVENT_LABEL=deploy/preview run "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "gh api -X POST" "${STATE}/calls.log"
}
