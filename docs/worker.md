# The broker

<!-- sources: broker/app, worker/src/index.ts -->

The GitHub App backend behind `https://api.diatreme.magmamoose.com`. It exists so
callers don't have to register and run their own GitHub App: the action's default
`auth-mode: public-app` exchanges an Actions OIDC token here for a short-lived
installation token.

## Active implementation

The production broker is a **Python/Lambda implementation** (`broker/app/`) running on
AWS Lambda behind API Gateway in `eu-west-1`. The **TypeScript Cloudflare Worker**
(`worker/src/index.ts`) remains in this repository as the code-of-record reference and
rollback target, but is not currently serving any hostname.

The two implementations use the same verification ladder and error contract, so the
wire protocol is identical. For operations and deployment details, see
[Deployment](operations/deployment.md).

This page explains the shared broker concepts. The exhaustive tables live elsewhere
so they can't drift apart:

- [Broker API](reference/broker-api.md): every route, parameter and status code.
- [Broker configuration](reference/configuration.md): every variable.
- [Errors](reference/errors.md): every failure and its fix.
- [Limits](reference/limits.md): caps, TTLs and lifetimes.

## Verification ladder

Both broker implementations (Python/Lambda and TypeScript/Cloudflare Worker) follow
the same verification order for `/token`, which is load-bearing:

1. Parse the body. Missing fields fail before any crypto runs.
2. Verify the OIDC token against the pinned issuer's key set.
3. Compare the token's `repository` claim to the requested `owner/repo`.
4. Check the deployment's repository allowlist.
5. Mint against the same GitHub host the token came from.

Steps 3 and 4 come after verification because an unverified claim is worth
nothing. Step 5 is what makes GitHub Enterprise work: a token from a configured
GHE issuer mints through the GHE App against that tenant's REST base, and a
github.com token never does.

The full ladder and every status code is in [Broker API](reference/broker-api.md).

## Surviving a JWKS outage

The broker can't verify anything without GitHub's public keys, so how it handles
not having them is most of its reliability story.

Two failure modes, handled differently:

**A key rotation.** GitHub signs with a `kid` the cached key set doesn't contain.
The library does not self-heal this on its own, so the broker forces one
re-fetch, throttled to once every 5 seconds across the whole deployment. Don't
"simplify" that throttle or the cooldown around it. Shortening the cooldown
widens the window in which the library's own unthrottled reload fires and
produces more upstream fetches per rotation, not fewer.

**A retrieval fault.** The key endpoint times out, answers non-200, or returns
something that isn't JSON. Every successful verification writes the key set to
KV as a last-known-good snapshot, and a retrieval fault falls back to that
snapshot rather than rejecting genuine tokens. The snapshot only ever supplies
keys: every other claim check still runs against the real token, and a snapshot
over 24 hours old is refused rather than trusted.

With no usable snapshot the request gets `503 oidc_key_fetch_failed`, never a
401. That distinction is the whole point. A 401 says the broker reached a verdict
and your token lost. A 503 says it never reached one. Collapsing the two turned
an upstream outage into a permanent, unfalsifiable "bad token"
([#147](https://github.com/MagmaMoose/diatreme/issues/147)).

## Development and deployment

Both broker implementations are kept in sync by their test suites:

- **Python broker** (`broker/app/`) is production. Runs on AWS Lambda. Configuration
  via SSM Parameter Store and Lambda environment. Smoke-tested weekly against both
  broker hostnames.
- **TypeScript Worker** (`worker/src/index.ts`) is the rollback target and code
  reference. Kept deployable but not serving traffic.

Full deployment pipeline, secrets, rollback procedure, and smoke testing are in
[Deployment](operations/deployment.md). Configuration options are documented in
[Broker configuration](reference/configuration.md).

### Running locally (TypeScript Worker)

If you need to verify the Worker locally:

```bash
cd worker
npm ci
npm run typecheck   # tsc --noEmit
npm test            # vitest
npm run check       # typecheck + tests + wrangler dry run
wrangler dev        # run locally against .dev.vars
```

Copy `worker/.dev.vars.example` to `worker/.dev.vars` and fill in the App
credentials. The test suite covers routing, verification, and JWKS rotation
separately.
