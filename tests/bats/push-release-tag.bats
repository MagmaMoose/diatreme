#!/usr/bin/env bats

# Behaviour coverage for scripts/push-release-tag.sh.
#
# Each test sets up a temporary work tree + bare repo as origin. The
# script only accepts https:// or git@ remotes, so we point the clone's
# origin at a fake https URL and use git's `url.<base>.insteadOf` to
# rewrite both the bare URL and the token-prefixed URL (which the script
# synthesises) to the local bare repo path.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/push-release-tag.sh"

setup() {
  WORK=$(mktemp -d)
  BARE="${WORK}/origin.git"
  CLONE="${WORK}/clone"
  export GITHUB_OUTPUT="${WORK}/output"
  : > "${GITHUB_OUTPUT}"

  # Hermetic: ignore the dev's global/system gitconfig (e.g. tag.gpgsign=true
  # would make `git tag <name>` fail with "no tag message?"). CI runners
  # don't have either set, but local developers might.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  git init --bare --initial-branch=main "${BARE}" >/dev/null

  git -C "${WORK}" init --initial-branch=main clone >/dev/null
  git -C "${CLONE}" -c user.name=tester -c user.email=t@example.com \
    commit --allow-empty -m "initial" >/dev/null

  # Origin URL the script will see when it runs `git config --get
  # remote.origin.url`. Rewriting rules below map both this URL and the
  # token-prefixed form the script synthesises to the local bare repo,
  # so the actual push/ls-remote land in our fixture.
  git -C "${CLONE}" remote add origin "https://example.invalid/origin.git"
  git -C "${CLONE}" config --add "url.${BARE}.insteadOf" "https://example.invalid/origin.git"
  git -C "${CLONE}" config --add "url.${BARE}.insteadOf" "https://x-access-token:fake@example.invalid/origin.git"

  export GITHUB_TOKEN=fake
  unset RUNNER_TEMP || true
  unset MESSAGE || true
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL || true
}

teardown() {
  rm -rf "${WORK}"
}

@test "push creates and pushes a lightweight tag, emits released=true" {
  cd "${CLONE}"
  run env TAG=v1.0.0 "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "released=true" "${GITHUB_OUTPUT}"
  git -C "${BARE}" tag -l | grep -Fq "v1.0.0"
}

@test "push creates an annotated tag when MESSAGE is set" {
  cd "${CLONE}"
  run env TAG=v1.0.1 MESSAGE="chore(release): v1.0.1" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "released=true" "${GITHUB_OUTPUT}"
  obj_type=$(git -C "${BARE}" cat-file -t "v1.0.1")
  [ "${obj_type}" = "tag" ]
}

@test "pre-check: tag already exists on remote → released=false, exit 0" {
  cd "${CLONE}"
  # Pre-populate the bare repo with the tag.
  git -C "${CLONE}" tag v2.0.0
  git -C "${CLONE}" push origin v2.0.0 >/dev/null
  git -C "${CLONE}" tag -d v2.0.0

  run env TAG=v2.0.0 "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "released=false" "${GITHUB_OUTPUT}"
  ! grep -Fq "released=true" "${GITHUB_OUTPUT}"
}

@test "unsupported remote URL → exit 1" {
  cd "${CLONE}"
  git -C "${CLONE}" remote set-url origin "ssh://weird.example.com/path.git"
  run env TAG=v3.0.0 "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "Unsupported git remote URL format"
}

@test "git identity left alone when caller pre-set it" {
  cd "${CLONE}"
  git -C "${CLONE}" config user.name "Caller Identity"
  git -C "${CLONE}" config user.email "caller@example.com"
  run env TAG=v4.0.0 "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(git -C "${CLONE}" config --get user.name)" = "Caller Identity" ]
  [ "$(git -C "${CLONE}" config --get user.email)" = "caller@example.com" ]
}

@test "git identity defaults to github-actions[bot] when caller did not set it" {
  cd "${CLONE}"
  git -C "${CLONE}" config --unset user.name 2>/dev/null || true
  git -C "${CLONE}" config --unset user.email 2>/dev/null || true
  run env TAG=v5.0.0 "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(git -C "${CLONE}" config --get user.name)" = "github-actions[bot]" ]
  [ "$(git -C "${CLONE}" config --get user.email)" = "github-actions[bot]@users.noreply.github.com" ]
}

@test "emits latest_tag on a successful push" {
  cd "${CLONE}"
  run env TAG=v7.1.0 "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "latest_tag=v7.1.0" "${GITHUB_OUTPUT}"
  grep -Fq "released=true" "${GITHUB_OUTPUT}"
}

@test "emits latest_tag on a no-op (tag already on remote), released=false" {
  cd "${CLONE}"
  git -C "${CLONE}" tag v7.2.0
  git -C "${CLONE}" push origin v7.2.0 >/dev/null
  git -C "${CLONE}" tag -d v7.2.0

  run env TAG=v7.2.0 "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "latest_tag=v7.2.0" "${GITHUB_OUTPUT}"
  grep -Fq "released=false" "${GITHUB_OUTPUT}"
}

@test "emits release_notes only on a real release when RELEASE_NOTES is set" {
  cd "${CLONE}"
  run env TAG=v7.3.0 RELEASE_NOTES="Pre-release rc.1 for version 7.3.0" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "release_notes=Pre-release rc.1 for version 7.3.0" "${GITHUB_OUTPUT}"
}

@test "does NOT emit release_notes on a no-op even when RELEASE_NOTES is set" {
  cd "${CLONE}"
  git -C "${CLONE}" tag v7.4.0
  git -C "${CLONE}" push origin v7.4.0 >/dev/null
  git -C "${CLONE}" tag -d v7.4.0

  run env TAG=v7.4.0 RELEASE_NOTES="should not appear" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "released=false" "${GITHUB_OUTPUT}"
  ! grep -Fq "release_notes=" "${GITHUB_OUTPUT}"
}

@test "no RELEASE_NOTES set → success still exits 0 (no dangling release_notes)" {
  cd "${CLONE}"
  run env TAG=v7.5.0 "${SCRIPT}"
  [ "$status" -eq 0 ]
  ! grep -Fq "release_notes=" "${GITHUB_OUTPUT}"
}

@test "stderr capture file is cleaned up under RUNNER_TEMP" {
  cd "${CLONE}"
  export RUNNER_TEMP="${WORK}/runner-tmp"
  mkdir -p "${RUNNER_TEMP}"

  run env TAG=v6.0.0 "${SCRIPT}"
  [ "$status" -eq 0 ]
  # The trap should clean the per-invocation temp file on exit.
  leftover=$(find "${RUNNER_TEMP}" -name 'tag_push.err.*' 2>/dev/null | wc -l | tr -d ' ')
  [ "${leftover}" = "0" ]
}

# ── RESUME_AT_HEAD: a promotion finishing what it started ───────────────────
# `promote-from` releases one named build. If that run dies after the stable
# tag is pushed (a registry hiccup on the retag), running it again has to
# finish the job, and "tag already exists, nothing to release" would leave the
# tag with no image behind it for good. So an existing tag on HEAD's commit is
# a resumed release. An existing tag anywhere else is a different build under
# this version, and must never be taken for this one.

# A bare `! cmd` only fails a bats test when it is the last line of it.
refute() {
  if "$@"; then
    echo "expected to fail, but succeeded: $*"
    return 1
  fi
}

publish_tag_at() {
  # $1 tag, $2 commit-ish, $3 "annotated" for an annotated tag
  if [ "${3:-}" = "annotated" ]; then
    git -C "${CLONE}" -c user.name=tester -c user.email=t@example.com \
      tag -a "$1" -m "chore(release): $1" "$2"
  else
    git -C "${CLONE}" tag "$1" "$2"
  fi
  git -C "${CLONE}" push origin "$1" >/dev/null 2>&1
  git -C "${CLONE}" tag -d "$1" >/dev/null
}

@test "RESUME_AT_HEAD: a lightweight tag already on HEAD resumes (released=true)" {
  cd "${CLONE}"
  publish_tag_at v8.0.0 HEAD
  run env TAG=v8.0.0 RESUME_AT_HEAD=true "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Resuming that release"* ]]
  grep -Fq "released=true" "${GITHUB_OUTPUT}"
  refute grep -Fq "released=false" "${GITHUB_OUTPUT}"
  grep -Fq "latest_tag=v8.0.0" "${GITHUB_OUTPUT}"
}

@test "RESUME_AT_HEAD: an annotated tag is compared by the commit it peels to" {
  # The tags Diatreme pushes are annotated, so the remote advertises the tag
  # OBJECT's id under the tag name. Comparing that to HEAD would never match
  # and every resume would be refused as "a different build".
  cd "${CLONE}"
  publish_tag_at v8.1.0 HEAD annotated
  run env TAG=v8.1.0 MESSAGE="chore(release): v8.1.0" RESUME_AT_HEAD=true "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "released=true" "${GITHUB_OUTPUT}"
}

@test "RESUME_AT_HEAD: a tag on a different commit is refused, not resumed" {
  cd "${CLONE}"
  publish_tag_at v8.2.0 HEAD annotated
  git -C "${CLONE}" -c user.name=tester -c user.email=t@example.com \
    commit --allow-empty -m "a later commit" >/dev/null

  run env TAG=v8.2.0 RESUME_AT_HEAD=true "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::Tag v8.2.0 already exists on remote at"* ]]
  [[ "$output" == *"Refusing to treat a different build as this release"* ]]
  refute grep -Fq "released=" "${GITHUB_OUTPUT}"
}

@test "RESUME_AT_HEAD: a tag that does not exist yet is pushed as usual" {
  cd "${CLONE}"
  run env TAG=v8.3.0 RESUME_AT_HEAD=true "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "released=true" "${GITHUB_OUTPUT}"
  git -C "${BARE}" tag -l | grep -Fq "v8.3.0"
}

@test "without RESUME_AT_HEAD a tag already on HEAD stays a no-op" {
  # The default must not move: for every other path an existing tag means a
  # parallel run already cut this release, and resuming would release it twice.
  cd "${CLONE}"
  publish_tag_at v8.4.0 HEAD
  run env TAG=v8.4.0 "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "released=false" "${GITHUB_OUTPUT}"
  refute grep -Fq "released=true" "${GITHUB_OUTPUT}"

  : > "${GITHUB_OUTPUT}"
  run env TAG=v8.4.0 RESUME_AT_HEAD=false "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "released=false" "${GITHUB_OUTPUT}"
}

# ── RESUME_MARKER: the commit alone is not proof ────────────────────────────
# Two prereleases can sit on one commit with different images behind them, and
# an ordinary release may have cut the same version there. The marker line in
# the tag's message is what says "this tag is this promotion's".

MARKER="Promoted-From: v9.0.0-rc.3"

publish_marked_tag() {
  # $1 tag, $2 commit-ish, $3 marker line
  git -C "${CLONE}" -c user.name=tester -c user.email=t@example.com \
    tag -a "$1" -m "chore(release): $1" -m "$3" "$2"
  git -C "${CLONE}" push origin "$1" >/dev/null 2>&1
  git -C "${CLONE}" tag -d "$1" >/dev/null
}

@test "RESUME_MARKER: a tag on HEAD carrying the marker resumes" {
  cd "${CLONE}"
  publish_marked_tag v9.0.0 HEAD "${MARKER}"
  run env TAG=v9.0.0 RESUME_AT_HEAD=true RESUME_MARKER="${MARKER}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Resuming that release"* ]]
  grep -Fq "released=true" "${GITHUB_OUTPUT}"
}

@test "RESUME_MARKER: a tag on HEAD promoted from another prerelease is refused" {
  cd "${CLONE}"
  publish_marked_tag v9.1.0 HEAD "Promoted-From: v9.1.0-rc.3"
  run env TAG=v9.1.0 RESUME_AT_HEAD=true RESUME_MARKER="Promoted-From: v9.1.0-rc.4" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"it is not this release"* ]]
  [[ "$output" == *"no 'Promoted-From: v9.1.0-rc.4' line"* ]]
  refute grep -Fq "released=" "${GITHUB_OUTPUT}"
}

@test "RESUME_MARKER: a tag on HEAD with no marker at all is refused" {
  cd "${CLONE}"
  publish_tag_at v9.2.0 HEAD annotated
  run env TAG=v9.2.0 RESUME_AT_HEAD=true RESUME_MARKER="${MARKER}" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"it is not this release"* ]]
}

@test "RESUME_MARKER: a lightweight tag cannot borrow the marker from its commit message" {
  cd "${CLONE}"
  git -C "${CLONE}" -c user.name=tester -c user.email=t@example.com \
    commit --allow-empty -m "feat: thing" -m "${MARKER}" >/dev/null
  publish_tag_at v9.3.0 HEAD
  run env TAG=v9.3.0 RESUME_AT_HEAD=true RESUME_MARKER="${MARKER}" "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"it is not this release"* ]]
}

@test "RESUME_MARKER: the tag this script pushes is one a later run resumes on" {
  # The round trip a promotion relies on: MESSAGE carries the marker, the tag
  # goes out, and the same call again finds its own tag.
  cd "${CLONE}"
  message="chore(release): v9.4.0"$'\n\n'"${MARKER}"
  run env TAG=v9.4.0 MESSAGE="${message}" RESUME_AT_HEAD=true RESUME_MARKER="${MARKER}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq "released=true" "${GITHUB_OUTPUT}"
  refute grep -q "Resuming" <<< "$output"

  : > "${GITHUB_OUTPUT}"
  run env TAG=v9.4.0 MESSAGE="${message}" RESUME_AT_HEAD=true RESUME_MARKER="${MARKER}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Resuming that release"* ]]
  grep -Fq "released=true" "${GITHUB_OUTPUT}"
}

@test "RESUME_AT_HEAD: a remote that cannot be asked is an error, not 'absent'" {
  # Reading a failed query as "absent" would walk a resumed run into `git tag`
  # with the tag already in the clone, and hide the real cause behind
  # "tag already exists".
  cd "${CLONE}"
  git -C "${CLONE}" config --unset-all "url.${BARE}.insteadOf"
  run env TAG=v9.5.0 RESUME_AT_HEAD=true "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::Could not ask the remote whether tag v9.5.0 exists"* ]]
  refute grep -Fq "released=" "${GITHUB_OUTPUT}"
}

# ── losing the race between check and push ──────────────────────────────────
# `git` is wrapped so the first two `ls-remote` calls (the resume check and
# the pre-check) see nothing, as they would a moment before a rival run's push
# lands. The push then fails against the tag that is really there.

blind_git() {
  REAL_GIT=$(command -v git)
  export REAL_GIT
  export LSREMOTE_CALLS="${WORK}/ls-remote.calls"
  echo 0 > "${LSREMOTE_CALLS}"
  mkdir -p "${WORK}/bin"
  cat > "${WORK}/bin/git" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "ls-remote" ]; then
  n=$(($(cat "${LSREMOTE_CALLS}") + 1))
  echo "${n}" > "${LSREMOTE_CALLS}"
  if [ "${n}" -le "${LSREMOTE_BLIND:-2}" ]; then exit 0; fi
fi
exec "${REAL_GIT}" "$@"
STUB
  chmod +x "${WORK}/bin/git"
}

@test "RESUME_AT_HEAD: losing the race to a tag on another commit is an error, not a green no-op" {
  cd "${CLONE}"
  publish_marked_tag v9.6.0 HEAD "Promoted-From: v9.6.0-rc.1"
  git -C "${CLONE}" -c user.name=tester -c user.email=t@example.com \
    commit --allow-empty -m "the build this run was asked to release" >/dev/null
  blind_git

  run env PATH="${WORK}/bin:${PATH}" TAG=v9.6.0 MESSAGE="chore(release): v9.6.0" \
    RESUME_AT_HEAD=true "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing to treat a different build as this release"* ]]
  refute grep -Fq "released=" "${GITHUB_OUTPUT}"
}

@test "RESUME_AT_HEAD: losing the race to the same release stays a no-op" {
  # The run that won is carrying the release through; doing it twice helps
  # nobody.
  cd "${CLONE}"
  publish_marked_tag v9.7.0 HEAD "${MARKER}"
  blind_git

  run env PATH="${WORK}/bin:${PATH}" TAG=v9.7.0 \
    MESSAGE="chore(release): v9.7.0"$'\n\n'"${MARKER}" \
    RESUME_AT_HEAD=true RESUME_MARKER="${MARKER}" "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"parallel run won the race"* ]]
  grep -Fq "released=false" "${GITHUB_OUTPUT}"
  refute grep -Fq "released=true" "${GITHUB_OUTPUT}"
}

@test "without RESUME_AT_HEAD losing the race is the no-op it always was" {
  cd "${CLONE}"
  publish_tag_at v9.8.0 HEAD annotated
  git -C "${CLONE}" -c user.name=tester -c user.email=t@example.com \
    commit --allow-empty -m "a later commit" >/dev/null
  blind_git

  run env PATH="${WORK}/bin:${PATH}" LSREMOTE_BLIND=1 TAG=v9.8.0 "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"parallel run won the race"* ]]
  grep -Fq "released=false" "${GITHUB_OUTPUT}"
}
