#!/usr/bin/env bats

setup() {
  export TEST_ROOT="$BATS_TEST_TMPDIR/suite-render"
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/output" "$TEST_ROOT/acc"
  export SCRIPT="$BATS_TEST_DIRNAME/../../scripts/render-suite-changelog.sh"
  export PATH="$TEST_ROOT/bin:$PATH"
  export GH_TOKEN=fixture-token
  export GITHUB_SERVER_URL=https://github.example.test
  export GITHUB_API_URL=https://github.example.test/api/v3
  export GITHUB_REPOSITORY=example/suite
  export CURRENT_BRANCH=main
  export CURRENT_ENV=acc
  export VERSION=1.2.0-acc.2
  export TAG_PREFIX=v
  export OUTPUT_DIR="$TEST_ROOT/output"
  export GITHUB_OUTPUT="$TEST_ROOT/github-output"
  export REMOTE_STATE="$TEST_ROOT/remote.json"
  export REQUEST_LOG="$TEST_ROOT/requests.jsonl"
  : > "$REQUEST_LOG"
  cat > "$TEST_ROOT/acc/kustomization.yaml" <<'YAML'
images:
  - name: registry.example.test/api
    newTag: v1.2.0
YAML
  cat > "$OUTPUT_DIR/release.json" <<'JSON'
{"schema_version":1,"environment":"acc","version":null,"previous_suite_tag":"v1.2.0-acc.1","commit":"trigger-commit","manifest":"acc/kustomization.yaml","changed":true,"apps":[{"id":"api","new_version":"v1.2.0","changes":[{"version":"v1.2.0","body":"Application notes","url":"https://github.example.test/example/api/releases/tag/v1.2.0"}]}],"images":[{"image":"registry.example.test/api","version":"v1.2.0"}]}
JSON
  printf '%s\n' '## Application changes (acc)' '' 'Application notes' > "$OUTPUT_DIR/notes.md"
  python3 - <<'PY'
import json,os
root=os.environ['TEST_ROOT']
json.dump({'head':'head-one','manifest':open(root+'/acc/kustomization.yaml').read(),
 'changelog':'# CHANGELOG\n\n## v1.0.0\n\nPrevious notes\n',
 'status':{'schema_version':1,'environments':{'prd':{'tag':'v1.0.0','images':[]}}},
 'commits':0},open(os.environ['REMOTE_STATE'],'w'))
PY
  cat > "$TEST_ROOT/bin/gh" <<'PY'
#!/usr/bin/env python3
import base64,json,os,sys
assert sys.argv[1:4]==['api','--hostname',os.environ['GITHUB_SERVER_URL'].split('://',1)[1]]
p=json.load(sys.stdin)
with open(os.environ['REQUEST_LOG'],'a') as f: f.write(json.dumps(p)+'\n')
state_path=os.environ['REMOTE_STATE']
s=json.load(open(state_path))
q=p['query']; v=p['variables']
if 'createCommitOnBranch' in q:
    if os.environ.get('API_REFUSED') == 'true':
        print(json.dumps({'errors':[{'type':'FORBIDDEN','message':'Not authorized'}]}));sys.exit(1)
    if os.environ.get('RACE_ONCE') == 'true' and s['commits']==0:
        s['commits']=-1;s['head']='head-raced'
        if os.environ.get('RACE_MANIFEST')=='true':s['manifest']='images: []\n'
        json.dump(s,open(state_path,'w'))
        print(json.dumps({'errors':[{'type':'STALE_DATA','message':'expectedHeadOid mismatch'}]}));sys.exit(1)
    assert v['input']['expectedHeadOid']==s['head']
    assert v['input']['branch']=={'repositoryNameWithOwner':'example/suite','branchName':'main'}
    assert {f['path'] for f in v['input']['fileChanges']['additions']}=={'CHANGELOG.md','suite/status.json'}
    for f in v['input']['fileChanges']['additions']:
        content=base64.b64decode(f['contents']).decode()
        if f['path']=='CHANGELOG.md':s['changelog']=content
        else:s['status']=json.loads(content)
    s['head']='head-created';s['commits']+=1
    json.dump(s,open(state_path,'w'))
    print(json.dumps({'data':{'createCommitOnBranch':{'commit':{'oid':s['head'],'url':'https://github.example.test/example/suite/commit/'+s['head']}}}}))
elif 'qualifiedName' in q:
    print(json.dumps({'data':{'repository':{'ref':{'target':{'oid':s['head']}}}}}))
else:
    print(json.dumps({'data':{'repository':{'manifest':{'text':s['manifest']},
     'changelog':{'text':s['changelog']} if s['changelog'] is not None else None,
     'status':{'text':json.dumps(s['status'])} if s['status'] is not None else None,
     'commit':{'committedDate':'2026-01-02T03:04:05Z'}}}}))
PY
  chmod +x "$TEST_ROOT/bin/gh"
  cd "$TEST_ROOT"
}

render() {
  run bash "$SCRIPT"
}

@test "signed changelog calls use the web host on a data residency tenant" {
  export GITHUB_SERVER_URL=https://tenant.ghe.com
  export GITHUB_API_URL=https://api.tenant.ghe.com
  render
  [ "$status" -eq 0 ]
  run python3 -c 'import json,os; assert json.load(open(os.environ["REMOTE_STATE"]))["commits"] == 1'
  [ "$status" -eq 0 ]
}

@test "one signed GraphQL commit preserves other environment status and prior changelog" {
  render
  [ "$status" -eq 0 ]
  run python3 - <<'PY'
import json,os
s=json.load(open(os.environ['REMOTE_STATE']))
assert s['commits']==1
assert s['status']['environments']['prd']['tag']=='v1.0.0'
a=s['status']['environments']['acc']
assert a['tag']=='v1.2.0-acc.2'
assert a['released_at']=='2026-01-02T03:04:05Z'
assert a['release_url'].endswith('/releases/tag/v1.2.0-acc.2')
assert 'Application notes' in s['changelog'] and 'Previous notes' in s['changelog']
assert s['changelog'].index('Application notes') < s['changelog'].index('Previous notes')
assert 'expectedHeadOid' in open(os.environ['REQUEST_LOG']).read()
assert json.load(open(os.environ['OUTPUT_DIR']+'/release.json'))['tag']==a['tag']
PY
  [ "$status" -eq 0 ]
  run cat "$GITHUB_OUTPUT"
  [[ "$output" == *"updated=true"* ]]
  [[ "$output" == *"notes-file="* ]]
  [[ "$output" == *"asset-file="* ]]
  [[ "$output" == *"status-file="* ]]
}

@test "rerun retains original notes timestamp and avoids another commit" {
  render
  [ "$status" -eq 0 ]
  printf '%s\n' 'New generated notes must not rewrite release' > "$OUTPUT_DIR/notes.md"
  export RELEASED_AT=2030-12-12T00:00:00Z
  render
  [ "$status" -eq 0 ]
  run python3 - <<'PY'
import json,os
s=json.load(open(os.environ['REMOTE_STATE']))
assert s['commits']==1
assert s['changelog'].count('suite-release:acc:v1.2.0-acc.2')==1
a=json.load(open(os.environ['OUTPUT_DIR']+'/release.json'))
assert a['released_at']=='2026-01-02T03:04:05Z'
assert 'Application notes' in a['notes']
assert 'New generated' not in a['notes']
PY
  [ "$status" -eq 0 ]
  run tail -n 1 "$GITHUB_OUTPUT"
  [ "$output" = updated=false ]
}

@test "stale selected manifest fails before any commit" {
  python3 -c 'import json,os; p=os.environ["REMOTE_STATE"]; d=json.load(open(p)); d["manifest"]="images: []\n"; json.dump(d,open(p,"w"))'
  render
  [ "$status" -ne 0 ]
  [[ "$output" == *"selected manifest changed"* ]]
  run python3 -c 'import json,os; assert json.load(open(os.environ["REMOTE_STATE"]))["commits"]==0'
  [ "$status" -eq 0 ]
}

@test "optimistic concurrency retries unrelated branch change without reset" {
  export RACE_ONCE=true
  render
  [ "$status" -eq 0 ]
  run python3 -c 'import json,os; ps=[json.loads(l) for l in open(os.environ["REQUEST_LOG"])]; cs=[p for p in ps if "createCommitOnBranch" in p["query"]]; assert len(cs)==2; assert cs[0]["variables"]["input"]["expectedHeadOid"]=="head-one"; assert cs[1]["variables"]["input"]["expectedHeadOid"]=="head-raced"'
  [ "$status" -eq 0 ]
}

@test "concurrent selected image change stops retry from publishing stale notes" {
  export RACE_ONCE=true
  export RACE_MANIFEST=true
  render
  [ "$status" -ne 0 ]
  [[ "$output" == *"selected manifest changed"* ]]
  run python3 -c 'import json,os; ps=[json.loads(l) for l in open(os.environ["REQUEST_LOG"])]; assert len([p for p in ps if "createCommitOnBranch" in p["query"]])==1'
  [ "$status" -eq 0 ]
}

@test "permission refusal fails without local writes or leaking token" {
  export API_REFUSED=true
  render
  [ "$status" -ne 0 ]
  [[ "$output" == *"GitHub refused"* ]]
  [[ "$output" != *"fixture-token"* ]]
  [ ! -f CHANGELOG.md ]
  [ ! -f suite/status.json ]
}

@test "first status creates both files with selected image inventory" {
  python3 -c 'import json,os; p=os.environ["REMOTE_STATE"]; d=json.load(open(p)); d["status"]=None; d["changelog"]=None; json.dump(d,open(p,"w"))'
  render
  [ "$status" -eq 0 ]
  run python3 -c 'import json; s=json.load(open("suite/status.json")); assert list(s["environments"])==["acc"]; assert len(s["environments"]["acc"]["images"])==1'
  [ "$status" -eq 0 ]
}

@test "same released tag with different selections fails rather than mutating history" {
  render
  [ "$status" -eq 0 ]
  python3 -c 'import json,os; p=os.environ["OUTPUT_DIR"]+"/release.json"; d=json.load(open(p)); d["images"][0]["version"]="v2.0.0"; json.dump(d,open(p,"w"))'
  render
  [ "$status" -ne 0 ]
  [[ "$output" == *"already records different image selections"* ]]
}

@test "rerunning a historical suite tag cannot replace newer environment status" {
  render
  [ "$status" -eq 0 ]
  python3 -c 'import json,os; p=os.environ["REMOTE_STATE"]; d=json.load(open(p)); d["status"]["environments"]["acc"]["tag"]="v1.2.0-acc.3"; json.dump(d,open(p,"w"))'
  render
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to replace a newer environment status"* ]]
  run python3 -c 'import json,os; assert json.load(open(os.environ["REMOTE_STATE"]))["commits"]==1'
  [ "$status" -eq 0 ]
}
