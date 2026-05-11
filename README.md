# Release Runner

<p align="center">
  <img src="docs/release-runner-logo.png" alt="Release Runner" width="200">
</p>

[![CI](https://github.com/calebsargeant/release-runner/actions/workflows/ci.yaml/badge.svg)](https://github.com/calebsargeant/release-runner/actions/workflows/ci.yaml)
[![Release](https://github.com/calebsargeant/release-runner/actions/workflows/release.yaml/badge.svg)](https://github.com/calebsargeant/release-runner/actions/workflows/release.yaml)
[![Docs](https://github.com/calebsargeant/release-runner/actions/workflows/docs-pages.yaml/badge.svg)](https://semver.calebsargeant.com)
[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Release%20Runner-purple?logo=github)](https://github.com/marketplace/actions/release-runner)
[![License](https://img.shields.io/github/license/calebsargeant/release-runner)](https://github.com/calebsargeant/release-runner/blob/main/LICENSE)

Instead of composing `cycjimmy/semantic-release-action` + `docker/metadata-action` + `cloudposse/github-action-docker-promote` + ~200 lines of glue YAML, use one action.

<!-- TODO: 30-second GIF showing PR→merge→release→Docker promotion -->

## The "Why"

Most teams that need semantic versioning, Docker image promotion, and multi-environment releases end up stitching the pieces together: one action picks the version (`semantic-release`, `release-please`, `GitVersion`, or `python-semantic-release`), another logs into GHCR, another retags or rebuilds an image, and a handful of inline shell steps wire it all together — bumping `appsettings.json`, opening promotion PRs, scraping ticket links into release notes.

What falls through the cracks is the connective tissue. Two release runs racing on `main` create a tag that the other workflow then crashes on. The prerelease identifier (`dev`, `rc`) drifts across environments because every workflow's `tag-prefix` got copy-pasted. The image you promoted to staging gets *rebuilt* instead of retagged, so the binary that passed staging tests isn't the binary you ship to prod. Release notes don't mention the four ClickUp tickets the PR descriptions linked to — your release manager assembles that by hand.

Release Runner consolidates this into one composite action and one reusable workflow. The versioning tool is a single input. Image promotion is retag-not-rebuild by default. Promotion PRs are auto-opened. ClickUp links and Projects v2 items are scraped into release notes automatically. And the bundled reusable workflow declares the `concurrency:` block that composite actions can't, so the race window goes away.

## 60-Second Quickstart

A production-only release from `main`, using the workflow `GITHUB_TOKEN`:

```yaml
name: Release

on:
  push:
    branches: [main]

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: calebsargeant/release-runner@v1
        with:
          environment: prod
          environments: '["prod"]'
          prerelease-identifiers: '{}'
          auth-mode: github-token
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

Add a `pyproject.toml` (default tool: `python-semantic-release`) and merge a conventional commit. You get a git tag, a GitHub Release, and a `CHANGELOG.md` entry. If branch protection blocks `GITHUB_TOKEN` from pushing tags, install the App — see *Scale up* below.

### Scale up

- **Docker image promotion** — add `packages: write` and `image_name: my-app`, plus a `docker-bake.hcl`. PR builds land at `pr-<N>`; merges retag to the release version, no rebuild.
- **Multiple environments** — switch to `environments: '["dev", "staging", "prod"]'`, set `prerelease-identifiers`, and turn on `create-promotion-pr: 'true'` to auto-open the next-env PR.
- **Strict branch protection** — install the [Release Runner GitHub App](https://github.com/apps/release-runner/installations/new) and drop the `auth-mode` and `github-token` inputs. The App becomes the default; grant the job `id-token: write` instead of `contents: write`.
- **Concurrent triggers** (push + promotion-PR merges on the same branch) — swap the `uses:` line for the bundled reusable workflow:

  ```yaml
  jobs:
    release:
      uses: calebsargeant/release-runner/.github/workflows/release-runner.yaml@v1
      with:
        environment: prod
        environments: '["prod"]'
        prerelease-identifiers: '{}'
  ```

  Same inputs; adds an automatic `concurrency: release-runner-<target-branch>` lock with FIFO queueing.

## What You Get

- **Four versioning backends behind one input.** `versioning-tool: semantic-release-npm | semantic-release-python | gitversion | release-please` — swap without touching anything else.
- **Retag-not-rebuild Docker promotion.** The image that passed PR CI as `pr-42` becomes `v1.2.3` via registry retag. No fresh build, no binary drift between staging and prod. Falls back to a Docker Bake rebuild only when the source image is missing.
- **Per-environment prerelease identifiers.** `{"dev":"dev","staging":"rc"}` → tags land as `v1.2.3-dev.1`, `v1.2.3-rc.1`, `v1.2.3`. Production sheds the suffix.
- **Promotion PRs auto-open.** In `deployment-model: tbd-pr` with `create-promotion-pr: 'true'`, pushing to `main` cuts the dev tag and opens `promote/staging/<version>`. Merging that opens `promote/prod/<version>`; merging that cuts the stable prod tag.
- **ClickUp + GitHub Projects v2 in release notes.** Scans commits and PR bodies in the release range for `app.clickup.com/t/...` URLs and issue/PR refs (`#NNN`), appends grouped sections to the GitHub Release notes and to any open promotion PR body.
- **Production guardrail on by default.** `admin-required-from: '@last'` makes manual `workflow_dispatch` runs targeting production require `permission: admin` on the repository. Push and promotion-PR-merge triggers are unaffected.
- **Built-in concurrency lock.** The bundled reusable workflow declares `concurrency: release-runner-<target-branch>` with `cancel-in-progress: false`, so concurrent triggers on the same branch queue FIFO instead of racing the tag write. Composite actions can't do this on their own.

## Compared to Alternatives

| Action | Versioning | Docker build | Promote (retag) | Multi-env prerelease | Promotion PRs | ClickUp | Projects v2 | Admin gate | Concurrency lock |
|---|---|---|---|---|---|---|---|---|---|
| **Release Runner** | all 4 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| cycjimmy/semantic-release-action | semantic-release (npm) | — | — | — | — | — | — | — | — |
| codfish/semantic-release-action | semantic-release (npm) | — | — | — | — | — | — | — | — |
| googleapis/release-please-action | release-please | — | — | — | — | — | — | — | — |
| python-semantic-release publish action | python-semantic-release | — | — | — | — | — | — | — | — |
| gittools/actions | GitVersion | — | — | — | — | — | — | — | — |
| @codedependant/semantic-release-docker | sr-npm (plugin) | ✓ | — | — | — | — | — | — | — |
| cloudposse/github-action-docker-promote | — | — | ✓ | — | — | — | — | — | — |
| Nextdoor/docker-image-retag-action | — | — | ✓ | — | — | — | — | — | — |

<sub>Best-effort comparison as of 2026-05-11; corrections welcome via PR.</sub>

## Setup

- [Concepts](https://semver.calebsargeant.com/concepts/) — TBD vs BBD, promotion PRs, Docker retag, the auth-token model.
- [Choose your setup](https://semver.calebsargeant.com/choose-your-setup/) — paste-ready snippets for each release model.
- [Repository setup](https://semver.calebsargeant.com/repository-setup/) — versioning config, `docker-bake.hcl`, PR CI, release workflow.
- [Organization setup](https://semver.calebsargeant.com/organization-setup/) — when to upgrade from `github-token` to the Release Runner App.

Full input/output reference: [Action reference](https://semver.calebsargeant.com/reference/action-inputs-outputs/).

## Outputs

| Output | Meaning |
|---|---|
| `version` | Semver without prefix, for example `1.0.0` |
| `tag` | Full Git tag, for example `v1.0.0` |
| `released` | `true` when a new release was created |
| `is-prerelease` | `true` for prerelease environments |
| `prerelease-identifier` | The prerelease identifier (e.g. `dev`, `rc`); empty for prod |
| `resolved-environment` | Environment selected for the run |

## Sponsor

If Release Runner saves you time or helps your team ship more reliably, consider supporting its development:

[![Sponsor on GitHub](https://img.shields.io/badge/Sponsor-♥-ea4aaa?logo=github)](https://github.com/sponsors/CalebSargeant)
[![Support on Ko-fi](https://img.shields.io/badge/Ko--fi-Support-ff5e5b?logo=ko-fi&logoColor=white)](https://ko-fi.com/calebsargeant)

<!-- TODO: Caleb fills in -->
GitHub Sponsors at the $X/month tier unlocks access to the hosted Release Runner dashboard — cross-repo release view, Slack notifications, audit log retention.
