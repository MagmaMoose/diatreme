#!/usr/bin/env bats

# Guards on `action.yml` input defaults whose value is a contract with an
# upstream action rather than a cosmetic choice.

@test "gitversion-config defaults to empty so GitVersion.yml stays optional" {
  # Regression: the default used to be the literal 'GitVersion.yml'. That value
  # is forwarded to gittools/actions/gitversion/execute as `configFilePath`,
  # which throws "GitVersion configuration file not found at <path>" whenever
  # the path is non-empty and missing. Every gitversion repo without a
  # GitVersion.yml therefore failed — notably the `versioning-tool: auto` repos
  # resolved to gitversion from a bare *.csproj/*.sln. Empty means "let
  # GitVersion discover its own config, or run on built-in defaults".
  command -v ruby >/dev/null || skip "ruby not available"
  run ruby - <<'RUBY'
require "yaml"

doc = YAML.load_file("action.yml")
default = doc.fetch("inputs").fetch("gitversion-config").fetch("default")
abort "expected empty default, got #{default.inspect}" unless default == ""
RUBY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "Execute GitVersion takes configFilePath from the detect step" {
  # gittools resolves configFilePath against the workspace root (this action
  # never sets targetPath), while detection is scoped to working-directory.
  # Reading the raw input here would desync the two for a subdirectory project,
  # and would also reopen the door to a `|| 'GitVersion.yml'` fallback in the
  # expression, which is what made GitVersion.yml mandatory in the first place.
  command -v ruby >/dev/null || skip "ruby not available"
  run ruby - <<'RUBY'
require "yaml"

doc = YAML.load_file("action.yml")
step = doc.fetch("runs").fetch("steps").find { |s| s["id"] == "gitversion" }
abort "no step with id 'gitversion'" if step.nil?

actual = step.fetch("with").fetch("configFilePath")
expected = "${{ steps.resolve-tool.outputs.config }}"
abort "expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
RUBY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "release-branch-versioning defaults to auto" {
  # Default-off would have shipped the fix to nobody: the failure it prevents
  # (a squash-merged release/1.15.0 tagged 1.14.5) is silent, so a consumer
  # only learns they needed the flag after a release has already gone out
  # under the wrong number.
  command -v ruby >/dev/null || skip "ruby not available"
  run ruby - <<'RUBY'
require "yaml"

doc = YAML.load_file("action.yml")
default = doc.fetch("inputs").fetch("release-branch-versioning").fetch("default")
abort "expected 'auto', got #{default.inspect}" unless default == "auto"
RUBY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "Execute GitVersion does not route force-bump through overrideConfig" {
  # `overrideConfig: increment=Minor` sets GitVersion's ROOT increment key,
  # and a branch's own `increment` overrides it — so a GitFlow config pinning
  # `branches: main: increment: Patch` swallowed the forced bump whole and cut
  # a patch anyway, with no diagnostic. force-bump is applied in
  # `Create GitVersion release tag` instead, by bumping the latest stable tag
  # the way the semantic-release paths do. Re-adding the override here would
  # put two mechanisms on the same knob, one of them silently inert.
  command -v ruby >/dev/null || skip "ruby not available"
  run ruby - <<'RUBY'
require "yaml"

doc = YAML.load_file("action.yml")
steps = doc.fetch("runs").fetch("steps")

execute = steps.find { |s| s["id"] == "gitversion" }
abort "no step with id 'gitversion'" if execute.nil?
override = execute.fetch("with", {})["overrideConfig"]
abort "Execute GitVersion still sets overrideConfig: #{override.inspect}" unless override.nil?

tag_step = steps.find { |s| s["id"] == "gitversion-tag" }
abort "no step with id 'gitversion-tag'" if tag_step.nil?
env = tag_step.fetch("env", {})
abort "gitversion-tag never reads force-bump" unless env.key?("INPUT_FORCE_BUMP")
RUBY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "release-mode steps gate on the resolved version, not the raw input" {
  # Two things pin the version before any tool runs: the `version-override`
  # input and the release branch named in HEAD's merge subject. The
  # `release-version` step resolves them into one value, and every release-mode
  # step gates on that. Gating on `inputs.version-override` again would run a
  # versioning tool on top of a version the branch already decided, and cut
  # two different tags for one release.
  command -v ruby >/dev/null || skip "ruby not available"
  run ruby - <<'RUBY'
require "yaml"

doc = YAML.load_file("action.yml")
offenders = doc.fetch("runs").fetch("steps").select do |s|
  cond = s["if"].to_s
  # The validate step itself must read the raw input: it serves `mode: ci`,
  # which never reaches the resolver.
  next false if s["id"] == "version-override"
  cond.include?("inputs.mode == 'release'") && cond.include?("inputs.version-override")
end

unless offenders.empty?
  abort "gate on steps.release-version.outputs.version instead: " +
        offenders.map { |s| s["name"] }.join(", ")
end
RUBY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
