#!/usr/bin/env bash
#
# extract-service-module.sh - Extract and relocate a forwarded service module.
#
# The module name comes from SERVICE_MODULE_NAME and determines the public path
# prefix: /services/<module>. Paths are selected by EXTRACTION_PATH_REGEXES,
# which is supplied by build-pro-api.sh from modules-config.json allowed_paths.
#
set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") <input-spec> <output-file>

Extract a service module from an OpenAPI spec, prefix kept paths with
/services/<module>, and prune unreferenced schemas/definitions.

Environment:
  SERVICE_MODULE_NAME       Module name used in the /services/<module> prefix
  EXTRACTION_PATH_REGEXES   JSON array of regex strings used as an allowlist
EOF
    exit 1
}

if [[ $# -ne 2 ]]; then
    usage
fi

INPUT="$1"
OUTPUT="$2"

if [[ "$INPUT" != "-" && ! -f "$INPUT" ]]; then
    echo "Error: input file not found: $INPUT" >&2
    exit 1
fi

for cmd in jq oastools; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: required command '$cmd' not found in PATH" >&2
        exit 1
    fi
done

MODULE_NAME="${SERVICE_MODULE_NAME:-}"
if [[ -z "$MODULE_NAME" ]]; then
    echo "Error: SERVICE_MODULE_NAME is required" >&2
    exit 1
fi

REGEXES_JSON="${EXTRACTION_PATH_REGEXES:-}"
if ! jq -e 'type == "array" and length > 0 and all(type == "string")' <<<"$REGEXES_JSON" >/dev/null 2>&1; then
    echo "Error: EXTRACTION_PATH_REGEXES must be a non-empty JSON array of strings" >&2
    exit 1
fi

PATH_PREFIX="/services/${MODULE_NAME}"

oastools parse -q "$INPUT" | jq \
    --argjson path_regexes "$REGEXES_JSON" \
    --arg path_prefix "$PATH_PREFIX" \
'
def refs_in($prefix):
    [.. | .["$ref"]? // empty | select(startswith($prefix)) | ltrimstr($prefix)]
    | unique;

def transitive_refs($defs; $prefix; $kept_paths):
    ([$kept_paths[] | refs_in($prefix)[]] | unique) as $seed |
    { found: $seed, frontier: $seed } |
    until(.frontier | length == 0;
        ([.frontier[] as $name | $defs[$name] // empty | refs_in($prefix)[]]
            | unique) as $all |
        ($all - .found) as $new |
        { found: (.found + $new), frontier: $new }
    ) |
    .found;

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

([$kept_paths[] | .. | .tags? // empty | arrays | .[]] | unique) as $needed_tags |

if .swagger then
    (.definitions // {}) as $defs |
    (transitive_refs($defs; "#/definitions/"; $kept_paths)) as $needed_defs |
    .paths = $kept_paths
    | if has("tags") then .tags = [.tags[]? | select(.name as $n | $needed_tags | index($n))] else . end
    | if has("definitions") then .definitions = (.definitions | with_entries(select(.key | IN($needed_defs[])))) else . end
elif .openapi then
    (.components.schemas // {}) as $schemas |
    (transitive_refs($schemas; "#/components/schemas/"; $kept_paths)) as $needed_schemas |
    .paths = $kept_paths
    | if has("tags") then .tags = [.tags[]? | select(.name as $n | $needed_tags | index($n))] else . end
    | if (.components.schemas? != null) then .components.schemas = (.components.schemas | with_entries(select(.key | IN($needed_schemas[])))) else . end
else
    error("unsupported spec format: expected swagger or openapi field")
end
' > "$OUTPUT"

PATHS=$(jq '.paths | length' "$OUTPUT")
echo "Wrote $OUTPUT - $PATHS path(s)"
