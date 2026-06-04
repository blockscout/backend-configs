#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENAPI_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

cat > "${TMP_DIR}/input.json" <<'JSON'
{
  "swagger": "2.0",
  "info": {
    "title": "Fixture",
    "version": "1.0.0"
  },
  "tags": [
    { "name": "Keep" },
    { "name": "Drop" }
  ],
  "paths": {
    "/api/v1/keep": {
      "get": {
        "tags": ["Keep"],
        "responses": {
          "200": {
            "description": "ok",
            "schema": { "$ref": "#/definitions/Kept" }
          }
        }
      }
    },
    "/api/v1/drop": {
      "get": {
        "tags": ["Drop"],
        "responses": {
          "200": {
            "description": "ok",
            "schema": { "$ref": "#/definitions/Dropped" }
          }
        }
      }
    }
  },
  "definitions": {
    "Kept": {
      "type": "object",
      "properties": {
        "nested": { "$ref": "#/definitions/Nested" }
      }
    },
    "Nested": {
      "type": "object"
    },
    "Dropped": {
      "type": "object"
    }
  }
}
JSON

mkdir -p "${TMP_DIR}/bin"
cat > "${TMP_DIR}/bin/oastools" <<'SH'
#!/usr/bin/env bash
if [[ "$1" != "parse" || "$2" != "-q" ]]; then
  echo "unexpected oastools invocation: $*" >&2
  exit 1
fi
cat "$3"
SH
chmod +x "${TMP_DIR}/bin/oastools"

PATH="${TMP_DIR}/bin:${PATH}" \
SERVICE_MODULE_NAME="bens" \
EXTRACTION_PATH_REGEXES='["^/api/v1/keep$"]' \
  "${OPENAPI_DIR}/extract-service-module.sh" \
    "${TMP_DIR}/input.json" \
    "${TMP_DIR}/output.json" >/dev/null

jq -e '
  (.paths | keys) == ["/services/bens/api/v1/keep"]
  and (.definitions | keys | sort) == ["Kept", "Nested"]
  and (.tags | map(.name)) == ["Keep"]
' "${TMP_DIR}/output.json" >/dev/null
