# Releasing a versioned application suite

<!-- sources: action.yml, scripts/collect-suite-release-notes.sh,
     scripts/render-suite-changelog.sh -->

A suite repository can select the image versions of several applications without
building those applications. Diatreme tags that selection, combines their published
release notes, and publishes a suite GitHub Release with a `release.json` snapshot.
Application Kubernetes resources can stay in their own repositories; Flux or another
deployment system reads the central image selections.

## Central selections and application catalog

Store one Kustomize selection per environment:

```yaml title="k8s/acc/kustomization.yaml"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../vendor/web/overlays/acc
  - ../../vendor/api/overlays/acc
images:
  - name: ghcr.io/example/web
    newTag: v1.4.0
  - name: ghcr.io/example/api
    newTag: v2.3.1
```

The `vendor` directories in this example are supplied by the deployment system.
Diatreme reads `images`; it does not fetch, build or deploy the resources. Each
selection needs a unique `name` and a SemVer `newTag`; digest selections are rejected.

Map those images to their application repositories:

```json title="suite/apps.json"
{
  "apps": [
    {
      "id": "web",
      "display_name": "Web application",
      "repository": "example/web",
      "image": "ghcr.io/example/web"
    },
    {
      "id": "api",
      "display_name": "API service",
      "repository": "example/api",
      "image": "ghcr.io/example/api"
    }
  ]
}
```

`id`, `repository` and `image` are required. `display_name` defaults to `id`.
Every selected image must appear in the catalog. Duplicate IDs, duplicate images
and malformed selections fail the run.

## Call the action with an explicit suite version

Suite releases require `suite-manifest`, `suite-catalog`, `version-override`,
`mode: release` and `detect-image-name: false`. Leave `image_name` empty.
This path skips automatic version calculation and image builds or promotions.

```yaml
name: Release suite
on:
  workflow_dispatch:
    inputs:
      version:
        description: Suite version, for example 1.5.0-acc.2
        required: true
        type: string

permissions:
  contents: write

concurrency:
  group: suite-release-${{ github.ref }}
  cancel-in-progress: false

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: MagmaMoose/diatreme@v2
        with:
          mode: release
          auth-mode: github-token
          github-token: ${{ secrets.SUITE_RELEASE_TOKEN }}
          deployment-model: tbd
          environment: acc
          environments: '["dev", "tst", "acc", "prd"]'
          prerelease-identifiers: '{"dev":"dev", "tst":"tst", "acc":"acc"}'
          suite-manifest: k8s/acc/kustomization.yaml
          suite-catalog: suite/apps.json
          version-override: ${{ inputs.version }}
          detect-image-name: 'false'
```

The action checks out the suite repository with complete history and tags. Pin the
action to a published commit SHA in a production workflow.

Use a token that can write the suite repository and read every catalog application
repository, including its GitHub Releases. An installation token obtained from
your own GitHub App works with `auth-mode: github-token`; the resulting changelog
commit is attributed to that App. The default workflow `GITHUB_TOKEN` cannot read
other private repositories. On GitHub Enterprise, the same token must cover the
application repositories on that host; the action uses the workflow's
`GITHUB_API_URL` and `GITHUB_SERVER_URL` for reads and links.

## The caller owns version planning

The suite version is separate from each application's image version. Diatreme
does not infer a suite bump from the application versions in this mode.

For the environment configuration above, supply versions such as
`1.5.0-dev.1`, `1.5.0-tst.3`, `1.5.0-acc.2` and stable `1.5.0` for `prd`.
The environment order makes the final environment stable; the preceding ones
are GitHub prereleases. The caller must choose the next base version and revision,
skip unchanged selections, and serialize releases on the same branch. Omit `prd`
from `prerelease-identifiers`.

## Aggregate notes and immutable snapshots

Diatreme compares the selected manifest with the newest reachable suite tag for
the same environment. An ACC release is compared with the preceding ACC release,
even if a TST or production tag is newer.

For each changed application, it reads every published release in the SemVer range
`old < release <= new`, on the selected image's channel. Stable image upgrades
include stable releases; candidate upgrades include that candidate channel. Draft
releases are excluded. Initial suite selections and rollbacks include the selected
application release only, with rollbacks labeled explicitly.

The exact application release tag must match `newTag` and have published notes.
Missing releases, empty notes and API failures stop the run before the suite tag
is created. Notes are copied from the application releases, with links to those
releases. Diatreme never edits the application repositories.

After tagging, one GitHub-signed commit writes `CHANGELOG.md` and
`suite/status.json` to the current suite branch. The commit preserves other
environment entries and earlier changelog notes. It checks the branch head
optimistically and refuses to write if the selected manifest has changed since
the release checkout. The suite tag continues to identify the original selection
commit; the later status commit does not move it.

The GitHub Release contains the aggregate notes and an attached `release.json`.
The snapshot includes the environment, suite tag, release URL and timestamp,
selected image versions, previous suite tag, and changed applications with their
version ranges and release notes. `suite/status.json` keeps the latest snapshot
under each environment for dashboards and other readers. This records a release
selection; deployment readiness comes from the deployment system.

## Resume a failed release

Rerun the original workflow at the same commit with the same `version-override`.
An existing suite tag at that commit resumes instead of creating another version.
The status/changelog commit is idempotent, and an existing GitHub Release is left
unchanged. A tag belonging to another commit, changed image selections for an
already recorded tag, or an attempt to overwrite newer environment history fails.

If the branch now contains a newer image selection, release that selection with
a new suite version. Do not reuse an older suite tag for different images.
