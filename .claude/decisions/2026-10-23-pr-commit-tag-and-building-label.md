# Preview environments: a tag per pull request head, and a label while it builds

**Status:** proposed (2026-10-23)

## Context

Label-driven GitOps preview controllers render one deploy per pull request head commit:
Flux Operator's `ResourceSetInputProvider` (type `GitHubPullRequest`) exports `id` and the
head `sha`, Argo CD's pull request generator `number` and `head_sha`. `mode: ci` pushed only
`pr-<N>`, which every push overwrites, so a Deployment pinned to it never rolls. And a
controller moves a preview as soon as it sees a new head, before that head's image exists.

## Options considered

1. **Tag per head commit in the same push as `pr-<N>`.** One build, both tags on its
   manifest.
2. **Retag `pr-<N>` after the push.** One code path for built and skipped heads, but it races:
   a newer run can move `pr-<N>` between this run's push and its retag, and the commit tag
   then names another commit's image.
3. **`--set <target>.tags+=` for bake.** Needs buildx 0.22; self-hosted runners may be older.

For holding the preview: a label for Flux Operator's `spec.skip.labels`, added before the
build and removed after the last push, which is the protocol the provider is built for.

## Decision

- `image-commit-tag` (opt-in): on `pull_request` in `mode: ci`, also push `pr-<N>-<sha7>`,
  sha7 from `github.event.pull_request.head.sha`. Option 1. Bake restates each tagged target's
  tags with repeated `--set <target>.tags=` and adds the commit tag on the repository of the
  first; the Dockerfile path adds a second `--tag`.
- A build skipped by `deploy-paths` retags `pr-<N>` (`scripts/retag-commit-image.sh`): absent
  is a warning, any other failure an error, with the GHE pull/tag/push fallback.
- `image-building-label` (opt-in): added as the first ci step, removed as the last, with no
  status function, so a failed or cancelled run leaves it on. Failure-isolated: warns only.
  Uses `steps.auth.outputs.token`.
- Loop guard: a run whose event is `labeled`/`unlabeled` for this label does not add it.

## Rationale

- The head SHA is what both controllers export; `github.sha` on a pull request is the merge
  commit nobody else knows.
- Same push cannot race and costs nothing extra. The retag exists only where there is no
  build to share a push with.
- Removing after the scan, not after the build: a gate failure fails the run, and a failed
  run keeps the preview where it was.
- A label change made with an App token starts workflows. Not adding the label on its own
  event bounds the chain at one run per change, and still removing it means a run whose
  predecessor was cancelled clears it.

## Consequences

- Two inputs and one output are frozen surface.
- `mode: release` is unchanged: it promotes `pr-<N>`. The commit tags are never cleaned up;
  registry retention is the consumer's.
- A re-run of a head, or a later run after the base moved, re-pushes the same commit tag with
  a new manifest; a Deployment already on that tag does not roll for it.
- Fork pull requests get a read-only `GITHUB_TOKEN`: they build, the label warns.
- A deploy-only pull request with `image-commit-tag` now runs buildx setup and the registry
  login for the retag.
