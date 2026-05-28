#!/usr/bin/env bash
#
# blockscout-extract.sh — Transform a Blockscout OpenAPI spec for multi-chain use
#
# Transforms an OpenAPI 3.0 specification to:
#   1. Remove /v2/config/* (or /api/v2/config/*) endpoints
#   2. Remove all non-GET operations
#   3. Remove "key" and "apikey" query parameters from all operations
#   4. Remove x-struct and x-validate vendor extensions everywhere
#   5. Add a required {chain_id} path parameter to all operations
#   6. Prefix all paths so they end up under /{chain_id}/api/...
#
# The script auto-detects which of the two upstream Blockscout swagger formats
# is being processed:
#   - Legacy:  paths look like "/v2/blocks", server URL has /api as base path
#   - Current: paths look like "/api/v2/blocks", server URL has no base path
# The applied prefix is chosen to normalise both to "/{chain_id}/api/v2/...".
#
# The output is JSON, suitable for further processing with oastools
# (validate, convert, join, etc.).
#
# Usage:
#   ./blockscout-extract.sh <input-spec> <output-file>
#
# Example:
#   ./blockscout-extract.sh tmp/blockscout.yaml tmp/blockscout-extracted.json
#
# Dependencies: jq (1.6+), oastools
#
set -euo pipefail

# --- Configuration -----------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY="${SCRIPT_DIR}/blockscout-overlay.yaml"

# -----------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") <input-spec> <output-file>

Transform a Blockscout OpenAPI spec for multi-chain use.

Applies:
  1. Remove /v2/config/* (or /api/v2/config/*) endpoints
  2. Remove all non-GET operations
  3. Remove "key" and "apikey" query parameters
  4. Remove x-struct and x-validate vendor extensions
  5. Add required {chain_id} path parameter
  6. Normalise path prefix to /{chain_id}/api/...

Arguments:
  input-spec    Path to a Blockscout OpenAPI 3.0 YAML or JSON file (or "-" for stdin)
  output-file   Path for the resulting JSON file
EOF
    exit 1
}

# --- Argument validation ------------------------------------------------------

if [[ $# -ne 2 ]]; then
    usage
fi

INPUT="$1"
OUTPUT="$2"

if [[ "$INPUT" != "-" && ! -f "$INPUT" ]]; then
    echo "Error: input file not found: $INPUT" >&2
    exit 1
fi

if [[ ! -f "$OVERLAY" ]]; then
    echo "Error: overlay file not found: $OVERLAY" >&2
    echo "Expected at: $OVERLAY" >&2
    exit 1
fi

# --- Dependency checks --------------------------------------------------------

for cmd in jq oastools; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: required command '$cmd' not found in PATH" >&2
        exit 1
    fi
done

# --- Transform ----------------------------------------------------------------
#
# Pipeline:
#   1. oastools parse     — YAML/JSON → JSON (normalises input)
#   2. oastools overlay   — apply overlay (non-GET removal, vendor ext removal,
#                           chain_id parameter append)
#   3. jq                 — config-path removal (regex), array-element filtering,
#                           chain_id fixup, format-aware path prefixing
#

oastools parse -q "$INPUT" \
  | oastools overlay apply -q -s - "$OVERLAY" \
  | jq '
# === Step 1: Remove /v2/config/* and /api/v2/config/* paths ===================
# A single regex covers both legacy ("/v2/config/...") and current
# ("/api/v2/config/...") swagger formats.

.paths |= with_entries(select(.key | test("^(?:/api)?/v2/config/") | not)) |

# === Step 3: Filter out "key" and "apikey" entries from parameters arrays =====
# Some operations have no parameters (null), so we guard with has() + type check.

walk(
  if type == "object"
     and has("parameters")
     and (.parameters | type) == "array"
  then
    .parameters |= map(select(.name != "key" and .name != "apikey"))
  else . end
) |

# === Step 5 fixup: Ensure chain_id exists on all GET operations ===============
#
# The overlay appends chain_id to existing parameters arrays, but cannot create
# the array when the key is absent.  This fixup catches those operations.

.paths |= with_entries(
  if .value.get and ((.value.get.parameters // []) | any(.name == "chain_id") | not) then
    .value.get.parameters = ((.value.get.parameters // []) + [{ name: "chain_id",
      in: "path", required: true, description: "The ID of the blockchain",
      schema: { type: "string" } }])
  else . end
) |

# === Step 6: Format-aware path prefixing ======================================
#
# Two upstream swagger formats coexist:
#   - Legacy:  paths "/v2/blocks",     server base path "/api"  → prefix "/{chain_id}/api"
#   - Current: paths "/api/v2/blocks", no server base path      → prefix "/{chain_id}"
# In both cases the resulting key becomes "/{chain_id}/api/v2/blocks".
#
# Detection: if any path key starts with "/api/", we are in the current format.

(
  if [.paths | keys[] | startswith("/api/")] | any then
    "/{chain_id}"
  else
    "/{chain_id}/api"
  end
) as $prefix |

.paths |= with_entries(.key = $prefix + .key)
' > "$OUTPUT"

# --- Summary ------------------------------------------------------------------

PATHS=$(jq '.paths | length' "$OUTPUT")
PARAMS=$(jq '[.paths[][].parameters[]?.name] | unique | length' "$OUTPUT")
echo "Wrote $OUTPUT — $PATHS path(s), $PARAMS unique parameter name(s)"
