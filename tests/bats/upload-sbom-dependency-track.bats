#!/usr/bin/env bats

# Behaviour coverage for scripts/upload-sbom-dependency-track.sh.
#
# curl is replaced with a PATH stub that logs its argv (and the --data payload
# file) to ${STUB_LOG} and returns a configurable HTTP code, so we can assert
# the endpoint, auth header, and project envelope without a Dependency-Track
# server.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/upload-sbom-dependency-track.sh"

setup() {
  WORK=$(mktemp -d)
  BIN="${WORK}/bin"
  mkdir -p "${BIN}"
  export STUB_LOG="${WORK}/stub.log"
  : > "${STUB_LOG}"

  # curl stub: log argv; dump the --config secret header and any `-F field=@file`
  # part contents into the log; write the response body to -o; print the (stubbed)
  # HTTP code on stdout like real curl with -w '%{http_code}'.
  cat > "${BIN}/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "${STUB_LOG}"
out=""; cfg=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2; continue;;
    --config|-K) cfg="$2"; shift 2; continue;;
    -F)
      v="$2"
      case "$v" in
        *=@*) n="${v%%=@*}"; p="${v#*=@}"; p="${p%%;*}"
              [ -f "$p" ] && echo "formfile:${n}:$(cat "$p")" >> "${STUB_LOG}" ;;
      esac
      shift 2; continue;;
    *) shift;;
  esac
done
if [ -n "${out}" ]; then echo "${STUB_BODY:-ok}" > "${out}"; fi
if [ -n "${cfg}" ] && [ -f "${cfg}" ]; then sed 's/^/cfg: /' "${cfg}" >> "${STUB_LOG}"; fi
printf '%s' "${STUB_HTTP:-201}"
EOF
  chmod +x "${BIN}/curl"
  export PATH="${BIN}:${PATH}"

  BOM="${WORK}/bom.cdx.json"
  echo '{"bomFormat":"CycloneDX","specVersion":"1.5","components":[]}' > "${BOM}"
}

teardown() {
  rm -rf "${WORK}"
}

@test "no DEPENDENCY_TRACK_URL -> skips silently, exit 0, no curl" {
  run env BOM_FILE="${BOM}" PROJECT_NAME=acme/app PROJECT_VERSION=pr-1 "${SCRIPT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "skipping SBOM upload"
  [ ! -s "${STUB_LOG}" ]
}

@test "POSTs the BOM to /api/v1/bom as a multipart raw file (Chargate-compatible)" {
  run env DEPENDENCY_TRACK_URL=https://dt.example.com/ \
    DEPENDENCY_TRACK_API_KEY=dt-key \
    BOM_FILE="${BOM}" PROJECT_NAME=acme/app PROJECT_VERSION=pr-7 "${SCRIPT}"
  [ "$status" -eq 0 ]
  # POST multipart, trailing slash trimmed.
  grep -Eq 'curl .*-X POST https://dt.example.com/api/v1/bom' "${STUB_LOG}"
  grep -Fq 'X-Api-Key: dt-key' "${STUB_LOG}"
  # Project fields are form parts; the BOM is a raw file part (no base64).
  grep -Fq 'projectName=acme/app' "${STUB_LOG}"
  grep -Fq 'projectVersion=pr-7' "${STUB_LOG}"
  grep -Fq 'autoCreate=true' "${STUB_LOG}"
  grep -Eq 'bom=@.*;type=application/json' "${STUB_LOG}"
  grep -Fq 'formfile:bom:{"bomFormat":"CycloneDX"' "${STUB_LOG}"   # raw, not base64
  ! grep -Eq '"bom":"[A-Za-z0-9+/=]{12,}"' "${STUB_LOG}"
}

@test "sets an identifying User-Agent (not the default curl signature)" {
  run env DEPENDENCY_TRACK_URL=https://dt.example.com \
    DEPENDENCY_TRACK_API_KEY=dt-key BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Eq 'curl .*-A diatreme' "${STUB_LOG}"
}

@test "strips a leading UTF-8 BOM marker before upload" {
  printf '\xef\xbb\xbf{"bomFormat":"CycloneDX","components":[]}' > "${BOM}"
  run env DEPENDENCY_TRACK_URL=https://dt.example.com \
    DEPENDENCY_TRACK_API_KEY=dt-key BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 0 ]
  # The uploaded part starts cleanly at '{' — the marker was removed.
  grep -Fq 'formfile:bom:{"bomFormat":"CycloneDX"' "${STUB_LOG}"
}

@test "missing BOM file is non-blocking (warn, exit 0)" {
  run env DEPENDENCY_TRACK_URL=https://dt.example.com \
    DEPENDENCY_TRACK_API_KEY=dt-key \
    BOM_FILE="${WORK}/nope.json" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "missing or empty"
}

@test "missing BOM file under STRICT fails the gate (exit 1)" {
  run env STRICT=true DEPENDENCY_TRACK_URL=https://dt.example.com \
    DEPENDENCY_TRACK_API_KEY=dt-key \
    BOM_FILE="${WORK}/nope.json" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "::error::Dependency-Track"
}

@test "a 500 from the server is non-blocking by default (warn, exit 0)" {
  run env STUB_HTTP=500 DEPENDENCY_TRACK_URL=https://dt.example.com \
    DEPENDENCY_TRACK_API_KEY=dt-key \
    BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "HTTP 500"
  echo "$output" | grep -Fq "non-blocking"
}

@test "a 500 under STRICT fails the gate (exit 1)" {
  run env STUB_HTTP=500 STRICT=true DEPENDENCY_TRACK_URL=https://dt.example.com \
    DEPENDENCY_TRACK_API_KEY=dt-key \
    BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 1 ]
}

@test "URL set but API key missing -> exit 1 (misconfig)" {
  run env DEPENDENCY_TRACK_URL=https://dt.example.com \
    BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 1 ]
}

@test "the API key is passed off curl argv via a --config file" {
  run env DEPENDENCY_TRACK_URL=https://dt.example.com \
    DEPENDENCY_TRACK_API_KEY=dt-key BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 0 ]
  # Key arrives via the config file, never on the curl command line.
  grep -Fq 'cfg: header = "X-Api-Key: dt-key"' "${STUB_LOG}"
  ! grep -Eq 'curl .*X-Api-Key' "${STUB_LOG}"
}

@test "a non-boolean AUTO_CREATE is an actionable error, not a generic payload failure" {
  run env DEPENDENCY_TRACK_URL=https://dt.example.com STRICT=true \
    DEPENDENCY_TRACK_API_KEY=dt-key AUTO_CREATE=yes \
    BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq "AUTO_CREATE must be 'true' or 'false'"
}

@test "a non-https URL warns about cleartext (still uploads)" {
  run env DEPENDENCY_TRACK_URL=http://dt.example.com \
    DEPENDENCY_TRACK_API_KEY=dt-key BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "not https"
  grep -Eq 'curl .*-X POST http://dt.example.com/api/v1/bom' "${STUB_LOG}"
}

# ── CycloneDX spec ceiling ──────────────────────────────────────────────────
# Dependency-Track rejects a spec it does not know outright ("Unrecognized
# specVersion 1.7"), and Trivy emits the newest spec its build knows with no flag
# to choose one. So a routine Trivy bump silently outruns the server: every
# released image 400'd while the DefectDojo half of the same scan imported fine,
# and because the sink is failure-isolated nothing went red — the projects were
# created empty and stayed that way.

_bom_spec() {
  # The specVersion actually handed to curl. Matches compact or pretty JSON, and
  # scans the whole log because a rewritten body may span lines.
  grep -o '"specVersion"[[:space:]]*:[[:space:]]*"[^"]*"' "${STUB_LOG}" \
    | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
}

@test "a BOM newer than the server's ceiling is relabelled before upload" {
  printf '{"bomFormat":"CycloneDX","specVersion":"1.7","components":[]}' > "${BOM}"
  run env DEPENDENCY_TRACK_URL=https://dt.example.com \
    DEPENDENCY_TRACK_API_KEY=dt-key BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(_bom_spec)" = "1.6" ]
  echo "$output" | grep -Fq "relabelling for upload"
}

@test "the \$schema is relabelled with the specVersion, not left contradicting it" {
  printf '{"$schema":"http://cyclonedx.org/schema/bom-1.7.schema.json","bomFormat":"CycloneDX","specVersion":"1.7","components":[]}' > "${BOM}"
  run env DEPENDENCY_TRACK_URL=https://dt.example.com \
    DEPENDENCY_TRACK_API_KEY=dt-key BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq 'bom-1.6.schema.json' "${STUB_LOG}"
  ! grep -Fq 'bom-1.7.schema.json' "${STUB_LOG}"
}

@test "a BOM at the ceiling is uploaded untouched" {
  printf '{"bomFormat":"CycloneDX","specVersion":"1.6","components":[]}' > "${BOM}"
  run env DEPENDENCY_TRACK_URL=https://dt.example.com \
    DEPENDENCY_TRACK_API_KEY=dt-key BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(_bom_spec)" = "1.6" ]
  ! echo "$output" | grep -Fq "relabelling"
}

@test "an OLDER BOM is never relabelled upward" {
  # The server accepts everything up to the ceiling. Rewriting 1.4 to 1.6 would
  # claim fields the document does not have, for no benefit.
  printf '{"bomFormat":"CycloneDX","specVersion":"1.4","components":[]}' > "${BOM}"
  run env DEPENDENCY_TRACK_URL=https://dt.example.com \
    DEPENDENCY_TRACK_API_KEY=dt-key BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(_bom_spec)" = "1.4" ]
}

@test "the ceiling moves with DT_MAX_CYCLONEDX_SPEC, so a server upgrade needs no code change" {
  printf '{"bomFormat":"CycloneDX","specVersion":"1.7","components":[]}' > "${BOM}"
  run env DEPENDENCY_TRACK_URL=https://dt.example.com DT_MAX_CYCLONEDX_SPEC=1.7 \
    DEPENDENCY_TRACK_API_KEY=dt-key BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(_bom_spec)" = "1.7" ]
  ! echo "$output" | grep -Fq "relabelling"
}

@test "version comparison is numeric, not lexical (1.10 is newer than 1.6)" {
  # A string compare would call 1.10 older than 1.6 and upload it unchanged.
  printf '{"bomFormat":"CycloneDX","specVersion":"1.10","components":[]}' > "${BOM}"
  run env DEPENDENCY_TRACK_URL=https://dt.example.com \
    DEPENDENCY_TRACK_API_KEY=dt-key BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$(_bom_spec)" = "1.6" ]
}

@test "a BOM with no specVersion is uploaded as-is, not mangled" {
  printf '{"bomFormat":"CycloneDX","components":[]}' > "${BOM}"
  run env DEPENDENCY_TRACK_URL=https://dt.example.com \
    DEPENDENCY_TRACK_API_KEY=dt-key BOM_FILE="${BOM}" PROJECT_NAME=a PROJECT_VERSION=v "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -Fq 'formfile:bom:{"bomFormat":"CycloneDX","components":[]}' "${STUB_LOG}"
}
