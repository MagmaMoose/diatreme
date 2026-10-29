# Broker configuration

<!-- sources: broker/app/config.py, broker/app/ssm.py, broker/app/broker.py,
     worker/src/index.ts, worker/wrangler.jsonc, worker/.dev.vars.example,
     .github/workflows/deploy-worker.yaml
     -->

Everything the broker reads at runtime. You only need this page if you self-host
a broker or operate the hosted one. Consumers of the action configure nothing
here: they set action inputs, which are documented in the
[repository README](https://github.com/MagmaMoose/diatreme#inputs).

All of these are read per request from the runtime environment, so changing one
takes effect on the next request after a redeploy. None of them are read from a
file at boot.

The **Python/Lambda broker** (production) reads environment variables whose names
come from its `BrokerConfig` field names uppercased (`app_id` → `APP_ID`). On
Lambda those values arrive as function environment variables; secrets come from
SSM Parameter Store under `SECRET_PATH` and overlay the environment on top (see
[`SECRET_PATH`](#secret_path) below). The **Cloudflare Worker** (rollback target)
uses different names for some of the same settings. Where they differ, both names
are shown.

## Required

| Name (Lambda / Worker) | Type | Secret | Effect |
| --- | --- | --- | --- |
| `APP_ID` / `GITHUB_APP_ID` | string | no | Numeric App ID of the github.com GitHub App the broker acts as. Without it, `/token` returns `503 config_unavailable`. On the Worker, absence also makes `/sign` and `/releases` fail. |
| `PRIVATE_KEY` / `GITHUB_APP_PRIVATE_KEY` | string (PEM) | yes | The App's private key. Accepts a real multi-line PEM or a single line with literal `\n` escapes. |

```text
# Python/Lambda broker
APP_ID=<your-app-id>
PRIVATE_KEY=<your-app-private-key-pem>

# Cloudflare Worker (rollback target)
GITHUB_APP_ID=<your-app-id>
GITHUB_APP_PRIVATE_KEY=<your-app-private-key-pem>
```

## Optional

### `OIDC_AUDIENCE`

Comma-separated list of OIDC audiences `/token` accepts. Entries are trimmed and
empties dropped.

| | |
| --- | --- |
| Type | comma-separated string |
| Default | `diatreme,release-runner` |
| Secret | no |

Blank or whitespace-only falls back to the default pair rather than accepting
nothing. `release-runner` is the pre-rename audience, still accepted so
long-pinned consumers keep working. A token whose `aud` isn't in the list fails
with `401 invalid_oidc_token` and `reason: audience_mismatch`.

The action sends whatever its `oidc-audience` input says, defaulting to
`diatreme`. Change one without the other and every release in every repository
pinned to that version breaks, so treat this list as append-only.

### `ALLOWED_REPOSITORIES`

Comma-separated `owner/name` allowlist for `/token`.

| | |
| --- | --- |
| Type | comma-separated string |
| Default | unset, meaning every repository the App is installed on is allowed |
| Secret | no |

```text
ALLOWED_REPOSITORIES=MagmaMoose/diatreme,MagmaMoose/chargate
```

Matching is exact string equality after trimming. There's no globbing, so
`MagmaMoose/*` matches nothing. A repository outside the list gets
`403 repo_not_allowed`.

### `TOKEN_PERMISSIONS_JSON`

Permissions stamped on the installation tokens `/token` mints. (The Cloudflare
Worker read this from `TOKEN_PERMISSIONS`; the Python/Lambda broker reads it from
`TOKEN_PERMISSIONS_JSON`.)

| | |
| --- | --- |
| Type | JSON object |
| Default | `{"contents": "write", "pull_requests": "write"}` |
| Secret | no |

```text
TOKEN_PERMISSIONS_JSON={"contents":"write","pull_requests":"write","packages":"write"}
```

Keys must be lowercase with underscores, matching GitHub's App permission names.
Values must be exactly `read` or `write`. Anything else, including a value of
`admin` or an empty parse result, makes `/token` return
`400 invalid_token_permissions` for every request. Blank or unset gives you the
default pair.

`/sign` ignores this and always mints with `contents: write` only.

!!! warning "You cannot grant what the App doesn't have"
    This narrows or names permissions on the token. It can't exceed what the
    GitHub App itself was granted at install time. Asking for a permission the
    App lacks gets you a token without it, not an error.

### `PROCESS_TRIGGER_SECRET`

Bearer token gating `POST /sign` and `GET /releases`.

| | |
| --- | --- |
| Type | string |
| Default | unset |
| Secret | yes |

Unset means both routes return `503` (`sign_disabled`, `releases_disabled`) and
neither can be reached. Compared in constant time. The hosted broker sets it;
a self-hosted broker that only needs `/token` can leave it out.

### `GITHUB_WEBHOOK_SECRET` (Cloudflare Worker only)

HMAC-SHA256 secret for `POST /webhook`, matching the secret configured on the
GitHub App. Not read by the Python/Lambda broker.

| | |
| --- | --- |
| Type | string |
| Default | unset |
| Secret | yes |

Unset means `/webhook` returns `503 webhook_disabled`.

### `AUTO_UPDATE_BRANCHES` (Cloudflare Worker only)

Enables the push auto-update behaviour behind `/webhook`. Not read by the
Python/Lambda broker.

| | |
| --- | --- |
| Type | string flag |
| Default | unset, disabled |
| Secret | no |

Enabled only by the exact values `1`, `true`, `yes` or `on`, case-insensitive
after trimming. Every other value, including `enabled`, leaves it off. With it
off, verified webhook deliveries are accepted and do nothing.

## GitHub Enterprise

All five are opt-in and only meaningful together. Setting `GHE_OIDC_ISSUER` is
what turns GHE support on: `/token` then trusts two issuers instead of one, and
mints against whichever one actually signed the token.

The Python/Lambda broker and the Cloudflare Worker use different names for the
GHE App credentials. Both sets are shown.

| Name (Lambda / Worker) | Required for GHE | Secret | Effect |
| --- | --- | --- | --- |
| `GHE_OIDC_ISSUER` (both) | yes | no | The tenant's OIDC issuer, for example `https://token.actions.example.ghe.com`. Trailing slashes and stray whitespace are stripped. |
| `GHE_API_BASE` (both) | yes | no | The tenant's REST base, for example `https://example.ghe.com/api/v3`. |
| `GHE_APP_ID` / `GHE_GITHUB_APP_ID` | yes | no | App ID of the duplicate App registered on the tenant. |
| `GHE_PRIVATE_KEY` / `GHE_GITHUB_APP_PRIVATE_KEY` | yes | yes | That App's private key. |
| `GHE_INSTALLATION_ID` / `GHE_GITHUB_APP_INSTALLATION_ID` | no | no | Skips the per-repo installation lookup, saving one API call. Ignored unless it parses to a positive integer. |

A github.com token is still verified against github.com and minted with the
github.com App. The issuer is pinned before its key set is selected, so a forged
`iss` can't make the broker verify against the wrong tenant's keys.

## AWS Lambda only

### `JWKS_TABLE_NAME`

Name of the DynamoDB table that holds last-known-good JWKS snapshots, one row
per trusted issuer.

| | |
| --- | --- |
| Type | string |
| Default | unset |
| Secret | no |

Unset disables the snapshot rescue path entirely: if the live JWKS fetch fails,
the broker returns `503 oidc_key_fetch_failed` with no fallback. Set it to enable
degraded-mode verification during GitHub JWKS outages. See [The broker](../worker.md#surviving-a-jwks-outage) for
how the rescue path works.

### `SECRET_PATH`

SSM Parameter Store path prefix from which the broker loads its secrets on Lambda.

| | |
| --- | --- |
| Type | string |
| Default | unset |
| Secret | no |

When set, the broker calls `GetParametersByPath` on this prefix and overlays the
results on top of the function's environment variables. Parameter basenames are
converted from kebab-case to snake_case and matched against `BrokerConfig` field
names, so `/diatreme/prod/private-key` lands on `PRIVATE_KEY`. The SSM overlay
wins over the environment, so a leaked env var can't beat Parameter Store.

Unset means no SSM lookup: every setting must arrive in the Lambda environment.

## KV namespaces (Cloudflare only)

Both are optional. Neither is hard-coded in `wrangler.jsonc`, so a self-hosted
deploy without them still works.

| Binding | Purpose | Without it |
| --- | --- | --- |
| `DIATREME_JWKS_CACHE` | Last-known-good JWKS snapshot per issuer, written after each successful verification. | The broker has no fallback when an issuer's key endpoint is unreachable, and returns `503 oidc_key_fetch_failed` instead of rescuing the request. |
| `COPILOT_QUOTA_KV` | Caches the `GET /releases` aggregate. | `/releases` recomputes on every call. Nothing else changes. |

Create and bind them:

```bash
wrangler kv namespace create DIATREME_JWKS_CACHE
wrangler kv namespace create COPILOT_QUOTA_KV
```

The deploy workflow injects the IDs from the `DIATREME_JWKS_CACHE_ID` and
`COPILOT_QUOTA_KV_ID` Actions variables, so the namespace IDs never land in the
repository. Set neither and the injection step is skipped entirely.

!!! note "COPILOT_QUOTA_KV is a legacy name"
    The Copilot features that namespace was created for were removed. The
    binding name is kept because `env.COPILOT_QUOTA_KV` is what the code reads,
    and renaming it would orphan the cached data for no benefit. It has nothing
    to do with Copilot now.

## Local development

**Python/Lambda broker:** set the variables above as process environment variables
before running `uvicorn app.main:app` (the FastAPI dev shell). `SECRET_PATH` is
unset locally, so every setting must be in the environment. No `.dev.vars` file is
involved.

**Cloudflare Worker:** copy the example and fill it in:

```bash
cp worker/.dev.vars.example worker/.dev.vars
```

`.dev.vars` is gitignored. `wrangler dev` reads it. The example file covers the
Worker App credentials and the GHE block; use the Worker variable names
(`GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY`, etc.) in that file.

## Related

- [Broker API](broker-api.md) for the routes these settings govern.
- [Limits](limits.md) for the caps and TTLs that aren't configurable.
