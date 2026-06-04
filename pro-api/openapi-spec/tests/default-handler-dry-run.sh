#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENAPI_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

cat > "${TMP_DIR}/config.json" <<'JSON'
{
  "output": {
    "filename": "pro-api.json",
    "version": "0.5.0"
  },
  "modules_config": {
    "url": "https://example.invalid/modules-config.json"
  },
  "source": {
    "blockscout": {
      "from_modules_config": "blockscout",
      "handler": "blockscout-extract.sh"
    },
    "services": {
      "metadata": {
        "from_modules_config": "metadata",
        "handler": "extract-metadata.sh"
      },
      "bens": {
        "from_modules_config": "bens"
      }
    }
  }
}
JSON

mkdir -p "${TMP_DIR}/bin"
cat > "${TMP_DIR}/bin/oastools" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "${TMP_DIR}/bin/curl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "${TMP_DIR}/bin/oastools" "${TMP_DIR}/bin/curl"

output="$(
  PATH="${TMP_DIR}/bin:${PATH}" \
    "${OPENAPI_DIR}/build-pro-api.sh" \
      --config "${TMP_DIR}/config.json" \
      --dry-run \
      2>&1
)"

grep -F '[dry-run] Would extract: extract-metadata.sh metadata.unknown.yaml -> metadata.json' <<<"${output}" >/dev/null
grep -F '[dry-run] Would extract: extract-service-module.sh bens.unknown.yaml -> bens.json' <<<"${output}" >/dev/null
