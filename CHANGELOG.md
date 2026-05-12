# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- Shared public GitHub App auth through the Cloudflare Worker token broker.
- Repository CI for actionlint, markdownlint, Docker Bake validation, Bats shell tests, and Worker checks.
- `registry-username` and `registry-password` inputs so callers can target
  container registries that don't accept GHCR-style `github.actor` +
  workflow-token auth — GHES `containers.<host>`, Harbor, Artifactory,
  Nexus, ACR, etc. Defaults to current behaviour when both are blank.
- `submodules` input passed through to the internal `actions/checkout`
  step. When set non-false under `auth-mode: private-app` / `auto`,
  the App installation token is broadened from current-repo scope to
  owner scope so sibling-repo submodules in the same org can be fetched.
  Default `false` keeps existing behaviour.

### Changed

- The repository release workflow now dogfoods this action directly.
- Convenience reusable workflows pin the root action at `v1` instead of `main`.

<!-- semantic-release will append entries above this line -->
