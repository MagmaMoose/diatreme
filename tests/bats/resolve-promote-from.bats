#!/usr/bin/env bats

# Behaviour coverage for scripts/resolve-promote-from.sh, the step that turns
# `promote-from: v1.5.0-rc.3` into "release that exact build as v1.5.0".
#
# The script runs before anything is written, so every refusal here is a
# release that did not go out wrong. The cases that matter are the ones where a
# plausible-looking input would otherwise ship something nobody tested: a
# `-dev.N` tag typed where `-rc.N` was meant, a stable tag that already names a
# different build, a fix on an older release line dragging `:latest` backwards.
#
# Each test builds a throwaway repository and tags it; the script reads local
# refs only, so there is nothing to stub.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/resolve-promote-from.sh"

ENVS='["dev","staging","prod"]'
IDS='{"dev":"dev","staging":"rc"}'

setup() {
  WORK=$(mktemp -d)
  export GITHUB_OUTPUT="${WORK}/output"
  : > "${GITHUB_OUTPUT}"

  # Hermetic: a developer's global gitconfig (tag.gpgsign=true) would make
  # plain `git tag <name>` fail. CI runners have neither set.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  git init --initial-branch=main "${WORK}/repo" >/dev/null
  cd "${WORK}/repo"
  git config user.name tester
  git config user.email t@example.com

  unset PROMOTE_FROM TAG_PREFIX VERSION_OVERRIDE FORCE_BUMP ENVIRONMENTS PRERELEASE_IDENTIFIERS || true
}

teardown() {
  cd /
  rm -rf "${WORK}"
}

commit() { git commit --allow-empty -m "$1" >/dev/null; }
out() { grep -E "^$1=" "${GITHUB_OUTPUT}" | tail -n 1 | cut -d= -f2-; }

# One release line: a stable 1.4.2 behind us, and three candidates for 1.5.0.
release_line() {
  commit "one";   git tag v1.4.2
  commit "two";   git tag v1.5.0-rc.1
  commit "three"; git tag v1.5.0-rc.2
  commit "four";  git tag v1.5.0-rc.3
  RC3=$(git rev-parse HEAD)
  commit "five: the branch has moved on"
}

promote() { run env TAG_PREFIX=v PROMOTE_FROM="$1" "${@:2}" "${SCRIPT}"; }

# A stable tag as a promotion pushes it: annotated, recording its source.
# $1 stable tag, $2 the prerelease it was promoted from, $3 commit-ish
promoted_tag() {
  git tag -a "$1" -m "chore(release): $1" -m "Promoted-From: $2" "$3"
}

# ── the name ─────────────────────────────────────────────────────────────────

@test "a prerelease tag resolves to its stable version and tag" {
  release_line
  promote v1.5.0-rc.3
  [ "$status" -eq 0 ]
  [ "$(out source_tag)" = "v1.5.0-rc.3" ]
  [ "$(out version)" = "1.5.0" ]
  [ "$(out tag)" = "v1.5.0" ]
}

@test "the tag prefix is optional on the input" {
  release_line
  promote 1.5.0-rc.3
  [ "$status" -eq 0 ]
  [ "$(out source_tag)" = "v1.5.0-rc.3" ]
  [ "$(out tag)" = "v1.5.0" ]
}

@test "an empty tag prefix works" {
  commit "one"; git tag 3.27.0-rc.1
  run env TAG_PREFIX= PROMOTE_FROM=3.27.0-rc.1 "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(out source_tag)" = "3.27.0-rc.1" ]
  [ "$(out tag)" = "3.27.0" ]
}

@test "a multi-package prefix is honoured" {
  commit "one"; git tag core-v1.4.0-rc.2
  run env TAG_PREFIX=core-v PROMOTE_FROM=core-v1.4.0-rc.2 "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(out version)" = "1.4.0" ]
  [ "$(out tag)" = "core-v1.4.0" ]
}

@test "surrounding whitespace from a pasted dispatch input is trimmed" {
  release_line
  promote "  v1.5.0-rc.3"$' \n'
  [ "$status" -eq 0 ]
  [ "$(out source_tag)" = "v1.5.0-rc.3" ]
}

@test "a stable tag is refused: there is nothing to promote" {
  release_line
  promote v1.4.2
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::promote-from:"* ]]
  [[ "$output" == *"already a stable version"* ]]
}

@test "something that is not a version is refused" {
  release_line
  promote main
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a prerelease tag"* ]]
}

@test "a tag from another package's series is refused" {
  commit "one"; git tag ui-v1.0.0-rc.1
  run env TAG_PREFIX=core-v PROMOTE_FROM=ui-v1.0.0-rc.1 "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a prerelease tag under tag-prefix 'core-v'"* ]]
}

@test "build metadata is refused: a Docker tag cannot carry '+'" {
  release_line
  promote v1.5.0-rc.3+build.7
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a prerelease tag"* ]]
}

@test "an empty input is refused rather than read as 'not a promotion'" {
  release_line
  promote "   "
  [ "$status" -eq 1 ]
  [[ "$output" == *"PROMOTE_FROM is required"* ]]
}

# ── the other ways to pin a version ─────────────────────────────────────────

@test "version-override alongside promote-from is an error" {
  release_line
  promote v1.5.0-rc.3 VERSION_OVERRIDE=1.6.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot be combined with version-override"* ]]
}

@test "force-bump alongside promote-from is an error" {
  release_line
  promote v1.5.0-rc.3 FORCE_BUMP=minor
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot be combined with force-bump"* ]]
}

# ── the channel that feeds production ───────────────────────────────────────

@test "a prerelease from the wrong channel is refused" {
  # `-dev.7` for `-rc.7` is one typo, both tags exist, and nothing else would
  # object to a development build going out as stable.
  release_line
  git tag v1.5.0-dev.7
  promote v1.5.0-dev.7 ENVIRONMENTS="${ENVS}" PRERELEASE_IDENTIFIERS="${IDS}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is a 'dev' prerelease"* ]]
  [[ "$output" == *"only 'rc' prereleases are promoted"* ]]
  [[ "$output" == *"'staging'"* ]]
}

@test "the channel before production is accepted" {
  release_line
  promote v1.5.0-rc.3 ENVIRONMENTS="${ENVS}" PRERELEASE_IDENTIFIERS="${IDS}"
  [ "$status" -eq 0 ]
}

@test "a candidate numbered without the dot is the same channel" {
  # `version-override: 1.5.0-rc1` is how a team that numbers candidates by
  # hand often writes them. It is still the `rc` channel.
  release_line
  git tag v1.5.0-rc4
  promote v1.5.0-rc4 ENVIRONMENTS="${ENVS}" PRERELEASE_IDENTIFIERS="${IDS}"
  [ "$status" -eq 0 ]
  [ "$(out version)" = "1.5.0" ]
  [ "$(out source_tag)" = "v1.5.0-rc4" ]
}

@test "an identifier that only starts like the channel is still refused" {
  release_line
  git tag v1.5.0-rcx.1
  git tag v1.5.0-dev1
  promote v1.5.0-rcx.1 ENVIRONMENTS="${ENVS}" PRERELEASE_IDENTIFIERS="${IDS}"
  [ "$status" -eq 1 ]
  promote v1.5.0-dev1 ENVIRONMENTS="${ENVS}" PRERELEASE_IDENTIFIERS="${IDS}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is a 'dev1' prerelease"* ]]
}

@test "the channel is the environment before the last, wherever that is" {
  commit "one"; git tag v2.0.0-rc.1; git tag v2.0.0-tst.4
  run env TAG_PREFIX=v PROMOTE_FROM=v2.0.0-tst.4 \
    ENVIRONMENTS='["dev","tst","acc","prd"]' \
    PRERELEASE_IDENTIFIERS='{"dev":"dev","tst":"tst","acc":"rc"}' "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"only 'rc' prereleases are promoted"* ]]
}

@test "a single environment has no channel to hold the source to" {
  release_line
  git tag v1.5.0-dev.7
  promote v1.5.0-dev.7 ENVIRONMENTS='["prod"]' PRERELEASE_IDENTIFIERS='{}'
  [ "$status" -eq 0 ]
}

@test "a previous environment with no identifier is held to rc, the default it is cut with" {
  # `Detect environment` tags an unmapped environment's prereleases as `-rc.N`,
  # so that is the channel. Skipping the guard here would switch it off for
  # exactly the config that leans on the default.
  release_line
  git tag v1.5.0-dev.7
  promote v1.5.0-dev.7 ENVIRONMENTS="${ENVS}" PRERELEASE_IDENTIFIERS='{"dev":"dev"}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"only 'rc' prereleases are promoted"* ]]

  promote v1.5.0-rc.3 ENVIRONMENTS="${ENVS}" PRERELEASE_IDENTIFIERS='{"dev":"dev"}'
  [ "$status" -eq 0 ]
}

@test "an empty identifier map still holds the source to rc" {
  release_line
  git tag v1.5.0-dev.7
  promote v1.5.0-dev.7 ENVIRONMENTS="${ENVS}" PRERELEASE_IDENTIFIERS=
  [ "$status" -eq 1 ]
  [[ "$output" == *"only 'rc' prereleases are promoted"* ]]
}

@test "environments that do not parse are an error, not a skipped guard" {
  release_line
  promote v1.5.0-rc.3 ENVIRONMENTS='[dev, prod' PRERELEASE_IDENTIFIERS="${IDS}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"environments is not a JSON array"* ]]
}

@test "an identifier map that does not parse is an error, not a skipped guard" {
  # Nothing else would report it: Detect environment never parses the map on
  # a stable run.
  release_line
  git tag v1.5.0-dev.7
  promote v1.5.0-dev.7 ENVIRONMENTS="${ENVS}" PRERELEASE_IDENTIFIERS='{"dev": "dev", "staging": rc}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"prerelease-identifiers is not a JSON object"* ]]
}

@test "no environments at all leaves the channel unchecked" {
  # Only reachable when the script is run outside the action, which always
  # passes its default.
  release_line
  git tag v1.5.0-dev.7
  promote v1.5.0-dev.7
  [ "$status" -eq 0 ]
}

# ── the commit ───────────────────────────────────────────────────────────────

@test "the commit is the prerelease's, not the branch tip" {
  release_line
  promote v1.5.0-rc.3
  [ "$status" -eq 0 ]
  [ "$(out commit)" = "${RC3}" ]
  [ "$(out commit)" != "$(git rev-parse HEAD)" ]
}

@test "an annotated prerelease tag resolves to its commit, not the tag object" {
  commit "one"
  git tag -a v1.5.0-rc.1 -m "chore(release): v1.5.0-rc.1"
  promote v1.5.0-rc.1
  [ "$status" -eq 0 ]
  [ "$(out commit)" = "$(git rev-parse HEAD)" ]
  [ "$(out commit)" != "$(git rev-parse v1.5.0-rc.1)" ]
}

@test "a tag that does not exist names the prereleases that do" {
  release_line
  promote v1.5.0-rc.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"tag 'v1.5.0-rc.9' does not exist"* ]]
  [[ "$output" == *"v1.5.0-rc.1 v1.5.0-rc.2 v1.5.0-rc.3"* ]]
}

@test "a tag that does not exist says so when the version has no prereleases" {
  release_line
  promote v9.0.0-rc.1
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no prerelease tags at all"* ]]
}

# ── the stable tag ───────────────────────────────────────────────────────────

@test "a free stable tag is a fresh promotion" {
  release_line
  promote v1.5.0-rc.3
  [ "$status" -eq 0 ]
  [[ "$output" != *"Resuming"* ]]
}

@test "a fresh promotion hands back the marker line for the stable tag" {
  release_line
  promote v1.5.0-rc.3
  [ "$status" -eq 0 ]
  [ "$(out marker)" = "Promoted-From: v1.5.0-rc.3" ]
}

@test "a stable tag this same promotion pushed resumes it" {
  release_line
  promoted_tag v1.5.0 v1.5.0-rc.3 "${RC3}"
  promote v1.5.0-rc.3
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::promote-from: v1.5.0 was already promoted from v1.5.0-rc.3. Resuming"* ]]
  [ "$(out tag)" = "v1.5.0" ]
}

@test "the same commit is not the same promotion: another prerelease there is refused" {
  # Re-running a prerelease release cuts rc.4 on the commit rc.3 is on, with
  # its own image behind it. rc.3 was promoted; "resuming" with rc.4 would
  # repoint the published v1.5.0 image at a different build.
  release_line
  git tag v1.5.0-rc.4 "${RC3}"
  promoted_tag v1.5.0 v1.5.0-rc.3 "${RC3}"
  promote v1.5.0-rc.4
  [ "$status" -eq 1 ]
  [[ "$output" == *"v1.5.0 was already promoted from v1.5.0-rc.3"* ]]
  [[ "$output" == *"would repoint a published version"* ]]
  [ ! -s "${GITHUB_OUTPUT}" ]
}

@test "a stable tag an ordinary release cut on that commit is not resumed" {
  release_line
  git tag -a v1.5.0 -m "chore(release): v1.5.0" "${RC3}"
  promote v1.5.0-rc.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"was not cut by a promotion"* ]]
  [[ "$output" == *"nothing to promote"* ]]
}

@test "a lightweight stable tag cannot vouch for itself through the commit message" {
  # A lightweight tag has no message of its own, and the commit's must not
  # stand in for one.
  commit "one"
  git commit --allow-empty -m "feat: thing" -m "Promoted-From: v1.5.0-rc.1" >/dev/null
  git tag v1.5.0-rc.1
  git tag v1.5.0
  promote v1.5.0-rc.1
  [ "$status" -eq 1 ]
  [[ "$output" == *"was not cut by a promotion"* ]]
}

@test "a stable tag on any other commit is never moved" {
  # rc.2 was promoted; somebody now asks for rc.3 under the same version.
  release_line
  git tag v1.5.0 v1.5.0-rc.2
  promote v1.5.0-rc.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"v1.5.0 already exists on commit"* ]]
  [[ "$output" == *"never moved"* ]]
}

@test "a refused promotion writes no outputs at all" {
  release_line
  git tag v1.5.0 v1.5.0-rc.2
  promote v1.5.0-rc.3
  [ "$status" -eq 1 ]
  [ ! -s "${GITHUB_OUTPUT}" ]
}

# ── its neighbours: release notes range and :latest ─────────────────────────

@test "the previous stable tag is the highest one below the promoted version" {
  release_line
  promote v1.5.0-rc.3
  [ "$status" -eq 0 ]
  [ "$(out previous_tag)" = "v1.4.2" ]
  [ "$(out tag_latest)" = "true" ]
}

@test "versions are compared numerically, not as text" {
  # As text 1.9.0 sorts after 1.10.0, which would name the wrong predecessor
  # and conclude that 1.11.0 is not the highest version.
  commit "one";   git tag v1.9.0
  commit "two";   git tag v1.10.0
  commit "three"; git tag v1.11.0-rc.1
  promote v1.11.0-rc.1
  [ "$status" -eq 0 ]
  [ "$(out previous_tag)" = "v1.10.0" ]
  [ "$(out tag_latest)" = "true" ]
}

@test "a first stable release has no previous tag and owns :latest" {
  commit "one"; git tag v0.1.0-rc.1
  promote v0.1.0-rc.1
  [ "$status" -eq 0 ]
  [ -z "$(out previous_tag)" ]
  [ "$(out tag_latest)" = "true" ]
}

@test "a fix promoted on an older release line leaves :latest alone" {
  commit "one";   git tag v1.4.2
  commit "two";   git tag v1.5.0
  git checkout -q -b release/1.4 v1.4.2
  commit "three"; git tag v1.4.3-rc.1
  promote v1.4.3-rc.1
  [ "$status" -eq 0 ]
  [ "$(out tag_latest)" = "false" ]
  [ "$(out previous_tag)" = "v1.4.2" ]
  [[ "$output" == *"::notice::promote-from: v1.4.3 is not the highest stable version (v1.5.0 is)"* ]]
}

@test "a prerelease of a higher version does not count as a higher stable version" {
  release_line
  git tag v2.0.0-rc.1
  promote v1.5.0-rc.3
  [ "$status" -eq 0 ]
  [ "$(out tag_latest)" = "true" ]
}

@test "a resumed promotion does not count its own stable tag as the previous one" {
  release_line
  promoted_tag v1.5.0 v1.5.0-rc.3 "${RC3}"
  promote v1.5.0-rc.3
  [ "$status" -eq 0 ]
  [ "$(out previous_tag)" = "v1.4.2" ]
  [ "$(out tag_latest)" = "true" ]
}

@test "stable tags of another package's series are ignored" {
  commit "one";   git tag core-v1.0.0; git tag ui-v9.0.0
  commit "two";   git tag core-v1.1.0-rc.1
  run env TAG_PREFIX=core-v PROMOTE_FROM=core-v1.1.0-rc.1 "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(out previous_tag)" = "core-v1.0.0" ]
  [ "$(out tag_latest)" = "true" ]
}

@test "an empty prefix does not mistake v-prefixed tags for its own" {
  commit "one";   git tag v9.0.0; git tag 1.0.0
  commit "two";   git tag 1.1.0-rc.1
  run env TAG_PREFIX= PROMOTE_FROM=1.1.0-rc.1 "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(out previous_tag)" = "1.0.0" ]
  [ "$(out tag_latest)" = "true" ]
}

# ── what else the run would publish ──────────────────────────────────────────

@test "a container package build is refused: it is a fresh image under the stable version" {
  release_line
  promote v1.5.0-rc.3 PUBLISH_PACKAGE=true PACKAGE_ECOSYSTEM=container
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot be combined with publish-package and package-ecosystem: container"* ]]
  [ ! -s "${GITHUB_OUTPUT}" ]
}

@test "package-ecosystem: container is only a problem when a package is published" {
  release_line
  promote v1.5.0-rc.3 PUBLISH_PACKAGE=false PACKAGE_ECOSYSTEM=container
  [ "$status" -eq 0 ]
}

@test "other package ecosystems are rebuilt from the prerelease's commit as usual" {
  release_line
  promote v1.5.0-rc.3 PUBLISH_PACKAGE=true PACKAGE_ECOSYSTEM=nuget
  [ "$status" -eq 0 ]
}

@test "npm provenance is refused when the workflow commit is not the promoted commit" {
  # npm attests the package to the commit the WORKFLOW was started on. Started
  # from a branch that has moved on, that is not the commit it is built from.
  release_line
  promote v1.5.0-rc.3 PUBLISH_PACKAGE=true PACKAGE_ECOSYSTEM=npm NPM_PROVENANCE=true \
    GITHUB_SHA="$(git rev-parse HEAD)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"npm-provenance would attest the package to commit"* ]]
  [[ "$output" == *"Start the workflow from the v1.5.0-rc.3 tag"* ]]
}

@test "npm provenance is fine when the workflow was started on the promoted commit" {
  release_line
  promote v1.5.0-rc.3 PUBLISH_PACKAGE=true PACKAGE_ECOSYSTEM=npm NPM_PROVENANCE=true \
    GITHUB_SHA="${RC3}"
  [ "$status" -eq 0 ]
}

@test "npm without provenance is not held to the workflow commit" {
  release_line
  promote v1.5.0-rc.3 PUBLISH_PACKAGE=true PACKAGE_ECOSYSTEM=npm NPM_PROVENANCE=false \
    GITHUB_SHA="$(git rev-parse HEAD)"
  [ "$status" -eq 0 ]
}
