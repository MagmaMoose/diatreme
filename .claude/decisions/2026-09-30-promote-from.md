# promote-from: release a named prerelease as stable

**Status:** proposed (2026-09-30)

## Context

Some consumers run a flow where no branch builds a stable version. A release
branch cuts `-rc.N` prereleases, QA signs one off, and that exact build has to
become `vX.Y.Z`. Diatreme had no path for it:

- `bbd` treats every environment as the first one: it looks for a `pr-<N>` image
  or rebuilds, and a stable version only comes from a branch mapped to production.
- `tbd`'s later-environment retag is close, but it picks the newest prerelease
  instead of a named one, tags the branch tip instead of the prerelease's commit,
  rebuilds when the retag fails, and always moves `:latest`.

## Options considered

1. **A new `mode: promote`.** Clean name, but roughly 25 release-mode steps
   (scan, sign, attest, publish package, GitHub Release, Projects, ClickUp, job
   summary) would each need `|| inputs.mode == 'promote'`, or be duplicated.
2. **An input on `mode: release`** (`promote-from`). Every downstream release
   step applies unchanged; only the steps that decide version, commit and image
   source branch on it.
3. **Extend `tbd` with a "source tag" knob.** Leaves `bbd` consumers out and
   keeps the branch-tip tag and the rebuild fallback.

## Decision

Option 2. `promote-from: <prerelease tag>` on `mode: release`:

- `resolve-promote-from.sh` runs right after checkout, from local refs, and
  settles tag, commit, stable version, previous stable tag and the `:latest`
  decision before anything is written.
- A second `actions/checkout` moves the workspace to the prerelease's commit, so
  the tag lands there and a published package is built from it.
- The environment is forced to the last entry of `environments`, so both
  production guardrails apply.
- `verify-promote-from-images.sh` confirms the source images exist below the
  guardrails and before the tag is cut. Only a definite absence stops the run.
- The retag never falls back to a rebuild. A failure is an error.
- The stable tag's message records its source (`Promoted-From: <tag>`).
  `push-release-tag.sh` runs with `RESUME_AT_HEAD` and that line as
  `RESUME_MARKER`: a stable tag on the prerelease's commit that carries it
  resumes the promotion; any other existing stable tag is refused.
- `publish-package` with `package-ecosystem: container` is refused (it builds an
  image), and provenance is only attested when the workflow commit is the
  promoted commit (`npm-provenance` refused otherwise, SLSA attestation skipped).

## Rationale

- The release tail is the larger and riskier half to duplicate. An input keeps
  one code path for everything after the tag.
- A second `actions/checkout` rather than `git checkout`: submodules and
  credentials behave exactly as in the first one.
- Preflight before the tag: without a rebuild to fall back on, finding a missing
  image after the tag is pushed leaves a stable tag with nothing behind it.
- Resume rather than no-op: the tag is pushed before the retag, so a registry
  failure in between must be finishable by running it again.
- Resume on a marker, not on the commit: two prereleases can share a commit
  (re-running a prerelease release cuts rc.4 where rc.3 is) with different
  images, and "same commit" alone would repoint a published image. A registry
  digest comparison was rejected: the GHE pull/tag/push fallback changes the
  digest, so every resume there would look like a conflict.
- Source restricted to the channel before production: `-dev.7` for `-rc.7` is
  one typo and both tags exist.

## Consequences

- Existing runs take the same paths: every new branch keys off
  `steps.promote-source.outputs.*`, which is empty unless the input is set.
- Two things do change for every run, both reporting only. A resumed promotion
  reaches post-release steps a second time for one tag, which no run could do
  before, so the ClickUp append now skips a section that is already there (the
  Projects append always did). And the job summary no longer says "Released"
  when the image promote step failed after the tag was cut.
- `TAG_LATEST` replaces `IS_PRERELEASE == false` in the retag path. Same value on
  every non-promote run; pinned by `tests/bats/promote-from.bats`.
- The `:latest` rule stops at the image tag and GitHub's Latest marker. An npm
  package from an older release line still takes the `latest` dist-tag, as on
  any stable release; picking another dist-tag name is a product decision.
- `version-file` is not written on a promotion (no branch to commit to).
- The preflight is a fourth consumer of the bake repository derivation; a bats
  guard counts the shared jq literal.
- A promotion costs a second checkout and an early registry login.
- Not covered: promoting between two prerelease channels (`dev` to `rc`). `tbd`
  already does that, by "newest".
