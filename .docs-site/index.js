/**
 * One repository's documentation site, as a Worker with Static Assets.
 *
 * Provisioned by Caldrith from MagmaMoose/admin (files/docs-site/index.js). Edit it THERE,
 * not here; a local edit is reconciled away on the next run.
 *
 * Nothing in this file is per-repository, and it is a copy of `workers/docs-site/src/index.js`
 * in MagmaMoose/tremvok, which is where the shape is documented. The whole per-repo
 * configuration is `name` in the wrangler.toml beside it.
 *
 * WHY THERE IS A SCRIPT AT ALL. An assets-only Worker — `[assets]` with no `main` — is served
 * straight off the edge with no code in the request path, and for a site reached over HTTP that
 * is the right answer. This one is never reached over HTTP: it is reached through a service
 * binding from the router on docs.magmamoose.com, and a service binding dispatches to a
 * Worker's fetch handler. `main` is what gives it one.
 */

export default {
  async fetch(request, env) {
    // The router has already stripped the `/<repo>` prefix, so the path that arrives is the
    // one the built site was laid out from. `env.ASSETS.fetch` applies the asset router:
    // directory URLs, index.html, and the `not_found_handling` set in wrangler.toml.
    return env.ASSETS.fetch(request);
  },
};
