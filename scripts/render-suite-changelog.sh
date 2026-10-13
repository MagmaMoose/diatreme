#!/usr/bin/env bash
# Persist a suite changelog and environment status in one GitHub-signed commit.
# Requires Python 3 and gh. No local commits, branch resets or tag mutations.
# Required: OUTPUT_DIR (collector notes.md/release.json), VERSION, CURRENT_ENV,
# CURRENT_BRANCH, GITHUB_REPOSITORY, GH_TOKEN. Optional: TAG_PREFIX (v),
# SUITE_CHANGELOG (CHANGELOG.md), SUITE_STATUS (suite/status.json), RELEASED_AT,
# GITHUB_SERVER_URL, GITHUB_API_URL, GITHUB_OUTPUT, PYTHON_BIN.
set -euo pipefail
: "${OUTPUT_DIR:?OUTPUT_DIR is required}"
: "${VERSION:?VERSION is required}"
: "${CURRENT_ENV:?CURRENT_ENV is required}"
: "${CURRENT_BRANCH:?CURRENT_BRANCH is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
exec "${PYTHON_BIN:-python3}" - <<'PY'
import base64
from datetime import datetime
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from urllib.parse import quote, urlparse


def fail(message):
    sys.exit('::error::Suite changelog: ' + message)


def path(value):
    parsed = PurePosixPath(value)
    if parsed.is_absolute() or '..' in parsed.parts or not value:
        fail('file paths must be relative without parent traversal')
    return str(parsed)


repository = os.environ['GITHUB_REPOSITORY']
if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
    fail('GITHUB_REPOSITORY must be owner/repo')
owner, repo = repository.split('/')
branch = os.environ['CURRENT_BRANCH']
server = os.environ.get('GITHUB_SERVER_URL', 'https://github.com').rstrip('/')
host = urlparse(server).hostname
if host == 'api.github.com':
    host = 'github.com'
if not host:
    fail('GITHUB_SERVER_URL needs a hostname')
prefix = os.environ.get('TAG_PREFIX', 'v')
version = os.environ['VERSION']
tag = version if prefix and version.startswith(prefix) else prefix + version
environment = os.environ['CURRENT_ENV']
if not re.fullmatch(r'[A-Za-z0-9_.-]+', environment) or not re.fullmatch(
    r'[A-Za-z0-9_.+-]+', tag
):
    fail('invalid release tag or environment')
changelog_path = path(os.environ.get('SUITE_CHANGELOG', 'CHANGELOG.md'))
status_path = path(os.environ.get('SUITE_STATUS', 'suite/status.json'))
output_dir = Path(os.environ['OUTPUT_DIR'])
try:
    snapshot = json.loads((output_dir / 'release.json').read_text())
    notes = (output_dir / 'notes.md').read_text()
    manifest = path(snapshot['manifest'])
    expected_manifest = Path(manifest).read_text()
except (OSError, ValueError, KeyError, TypeError):
    fail('collector output or selected manifest is unreadable')
if snapshot.get('environment') != environment or not isinstance(snapshot.get('images'), list):
    fail('collector snapshot does not match environment or lacks images')
if len({manifest, status_path, changelog_path}) != 3:
    fail('manifest, changelog and status paths must differ')
api_env = os.environ.copy()
api_env['GH_ENTERPRISE_TOKEN'] = os.environ['GH_TOKEN']


def graphql(query, variables):
    response = subprocess.run(
        ['gh', 'api', '--hostname', host, 'graphql', '--input', '-'],
        input=json.dumps({'query': query, 'variables': variables}),
        capture_output=True, text=True, env=api_env, check=False,
    )
    try:
        body = json.loads(response.stdout)
    except ValueError:
        fail(f'GitHub API failed ({response.returncode}); no files were published')
    if not isinstance(body, dict):
        fail('invalid GitHub API response')
    if response.returncode and not body.get('errors'):
        fail(f'GitHub API failed ({response.returncode}); no files were published')
    return body


REF_QUERY = '''query($owner:String!,$repo:String!,$ref:String!) {
  repository(owner:$owner,name:$repo) { ref(qualifiedName:$ref) {
    target { ... on Commit { oid } }
  } }
}'''
FILES_QUERY = '''query($owner:String!,$repo:String!,$manifest:String!,
  $changelog:String!,$status:String!,$commit:String!) {
  repository(owner:$owner,name:$repo) {
    manifest:object(expression:$manifest) { ... on Blob { text } }
    changelog:object(expression:$changelog) { ... on Blob { text } }
    status:object(expression:$status) { ... on Blob { text } }
    commit:object(expression:$commit) { ... on Commit { committedDate } }
  }
}'''
COMMIT_MUTATION = '''mutation($input:CreateCommitOnBranchInput!) {
  createCommitOnBranch(input:$input) { commit { oid url } }
}'''


def read_branch():
    data = graphql(REF_QUERY, {'owner': owner, 'repo': repo, 'ref': 'refs/heads/' + branch})
    try:
        head = data['data']['repository']['ref']['target']['oid']
    except (KeyError, TypeError):
        fail('cannot resolve current branch')
    data = graphql(FILES_QUERY, {
        'owner': owner, 'repo': repo, 'manifest': head + ':' + manifest,
        'changelog': head + ':' + changelog_path, 'status': head + ':' + status_path,
        'commit': snapshot.get('commit', head),
    })
    try:
        files = data['data']['repository']
        if data.get('errors') or files['manifest']['text'] != expected_manifest:
            fail('selected manifest changed since this release checkout; refusing stale status')
        previous_changelog = files['changelog']['text'] if files.get('changelog') else '# CHANGELOG\n'
        previous_status = json.loads(files['status']['text']) if files.get('status') else {
            'schema_version': 1, 'environments': {},
        }
        date = files['commit']['committedDate']
    except (KeyError, ValueError, TypeError):
        fail('remote manifest, changelog or status is invalid')
    if not isinstance(previous_status, dict) or not isinstance(previous_status.get('environments'), dict):
        fail('remote status must contain an environments object')
    return head, previous_changelog, previous_status, date


updated = False
for attempt in range(3):
    head, old_changelog, status, commit_date = read_branch()
    previous = status['environments'].get(environment)
    if previous is not None and not isinstance(previous, dict):
        fail('existing environment status must be an object')
    released_at = os.environ.get('RELEASED_AT') or commit_date
    if not isinstance(released_at, str) or not released_at:
        fail('release timestamp is missing')
    try:
        datetime.fromisoformat(released_at.replace('Z', '+00:00'))
    except ValueError:
        fail('release timestamp must be ISO 8601')
    if previous and previous.get('tag') == tag:
        if previous.get('images') != snapshot['images']:
            fail('published suite tag already records different image selections')
        # Preserve original timestamp, notes and snapshot across workflow reruns.
        snapshot = previous
        updated_changelog = old_changelog
        updated_status = json.dumps(status, indent=2) + '\n'
        notes = previous.get('notes', notes)
        break
    snapshot.update({
        'version': version, 'tag': tag,
        'release_url': server + '/' + repository + '/releases/tag/' + quote(tag, safe=''),
        'released_at': released_at,
    })
    # Collector's first heading does not include the final published tag/date.
    body = re.sub(r'\A##[^\n]*\n\s*', '', notes, count=1).rstrip()
    notes = f'## {tag} ({environment}, {released_at[:10]})\n\n{body}\n'
    snapshot['notes'] = notes
    marker = f'<!-- suite-release:{environment}:{tag} -->'
    if marker in old_changelog:
        if previous and previous.get('tag') != tag:
            fail('this suite release is already in history; refusing to replace a newer environment status')
        # A prior partial integration wrote notes but not the environment entry.
        # Keep that immutable entry and add status without duplicating changelog.
        updated_changelog = old_changelog
    else:
        header = re.match(r'\A# [^\n]*\n', old_changelog)
        remainder = old_changelog[header.end():].lstrip() if header else old_changelog.lstrip()
        title = header[0].rstrip() if header else '# CHANGELOG'
        updated_changelog = f'{title}\n\n{marker}\n{notes}\n{remainder}'
    status['environments'][environment] = dict(snapshot)
    updated_status = json.dumps(status, indent=2) + '\n'
    additions = [
        {'path': name, 'contents': base64.b64encode(content.encode()).decode()}
        for name, content in ((changelog_path, updated_changelog), (status_path, updated_status))
    ]
    result = graphql(COMMIT_MUTATION, {'input': {
        'branch': {'repositoryNameWithOwner': repository, 'branchName': branch},
        'expectedHeadOid': head,
        'message': {'headline': f'chore(release): record {tag} for {environment} [skip ci]'},
        'fileChanges': {'additions': additions},
    }})
    if result.get('errors'):
        errors = json.dumps(result['errors']).lower()
        if any(term in errors for term in ('stale_data', 'expectedheadoid', 'expected head', 'head oid')):
            if attempt < 2:
                continue
            fail('branch changed during all three commit attempts; retry the release')
        fail('GitHub refused the signed changelog commit; check repository permissions and rules')
    try:
        result['data']['createCommitOnBranch']['commit']['oid']
    except (KeyError, TypeError):
        fail('GitHub did not confirm the signed commit')
    updated = True
    break

for filename, content in ((changelog_path, updated_changelog), (status_path, updated_status)):
    local = Path(filename)
    local.parent.mkdir(parents=True, exist_ok=True)
    local.write_text(content)
(output_dir / 'notes.md').write_text(notes)
(output_dir / 'release.json').write_text(json.dumps(snapshot, indent=2) + '\n')
if os.environ.get('GITHUB_OUTPUT'):
    with open(os.environ['GITHUB_OUTPUT'], 'a') as handle:
        for key, value in (
            ('notes-file', str((output_dir / 'notes.md').resolve())),
            ('asset-file', str((output_dir / 'release.json').resolve())),
            ('status-file', str(Path(status_path).resolve())),
            ('updated', str(updated).lower()),
        ):
            handle.write(f'{key}={value}\n')
print(f'Suite changelog: {tag} on {branch}, updated={str(updated).lower()}.')
PY
