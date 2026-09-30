# Deploy PRs belong to Tremvok; Diatreme keeps deploy-paths

**Status:** accepted (2026-10-01)

## Context

v2.18.0 added `deploy-pr-targets` and `mode: deploy-promote`: after a release, open a pull
request moving the image tag in the first GitOps overlay, and open the next overlay's when one
merges. It was put here because Diatreme holds the version and the promoted images at the
moment of release.

That is the wrong boundary. Diatreme answers "what version, and is it released?"; Tremvok
answers "get that live, prove it, and tell everyone". Opening the pull request that changes
what an environment runs is deploying, and Tremvok is also where verifying the rollout and
notifying about it live. No repository had adopted v2.18.0's inputs when this was decided.

## Decision

- The deploy PRs are Tremvok's `gitops-pr` target (Tremvok ADR 0006). It starts from the
  `release: published` event, which Diatreme already emits after the image is in the registry,
  so nothing has to cross a workflow boundary as an output.
- v2.19.0 removes `deploy-pr-targets`, `deploy-pr-base`, `deploy-pr-branch-prefix`,
  `mode: deploy-promote`, the `deploy-pr` output and the scripts behind them. Removing
  released inputs is normally a major; here nothing used them, and a v3 for an unadopted
  feature would cost every consumer a pin change for nothing.
- The two guards that are release-side stay, as `deploy-paths`: skip the `mode: ci` image
  build for a pull request that changes nothing else, and refuse a `mode: release` push that
  changes nothing else, before versioning.

## Consequences

- A GitOps consumer wires two tools: Diatreme with `deploy-paths` (and the same directories in
  its push `paths-ignore`), and a Tremvok workflow on `release: published` and on pushes to
  the overlays.
- The release loop guard does not depend on which tool opens deploy PRs: any push that only
  changes `deploy-paths` is refused.
