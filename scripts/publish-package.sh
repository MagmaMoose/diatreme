#!/usr/bin/env bash
# Pack and publish a language package to a configurable feed.
#
# Called by the "Publish package" step in action.yml (mode: release), gated on
# `released == 'true'`, after Docker image promotion and before the GitHub
# Release is published — so a downstream `release:published` listener finds the
# package already available in the feed (same ordering rationale as the image
# promote step).
#
# The published version is the one diatreme already computed (VERSION). The
# prerelease/stable distinction is encoded in that string (e.g. 1.2.3-rc.1) and
# each diatreme run targets a single environment, so environment/branch gating
# is inherited from the caller's versioning gate — dev/staging runs publish
# prerelease versions, prod runs publish stable versions, all on `released`.
#
# Required env:
#   ECOSYSTEM   - nuget | pip | npm | maven | gradle | rubygems | container | helm | s3
#   VERSION     - semver to publish (e.g. 1.2.3 or 1.2.3-rc.1)
#   TOKEN       - auth token / API key for the feed (not required for pip when
#                 PYPI_TRUSTED_PUBLISHING=true — a token is minted via OIDC)
#
# Optional env:
#   FEED_URL              - feed/registry URL. Defaults per-ecosystem (GitHub
#                           Packages NuGet for OWNER / PyPI / npmjs.org).
#                           REQUIRED for s3, as s3://bucket[/prefix].
#   AWS_ROLE_TO_ASSUME    - role the caller's OIDC step assumed. REQUIRED for s3;
#                           only verified here, so a missing credentials step
#                           fails with a sentence rather than a 403 at upload.
#   PACKAGE_PATH          - project file or directory to pack/build/publish.
#                           Defaults to WORKING_DIRECTORY, then '.'.
#   WORKING_DIRECTORY     - base directory (the action's working-directory).
#   USERNAME              - feed/login username. pip/twine default '__token__';
#                           maven/gradle/rubygems/container login default
#                           'x-access-token'. Ignored by nuget and npm.
#   OWNER                 - repo owner, used to derive GitHub Packages URLs.
#   REPOSITORY            - owner/repo (github.repository). The default maven
#                           feed and container image name are derived from it.
#   PACKAGE_NAME          - container image name override (defaults to
#                           REPOSITORY lowercased). Ignored by the others.
#   IS_PRERELEASE         - true | false (selects the npm dist-tag).
#   PRERELEASE_IDENTIFIER - e.g. dev, rc; npm dist-tag for prereleases
#                           (falls back to 'next').
#   NPM_PROVENANCE        - true | false. `npm publish --provenance` (public
#                           npmjs only; needs id-token: write).
#   PYPI_TRUSTED_PUBLISHING - true | false. Mint a PyPI upload token from the
#                           workflow's GitHub OIDC identity instead of TOKEN
#                           (public PyPI / TestPyPI only; needs id-token: write).
#   RELEASE_TAG           - the release tag (tag-prefix + version), for
#                           HELM_APP_VERSION=tag.
#   HELM_APP_VERSION      - version | tag | chart: what a chart's appVersion is
#                           set to (default version).
#   HELM_LINT             - true | false. `helm lint` before packaging.
#   HELM_SIGN             - true | false. cosign-sign the pushed chart by digest
#                           (keyless; needs id-token: write and cosign on PATH).
#   ARTIFACTHUB_REPO_FILE - artifacthub-repo.yml to push as the chart's
#                           `artifacthub.io` tag (needs oras on PATH).
#   ARTIFACTHUB_API_KEY_ID / ARTIFACTHUB_API_KEY_SECRET - list the chart on
#                           Artifact Hub when it is not listed yet.
#   ARTIFACTHUB_ORG       - Artifact Hub organization to list it under (empty:
#                           the key's user).
#   ARTIFACTHUB_REPOSITORY_NAME - its Artifact Hub name (default: chart name).
#   ARTIFACTHUB_API_URL   - Artifact Hub API base (default the public one).
#
# Side effects:
#   - Writes `published=true|false` to $GITHUB_OUTPUT when that var is set, and
#     `artifacthub_repository_id` when a chart is listed on Artifact Hub.
#   - Masks TOKEN (and an Artifact Hub key secret) in the workflow log.
#
# Exit codes:
#   0 - package published (re-runs are idempotent: nuget --skip-duplicate,
#       twine --skip-existing, npm tolerates an already-published version)
#   1 - misconfiguration or a publish error

set -euo pipefail

# ECOSYSTEM is validated by the case statement below (the '' branch gives an
# actionable message) so an empty package-ecosystem input doesn't trip the
# generic `set -u` unbound-variable error first.
: "${VERSION:?VERSION is required}"

# Mask the token in any log output before we do anything with it.
if [ -n "${TOKEN:-}" ]; then
  echo "::add-mask::${TOKEN}"
fi

emit_published() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "published=$1" >> "${GITHUB_OUTPUT}"
  fi
}

# Run a publish command, treating an "already published / version exists"
# conflict as success — GitHub Packages (and npmjs) reject overwriting a
# released version, so a re-run must be a no-op, not a hard failure. $1 is an
# extended-regex of conflict messages to tolerate; the rest is the command.
run_publish() {
  local conflict_re="$1"; shift
  local err rc=0
  err="$(mktemp)"
  "$@" 2>"${err}" || rc=$?
  cat "${err}" >&2
  if [ "${rc}" -ne 0 ]; then
    if grep -qiE "${conflict_re}" "${err}"; then
      echo "Already published — idempotent re-run, treating as success."
    else
      rm -f "${err}"
      return "${rc}"
    fi
  fi
  rm -f "${err}"
  return 0
}

# Mint a short-lived PyPI/TestPyPI upload token from the ambient GitHub Actions
# OIDC identity (PyPI "trusted publishing") — no stored secret. $1 is the PyPI
# host (pypi.org | test.pypi.org), which also selects the OIDC audience. Prints
# the minted token on stdout; on any failure prints a ::error:: line to stderr
# and returns non-zero. Uses python (always present in the pip path) so we don't
# add a jq/curl dependency.
mint_pypi_token() {
  local host="$1"
  python - "${host}" <<'PY'
import json, os, sys, urllib.error, urllib.request

host = sys.argv[1]
audience = "testpypi" if host == "test.pypi.org" else "pypi"
try:
    req_url = os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"]
    req_tok = os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]
except KeyError:
    sys.exit("::error::pypi-trusted-publishing needs 'id-token: write' on the job "
             "(ACTIONS_ID_TOKEN_REQUEST_URL is unset).")
sep = "&" if "?" in req_url else "?"
oidc_req = urllib.request.Request(req_url + sep + "audience=" + audience,
                                  headers={"Authorization": "bearer " + req_tok})
try:
    oidc = json.load(urllib.request.urlopen(oidc_req))["value"]
except Exception as exc:  # noqa: BLE001
    sys.exit("::error::could not obtain a GitHub OIDC token: %s" % exc)
mint_req = urllib.request.Request("https://%s/_/oidc/mint-token" % host,
                                  data=json.dumps({"token": oidc}).encode(),
                                  headers={"Content-Type": "application/json"})
try:
    resp = json.load(urllib.request.urlopen(mint_req))
except urllib.error.HTTPError as exc:
    body = exc.read().decode("utf-8", "replace")
    sys.exit("::error::%s rejected the OIDC token (HTTP %s) — is a Trusted Publisher "
             "configured for this repo+workflow? %s" % (host, exc.code, body))
except Exception as exc:  # noqa: BLE001
    sys.exit("::error::PyPI token mint failed: %s" % exc)
token = resp.get("token")
if not token:
    sys.exit("::error::PyPI mint-token response had no 'token': %s" % json.dumps(resp))
print(token)
PY
}

# The chart digest from `helm push` / `helm pull` output on stdin, or nothing.
helm_digest() {
  sed -nE 's/^Digest:[[:space:]]*(sha256:[0-9a-f]{64}).*$/\1/p' | tail -n 1
}

# Artifact Hub reads charts anonymously, and a new GHCR package starts out
# private: Artifact Hub then lists a repository with nothing in it, which looks
# like its bug rather than ours. Only GHCR is probed; its anonymous token
# endpoint answers 403 for a package that is not public.
warn_unless_public() {
  local registry="$1" repo="$2" version="$3" token=""
  [ "${registry}" = "ghcr.io" ] || return 0
  token="$(curl -fsS "https://ghcr.io/token?scope=repository:${repo}:pull" 2>/dev/null \
    | jq -r '.token // empty' 2>/dev/null || true)"
  if [ -n "${token}" ] && curl -fsS -o /dev/null \
      -H "Authorization: Bearer ${token}" \
      -H "Accept: application/vnd.oci.image.manifest.v1+json" \
      "https://ghcr.io/v2/${repo}/manifests/${version}" 2>/dev/null; then
    return 0
  fi
  echo "::warning::${registry}/${repo}:${version} cannot be pulled anonymously, so Artifact Hub cannot read it. Make the package public in its GitHub package settings."
}

ARTIFACTHUB_API_URL="${ARTIFACTHUB_API_URL:-https://artifacthub.io/api/v1}"

# The ID of the Artifact Hub repository whose URL is exactly $2, or nothing.
# $1 is a curl header file holding the API key.
artifacthub_find() {
  curl -fsS -G -H @"$1" "${ARTIFACTHUB_API_URL}/repositories/search" \
    --data-urlencode "kind=0" --data-urlencode "url=$2" --data-urlencode "limit=60" \
    | jq -r --arg url "$2" '[.[] | select(.url == $url) | .repository_id] | first // empty'
}

# List the chart's OCI repository ($1) on Artifact Hub as $2, unless it is listed
# already, and report its ID. Artifact Hub is a sink: when it is down or says no,
# the chart is still published, so this warns and never fails the release. The
# API key goes to curl in a header FILE, because argv is readable by every
# process on the runner.
list_on_artifacthub() {
  local url="$1" name="$2" headers response endpoint status id=""
  headers="$(mktemp)"
  response="$(mktemp)"
  chmod 600 "${headers}"
  printf 'X-API-KEY-ID: %s\nX-API-KEY-SECRET: %s\n' \
    "${ARTIFACTHUB_API_KEY_ID}" "${ARTIFACTHUB_API_KEY_SECRET}" > "${headers}"

  if ! id="$(artifacthub_find "${headers}" "${url}")"; then
    echo "::warning::could not search Artifact Hub for ${url}; the chart is published but its listing was not checked."
    rm -f "${headers}" "${response}"
    return 0
  fi
  if [ -z "${id}" ]; then
    endpoint="${ARTIFACTHUB_API_URL}/repositories/user"
    [ -n "${ARTIFACTHUB_ORG:-}" ] && endpoint="${ARTIFACTHUB_API_URL}/repositories/org/${ARTIFACTHUB_ORG}"
    status="$(jq -nc --arg name "${name}" --arg url "${url}" \
        '{kind: 0, name: $name, display_name: $name, url: $url}' \
      | curl -sS -o "${response}" -w '%{http_code}' -X POST -H @"${headers}" \
          -H 'Content-Type: application/json' --data-binary @- "${endpoint}" || true)"
    if [ "${status}" != "201" ]; then
      echo "::warning::Artifact Hub did not add ${url} as '${name}' (HTTP ${status:-none}): $(head -c 300 "${response}"). A name someone else holds needs artifacthub-repository-name."
      rm -f "${headers}" "${response}"
      return 0
    fi
    echo "Added ${url} to Artifact Hub as '${name}'."
    if ! id="$(artifacthub_find "${headers}" "${url}")"; then
      echo "::warning::added ${url} to Artifact Hub but could not read back its ID; the Artifact Hub control panel shows it."
      id=""
    fi
  fi
  rm -f "${headers}" "${response}"

  [ -n "${id}" ] || return 0
  echo "Artifact Hub repository ID: ${id}"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "artifacthub_repository_id=${id}" >> "${GITHUB_OUTPUT}"
  fi
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### Artifact Hub"
      echo "\`${url}\` is listed as repository \`${id}\`. Put \`repositoryID: ${id}\` in artifacthub-repo.yml for Verified Publisher."
    } >> "${GITHUB_STEP_SUMMARY}"
  fi
}

OWNER_LOWER="$(printf '%s' "${OWNER:-}" | tr '[:upper:]' '[:lower:]')"
BASE_DIR="${WORKING_DIRECTORY:-.}"
[ -z "${BASE_DIR}" ] && BASE_DIR="."
TARGET="${PACKAGE_PATH:-}"
IS_PRERELEASE="${IS_PRERELEASE:-false}"

case "${ECOSYSTEM:-}" in
  nuget)
    : "${TOKEN:?TOKEN is required for nuget publishing}"
    FEED="${FEED_URL:-}"
    if [ -z "${FEED}" ]; then
      if [ -z "${OWNER_LOWER}" ]; then
        echo "::error::package-feed-url is empty and the repository owner is unknown; cannot derive a GitHub Packages NuGet feed."
        exit 1
      fi
      FEED="https://nuget.pkg.github.com/${OWNER_LOWER}/index.json"
      echo "No package-feed-url set — defaulting to GitHub Packages: ${FEED}"
    fi

    PROJECT="${TARGET:-${BASE_DIR}}"
    OUT_DIR="$(mktemp -d)"

    echo "dotnet pack '${PROJECT}' → ${VERSION}"
    dotnet pack "${PROJECT}" \
      --configuration Release \
      -p:Version="${VERSION}" \
      -p:PackageVersion="${VERSION}" \
      --output "${OUT_DIR}"

    shopt -s nullglob
    PKGS=("${OUT_DIR}"/*.nupkg)
    shopt -u nullglob
    if [ "${#PKGS[@]}" -eq 0 ]; then
      echo "::error::dotnet pack produced no .nupkg files in ${OUT_DIR}. Check that '${PROJECT}' is a packable project (<IsPackable> not false)."
      exit 1
    fi

    for pkg in "${PKGS[@]}"; do
      echo "dotnet nuget push '$(basename "${pkg}")' → ${FEED}"
      # --skip-duplicate makes re-runs (or a parallel run that already
      # pushed this version) a no-op instead of a hard failure.
      dotnet nuget push "${pkg}" \
        --source "${FEED}" \
        --api-key "${TOKEN}" \
        --skip-duplicate
    done
    ;;

  pip)
    FEED="${FEED_URL:-}"          # empty → PyPI default
    USER="${USERNAME:-}"
    [ -z "${USER}" ] && USER="__token__"
    if [ "${PYPI_TRUSTED_PUBLISHING:-false}" = "true" ]; then
      # Tokenless: mint a short-lived token from the workflow's OIDC identity.
      # Only public PyPI / TestPyPI expose the mint endpoint we target; private
      # indexes must keep using package-token.
      case "${FEED}" in
        "")                                MINT_HOST="pypi.org" ;;
        *test.pypi.org*)                   MINT_HOST="test.pypi.org" ;;
        https://pypi.org*|*upload.pypi.org*) MINT_HOST="pypi.org" ;;
        *)
          echo "::error::pypi-trusted-publishing is only supported for public PyPI / TestPyPI, not '${FEED}'. Use package-token for private indexes."
          exit 1
          ;;
      esac
      echo "Minting a short-lived ${MINT_HOST} token via GitHub OIDC (trusted publishing)…"
      if ! TOKEN="$(mint_pypi_token "${MINT_HOST}")"; then
        exit 1
      fi
      echo "::add-mask::${TOKEN}"
      USER="__token__"
    else
      : "${TOKEN:?TOKEN is required for pip publishing (set pypi-trusted-publishing: true to mint one via GitHub OIDC for public PyPI instead).}"
    fi
    SRC_DIR="${TARGET:-${BASE_DIR}}"
    # Build into a fresh temp dir (not ${SRC_DIR}/dist) so only this run's
    # artifacts are uploaded — a pre-existing/checked-in dist/ would otherwise
    # get swept up by the glob below. Mirrors the nuget path's mktemp -d.
    DIST_DIR="$(mktemp -d)/dist"

    echo "python -m build '${SRC_DIR}'"
    python -m pip install --upgrade build twine >/dev/null
    # The built version comes from the project metadata (pyproject.toml /
    # setup.py). semantic-release-python bumps and commits that before this
    # step, so the build matches VERSION; with other tools, persist VERSION
    # into the project (e.g. the action's `version-file` input) first.
    python -m build --outdir "${DIST_DIR}" "${SRC_DIR}"

    shopt -s nullglob
    DISTS=("${DIST_DIR}"/*)
    shopt -u nullglob
    if [ "${#DISTS[@]}" -eq 0 ]; then
      echo "::error::python -m build produced no artifacts in ${DIST_DIR}."
      exit 1
    fi

    UPLOAD_ARGS=(upload --non-interactive --skip-existing)
    if [ -n "${FEED}" ]; then
      UPLOAD_ARGS+=(--repository-url "${FEED}")
      echo "twine upload → ${FEED}"
    else
      echo "twine upload → PyPI"
    fi
    UPLOAD_ARGS+=("${DISTS[@]}")
    # Credentials via env so they never appear in argv/process listings.
    TWINE_USERNAME="${USER}" TWINE_PASSWORD="${TOKEN}" \
      python -m twine "${UPLOAD_ARGS[@]}"
    ;;

  npm)
    : "${TOKEN:?TOKEN is required for npm publishing}"
    FEED="${FEED_URL:-}"
    [ -z "${FEED}" ] && FEED="https://registry.npmjs.org"
    NPM_PROVENANCE="${NPM_PROVENANCE:-false}"
    if [ "${NPM_PROVENANCE}" = "true" ]; then
      # Provenance attestations are only accepted by the public npm registry.
      case "${FEED}" in
        https://registry.npmjs.org|https://registry.npmjs.org/) : ;;
        *)
          echo "::error::npm-provenance is only supported when publishing to the public npm registry (registry.npmjs.org), not '${FEED}'."
          exit 1
          ;;
      esac
      # The npm CLI signs the attestation with the job's OIDC identity.
      if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
        echo "::error::npm-provenance needs 'id-token: write' on the job (ACTIONS_ID_TOKEN_REQUEST_URL is unset)."
        exit 1
      fi
    fi
    PKG_DIR="${TARGET:-${BASE_DIR}}"
    # Accept a package.json path as well as a directory.
    if [ -f "${PKG_DIR}" ]; then
      PKG_DIR="$(dirname "${PKG_DIR}")"
    fi
    cd "${PKG_DIR}" || { echo "::error::npm package directory '${PKG_DIR}' not found."; exit 1; }

    # Strip the scheme to the //host/path form npm uses for _authToken, and
    # drop any trailing slash so the key matches the registry npm computes.
    REG_KEY="$(printf '%s' "${FEED}" | sed -E 's#^[a-zA-Z]+:##; s#/+$##')"
    # Write auth to a throwaway userconfig outside the working tree (removed on
    # exit) instead of appending it to a .npmrc in the package dir — the latter
    # leaves the token on disk in the checkout and could clobber an existing
    # .npmrc.
    NPMRC="$(mktemp)"
    trap 'rm -f "${NPMRC}"' EXIT
    {
      echo "registry=${FEED}"
      echo "${REG_KEY}/:_authToken=${TOKEN}"
    } > "${NPMRC}"
    export npm_config_userconfig="${NPMRC}"

    # Align package.json with the released version (no-op if already there).
    npm version "${VERSION}" --no-git-tag-version --allow-same-version >/dev/null

    PUBLISH_ARGS=(publish --registry "${FEED}")
    if [ "${NPM_PROVENANCE}" = "true" ]; then
      PUBLISH_ARGS+=(--provenance)
      echo "npm provenance: on (--provenance)"
    fi
    if [ "${IS_PRERELEASE}" = "true" ]; then
      # Keep prereleases off the default `latest` dist-tag so consumers don't
      # pick them up implicitly. Use the environment's prerelease identifier
      # (dev, rc, …) as the tag, falling back to `next`.
      DIST_TAG="${PRERELEASE_IDENTIFIER:-next}"
      [ -z "${DIST_TAG}" ] && DIST_TAG="next"
      PUBLISH_ARGS+=(--tag "${DIST_TAG}")
      echo "npm publish → ${FEED} (dist-tag: ${DIST_TAG})"
    else
      echo "npm publish → ${FEED} (dist-tag: latest)"
    fi
    # npm publish errors if the version already exists; tolerate that so re-runs
    # are idempotent like the nuget/twine paths.
    run_publish 'cannot publish over|previously published|EPUBLISHCONFLICT' \
      npm "${PUBLISH_ARGS[@]}"
    ;;

  maven)
    : "${TOKEN:?TOKEN is required for maven publishing}"
    POM="${TARGET:-${BASE_DIR}}"
    [ -d "${POM}" ] && POM="${POM%/}/pom.xml"
    if [ ! -f "${POM}" ]; then
      echo "::error::maven: no pom.xml at '${POM}'. Point package-path at the project dir or its pom.xml."
      exit 1
    fi
    FEED="${FEED_URL:-}"
    if [ -z "${FEED}" ]; then
      if [ -z "${REPOSITORY:-}" ]; then
        echo "::error::package-feed-url is empty and the repository (owner/repo) is unknown; cannot derive a GitHub Packages Maven feed."
        exit 1
      fi
      FEED="https://maven.pkg.github.com/${REPOSITORY}"
      echo "No package-feed-url set — defaulting to GitHub Packages: ${FEED}"
    fi
    # Per-run settings.xml with the feed credentials (server id 'github' matches
    # the altDeploymentRepository id below). Written outside the project tree and
    # removed on exit so the token isn't left on disk.
    SETTINGS="$(mktemp)"
    trap 'rm -f "${SETTINGS}"' EXIT
    cat > "${SETTINGS}" <<XML
<settings>
  <servers>
    <server>
      <id>github</id>
      <username>${USERNAME:-x-access-token}</username>
      <password>${TOKEN}</password>
    </server>
  </servers>
</settings>
XML
    echo "mvn deploy '${POM}' → ${FEED} (version ${VERSION})"
    mvn --batch-mode --no-transfer-progress -f "${POM}" \
      versions:set -DnewVersion="${VERSION}" -DgenerateBackupPoms=false
    # altDeploymentRepository in the 'id::url' form (Maven 3.9+, the runner default).
    run_publish '409|status code: ?409|already exists|cannot be deployed|Conflict' \
      mvn --batch-mode --no-transfer-progress -f "${POM}" --settings "${SETTINGS}" \
        -DskipTests -DaltDeploymentRepository="github::${FEED}" deploy
    ;;

  gradle)
    : "${TOKEN:?TOKEN is required for gradle publishing}"
    PROJECT_DIR="${TARGET:-${BASE_DIR}}"
    [ -f "${PROJECT_DIR}" ] && PROJECT_DIR="$(dirname "${PROJECT_DIR}")"
    cd "${PROJECT_DIR}" || { echo "::error::gradle project dir '${PROJECT_DIR}' not found."; exit 1; }
    GRADLE_BIN="gradle"
    [ -x ./gradlew ] && GRADLE_BIN="./gradlew"
    # Gradle publishing is defined by the project's maven-publish block. Pass the
    # version (-Pversion) and the credentials the GitHubPackages repository
    # conventionally reads — GITHUB_ACTOR/GITHUB_TOKEN and the gpr.* project
    # properties — via env so they never reach argv.
    echo "${GRADLE_BIN} publish (version ${VERSION}) → ${FEED_URL:-GitHub Packages (maven)}"
    run_publish '409|Conflict|already exists|received status code 409' \
      env GITHUB_ACTOR="${USERNAME:-x-access-token}" GITHUB_TOKEN="${TOKEN}" \
          ORG_GRADLE_PROJECT_gprUser="${USERNAME:-x-access-token}" \
          ORG_GRADLE_PROJECT_gprToken="${TOKEN}" \
          ORG_GRADLE_PROJECT_githubToken="${TOKEN}" \
        "${GRADLE_BIN}" --no-daemon publish -Pversion="${VERSION}"
    ;;

  rubygems)
    : "${TOKEN:?TOKEN is required for rubygems publishing}"
    FEED="${FEED_URL:-}"
    if [ -z "${FEED}" ]; then
      if [ -z "${OWNER_LOWER}" ]; then
        echo "::error::package-feed-url is empty and the repository owner is unknown; cannot derive a GitHub Packages RubyGems host."
        exit 1
      fi
      FEED="https://rubygems.pkg.github.com/${OWNER_LOWER}"
      echo "No package-feed-url set — defaulting to GitHub Packages: ${FEED}"
    fi
    SRC_DIR="${TARGET:-${BASE_DIR}}"
    [ -f "${SRC_DIR}" ] && SRC_DIR="$(dirname "${SRC_DIR}")"
    cd "${SRC_DIR}" || { echo "::error::rubygems project dir '${SRC_DIR}' not found."; exit 1; }
    shopt -s nullglob
    GEMSPECS=(*.gemspec)
    shopt -u nullglob
    if [ "${#GEMSPECS[@]}" -eq 0 ]; then
      echo "::error::rubygems: no .gemspec in '${SRC_DIR}'. The gemspec must carry the released version."
      exit 1
    fi
    GEM_OUT="$(mktemp -d)"
    for spec in "${GEMSPECS[@]}"; do
      echo "gem build '${spec}'"
      gem build "${spec}" --output "${GEM_OUT}/$(basename "${spec%.gemspec}").gem"
    done
    for gem in "${GEM_OUT}"/*.gem; do
      echo "gem push '$(basename "${gem}")' → ${FEED}"
      # API key via env (off argv); 'Bearer <token>' is what GitHub Packages wants.
      run_publish 'already exists|already been pushed|conflict|status: ?422' \
        env GEM_HOST_API_KEY="Bearer ${TOKEN}" gem push --host "${FEED}" "${gem}"
    done
    ;;

  container)
    : "${TOKEN:?TOKEN is required for container publishing}"
    REGISTRY="${FEED_URL:-ghcr.io}"
    REGISTRY="${REGISTRY#http://}"; REGISTRY="${REGISTRY#https://}"; REGISTRY="${REGISTRY%/}"
    IMAGE_NAME="${PACKAGE_NAME:-}"
    [ -z "${IMAGE_NAME}" ] && IMAGE_NAME="$(printf '%s' "${REPOSITORY:-${OWNER_LOWER}}" | tr '[:upper:]' '[:lower:]')"
    if [ -z "${IMAGE_NAME}" ]; then
      echo "::error::container: cannot determine the image name. Set package-name (or provide the repository)."
      exit 1
    fi
    CONTEXT="${TARGET:-${BASE_DIR}}"
    IMAGE_REF="${REGISTRY}/${IMAGE_NAME}:${VERSION}"
    echo "docker login ${REGISTRY}"
    printf '%s' "${TOKEN}" | docker login "${REGISTRY}" --username "${USERNAME:-x-access-token}" --password-stdin
    echo "docker build + push → ${IMAGE_REF}"
    docker build --tag "${IMAGE_REF}" "${CONTEXT}"
    # docker push overwrites a mutable tag, so a re-run is naturally idempotent.
    docker push "${IMAGE_REF}"
    ;;

  s3)
    # A built artifact to an S3 object store, under a VERSION-SCOPED, IMMUTABLE key.
    #
    # Unlike the language ecosystems above, there is no pack step: the artifact is whatever
    # PACKAGE_PATH points at, already built by the caller. That is the point — a Lambda zip, a
    # signed binary, a firmware image and a tarball are all the same thing to a bucket, and
    # inventing a pack convention per artifact type is how this stops being reusable.
    #
    # AUTH IS OIDC, never a long-lived key, matching PYPI_TRUSTED_PUBLISHING above:
    # AWS_ROLE_TO_ASSUME is assumed from the workflow's own GitHub identity, so the publishing
    # repo holds no AWS credential at all and the role's trust policy is what decides who may
    # publish. Needs `id-token: write` on the job.
    #
    # IDEMPOTENT BY REFUSAL, which is deliberately stricter than the others. nuget skips
    # duplicates and docker overwrites a mutable tag; here an existing key means the version
    # was already published, and silently overwriting it would swap the bytes under a version
    # someone has already reviewed and pinned. A re-run is a no-op that reports success.
    : "${FEED_URL:?FEED_URL is required for s3 publishing (e.g. s3://my-bucket/edge)}"
    : "${AWS_ROLE_TO_ASSUME:?AWS_ROLE_TO_ASSUME is required for s3 publishing}"

    ARTIFACT="${TARGET:-${BASE_DIR}}"
    if [ ! -f "${ARTIFACT}" ]; then
      echo "::error::s3: package-path must be the built artifact FILE. Not a file: ${ARTIFACT}"
      exit 1
    fi

    DEST="${FEED_URL#s3://}"; DEST="${DEST%/}"
    S3_BUCKET="${DEST%%/*}"
    S3_PREFIX=""
    [ "${DEST}" != "${S3_BUCKET}" ] && S3_PREFIX="${DEST#*/}/"
    # Derive the extension from the basename only: a path like `build.out/myapp` would
    # otherwise strip to `out/myapp`, embedding a slash in the key. Omit the extension
    # entirely for extensionless artifacts (binaries, firmware images).
    BASENAME="${ARTIFACT##*/}"
    if [ "${BASENAME}" = "${BASENAME%.*}" ]; then
      S3_KEY="${S3_PREFIX}${VERSION}"
    else
      S3_KEY="${S3_PREFIX}${VERSION}.${BASENAME##*.}"
    fi

    echo "aws sts assume-role-with-web-identity → ${AWS_ROLE_TO_ASSUME}"
    # `aws-actions/configure-aws-credentials` in the caller's workflow is the supported path
    # and leaves the session in the environment; this only verifies it happened, so that a
    # missing OIDC step fails here with a sentence rather than at the upload with a 403.
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
      echo "::error::s3: no usable AWS session. Add aws-actions/configure-aws-credentials with"
      echo "::error::  role-to-assume: ${AWS_ROLE_TO_ASSUME}"
      echo "::error::before this action, and give the job 'id-token: write'."
      exit 1
    fi

    if HEAD_ERR=$(aws s3api head-object --bucket "${S3_BUCKET}" --key "${S3_KEY}" 2>&1); then
      echo "s3://${S3_BUCKET}/${S3_KEY} already published — nothing to do."
      emit_published "false"
      exit 0
    elif echo "${HEAD_ERR}" | grep -qiE "403|AccessDenied|Forbidden"; then
      echo "::error::s3: AccessDenied on s3:head-object for ${S3_KEY}."
      echo "::error::  The role must include s3:GetObject (or s3:ListBucket) alongside"
      echo "::error::  s3:PutObject so immutability can be verified before writing."
      echo "::error::  See the IAM permissions section in README."
      exit 1
    fi

    echo "aws s3api put-object → s3://${S3_BUCKET}/${S3_KEY}"
    # SHA256 checksum so a consumer can verify the object without downloading it, and so a
    # caller can compare digests to decide whether anything changed.
    aws s3api put-object \
      --bucket "${S3_BUCKET}" \
      --key "${S3_KEY}" \
      --body "${ARTIFACT}" \
      --checksum-algorithm SHA256 \
      >/dev/null
    ;;

  helm)
    # Helm chart -> an OCI registry. `helm push` is the only supported path:
    # the classic chartmuseum/index.yaml flow needs a server nobody runs any more.
    : "${TOKEN:?TOKEN is required for helm publishing}"
    REGISTRY="${FEED_URL:-ghcr.io}"
    REGISTRY="${REGISTRY#oci://}"; REGISTRY="${REGISTRY#http://}"; REGISTRY="${REGISTRY#https://}"
    REGISTRY="${REGISTRY%/}"

    CHART_DIR="${TARGET:-${BASE_DIR}}"
    [ -f "${CHART_DIR}" ] && CHART_DIR="$(dirname "${CHART_DIR}")"
    if [ ! -f "${CHART_DIR}/Chart.yaml" ]; then
      echo "::error::helm: no Chart.yaml in '${CHART_DIR}'. Point package-path at the chart directory."
      exit 1
    fi

    # OCI repository names must be lowercase, and `github.repository_owner`
    # preserves the account's display casing (e.g. CalebSargeant). helm rejects
    # that outright with "invalid reference: invalid repository", AFTER the image
    # half of a release has already published — a half-successful release that
    # reads like a flake. Lowercase it here so no caller has to know.
    REPO_PATH="${PACKAGE_NAME:-}"
    if [ -z "${REPO_PATH}" ]; then
      if [ -z "${OWNER_LOWER}" ]; then
        echo "::error::helm: package-feed-url has no path and the repository owner is unknown; cannot derive an OCI target."
        exit 1
      fi
      REPO_PATH="${OWNER_LOWER}/charts"
    fi
    REPO_PATH="$(printf '%s' "${REPO_PATH}" | tr '[:upper:]' '[:lower:]')"

    # Everything the opt-in extras need is checked HERE, before anything is
    # pushed: a misconfigured extra must not leave a chart half-published.
    case "${HELM_APP_VERSION:-version}" in
      version) APP_VERSION="${VERSION}" ;;
      tag)
        # Image promotion pushes the release TAG (tag-prefix + version, v1.4.0 by
        # default), not the bare version. A chart whose default image tag is its
        # appVersion has to carry the tag, or it points at an image nobody pushed.
        APP_VERSION="${RELEASE_TAG:-}"
        if [ -z "${APP_VERSION}" ]; then
          echo "::error::helm-app-version: tag needs the release tag, and this run has none."
          exit 1
        fi
        ;;
      chart) APP_VERSION="" ;;
      *)
        echo "::error::helm-app-version must be version, tag or chart, not '${HELM_APP_VERSION}'."
        exit 1
        ;;
    esac

    AH_KEYS=false
    if [ -n "${ARTIFACTHUB_API_KEY_ID:-}" ] && [ -n "${ARTIFACTHUB_API_KEY_SECRET:-}" ]; then
      AH_KEYS=true
      echo "::add-mask::${ARTIFACTHUB_API_KEY_SECRET}"
    elif [ -n "${ARTIFACTHUB_API_KEY_ID:-}${ARTIFACTHUB_API_KEY_SECRET:-}" ]; then
      echo "::error::artifacthub-api-key-id and artifacthub-api-key-secret go together, and only one is set."
      exit 1
    fi
    if [ -n "${ARTIFACTHUB_REPO_FILE:-}" ] && [ ! -f "${ARTIFACTHUB_REPO_FILE}" ]; then
      echo "::error::artifacthub-repo-file '${ARTIFACTHUB_REPO_FILE}' does not exist."
      exit 1
    fi

    # helm pushes a chart to <registry>/<path>/<chart name>: the repository that
    # cosign signs and Artifact Hub lists.
    CHART_NAME="$(sed -nE "s/^name:[[:space:]]*['\"]?([^'\"[:space:]#]+).*$/\1/p" "${CHART_DIR}/Chart.yaml" | head -n 1)"
    CHART_REPO="${REGISTRY}/${REPO_PATH}/${CHART_NAME}"
    if [ -z "${CHART_NAME}" ] && { [ "${HELM_SIGN:-false}" = "true" ] || [ -n "${ARTIFACTHUB_REPO_FILE:-}" ] || [ "${AH_KEYS}" = "true" ]; }; then
      echo "::error::helm: '${CHART_DIR}/Chart.yaml' has no name, so there is no chart repository to sign or list."
      exit 1
    fi
    AH_NAME="${ARTIFACTHUB_REPOSITORY_NAME:-${CHART_NAME}}"
    if [ "${AH_KEYS}" = "true" ] && ! printf '%s' "${AH_NAME}" | grep -Eq '^[a-z][a-z0-9-]*$'; then
      echo "::error::'${AH_NAME}' is not a valid Artifact Hub repository name (lowercase letters, digits and hyphens, starting with a letter). Set artifacthub-repository-name."
      exit 1
    fi

    if [ "${HELM_LINT:-false}" = "true" ]; then
      echo "helm lint '${CHART_DIR}'"
      if ! helm lint "${CHART_DIR}"; then
        echo "::error::helm lint failed for '${CHART_DIR}'; nothing was published."
        exit 1
      fi
    fi

    CHART_OUT="$(mktemp -d)"
    # --version always, and --app-version unless helm-app-version is `chart`: a
    # chart whose appVersion lags its version ships the previous image, which is
    # invisible until something is running the wrong code.
    PACKAGE_ARGS=(--version "${VERSION}")
    if [ -n "${APP_VERSION}" ]; then
      PACKAGE_ARGS+=(--app-version "${APP_VERSION}")
    fi
    echo "helm package '${CHART_DIR}' (version ${VERSION}, appVersion ${APP_VERSION:-as committed}) -> oci://${REGISTRY}/${REPO_PATH}"
    helm package "${CHART_DIR}" "${PACKAGE_ARGS[@]}" --destination "${CHART_OUT}"

    # Credentials over stdin, never argv.
    printf '%s' "${TOKEN}" | helm registry login "${REGISTRY}" \
      --username "${USERNAME:-x-access-token}" --password-stdin

    # helm prints the digest it pushed, which is what gets signed. A re-run that
    # finds the version already there prints none.
    DIGEST=""
    PUSH_LOG="$(mktemp)"
    shopt -s nullglob
    for chart in "${CHART_OUT}"/*.tgz; do
      echo "helm push '$(basename "${chart}")'"
      push_rc=0
      run_publish 'already exists|409|Conflict' \
        helm push "${chart}" "oci://${REGISTRY}/${REPO_PATH}" >"${PUSH_LOG}" 2>&1 || push_rc=$?
      cat "${PUSH_LOG}"
      [ "${push_rc}" -eq 0 ] || exit "${push_rc}"
      DIGEST="$(helm_digest < "${PUSH_LOG}")"
    done
    shopt -u nullglob
    rm -f "${PUSH_LOG}"

    if [ "${HELM_SIGN:-false}" = "true" ]; then
      if [ -z "${DIGEST}" ]; then
        # Already published: ask the registry, so a run that pushed and then
        # failed to sign can be re-run into a signed chart.
        PULL_DIR="$(mktemp -d)"
        DIGEST="$(helm pull "oci://${CHART_REPO}" --version "${VERSION}" --destination "${PULL_DIR}" 2>&1 | helm_digest || true)"
        rm -rf "${PULL_DIR}"
      fi
      if [ -z "${DIGEST}" ]; then
        echo "::error::no digest for ${CHART_REPO}:${VERSION}; the chart is published but NOT signed."
        exit 1
      fi
      printf '%s' "${TOKEN}" | cosign login "${REGISTRY}" \
        --username "${USERNAME:-x-access-token}" --password-stdin
      echo "cosign sign ${CHART_REPO}@${DIGEST}"
      cosign sign --yes "${CHART_REPO}@${DIGEST}"
    fi

    if [ -n "${ARTIFACTHUB_REPO_FILE:-}" ]; then
      printf '%s' "${TOKEN}" | oras login "${REGISTRY}" \
        --username "${USERNAME:-x-access-token}" --password-stdin
      echo "oras push ${CHART_REPO}:artifacthub.io"
      # oras records a file's path as its layer title, so push from the file's
      # own directory and name it bare.
      (
        cd "$(dirname "${ARTIFACTHUB_REPO_FILE}")"
        oras push "${CHART_REPO}:artifacthub.io" \
          --config /dev/null:application/vnd.cncf.artifacthub.config.v1+yaml \
          "$(basename "${ARTIFACTHUB_REPO_FILE}"):application/vnd.cncf.artifacthub.repository-metadata.layer.v1.yaml"
      )
    fi

    if [ -n "${ARTIFACTHUB_REPO_FILE:-}" ] || [ "${AH_KEYS}" = "true" ]; then
      warn_unless_public "${REGISTRY}" "${REPO_PATH}/${CHART_NAME}" "${VERSION}"
    fi
    if [ "${AH_KEYS}" = "true" ]; then
      list_on_artifacthub "oci://${CHART_REPO}" "${AH_NAME}"
    fi
    ;;

  '')
    echo "::error::publish-package is true but package-ecosystem is empty. Set package-ecosystem to nuget, pip, npm, maven, gradle, rubygems, container, helm, or s3."
    exit 1
    ;;

  *)
    echo "::error::Unsupported package-ecosystem '${ECOSYSTEM}'. Use nuget, pip, npm, maven, gradle, rubygems, container, helm, or s3."
    exit 1
    ;;
esac

echo "Published ${ECOSYSTEM} package version ${VERSION}."
emit_published "true"
