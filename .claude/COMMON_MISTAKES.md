# Common mistakes (footguns)

- **One root action file.** Exactly one `action.yml` at repo root; CI fails otherwise.
  Input/output **names, defaults and behaviour are frozen** — consumers pin by SHA, so a
  change breaks repos that cannot be updated. Keep README examples aligned.
- **Shell scripts need the exec bit in Git.** `core.fileMode=false`, so a new `scripts/*.sh`
  ships `100644` and breaks CI: `git update-index --chmod=+x scripts/<f>.sh`. `.mjs` run via
  `node` don't need it; `tests/bats/*.bats` are run *by* bats — leave those `100644`.
- **Keep the worker self-contained**: only runtime dep is `jose`. Don't couple it to
  `scripts/`, and never vendor code from the private `MagmaMoose/diatreme-pro`.
- **`bats tests/bats` fails only `action-shell-syntax` locally** on macOS system Ruby 2.6
  (`YAML.safe_load_file` missing). Not a real failure; it passes on CI.
- **`createRemoteJWKSet` does NOT self-heal a key rotation** — don't "simplify" the forced
  reload or the cooldown in `worker/`. Mechanics in `.claude/INFRA_NOTES.md`.
- **Never swallow an error with a bare `catch {}` on the /token path.** That turned a JWKS
  outage into a permanent, unfalsifiable `invalid_oidc_token` (#147). Classify on jose's
  `.code`, never `instanceof JOSEError` (all jose errors extend it). A *retrieval* fault is
  503, never 401.
- **The broker fallback must never fire on 4xx.** A rejected token is an answer, not an
  outage. Connection failure and 5xx only; `tests/bats/request-public-app-token.bats` pins it.
- **Copilot/triage/quota features were removed** and the KV binding that served them is gone.
  Don't reintroduce either.
- **Never commit** secrets, `.dev.vars`, or caches (`node_modules/`, `.wrangler/`,
  `coverage/`, `site/`, `broker/.venv/`).
- **Pinning psr is not pinning psr's dependencies.** `scripts/psr-requirements.txt`
  pins the CLI exactly, but pip resolved its transitive deps fresh on every release
  run: GitPython 3.1.60 deleted `Actor.name_email_regex`, psr 10.6.1 reads it to
  validate `commit_author`, and every consumer release broke with no Diatreme change.
  Pin the offending dep there too. Note `--version` / `--help` never load a config,
  so the CI smoke test now resolves a real version in a throwaway repo.
- After editing `scripts/`, run `shellcheck -S warning scripts/*.sh` and `actionlint`.

Broker internals, infrastructure, DNS and TLS: `.claude/INFRA_NOTES.md`.

- **The image sinks fire in `mode: release` ONLY — never wire them into the `pr-<N>` scan.**
  Dependency-Track and DefectDojo describe what is *deployed*. A pr-`<N>` upload succeeds and
  looks completely correct, which is why this is easy to get wrong: the damage is cumulative,
  not immediate. One Dependency-Track project version per pull request, for ever, and the
  "current" inventory ends up describing whichever PR happened to run last rather than what
  is actually running. Chargate learned the same lesson on its source BOM and already refuses
  to upload on pull requests. The CI scan still runs — its job is `image-scan-gate` and the
  log — but it carries no sink env at all, and `tests/bats/scan-image.bats` asserts that in
  both directions. A severity gate on the release scan is likewise pointless: the tag is cut
  and the image pushed by then, so it could only paint a finished release red.
- **Released refs are derived in THREE places now** (Promote images, cosign signing, and the
  release scan), each re-running `bake --print` and appending `:${NORMALIZE_TAG}`. They must
  stay identical or the org signs one set of images and inventories another. There is a bats
  guard counting the two derivation literals; if you add a fourth consumer, update it rather
  than deleting it.
