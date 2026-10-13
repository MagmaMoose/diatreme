#!/usr/bin/env bats

setup() {
  export ORIGINAL_PATH="$PATH"
  export TEST_ROOT="$BATS_TEST_TMPDIR/suite"
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/acc"
  export SCRIPT="$BATS_TEST_DIRNAME/../../scripts/collect-suite-release-notes.sh"
  export PATH="$TEST_ROOT/bin:$PATH"
  export GH_TOKEN=fixture-token
  export GITHUB_SERVER_URL=https://github.example.test
  export GITHUB_API_URL=https://github.example.test/api/v3
  export SUITE_MANIFEST=acc/kustomization.yaml
  export SUITE_CATALOG="$TEST_ROOT/catalog.json"
  export CURRENT_ENV=acc
  export VERSION=1.3.0-acc.2
  export TAG_PREFIX=v
  export OUTPUT_DIR="$TEST_ROOT/output"
  export FIXTURE_TAGS="$TEST_ROOT/tags"
  export FIXTURE_HEAD_TAGS="$TEST_ROOT/head-tags"
  export FIXTURE_OLD="$TEST_ROOT/old.yaml"
  export FIXTURE_RELEASES="$TEST_ROOT/releases.json"
  export FIXTURE_API_LOG="$TEST_ROOT/api-log"
  export FIXTURE_GIT_LOG="$TEST_ROOT/git-log"
  : > "$FIXTURE_API_LOG"
  : > "$FIXTURE_GIT_LOG"
  : > "$FIXTURE_HEAD_TAGS"
  printf '%s\n' v1.2.0-acc.1 v1.4.0-tst.2 v1.3.0 > "$FIXTURE_TAGS"
  cat > "$SUITE_CATALOG" <<'JSON'
{"apps":[{"id":"api","repository":"example/api","image":"registry.example.test/api","display_name":"API application"}]}
JSON
  cat > "$TEST_ROOT/bin/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE_GIT_LOG"
case "$*" in
  'rev-parse HEAD') echo 1234567890abcdef ;;
  'tag --points-at HEAD') cat "$FIXTURE_HEAD_TAGS" ;;
  'tag --merged HEAD') cat "$FIXTURE_TAGS" ;;
  'show v1.2.0-acc.1:acc/kustomization.yaml') cat "$FIXTURE_OLD" ;;
  'show v1.3.0:acc/kustomization.yaml') cat "$FIXTURE_OLD" ;;
  *) echo "unexpected git invocation: $*" >&2; exit 1 ;;
esac
SH
  cat > "$TEST_ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE_API_LOG"
[ "${FIXTURE_API_FAILURE:-false}" != true ] || exit 1
cat "$FIXTURE_RELEASES"
SH
  chmod +x "$TEST_ROOT/bin/git" "$TEST_ROOT/bin/gh"
  cat > "$FIXTURE_OLD" <<'YAML'
images:
  - name: registry.example.test/api
    newTag: v1.0.0
YAML
  cat > "$TEST_ROOT/acc/kustomization.yaml" <<'YAML'
images:
  - name: registry.example.test/api
    newTag: v1.2.0
YAML
  cat > "$FIXTURE_RELEASES" <<'JSON'
[[
  {"tag_name":"v1.3.0","body":"Future changes","html_url":"https://github.example.test/example/api/releases/tag/v1.3.0"},
  {"tag_name":"v1.2.0","body":"Latest changes","html_url":"https://github.example.test/example/api/releases/tag/v1.2.0"},
  {"tag_name":"v1.2.0-acc.1","body":"Candidate changes","html_url":"https://github.example.test/example/api/releases/tag/v1.2.0-acc.1"}
], [
  {"tag_name":"v1.1.0","body":"Intermediate changes","html_url":"https://github.example.test/example/api/releases/tag/v1.1.0"},
  {"tag_name":"v1.0.0","body":"Previous changes","html_url":"https://github.example.test/example/api/releases/tag/v1.0.0"},
  {"tag_name":"v1.1.5","body":"Draft changes","draft":true,"html_url":"https://github.example.test/example/api/releases/tag/v1.1.5"}
]]
JSON
  cd "$TEST_ROOT"
}

collect() {
  run bash "$SCRIPT"
}

@test "release collection uses the web host on a data residency tenant" {
  export GITHUB_SERVER_URL=https://tenant.ghe.com
  export GITHUB_API_URL=https://api.tenant.ghe.com
  sed 's#https://github.example.test/#https://tenant.ghe.com/#g' "$FIXTURE_RELEASES" > "$TEST_ROOT/tenant-releases.json"
  mv "$TEST_ROOT/tenant-releases.json" "$FIXTURE_RELEASES"
  collect
  [ "$status" -eq 0 ]
  run cat "$FIXTURE_API_LOG"
  [[ "$output" == *"--hostname tenant.ghe.com"* ]]
  [[ "$output" != *"--hostname api.tenant.ghe.com"* ]]
}

@test "upgrade aggregates every stable app release across pages against same-environment suite baseline" {
  collect
  [ "$status" -eq 0 ]
  run python3 -c 'import json,os; d=json.load(open(os.environ["OUTPUT_DIR"]+"/release.json")); assert d["previous_suite_tag"] == "v1.2.0-acc.1"; a=d["apps"][0]; assert [r["version"] for r in a["changes"]] == ["v1.1.0", "v1.2.0"]; assert a["direction"] == "upgrade"; assert a["changelog_url"].endswith("/releases/tag/v1.2.0"); assert d["environment"] == "acc"; assert d["version"] == "1.3.0-acc.2"'
  [ "$status" -eq 0 ]
  run cat "$FIXTURE_API_LOG"
  [[ "$output" == *"--hostname github.example.test"* ]]
  [[ "$output" == *"--paginate --slurp"* ]]
  run cat "$OUTPUT_DIR/notes.md"
  [[ "$output" == *"Intermediate changes"* ]]
  [[ "$output" == *"Latest changes"* ]]
  [[ "$output" != *"Candidate changes"* ]]
  [[ "$output" != *"Draft changes"* ]]
  [[ "$output" != *"Previous changes"* ]]
}

@test "candidate upgrades compare numerical SemVer revisions and exclude other channels" {
  sed 's/v1.0.0/v1.2.0-acc.2/' "$FIXTURE_OLD" > old.tmp
  mv old.tmp "$FIXTURE_OLD"
  sed 's/v1.2.0/v1.2.0-acc.10/' "$TEST_ROOT/acc/kustomization.yaml" > current.tmp
  mv current.tmp "$TEST_ROOT/acc/kustomization.yaml"
  cat > "$FIXTURE_RELEASES" <<'JSON'
[[
 {"tag_name":"v1.2.0-acc.10","body":"Candidate ten","html_url":"https://github.example.test/example/api/releases/tag/v1.2.0-acc.10"},
 {"tag_name":"v1.2.0-acc.3","body":"Candidate three","html_url":"https://github.example.test/example/api/releases/tag/v1.2.0-acc.3"},
 {"tag_name":"v1.2.0-tst.4","body":"Test four","html_url":"https://github.example.test/example/api/releases/tag/v1.2.0-tst.4"},
 {"tag_name":"v1.2.0-acc.2","body":"Old two","html_url":"https://github.example.test/example/api/releases/tag/v1.2.0-acc.2"}
]]
JSON
  collect
  [ "$status" -eq 0 ]
  run python3 -c 'import json,os; d=json.load(open(os.environ["OUTPUT_DIR"]+"/release.json")); assert [r["version"] for r in d["apps"][0]["changes"]] == ["v1.2.0-acc.3", "v1.2.0-acc.10"]'
  [ "$status" -eq 0 ]
}

@test "first suite release captures selected app release only and prepare allows empty version" {
  : > "$FIXTURE_TAGS"
  export VERSION=''
  collect
  [ "$status" -eq 0 ]
  run python3 -c 'import json,os; d=json.load(open(os.environ["OUTPUT_DIR"]+"/release.json")); assert d["previous_suite_tag"] is None; assert d["version"] is None; a=d["apps"][0]; assert a["old_version"] is None; assert a["direction"] == "added"; assert [r["version"] for r in a["changes"]] == ["v1.2.0"]'
  [ "$status" -eq 0 ]
}

@test "unchanged selections produce no-change snapshot without API calls" {
  cp "$TEST_ROOT/acc/kustomization.yaml" "$FIXTURE_OLD"
  collect
  [ "$status" -eq 0 ]
  [ ! -s "$FIXTURE_API_LOG" ]
  run python3 -c 'import json,os; d=json.load(open(os.environ["OUTPUT_DIR"]+"/release.json")); assert d["changed"] is False; assert d["apps"] == []; assert len(d["images"]) == 1'
  [ "$status" -eq 0 ]
}

@test "rollback reports target notes without pretending intervening versions are new changes" {
  cp "$TEST_ROOT/acc/kustomization.yaml" "$FIXTURE_OLD"
  sed 's/v1.2.0/v1.0.0/' "$TEST_ROOT/acc/kustomization.yaml" > current.tmp
  mv current.tmp "$TEST_ROOT/acc/kustomization.yaml"
  collect
  [ "$status" -eq 0 ]
  run python3 -c 'import json,os; d=json.load(open(os.environ["OUTPUT_DIR"]+"/release.json")); a=d["apps"][0]; assert a["direction"] == "rollback"; assert [r["version"] for r in a["changes"]] == ["v1.0.0"]'
  [ "$status" -eq 0 ]
  run cat "$OUTPUT_DIR/notes.md"
  [[ "$output" == *"(rollback)"* ]]
}

@test "missing exact published app release fails with no fabricated output" {
  printf '%s\n' '[[{"tag_name":"v1.1.0","body":"Old release"}]]' > "$FIXTURE_RELEASES"
  collect
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected one published release for example/api v1.2.0"* ]]
  [ ! -e "$OUTPUT_DIR/notes.md" ]
}

@test "empty intermediate release notes fail rather than silently hiding changes" {
  python3 -c 'import json,os; p=os.environ["FIXTURE_RELEASES"]; d=json.load(open(p)); d[1][0]["body"]=""; json.dump(d,open(p,"w"))'
  collect
  [ "$status" -ne 0 ]
  [[ "$output" == *"published release notes are empty for example/api v1.1.0"* ]]
}

@test "release API outage fails visibly without response data or token" {
  export FIXTURE_API_FAILURE=true
  collect
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh read failed"* ]]
  [[ "$output" != *"fixture-token"* ]]
}

@test "production baseline ignores candidate suite tags" {
  export CURRENT_ENV=prd
  export VERSION=1.4.0
  collect
  [ "$status" -eq 0 ]
  run python3 -c 'import json,os; d=json.load(open(os.environ["OUTPUT_DIR"]+"/release.json")); assert d["previous_suite_tag"] == "v1.3.0"'
  [ "$status" -eq 0 ]
}

@test "resuming a tagged HEAD uses preceding same-environment baseline" {
  printf '%s\n' v1.3.0-acc.2 >> "$FIXTURE_TAGS"
  printf '%s\n' v1.3.0-acc.2 > "$FIXTURE_HEAD_TAGS"
  export VERSION=''
  collect
  [ "$status" -eq 0 ]
  run python3 -c 'import json,os; d=json.load(open(os.environ["OUTPUT_DIR"]+"/release.json")); assert d["previous_suite_tag"] == "v1.2.0-acc.1"'
  [ "$status" -eq 0 ]
}

@test "recollection is deterministic and does not mutate git" {
  collect
  [ "$status" -eq 0 ]
  cp "$OUTPUT_DIR/notes.md" expected-notes
  cp "$OUTPUT_DIR/release.json" expected-release
  collect
  [ "$status" -eq 0 ]
  cmp expected-notes "$OUTPUT_DIR/notes.md"
  cmp expected-release "$OUTPUT_DIR/release.json"
  run cat "$FIXTURE_GIT_LOG"
  [[ "$output" != *"commit"* ]]
  [[ "$output" != *"push"* ]]
}

@test "manifest image outside catalog fails before release reads" {
  sed 's|registry.example.test/api|registry.example.test/unknown|' "$TEST_ROOT/acc/kustomization.yaml" > current.tmp
  mv current.tmp "$TEST_ROOT/acc/kustomization.yaml"
  collect
  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest images missing from catalog"* ]]
  [ ! -s "$FIXTURE_API_LOG" ]
}

@test "all changed application selections share one snapshot and notes body" {
  python3 -c 'import json,os; p=os.environ["SUITE_CATALOG"]; d=json.load(open(p)); d["apps"].append({"id":"ui","repository":"example/ui","image":"registry.example.test/ui","display_name":"User interface"}); json.dump(d,open(p,"w"))'
  cat >> "$TEST_ROOT/acc/kustomization.yaml" <<'YAML'
  - name: registry.example.test/ui
    newTag: v1.2.0
YAML
  collect
  [ "$status" -eq 0 ]
  run python3 -c 'import json,os; d=json.load(open(os.environ["OUTPUT_DIR"]+"/release.json")); assert [a["id"] for a in d["apps"]] == ["api","ui"]; assert d["apps"][0]["direction"] == "upgrade"; assert d["apps"][1]["direction"] == "added"; assert len(d["images"]) == 2'
  [ "$status" -eq 0 ]
  run cat "$OUTPUT_DIR/notes.md"
  [[ "$output" == *"API application"* ]]
  [[ "$output" == *"User interface"* ]]
  run cat "$FIXTURE_API_LOG"
  [[ "$output" == *"repos/example/api/releases"* ]]
  [[ "$output" == *"repos/example/ui/releases"* ]]
}

@test "removing a managed image fails instead of silently omitting a workload" {
  cat >> "$FIXTURE_OLD" <<'YAML'
  - name: registry.example.test/removed
    newTag: v1.0.0
YAML
  collect
  [ "$status" -ne 0 ]
  [[ "$output" == *"removed images need an explicit migration"* ]]
  [ ! -s "$FIXTURE_API_LOG" ]
}
