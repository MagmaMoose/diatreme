#!/usr/bin/env bats

# Behaviour coverage for the release-notes half of
# scripts/append-clickup-tickets.sh: the section is appended once.
#
# It used to be unreachable twice for one tag, because an existing tag meant
# `released=false` and the step never ran. A resumed `promote-from` run changes
# that: it reaches this step again for a release that already exists, and an
# unconditional append listed every ticket a second time.
#
# `gh` is stubbed. `release view` prints the body in ${STUB_BODY}; `release
# edit` copies the notes file it is handed to ${STUB_EDITED}, since the script
# removes its own copy on exit.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/append-clickup-tickets.sh"

setup() {
  WORK=$(mktemp -d)
  BIN="${WORK}/bin"
  mkdir -p "${BIN}"
  export STUB_BODY="${WORK}/body.md"
  export STUB_EDITED="${WORK}/edited.md"
  export STUB_GH_LOG="${WORK}/gh.log"
  : > "${STUB_BODY}"; : > "${STUB_GH_LOG}"

  cat > "${BIN}/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "${STUB_GH_LOG}"
case "$1 $2" in
  "release view") cat "${STUB_BODY}" ;;
  "release edit")
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--notes-file" ]; then cp "$2" "${STUB_EDITED}"; fi
      shift
    done
    ;;
esac
exit 0
EOF
  chmod +x "${BIN}/gh"
  export PATH="${BIN}:${PATH}"

  # Hermetic: see latest-tag.bats.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  git init --initial-branch=main "${WORK}/repo" >/dev/null
  cd "${WORK}/repo"
  git config user.name tester
  git config user.email t@example.com
  git commit --allow-empty -m "chore: start" >/dev/null
  git tag v1.4.2
  git commit --allow-empty -m "feat: thing" -m "https://app.clickup.com/t/abc123" >/dev/null
  git tag v1.5.0

  export GH_TOKEN=fake OWNER=acme REPO=app TAG=v1.5.0 PRERELEASE_IDENTIFIER=
}

teardown() {
  cd /
  rm -rf "${WORK}"
}

@test "a release without the section gets it appended" {
  printf "## What's Changed\n\n* feat: thing\n" > "${STUB_BODY}"
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "gh release edit v1.5.0" "${STUB_GH_LOG}"
  grep -Fxq "## ClickUp tickets" "${STUB_EDITED}"
  grep -Fxq -- "- https://app.clickup.com/t/abc123" "${STUB_EDITED}"
  grep -Fxq "## What's Changed" "${STUB_EDITED}"
}

@test "a release that already has the section is left as it is" {
  printf "## What's Changed\n\n* feat: thing\n\n## ClickUp tickets\n\n- https://app.clickup.com/t/abc123\n" > "${STUB_BODY}"
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already contain a ClickUp section"* ]]
  run grep -q "gh release edit" "${STUB_GH_LOG}"
  [ "$status" -ne 0 ]
  [ ! -e "${STUB_EDITED}" ]
}

@test "a body saved with CRLF line endings still counts as having the section" {
  # Release bodies edited in the web UI come back with CRLF.
  printf "## What's Changed\r\n\r\n## ClickUp tickets\r\n\r\n- https://app.clickup.com/t/abc123\r\n" > "${STUB_BODY}"
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  run grep -q "gh release edit" "${STUB_GH_LOG}"
  [ "$status" -ne 0 ]
}
