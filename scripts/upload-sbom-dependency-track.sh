#!/usr/bin/env bash
# Upload a CycloneDX SBOM to a Dependency-Track server.
#
# Called by scripts/scan-image.sh (the "Scan image and report" step in
# action.yml, mode: ci) once per assembled image. Dependency-Track is the
# SBOM/component sink for the Magma Moose pipeline: it ingests the CycloneDX
# BOM and re-derives component CVEs itself, so a plain component inventory is
# enough — we never push "findings" here (that is DefectDojo's job).
#
# This is the *assembled-image* SBOM project, deliberately distinct from the
# *source-dependency* SBOM that Chargate pushes for the same repo. They are two
# projects on one server: the source SBOM only sees declared dependencies, the
# image SBOM also sees base-image packages and anything the Dockerfile added.
#
# Wire format mirrors Chargate's known-working client: POST /api/v1/bom
# multipart/form-data with the BOM as a raw file part (no base64 — friendlier to
# reverse proxies), a leading UTF-8 BOM marker stripped, and an identifying
# User-Agent so edge WAFs don't ban the default "curl/X.Y" signature.
#
# Failure-isolated by default (rule: any reporting backend can be down without
# failing the PR gate). A DT outage logs a ::warning:: and exits 0; set
# STRICT=true to make upload failure fatal.
#
# Required env:
#   DEPENDENCY_TRACK_URL      - DT base URL, e.g. https://dtrack.example.com
#                               (no trailing /api). Empty → skip silently.
#   DEPENDENCY_TRACK_API_KEY  - DT API key with BOM_UPLOAD (+ PROJECT_CREATION_UPLOAD
#                               when AUTO_CREATE is true).
#   BOM_FILE                  - path to the CycloneDX JSON to upload.
#   PROJECT_NAME              - DT project name (the assembled-image project).
#   PROJECT_VERSION           - DT project version (e.g. the pr-<N> tag).
#
# Optional env:
#   AUTO_CREATE   - true | false. Create the project on first upload. Default true.
#   DT_USER_AGENT - override the request User-Agent.
#   STRICT        - true | false. Treat an upload error as fatal. Default false.
#
# Side effects:
#   - Masks DEPENDENCY_TRACK_API_KEY in the workflow log.
#
# Exit codes:
#   0 - uploaded, skipped (no URL), or upload failed while not STRICT
#   1 - misconfiguration, or upload failed while STRICT=true

set -euo pipefail

DT_URL="${DEPENDENCY_TRACK_URL:-}"
STRICT="${STRICT:-false}"

# No server configured → this sink is simply off. Not an error.
if [ -z "${DT_URL}" ]; then
  echo "Dependency-Track: no DEPENDENCY_TRACK_URL set — skipping SBOM upload."
  exit 0
fi

if [ -n "${DEPENDENCY_TRACK_API_KEY:-}" ]; then
  echo "::add-mask::${DEPENDENCY_TRACK_API_KEY}"
fi

# Treat an upload problem as failure-isolated (warn + exit 0) unless STRICT.
sink_fail() {
  if [ "${STRICT}" = "true" ]; then
    echo "::error::Dependency-Track: $1"
    exit 1
  fi
  echo "::warning::Dependency-Track: $1 (sink failure is non-blocking; set STRICT=true to fail the gate)."
  exit 0
}

: "${DEPENDENCY_TRACK_API_KEY:?DEPENDENCY_TRACK_API_KEY is required when DEPENDENCY_TRACK_URL is set}"
: "${PROJECT_NAME:?PROJECT_NAME is required}"
: "${PROJECT_VERSION:?PROJECT_VERSION is required}"

if [ ! -s "${BOM_FILE:-}" ]; then
  sink_fail "BOM_FILE '${BOM_FILE:-}' is missing or empty — nothing to upload"
fi

# Trim a trailing slash so we build a clean /api/v1/bom path.
DT_URL="${DT_URL%/}"
ENDPOINT="${DT_URL}/api/v1/bom"
# Identify ourselves instead of the default "curl/X.Y", which edge WAFs (e.g.
# Cloudflare Bot Fight Mode / error 1010) commonly ban by client signature.
# Mirrors Chargate's Dependency-Track client.
USER_AGENT="${DT_USER_AGENT:-diatreme (+https://github.com/MagmaMoose/diatreme)}"

# A plaintext endpoint would put the API key on the wire in the clear.
case "${DT_URL}" in
  https://*) ;;
  *) echo "::warning::Dependency-Track URL is not https (${DT_URL}) — the API key will be sent in cleartext." ;;
esac

AUTO_CREATE="${AUTO_CREATE:-true}"
case "${AUTO_CREATE}" in
  true|false) ;;
  *) sink_fail "AUTO_CREATE must be 'true' or 'false', got '${AUTO_CREATE}'" ;;
esac

# A leading UTF-8 BOM marker trips Dependency-Track's parser; strip it before
# upload (mirrors the official gh-upload-sbom action and Chargate's client).
UPLOAD_BOM="${BOM_FILE}"
STRIPPED=""
if [ "$(head -c 3 "${BOM_FILE}" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
  STRIPPED="$(mktemp)"
  tail -c +4 "${BOM_FILE}" > "${STRIPPED}"
  UPLOAD_BOM="${STRIPPED}"
fi

# Dependency-Track rejects a CycloneDX spec it does not recognise outright:
#
#   HTTP 400 {"title":"The uploaded BOM is invalid","detail":"Unrecognized specVersion 1.7"}
#
# Trivy emits the newest spec its build knows and has NO flag to choose one, so a
# routine Trivy bump silently outruns the server: 4.14.2 accepts up to 1.6, Trivy
# 0.71 already writes 1.7. Every released image failed this way while the DefectDojo
# half of the same scan imported fine, which is what made it look like a
# Dependency-Track fault rather than a spec mismatch. The sink is failure-isolated,
# so nothing went red — the projects were simply created empty and stayed that way.
#
# Relabel to the ceiling rather than pinning Trivy: a security scanner must stay
# current, and its CycloneDX output has so far been backward-compatible in
# substance (verified end to end against 4.14.2 — a relabelled Trivy BOM ingests
# its components normally). Nothing is dropped or rewritten but the version claim;
# if a future spec genuinely is incompatible the server rejects it exactly as it
# does today, which is no worse than the status quo.
#
# Raise DT_MAX_CYCLONEDX_SPEC when the server learns a newer spec, and delete this
# block once the floor supports whatever Trivy emits.
DOWNGRADED=""
DT_MAX_SPEC="${DT_MAX_CYCLONEDX_SPEC:-1.6}"
BOM_SPEC="$(jq -r '.specVersion // empty' "${UPLOAD_BOM}" 2>/dev/null || true)"
if [ -n "${BOM_SPEC}" ] && [ "${BOM_SPEC}" != "${DT_MAX_SPEC}" ] &&
   [ "$(printf '%s\n%s\n' "${BOM_SPEC}" "${DT_MAX_SPEC}" | sort -V | tail -1)" != "${DT_MAX_SPEC}" ]; then
  DOWNGRADED="$(mktemp)"
  if jq -c --arg v "${DT_MAX_SPEC}" \
       '.specVersion = $v
        | if has("$schema")
          then .["$schema"] = "http://cyclonedx.org/schema/bom-\($v).schema.json"
          else . end' \
       "${UPLOAD_BOM}" > "${DOWNGRADED}" 2>/dev/null && [ -s "${DOWNGRADED}" ]; then
    echo "Dependency-Track: BOM declares CycloneDX ${BOM_SPEC}; the server accepts up to ${DT_MAX_SPEC} — relabelling for upload."
    UPLOAD_BOM="${DOWNGRADED}"
  else
    # Leave it alone and let the server decide. A failed rewrite must not turn a
    # possibly-acceptable BOM into no upload at all.
    echo "::warning::Dependency-Track: could not relabel CycloneDX ${BOM_SPEC} to ${DT_MAX_SPEC}; uploading as-is."
    rm -f "${DOWNGRADED}"
    DOWNGRADED=""
  fi
fi

BODY="$(mktemp)"
ERR="$(mktemp)"
# Keep the API key off curl's argv (it would be world-readable via the process
# table on a persistent/multi-tenant self-hosted runner). curl reads it from a
# --config file with 0600 perms instead.
CURL_CFG="$(mktemp)"
chmod 600 "${CURL_CFG}"
trap 'rm -f "${BODY}" "${ERR}" "${CURL_CFG}" "${STRIPPED}" "${DOWNGRADED}"' EXIT
printf 'header = "X-Api-Key: %s"\n' "${DEPENDENCY_TRACK_API_KEY}" > "${CURL_CFG}"

echo "Dependency-Track: uploading image SBOM → project '${PROJECT_NAME}' @ '${PROJECT_VERSION}' (${ENDPOINT})"

# POST /api/v1/bom multipart with the BOM as a raw file part (no base64) — the
# reverse-proxy-friendly upload path Chargate uses against the same servers.
# autoCreate needs PROJECT_CREATION_UPLOAD on the API key.
HTTP_CODE="$(curl -sS --config "${CURL_CFG}" -o "${BODY}" -w '%{http_code}' \
  -X POST "${ENDPOINT}" \
  -A "${USER_AGENT}" \
  -H 'Accept: application/json' \
  -F "projectName=${PROJECT_NAME}" \
  -F "projectVersion=${PROJECT_VERSION}" \
  -F "autoCreate=${AUTO_CREATE}" \
  -F "bom=@${UPLOAD_BOM};type=application/json" \
  2>"${ERR}" || true)"

if ! printf '%s' "${HTTP_CODE}" | grep -qE '^2[0-9][0-9]$'; then
  cat "${ERR}" >&2 || true
  head -c 500 "${BODY}" >&2 2>/dev/null || true
  sink_fail "upload returned HTTP ${HTTP_CODE:-000}"
fi

echo "Dependency-Track: SBOM accepted (HTTP ${HTTP_CODE})."
