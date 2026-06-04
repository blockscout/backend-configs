#!/usr/bin/env bash
#
# extract-metadata.sh — Extract and relocate metadata service operations
#
# Transforms an OpenAPI (Swagger 2.0) specification to:
#   1. Keep only paths matching the configured regex allowlist
#   2. Prefix each kept path with /services/metadata
#   3. Remove all definitions not transitively referenced by those operations
#   4. Remove tags not used by kept operations
#
# Path selection:
#   - If EXTRACTION_PATH_REGEXES env var is set (JSON array of regex strings),
#     paths in the input spec are filtered by matching any regex.
#   - Otherwise the hardcoded SOURCE_PATH_REGEXES below are used (default).
#
# Usage:
#   ./extract-metadata.sh <input-spec> <output-file>
#
# Example (with default allowlist):
#   ./extract-metadata.sh tmp/metadata.yaml tmp/metadata-extracted.json
#
# Example (with explicit regex allowlist):
#   EXTRACTION_PATH_REGEXES='["^/api/v1/metadata$"]' \
#     ./extract-metadata.sh tmp/metadata.yaml tmp/metadata-extracted.json
#
# Dependencies: jq (1.6+), oastools
#
set -euo pipefail

# --- Configuration -----------------------------------------------------------
# Default regex allowlist used when EXTRACTION_PATH_REGEXES is not set.

SOURCE_PATH_REGEXES=(
    '^/api/v1/metadata$'
)

# Prefix prepended to each kept path in the output.
PATH_PREFIX="/services/metadata"

# $ref prefix used in Swagger 2.0 definitions.
REF_PREFIX="#/definitions/"
# For OpenAPI 3.x, change REF_PREFIX to "#/components/schemas/"
# -----------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") <input-spec> <output-file>

Extract metadata service operations from an OpenAPI spec, prefix their paths
with ${PATH_PREFIX}, and prune unreferenced definitions.

Arguments:
  input-spec    Path to a Swagger 2.0 YAML or JSON file (or "-" for stdin)
  output-file   Path for the resulting JSON file

Environment:
  EXTRACTION_PATH_REGEXES   JSON array of regex strings overriding the default
                            allowlist. Each path key in the input spec is kept
                            iff it matches at least one regex.
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

# --- Dependency checks --------------------------------------------------------
for cmd in jq oastools; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: required command '$cmd' not found in PATH" >&2
        exit 1
    fi
done

# --- Resolve regex allowlist (env var > hardcoded default) -------------------
if [[ -n "${EXTRACTION_PATH_REGEXES:-}" ]]; then
    REGEXES_JSON="$EXTRACTION_PATH_REGEXES"
    if ! jq -e 'type == "array" and all(type == "string")' <<<"$REGEXES_JSON" >/dev/null 2>&1; then
        echo "Error: EXTRACTION_PATH_REGEXES must be a JSON array of strings" >&2
        exit 1
    fi
else
    REGEXES_JSON=$(printf '%s\n' "${SOURCE_PATH_REGEXES[@]}" | jq -R . | jq -s .)
fi

# --- Transform ----------------------------------------------------------------
#
# Pipeline:  oastools parse (YAML/JSON → JSON)  →  jq (all transformations)  →  output file
#
# The jq filter:
#   1. Filters .paths keys by matching against the regex allowlist
#   2. Builds a new paths object: each kept path → prefixed path
#   3. BFS-traverses $ref pointers to find all transitively needed definitions
#   4. Rebuilds the document with prefixed paths, pruned definitions and tags
#
oastools parse -q "$INPUT" | jq \
    --argjson path_regexes "$REGEXES_JSON" \
    --arg     path_prefix  "$PATH_PREFIX" \
    --arg     ref_prefix   "$REF_PREFIX" \
'
# ---------------------------------------------------------------------------
# refs_in: collect all definition names referenced via $ref within a value.
# ---------------------------------------------------------------------------
def refs_in($prefix):
    [.. | .["$ref"]? // empty | select(startswith($prefix)) | ltrimstr($prefix)]
    | unique;

# === Step 1: Filter paths by regex allowlist & build kept operations =========
# Bind .paths once: after `keys[]`, the current value is the key string, not the
# document root, so `.paths[$p]` would be wrong (see jq path binding).
.paths as $paths |
(
    [$paths | keys[] as $p
        | select($path_regexes | any(. as $r | $p | test($r)))
        | { key: ($path_prefix + $p), value: $paths[$p] }
    ] | from_entries
) as $kept_paths |

if ($kept_paths | length) == 0 then
    error("no paths matched the regex allowlist: \($path_regexes)")
else . end |

# === Step 2: Transitive $ref closure (BFS) ===================================
.definitions as $defs |
(
    ([$kept_paths[] | refs_in($ref_prefix)[]] | unique) as $seed |
    { found: $seed, frontier: $seed } |
    until(.frontier | length == 0;
        ([.frontier[] as $name | $defs[$name] // empty | refs_in($ref_prefix)[]]
            | unique) as $all |
        ($all - .found) as $new |
        { found: (.found + $new), frontier: $new }
    ) |
    .found
) as $needed_defs |

# === Step 3: Identify needed tags ============================================
([$kept_paths[] | .. | .tags? // empty | arrays | .[]] | unique) as $needed_tags |

# === Step 4: Rebuild the document ============================================
{
    swagger,
    info,
    tags:        [.tags[]? | select(.name as $n | $needed_tags | index($n))],
    consumes,
    produces,
    paths:       $kept_paths,
    definitions: (.definitions | with_entries(select(.key | IN($needed_defs[]))))
}
' > "$OUTPUT"

# --- Summary ------------------------------------------------------------------
DEFS=$(jq '.definitions | length' "$OUTPUT")
PATHS=$(jq '.paths | length' "$OUTPUT")
echo "Wrote $OUTPUT — $PATHS path(s), $DEFS definition(s)"
