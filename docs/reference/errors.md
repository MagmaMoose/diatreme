# Errors

<!-- sources: broker/app, worker/src/index.ts, scripts/request-public-app-token.sh, scripts/detect-
     versioning-tool.sh, scripts/build-image-dockerfile.sh, scripts/resolve-promote-from.sh,
     scripts/verify-promote-from-images.sh, action.yml
     -->

Every failure a Diatreme run can surface, what causes it, and what to do. The
action fails hard: any broker fault exits the step non-zero, so a broken broker
is a red X on the release rather than a silent skip.

## Reading a broker failure in the run log

The action prints the HTTP status, the `error` code, the `reason` when there is
one, and which broker answered:

```text
Error: Token broker request failed with HTTP 401: invalid_oidc_token (audience_mismatch) [https://api.diatreme.magmamoose.com]
```

The hostname in brackets matters. If it's the fallback rather than the primary,
the primary was unreachable or returned 5xx and you have two problems, not one.
A preceding `::warning::` line names the primary's status.

## Token verification failures

All of these are `401 invalid_oidc_token` unless noted. The `reason` is what
tells you which check failed.

| `reason` | What it means | What to do |
| --- | --- | --- |
| `malformed_token` | The value sent as `oidcToken` isn't a decodable JWT. | Almost always a broken OIDC mint upstream of the broker. Check the `Request public GitHub App token` step actually received a token, and that `id-token: write` is granted. |
| `audience_mismatch` | The token's `aud` isn't in the broker's accepted list. | Your `oidc-audience` input and the broker's `OIDC_AUDIENCE` disagree. Leave the input at its default unless you run your own broker. |
| `issuer_mismatch` | The token's `iss` isn't a trusted issuer. | Expected on a GitHub Enterprise runner talking to a broker without `GHE_OIDC_ISSUER` configured. See [Configuration](configuration.md#github-enterprise). |
| `token_expired` | `exp` is in the past. | The token is minted seconds before use, so this means real clock skew or a job that stalled for an hour between mint and exchange. Re-run. |
| `token_not_yet_valid` | `nbf` is in the future. | Clock skew on the broker side. Re-run, and if it persists, report it. |
| `signature_invalid` | The signature didn't verify against a key that matched. | Not something a caller can cause with a genuine token. Report it. |
| `kid_not_found` | No signing key matched the token's `kid`, even after a forced re-fetch. | Usually a GitHub key rotation the broker hasn't caught up with. Retry once. If it persists past a few minutes, report it. |
| `key_ambiguous` | More than one key matched the `kid`. | Report it. Not caller-fixable. |
| `alg_unsupported` | The token's algorithm isn't allowed. | Report it. |
| `claim_invalid` | A claim other than `aud`, `iss` or `nbf` failed validation. | Report it with the run URL. |
| `unknown` | The failure carried no classifiable code. | Report it with the run URL. |

### `403 repo_mismatch`

The token's `repository` claim isn't the `owner`/`repo` the request asked for.
The broker will not mint a token for a repository other than the one whose
runner minted the OIDC token, which is the property that makes a public broker
safe. Seeing this from an unmodified action means something rewrote the request.

### `403 repo_not_allowed`

The repository is outside the broker's `ALLOWED_REPOSITORIES`. On a self-hosted
broker, add it. On the hosted broker this shouldn't happen; report it.

### `404 app_not_installed`

The Diatreme GitHub App isn't installed on the repository. Install it from
[github.com/apps/diatreme](https://github.com/apps/diatreme) and re-run. This is
the single most common first-run failure.

### `400 invalid_repository`

`owner` or `repo` contains a character outside `A-Za-z0-9_.-`. Not reachable
through the action, which derives both from `GITHUB_REPOSITORY`.

## Availability failures

### `503 oidc_key_fetch_failed` with `reason: jwks_unavailable`

The broker could not retrieve the issuer's key set, so it never reached a
verdict on your token. This is broker or upstream unavailability, not a bad
token, and it is worth retrying.

Causes seen in practice: a timeout or connection reset reaching
`token.actions.githubusercontent.com`, a non-200 from that endpoint, or a
response that doesn't parse as JSON.

What to do: re-run the job. The broker keeps a last-known-good key set and will
rescue the request from it when one is available and fresh enough, so a
persistent 503 means both the live fetch and the snapshot are unusable.

!!! note "Why this isn't a 401"
    It used to be. A bare catch turned every retrieval fault into
    `invalid_oidc_token`, which sent people hunting for a bad token during what
    was actually an outage, with no way to tell the two apart
    ([#147](https://github.com/MagmaMoose/diatreme/issues/147)). Retrieval
    faults are 503 now, and only 503.

### `500 github_installation_lookup_failed`

GitHub answered the installation lookup with something the broker couldn't use.
Transient. Re-run, and check [GitHub's status page](https://www.githubstatus.com/)
if it repeats.

### `502 installation_token_failed` / `502 sign_failed`

Only on `/sign`. The first means no token could be minted for that repository,
the second that GitHub rejected the commit. The usual cause of `sign_failed` is
a stale `expected_head_oid`: the branch moved between reading the head and
writing the commit. Re-read the head and retry.

### `503 sign_disabled` / `503 releases_disabled` / `503 webhook_disabled`

The relevant secret isn't configured on that deployment. See
[Configuration](configuration.md). On a self-hosted broker this is your answer.
On the hosted one, report it.

## Client-side action failures

These come from the action's own scripts, before or instead of a broker call.

| Message | Cause | Fix |
| --- | --- | --- |
| `auth-mode public-app requires token-broker-url.` | `token-broker-url` was explicitly set to an empty string. | Leave it unset to get the default, or give it a real URL. |
| `OIDC request environment is unavailable. Grant 'id-token: write' to this job.` | The job has no OIDC permission, so no token can be minted at all. | Add `permissions: id-token: write` to the job. See [Setup](../setup.md#required-permissions). |
| `GITHUB_REPOSITORY must be owner/repo.` | The environment variable is missing or malformed. | Only reachable outside a normal Actions run. |
| `Token broker request failed with HTTP <status>: <error>` | The broker answered non-200. | Find the `error` and `reason` in the tables above. |

### `promote-from` refusals

Every message in this table starts with `promote-from:`. All but the last stop
the run before a tag, an image or a GitHub Release is written.

| Message | Cause | Fix |
| --- | --- | --- |
| `tag '<tag>' does not exist in this repository` | The tag was mistyped, or never cut. The message lists the prereleases of that version that do exist. | Promote one of those. |
| `'<tag>' is already a stable version` | A stable tag was passed. | Pass the prerelease, e.g. `v1.5.0-rc.3`. |
| `'<tag>' is not a prerelease tag under tag-prefix '<prefix>'` | The value is not a SemVer prerelease in this package's tag series. | Check `tag-prefix` matches the one the prerelease was cut with. |
| `is a '<id>' prerelease, but only '<id>' prereleases are promoted to stable` | The tag is from a channel other than the one that feeds production: the environment before the last in `environments`. | Promote that channel's build, or correct `environments` and `prerelease-identifiers`. |
| `<tag> already exists on commit <sha>` | A different build was already released as that stable version. | Cut a new version. If the tag was a mistake, delete it and its GitHub Release first. |
| `<tag> was already promoted from <other>` | Another prerelease on the same commit was already promoted to that version. It is a separate image, so promoting this one would repoint a published version. | Cut a new version. |
| `was not cut by a promotion` | The stable version already exists on this commit and its tag has no `Promoted-From` line: an ordinary release cut it. | Nothing to promote; it is released. |
| `cannot be combined with version-override` / `force-bump` | The version of a promotion is the source tag's own. | Remove the other input. |
| `cannot be combined with publish-package and package-ecosystem: container` | That path runs `docker build` and would push a fresh image under the stable version. | Promote the image through a bake file or `Dockerfile`, or turn `publish-package` off for the run. |
| `npm-provenance would attest the package to commit <sha>` | The workflow was started on a commit other than the prerelease's, and npm attests to the workflow's commit. | Start the workflow from the prerelease tag, or turn `npm-provenance` off for the run. |
| `a promotion always releases the stable version, to '<env>'` | `environment` names something other than the last entry of `environments`. | Remove `environment`. |
| `environments is not a JSON array` / `prerelease-identifiers is not a JSON object` | One of the two inputs does not parse. | Fix the JSON. |
| `source image(s) are not in the registry` | The prerelease has a git tag but no image: its build failed, or a retention policy removed it. | Cut a new prerelease and promote that one. |
| `could not retag <source> as <target>` | The registry refused the retag after the stable tag was pushed. The message carries the registry's error. | Fix the cause and re-run. The promotion resumes from the tag that is already there; it never falls back to a rebuild. |

Two more come from the tag push itself, without the prefix, when the remote
already holds the stable tag and it is not this promotion's:

| Message | Cause | Fix |
| --- | --- | --- |
| `Tag <tag> already exists on remote at <sha>, not at <sha>` | Another run released a different build as that version between this run's checks and its push. | Cut a new version. |
| `Tag <tag> already exists on remote on the commit being released, but it is not this release` | The tag on the remote does not record this prerelease as its source. | Cut a new version. |

See [Promoting a release candidate to stable](../how-to/promote-a-release-candidate.md).

## Getting more detail

On the Cloudflare deployment, every verification failure logs one structured
line:

```bash
npx wrangler tail diatreme --format json --search oidc_verify_failed
```

It carries the classified `reason`, the underlying error name and code, the
token's `kid`, `iss`, `aud`, `repository`, `iat` and `exp`, the audiences and
issuers the broker expected, and for a retrieval fault the upstream HTTP status
and content type. It never carries the token itself. Field values are truncated,
so a hostile token can't flood the log.

## Related

- [Broker API](broker-api.md) for the full status table per route.
- [Configuration](configuration.md) for the settings these errors point at.
