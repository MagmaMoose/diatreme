#!/usr/bin/env bash
# Read suite image selections and aggregate published application release notes.
# Requires Python 3 with PyYAML, git and gh. Reads repositories only; never tags,
# commits or edits the manifest. PYTHON_BIN may select the caller's interpreter.
# Required: SUITE_MANIFEST, SUITE_CATALOG, CURRENT_ENV, GH_TOKEN, OUTPUT_DIR.
# Optional: VERSION, TAG_PREFIX (v), GITHUB_API_URL, GITHUB_SERVER_URL.
set -euo pipefail

: "${SUITE_MANIFEST:?SUITE_MANIFEST is required}"
: "${SUITE_CATALOG:?SUITE_CATALOG is required}"
: "${CURRENT_ENV:?CURRENT_ENV is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OUTPUT_DIR:?OUTPUT_DIR is required}"

exec "${PYTHON_BIN:-python3}" - <<'PY'
import functools
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from urllib.parse import urlparse

try:
    import yaml
except ImportError:
    sys.exit("::error::Suite release notes require PyYAML in PYTHON_BIN.")


def fail(message):
    sys.exit("::error::Suite release notes: " + message)


def run(args):
    read_env = os.environ.copy()
    if args[0] == 'gh':
        # gh uses a different variable for custom Enterprise hostnames.
        read_env['GH_ENTERPRISE_TOKEN'] = os.environ['GH_TOKEN']
    result = subprocess.run(args, text=True, capture_output=True, check=False, env=read_env)
    if result.returncode:
        # Do not print API responses or inherited credentials on a failed read.
        fail(f"{args[0]} read failed ({result.returncode}): {' '.join(args[1:])}")
    return result.stdout


VERSION_RE = re.compile(
    r"^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)


def semver(value):
    match = VERSION_RE.fullmatch(value)
    if not match:
        fail(f"not a SemVer image/release version: {value!r}")
    pre = tuple(match[4].split('.')) if match[4] else ()
    if any(p.isdigit() and len(p) > 1 and p.startswith('0') for p in pre):
        fail(f"numeric prerelease identifier has a leading zero: {value!r}")
    return (tuple(int(match[i]) for i in (1, 2, 3)), pre)


def compare(left, right):
    if left[0] != right[0]:
        return (left[0] > right[0]) - (left[0] < right[0])
    a, b = left[1], right[1]
    if not a or not b:
        return (not a) - (not b)
    for x, y in zip(a, b):
        if x == y:
            continue
        if x.isdigit() and y.isdigit():
            return (int(x) > int(y)) - (int(x) < int(y))
        if x.isdigit() != y.isdigit():
            return -1 if x.isdigit() else 1
        return (x > y) - (x < y)
    return (len(a) > len(b)) - (len(a) < len(b))


def channel(version):
    # The complete prefix before a final numerical revision identifies a channel.
    pre = version[1]
    return '.'.join(pre[:-1] if pre and pre[-1].isdigit() else pre)


def image_versions(content, description):
    try:
        document = yaml.safe_load(content)
    except yaml.YAMLError:
        fail(f"invalid YAML in {description}")
    if not isinstance(document, dict) or not isinstance(document.get('images'), list):
        fail(f"{description} must contain an images list")
    versions = {}
    for image in document['images']:
        if not isinstance(image, dict) or not isinstance(image.get('name'), str):
            fail(f"invalid images entry in {description}")
        name = image['name']
        if name in versions:
            fail(f"duplicate image {name!r} in {description}")
        if not isinstance(image.get('newTag'), str) or not image['newTag']:
            fail(f"image {name!r} needs a nonempty newTag in {description}")
        if image.get('digest'):
            fail(f"image {name!r} uses digest; suite version selections require newTag")
        semver(image['newTag'])
        versions[name] = image['newTag']
    return versions


def markdown(value):
    return re.sub(r'([\\`*\[\]<>])', r'\\\1', value)


manifest = os.environ['SUITE_MANIFEST']
manifest_path = PurePosixPath(manifest)
if manifest_path.is_absolute() or '..' in manifest_path.parts:
    fail("SUITE_MANIFEST must be relative to the repository root without '..'")
manifest = str(manifest_path)
environment = os.environ['CURRENT_ENV']
prefix = os.environ.get('TAG_PREFIX', 'v')
version = os.environ.get('VERSION', '')
server = os.environ.get('GITHUB_SERVER_URL', 'https://github.com').rstrip('/')
host = urlparse(server).hostname
if not host:
    fail("GITHUB_SERVER_URL must contain a hostname")
if host == 'api.github.com':
    host = 'github.com'

try:
    catalog = json.loads(Path(os.environ['SUITE_CATALOG']).read_text())
    apps = catalog['apps']
except (OSError, ValueError, KeyError, TypeError):
    fail("SUITE_CATALOG must be readable JSON with an apps list")
if not isinstance(apps, list) or not apps:
    fail("SUITE_CATALOG apps must be a nonempty list")
by_image = {}
ids = set()
for app in apps:
    if not isinstance(app, dict) or any(
        not isinstance(app.get(key), str) or not app[key]
        for key in ('id', 'repository', 'image')
    ):
        fail("catalog entries require id, repository and image strings")
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', app['repository']):
        fail(f"catalog repository must be owner/repo: {app['repository']!r}")
    if app['id'] in ids or app['image'] in by_image:
        fail("catalog contains duplicate app id or image")
    if not isinstance(app.get('display_name', app['id']), str):
        fail("catalog display_name must be a string")
    ids.add(app['id'])
    by_image[app['image']] = app

try:
    current = image_versions(Path(manifest).read_text(), manifest)
except OSError:
    fail(f"cannot read manifest {manifest!r}")
unknown = set(current) - set(by_image)
if unknown:
    fail(f"manifest images missing from catalog: {', '.join(sorted(unknown))}")

head = run(['git', 'rev-parse', 'HEAD']).strip()
head_tags = set(run(['git', 'tag', '--points-at', 'HEAD']).splitlines())
candidates = []
for tag in run(['git', 'tag', '--merged', 'HEAD']).splitlines():
    if not tag.startswith(prefix):
        continue
    suffix = tag[len(prefix):]
    match = VERSION_RE.fullmatch(suffix)
    if not match:
        continue
    parsed = semver(suffix)
    same_env = not parsed[1] if environment == 'prd' else (
        len(parsed[1]) == 2 and parsed[1][0] == environment and parsed[1][1].isdigit()
    )
    # On a re-run before version calculation, HEAD's suite tag is the release
    # being resumed. After calculation the caller supplies it explicitly.
    if not same_env or tag == prefix + version.removeprefix(prefix) or (
        not version and tag in head_tags
    ):
        continue
    candidates.append((parsed, tag))
candidates.sort(key=functools.cmp_to_key(lambda a, b: compare(a[0], b[0])))
previous_tag = candidates[-1][1] if candidates else None
old = image_versions(run(['git', 'show', f'{previous_tag}:{manifest}']),
                     f'{previous_tag}:{manifest}') if previous_tag else {}
removed = set(old) - set(current)
if removed:
    fail(f"removed images need an explicit migration: {', '.join(sorted(removed))}")

changes = []
for image, new in current.items():
    previous = old.get(image)
    if previous == new:
        continue
    app = by_image[image]
    new_version = semver(new)
    old_version = semver(previous) if previous else None
    direction = 'added' if old_version is None else (
        'rollback' if compare(new_version, old_version) < 0 else 'upgrade'
    )
    # --slurp preserves every page as one JSON array; flatten below.
    response = run(['gh', 'api', '--hostname', host,
                    f"repos/{app['repository']}/releases?per_page=100",
                    '--paginate', '--slurp'])
    try:
        pages = json.loads(response)
        releases = [item for page in pages for item in page]
        if not all(isinstance(item, dict) for item in releases):
            raise ValueError
    except (TypeError, ValueError):
        fail(f"invalid release API response for {app['repository']}")
    published = [r for r in releases if not r.get('draft')]
    exact = [r for r in published if r.get('tag_name') == new]
    if len(exact) != 1:
        fail(f"expected one published release for {app['repository']} {new}, found {len(exact)}")
    selected = []
    for release in published:
        tag = release.get('tag_name', '')
        if not isinstance(tag, str) or not VERSION_RE.fullmatch(tag):
            continue
        parsed = semver(tag)
        if release is exact[0] or (
            direction == 'upgrade' and old_version is not None
            and compare(parsed, old_version) > 0 and compare(parsed, new_version) <= 0
            and channel(parsed) == channel(new_version)
        ):
            body = release.get('body')
            if not isinstance(body, str) or not body.strip():
                fail(f"published release notes are empty for {app['repository']} {tag}")
            link = release.get('html_url')
            if not isinstance(link, str) or not link.startswith(server + '/'):
                fail(f"invalid release link for {app['repository']} {tag}")
            selected.append((parsed, {
                'version': tag, 'url': link, 'body': body.strip(),
            }))
    selected.sort(key=functools.cmp_to_key(lambda a, b: compare(a[0], b[0])))
    changes.append({
        'id': app['id'], 'display_name': app.get('display_name', app['id']),
        'repository': app['repository'], 'image': image,
        'old_version': previous, 'new_version': new, 'direction': direction,
        'changelog_url': selected[-1][1]['url'],
        'changes': [item[1] for item in selected],
    })

snapshot = {
    'schema_version': 1, 'environment': environment, 'version': version or None,
    'previous_suite_tag': previous_tag, 'commit': head,
    'manifest': manifest, 'changed': bool(changes), 'apps': changes,
    'images': [{'image': image, 'version': tag} for image, tag in current.items()],
}
heading = f"## {markdown(version)} ({markdown(environment)})" if version else (
    f"## Application changes ({markdown(environment)})"
)
lines = [heading, '']
if previous_tag:
    lines.extend([f"Previous suite release: `{previous_tag}`.", ''])
else:
    lines.extend(['Initial suite baseline. Selected application releases are listed below.', ''])
if not changes:
    lines.extend(['No application image changes.', ''])
for app in changes:
    change = f"{app['old_version'] or 'initial'} → {app['new_version']}"
    if app['direction'] == 'rollback':
        change += ' (rollback)'
    lines.extend([
        f"### {markdown(app['display_name'])}: {markdown(change)}", '',
        f"[Application changelog]({app['changelog_url']})", '',
    ])
    for release in app['changes']:
        lines.extend([
            f"#### [{markdown(release['version'])}]({release['url']})", '',
            release['body'], '',
        ])
output = Path(os.environ['OUTPUT_DIR'])
output.mkdir(parents=True, exist_ok=True)
(output / 'notes.md').write_text('\n'.join(lines))
(output / 'release.json').write_text(json.dumps(snapshot, indent=2) + '\n')
print(f"Suite release notes: {len(changes)} changed application(s), baseline {previous_tag or 'initial'}.")
PY
