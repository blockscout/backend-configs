#!/usr/bin/env bash
#
# stats-service-extract.sh — Transform a stats-service OpenAPI spec for multi-chain use
#
# Transforms the specification to:
#   1. Remove /health endpoint
#   2. Remove /api/v1/update-status endpoint (internal monitoring, not public)
#   3. Remove all non-GET operations (and prune empty path items)
#   4. Remove all definitions not transitively referenced by kept operations
#   5. Remove tags not used by kept operations
#   6. Add a required {chain_id} path parameter to all operations
#   7. Prefix all paths with /{chain_id}/stats-service
#
# Usage:
#   ./stats-service-extract.sh <input-spec> <output-file>
#
# Example:
#   ./stats-service-extract.sh tmp/stats-service.yaml tmp/stats-service-extracted.json
#
# Dependencies: jq (1.6+), oastools
#
set -euo pipefail

# --- Configuration -----------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY="${SCRIPT_DIR}/stats-service-overlay.yaml"

# -----------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") <input-spec> <output-file>

Transform a stats-service OpenAPI spec for multi-chain use.

Arguments:
  input-spec    Path to a stats-service OpenAPI YAML or JSON file (or "-" for stdin)
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

for cmd in jq oastools; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: required command '$cmd' not found in PATH" >&2
        exit 1
    fi
done

# --- Transform ----------------------------------------------------------------
#
# Pipeline:
#   1. oastools parse     — YAML/JSON → JSON
#   2. oastools overlay   — remove /health, /update-status, non-GET methods
#   3. jq                 — prune empty paths, BFS ref closure, add chain_id, prefix paths
#

oastools parse -q "$INPUT" \
  | oastools overlay apply -q -s - "$OVERLAY" \
  | jq --arg ref_prefix "#/definitions/" '
# ---------------------------------------------------------------------------
# refs_in: collect all definition names referenced via $ref within a value.
#
# Walks the JSON tree with recursive descent (..), extracts any "$ref" string
# that starts with the definitions prefix, and strips the prefix to return
# bare definition names.  Returns a unique, sorted array.
# ---------------------------------------------------------------------------
def refs_in($prefix):
    [.. | .["$ref"]? // empty | select(startswith($prefix)) | ltrimstr($prefix)]
    | unique;

# === Prune empty path items ===================================================
#
# After removing non-GET methods, path items that had only non-GET operations
# (e.g. /api/v1/charts/batch-update with only POST) become empty objects.

.paths |= with_entries(select(.value | keys | length > 0)) |

# === Transitive $ref closure (BFS) ============================================
#
# Starting from ALL $refs across every kept path, iteratively discover all
# definitions reachable through nested $refs.
#
#   found    — accumulator of all definition names seen so far
#   frontier — newly discovered names to explore next iteration
#
# Stops when no new definitions are found (fixed point).

.definitions as $defs |
(
    ([.paths[] | refs_in($ref_prefix)[]] | unique) as $seed |
    { found: $seed, frontier: $seed } |
    until(.frontier | length == 0;
        ([.frontier[] as $name | $defs[$name] // empty | refs_in($ref_prefix)[]]
            | unique) as $all |
        ($all - .found) as $new |
        { found: (.found + $new), frontier: $new }
    ) |
    .found
) as $needed_defs |

# === Prune unused definitions =================================================

.definitions |= with_entries(select(.key | IN($needed_defs[]))) |

# === Prune unused tags ========================================================

([.paths[] | .. | .tags? // empty | arrays | .[]] | unique) as $needed_tags |
.tags |= if . then [.[] | select(.name as $n | $needed_tags | index($n))] else . end |

# === Add chain_id path parameter to all GET operations ========================
#
# Most operations in this spec lack a parameters array, so we initialise or
# append as needed.

.paths |= with_entries(
  if .value.get then
    .value.get.parameters = ((.value.get.parameters // []) + [{
      name: "chain_id", in: "path", required: true,
      description: "The ID of the blockchain",
      type: "string"
    }])
  else . end
) |

# === Prefix all paths with /{chain_id}/stats-service ==========================

.paths |= with_entries(.key = "/{chain_id}/stats-service" + .key)
' > "$OUTPUT"

# --- Summary ------------------------------------------------------------------

PATHS=$(jq '.paths | length' "$OUTPUT")
DEFS=$(jq '.definitions | length' "$OUTPUT")
echo "Wrote $OUTPUT — $PATHS path(s), $DEFS definition(s)"
