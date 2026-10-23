#!/usr/bin/env bats

# The ci build step as action.yml wires it: the real `run:` block of "Build and
# push CI image" against stubs, on a push and on a pull request, plus the
# wiring that hands its tag to the scan and the job summary. The tag rules
# themselves are tests/bats/ci-image-tag.bats; what this holds is that the
# build pushes exactly that tag, a bake file sees it as ${VERSION}, and the
# scan reads the tag back instead of re-deriving it. With image-commit-tag, a
# pull request build also pushes pr-<N>-<sha7> of the pull request's head, in
# the same push.

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
ACTION_YML="${REPO_ROOT}/action.yml"

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

setup() {
  WORK=$(mktemp -d)
  export GITHUB_OUTPUT="${WORK}/output"
  : > "${GITHUB_OUTPUT}"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  export STUB_LOG="${WORK}/calls.log"
  : > "${STUB_LOG}"

  # The real tag script, and a Dockerfile builder that records what it was
  # asked to push.
  STUB_ACTION="${WORK}/action"
  mkdir -p "${STUB_ACTION}/scripts" "${WORK}/bin"
  cp "${REPO_ROOT}/scripts/ci-image-tag.sh" "${STUB_ACTION}/scripts/"
  cat > "${STUB_ACTION}/scripts/build-image-dockerfile.sh" <<'EOF'
#!/usr/bin/env bash
echo "dockerfile TAGS=${TAGS}" >> "${STUB_LOG}"
EOF
  chmod +x "${STUB_ACTION}/scripts/"*.sh

  # docker: `bake --print` prints ${BAKE_PRINT_FILE} (one target unless a test
  # says otherwise); a real bake records the VERSION it was given, which is
  # what a bake file's tags interpolate, and each of its arguments.
  export BAKE_PRINT_FILE="${WORK}/print.json"
  echo '{"target":{"app":{"tags":["ghcr.io/acme/app:x"]}}}' > "${BAKE_PRINT_FILE}"
  cat > "${WORK}/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"--print"*) cat "${BAKE_PRINT_FILE}" ;;
  "buildx bake "*)
    echo "bake VERSION=${VERSION}" >> "${STUB_LOG}"
    printf 'bake arg %s\n' "$@" >> "${STUB_LOG}" ;;
esac
EOF
  chmod +x "${WORK}/bin/docker"

  git init -q --initial-branch=master "${WORK}/repo"
  cd "${WORK}/repo"
  GIT_COMMITTER_DATE="@1760000000 +0000" \
    git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m initial
  SHA7=$(git rev-parse --short=7 HEAD)
  # A pull request's head: never HEAD, which stands in for the merge commit
  # actions/checkout builds on a pull request.
  HEAD_SHA=1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d
}

teardown() {
  cd /
  rm -rf "${WORK}"
}

build() {
  run_step "Build and push CI image" \
    "GITHUB_ACTION_PATH=${STUB_ACTION}" "PATH=${WORK}/bin:${PATH}" \
    REGISTRY=ghcr.io INPUT_PLATFORMS= BAKE_GITHUB_TOKEN= OWNER=Acme \
    INPUT_IMAGE_NAME=app INPUT_BAKE_FILE=docker-bake.hcl INPUT_BAKE_TARGET=default \
    INPUT_DOCKERFILE=Dockerfile VERSION_OVERRIDE= PR_NUMBER= REF_NAME=test STRATEGY=dockerfile \
    HEAD_SHA= IMAGE_COMMIT_TAG=false "$@"
}

@test "a push builds <branch>-<sha7>-<time>, never pr-" {
  build
  [ "$status" -eq 0 ]
  grep -Fxq "dockerfile TAGS=ghcr.io/acme/app:test-${SHA7}-1760000000" "${STUB_LOG}"
  [ "$(out image-tag)" = "test-${SHA7}-1760000000" ]
  if grep -q ":pr-" "${STUB_LOG}"; then echo "pushed a pr- tag"; false; fi
}

@test "a pull request still builds pr-<N>" {
  build PR_NUMBER=42 REF_NAME=42/merge
  grep -Fxq "dockerfile TAGS=ghcr.io/acme/app:pr-42" "${STUB_LOG}"
  [ "$(out image-tag)" = "pr-42" ]
}

@test "version-override still names the build" {
  build VERSION_OVERRIDE=3.20.0 PR_NUMBER=42
  grep -Fxq "dockerfile TAGS=ghcr.io/acme/app:3.20.0" "${STUB_LOG}"
}

@test "a bake file gets the tag as VERSION" {
  build STRATEGY=bake REF_NAME=feature/12-x
  [ "$status" -eq 0 ]
  grep -Fxq "bake VERSION=feature-12-x-${SHA7}-1760000000" "${STUB_LOG}"
}

@test "the scan reads the tag the build pushed, and derives nothing itself" {
  head=$(step_head "Scan image and report")
  grep -Fq 'VERSION: ${{ steps.build-pr-image.outputs.image-tag }}' <<< "${head}"
  if grep -Fq "format('pr-{0}'" "${ACTION_YML}"; then
    echo "a pr-<N> tag is still derived inline somewhere"; false
  fi
}

@test "the job summary and the image-tag output read the build's tag" {
  step_head "Write job summary" | grep -Fq 'CI_IMAGE_TAG: ${{ steps.build-pr-image.outputs.image-tag }}'
  grep -A3 '^  image-tag:' "${ACTION_YML}" | grep -Fq 'steps.build-pr-image.outputs.image-tag'
}

@test "the commit tag names the pull request head, not the merge commit actions/checkout builds" {
  build PR_NUMBER=42 REF_NAME=42/merge IMAGE_COMMIT_TAG=true HEAD_SHA="${HEAD_SHA}"
  [ "$status" -eq 0 ]
  grep -Fxq "dockerfile TAGS=ghcr.io/acme/app:pr-42" "${STUB_LOG}"
  grep -Fxq "ghcr.io/acme/app:pr-42-1a2b3c4" "${STUB_LOG}"
  [ "$(out image-commit-tag)" = "pr-42-1a2b3c4" ]
  [ "$(out image-tag)" = "pr-42" ]
  if grep -q "${SHA7}" "${STUB_LOG}"; then echo "tagged the merge commit"; false; fi
  for s in "Build and push CI image" "Tag skipped build for the pull request head"; do
    step_head "${s}" | grep -Fq 'HEAD_SHA: ${{ github.event.pull_request.head.sha }}' \
      || { echo "${s}: HEAD_SHA is not the pull request head"; false; }
    if step_head "${s}" | grep -Fq '${{ github.sha }}'; then echo "${s}: reads github.sha"; false; fi
  done
}

@test "a bake build pushes the commit tag in the same push, beside every tag the bake file gives" {
  cat > "${BAKE_PRINT_FILE}" <<'EOF'
{"target": {
  "app": {"tags": ["ghcr.io/acme/app:pr-42", "ghcr.io/acme/app:extra"]},
  "worker": {"tags": ["registry.local:5000/acme/worker:pr-42"]},
  "base": {}
}}
EOF
  build STRATEGY=bake PR_NUMBER=42 IMAGE_COMMIT_TAG=true HEAD_SHA="${HEAD_SHA}"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^bake VERSION=' "${STUB_LOG}")" -eq 1 ]
  grep -Fxq "bake VERSION=pr-42" "${STUB_LOG}"
  grep -Fxq "bake arg app.tags=ghcr.io/acme/app:pr-42" "${STUB_LOG}"
  grep -Fxq "bake arg app.tags=ghcr.io/acme/app:extra" "${STUB_LOG}"
  grep -Fxq "bake arg app.tags=ghcr.io/acme/app:pr-42-1a2b3c4" "${STUB_LOG}"
  grep -Fxq "bake arg worker.tags=registry.local:5000/acme/worker:pr-42" "${STUB_LOG}"
  grep -Fxq "bake arg worker.tags=registry.local:5000/acme/worker:pr-42-1a2b3c4" "${STUB_LOG}"
  if grep -q "^bake arg base\.tags=" "${STUB_LOG}"; then echo "an untagged target got a tag"; false; fi
}

@test "image-commit-tag off, the default, pushes no commit tag" {
  build STRATEGY=bake PR_NUMBER=42 HEAD_SHA="${HEAD_SHA}"
  [ "$status" -eq 0 ]
  if grep -q '\.tags=' "${STUB_LOG}"; then echo "the bake file's tags were overridden"; false; fi
  [ -z "$(out image-commit-tag)" ]
}

@test "a push gets no commit tag: it has no pull request head" {
  build IMAGE_COMMIT_TAG=true
  [ "$status" -eq 0 ]
  [ "$(grep -c 'ghcr.io/acme/app:' "${STUB_LOG}")" -eq 1 ]
  [ -z "$(out image-commit-tag)" ]
}

@test "the image-commit-tag output reads the build, then the skipped build's retag" {
  grep -A3 '^  image-commit-tag:' "${ACTION_YML}" | grep -Fq \
    'steps.build-pr-image.outputs.image-commit-tag || steps.retag-commit.outputs.image-commit-tag'
}
