#!/usr/bin/env bash
# A `gh` stub with just enough GitHub in it for the deploy PR scripts:
# branches, file contents at a ref, open pull requests, and the writes the
# scripts make. Loaded by the deploy-pr suites with `load deploy-pr-stub`.
#
# State lives under ${STATE}:
#   refs/<branch>              a branch that exists; its content is the sha
#                              (`/` in a branch name is stored as `__`)
#   files/<path>               a file at every ref
#   files@<ref>/<path>         a file at one ref, taking precedence
#   prs.json                   what `gh pr list` returns (open PRs)
#   pr.json                    what `gh api .../pulls/<n>` returns
#   pr-files.json              what `gh api .../pulls/<n>/files` returns
#   compare.json               what `gh api .../compare/...` returns
#   commit.json                what `gh api .../commits/<sha>` returns
# Every call is appended to ${STATE}/calls.log; the body of the contents PUT
# is kept as ${STATE}/put.json, and a created PR's body as ${STATE}/body.md.
# STUB_PR_URL is what `gh pr create` prints.

deploy_pr_stub_setup() {
  STATE="${BATS_TEST_TMPDIR}/gh-state"
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${STATE}/refs" "${STATE}/files" "${STUB_BIN}"
  echo '[]' > "${STATE}/prs.json"
  : > "${STATE}/calls.log"
  export STATE
  export STUB_PR_URL="https://ghe.example/octo/app/pull/42"

  cat > "${STUB_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
echo "gh $*" >> "${STATE}/calls.log"

refkey() { printf '%s' "$1" | sed 's#/#__#g'; }

respond() {  # respond JSON [jq-expr]
  if [ -n "${2:-}" ]; then printf '%s' "$1" | jq -r "$2"; else printf '%s\n' "$1"; fi
}

file_at() {  # file_at REF PATH -> prints content, or fails
  if [ -f "${STATE}/files@$1/$2" ]; then cat "${STATE}/files@$1/$2"
  elif [ -f "${STATE}/files/$2" ]; then cat "${STATE}/files/$2"
  else return 1
  fi
}

case "$1 ${2:-}" in
  "pr list")
    cat "${STATE}/prs.json"; exit 0 ;;
  "pr create")
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in --body-file) cp "$2" "${STATE}/body.md"; shift 2 ;; *) shift ;; esac
    done
    echo "${STUB_PR_URL}"; exit 0 ;;
  "pr edit")
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in --body-file) cp "$2" "${STATE}/edit-body.md"; shift 2 ;; *) shift ;; esac
    done
    exit 0 ;;
  "pr close")
    exit 0 ;;
esac

[ "$1" = "api" ] || { echo "stub: unexpected gh $*" >&2; exit 9; }
shift
method=GET endpoint="" jqexpr="" input=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X|--method) method="$2"; shift 2 ;;
    --jq) jqexpr="$2"; shift 2 ;;
    --input) input="$2"; shift 2 ;;
    -f|-F) shift 2 ;;
    --paginate) shift ;;
    *) [ -n "${endpoint}" ] || endpoint="$1"; shift ;;
  esac
done
path="${endpoint%%\?*}"
query=""
case "${endpoint}" in *\?*) query="${endpoint#*\?}" ;; esac
ref=$(printf '%s' "${query}" | sed -n 's/.*ref=\([^&]*\).*/\1/p')

case "${method} ${path}" in
  "GET repos/"*"/git/ref/heads/"*)
    branch="${path#*/git/ref/heads/}"
    f="${STATE}/refs/$(refkey "${branch}")"
    [ -f "${f}" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
    respond "{\"object\":{\"sha\":\"$(cat "${f}")\"}}" "${jqexpr}" ;;
  "POST repos/"*"/git/refs")
    printf '%s\n' "${method} ${path}" >> "${STATE}/writes.log"; exit 0 ;;
  "DELETE repos/"*"/git/refs/heads/"*)
    printf '%s\n' "${method} ${path}" >> "${STATE}/writes.log"; exit 0 ;;
  "PUT repos/"*"/contents/"*)
    cp "${input}" "${STATE}/put.json"
    printf '%s\n' "${method} ${path}" >> "${STATE}/writes.log"; exit 0 ;;
  "GET repos/"*"/contents/"*)
    file="${path#*/contents/}"
    content=$(file_at "${ref}" "${file}") || { echo "HTTP 404: Not Found" >&2; exit 1; }
    b64=$(printf '%s\n' "${content}" | base64 | tr -d '\n')
    respond "{\"sha\":\"blob-$(printf '%s' "${ref}")\",\"content\":\"${b64}\"}" "${jqexpr}" ;;
  "GET repos/"*"/pulls/"*"/files")
    respond "$(cat "${STATE}/pr-files.json")" "${jqexpr}" ;;
  "GET repos/"*"/pulls/"*)
    respond "$(cat "${STATE}/pr.json")" "${jqexpr}" ;;
  "GET repos/"*"/compare/"*)
    [ -f "${STATE}/compare.json" ] || { echo "HTTP 404" >&2; exit 1; }
    respond "$(cat "${STATE}/compare.json")" "${jqexpr}" ;;
  "GET repos/"*"/commits/"*)
    respond "$(cat "${STATE}/commit.json")" "${jqexpr}" ;;
  *)
    echo "stub: unexpected gh api ${method} ${endpoint}" >&2; exit 9 ;;
esac
STUB
  chmod +x "${STUB_BIN}/gh"
  export PATH="${STUB_BIN}:${PATH}"
}

# branch NAME SHA: make a branch exist.
stub_branch() { printf '%s' "$2" > "${STATE}/refs/$(printf '%s' "$1" | sed 's#/#__#g')"; }

# stub_file PATH [REF]: file content from stdin, at every ref or at one.
stub_file() {
  local dir="${STATE}/files"
  [ -z "${2:-}" ] || dir="${STATE}/files@$2"
  mkdir -p "${dir}/$(dirname "$1")"
  cat > "${dir}/$1"
}

# The file the contents PUT would have committed.
put_content() { jq -r '.content' "${STATE}/put.json" | base64 --decode; }

output_of() { grep -E "^$1=" "${GITHUB_OUTPUT}" | tail -n 1 | cut -d= -f2-; }
