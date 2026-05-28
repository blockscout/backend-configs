#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# merge-specs.sh
#
# Enriches, converts, and merges multiple OpenAPI/Swagger specs into a
# single OpenAPI 3.0.0 file with unified metadata.
#
# NOTE: This script is NOT intended to be run standalone. It is called by
#       build-pro-api.sh, which handles downloading, caching, and cleanup
#       of intermediate files. Running this script directly may leave
#       temporary converted files behind (e.g. *-converted.json), because
#       Swagger 2.0 → OpenAPI 3.0 conversion tracking relies on the parent
#       process managing cleanup.
#
# Pipeline:
#   1. Convert any Swagger 2.0 specs to OpenAPI 3.0.0
#   2. Join all specs with post-overlay (branding + rate-limit headers)
#   3. Post-process (version, servers, tags cleanup via jq)
#   4. Validate the result
#
# Usage (via build-pro-api.sh):
#   ./merge-specs.sh <main-spec> -a <spec> [-a <spec>...] [-v version] [-o output] [--keep-intermediates]
#
# Example:
#   ./merge-specs.sh blockscout-extracted.json \
#     -a metadata-extracted.json \
#     -a multichain-extracted.json \
#     -a stats-service-extracted.json \
#     -v 0.5.0 \
#     -o merged.json
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Usage -----------------------------------------------------------------
usage() {
    cat <<'USAGE'
Usage: merge-specs.sh <main-spec> -a <spec> [-a ...] [options]

Arguments:
  <main-spec>              Primary OpenAPI/Swagger spec (first positional arg)

Options:
  -a, --add <file>         Additional spec to merge (repeatable, at least one)
  -v, --version <version>  API version for info.version (default: 0.5.0)
  -o, --output <file>      Output file path (default: merged.json)
  --keep-intermediates      Keep intermediate converted/overlay files
  -h, --help               Show this help message

Example:
  ./merge-specs.sh blockscout-extracted.json \
    -a metadata-extracted.json \
    -a multichain-extracted.json \
    -a stats-service-extracted.json \
    -v 0.5.0 -o merged.json
USAGE
    exit "${1:-0}"
}

# --- Parse arguments -------------------------------------------------------
MAIN_SPEC=""
ADDITIONAL_SPECS=()
API_VERSION="0.5.0"
OUTPUT_FILE="merged.json"
KEEP_INTERMEDIATES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage 0
            ;;
        -a|--add)
            [[ $# -lt 2 ]] && { echo "Error: -a requires a file argument" >&2; exit 1; }
            ADDITIONAL_SPECS+=("$2")
            shift 2
            ;;
        -v|--version)
            [[ $# -lt 2 ]] && { echo "Error: -v requires a version argument" >&2; exit 1; }
            API_VERSION="$2"
            shift 2
            ;;
        -o|--output)
            [[ $# -lt 2 ]] && { echo "Error: -o requires a file argument" >&2; exit 1; }
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --keep-intermediates)
            KEEP_INTERMEDIATES=true
            shift
            ;;
        -*)
            echo "Unknown flag: $1" >&2
            usage 1
            ;;
        *)
            if [[ -z "$MAIN_SPEC" ]]; then
                MAIN_SPEC="$1"
            else
                echo "Error: unexpected argument '$1' (use -a to add specs)" >&2
                usage 1
            fi
            shift
            ;;
    esac
done

# Validate required args
if [[ -z "$MAIN_SPEC" ]]; then
    echo "Error: main spec file is required" >&2
    usage 1
fi
if [[ ${#ADDITIONAL_SPECS[@]} -eq 0 ]]; then
    echo "Error: at least one -a <spec> is required" >&2
    usage 1
fi

# --- Resolve file paths (relative to SCRIPT_DIR) --------------------------
resolve_path() {
    local f="$1"
    if [[ "$f" = /* ]]; then
        echo "$f"
    else
        echo "${SCRIPT_DIR}/${f}"
    fi
}

MAIN_SPEC="$(resolve_path "$MAIN_SPEC")"
RESOLVED_ADDITIONAL=()
for f in "${ADDITIONAL_SPECS[@]}"; do
    RESOLVED_ADDITIONAL+=("$(resolve_path "$f")")
done

OUTPUT_PATH="$(resolve_path "$OUTPUT_FILE")"

# --- Intermediate file tracking --------------------------------------------
INTERMEDIATES=()  # files to clean up

cleanup() {
    if [[ "$KEEP_INTERMEDIATES" == false ]]; then
        if [[ ${#INTERMEDIATES[@]} -gt 0 ]]; then
            echo ""
            echo "Cleaning up intermediate files..."
            for f in "${INTERMEDIATES[@]}"; do
                if [[ -f "$f" ]]; then
                    rm -f "$f"
                    echo "  Removed $(basename "$f")"
                fi
            done
        fi
    else
        if [[ ${#INTERMEDIATES[@]} -gt 0 ]]; then
            echo ""
            echo "Keeping intermediate files (--keep-intermediates):"
            for f in "${INTERMEDIATES[@]}"; do
                [[ -f "$f" ]] && echo "  $(basename "$f")"
            done
        fi
    fi
}

trap cleanup EXIT

# --- Preflight checks ------------------------------------------------------
echo "=== Preflight ==="

for cmd in oastools jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: required command '$cmd' not found in PATH" >&2
        exit 1
    fi
done
echo "oastools found: $(command -v oastools)"

for f in "$MAIN_SPEC" "${RESOLVED_ADDITIONAL[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "Error: file not found: $f" >&2
        exit 1
    fi
done
echo "All source files present."
echo "  Main:    $(basename "$MAIN_SPEC")"
for f in "${RESOLVED_ADDITIONAL[@]}"; do
    echo "  Add:     $(basename "$f")"
done
echo "  Version: ${API_VERSION}"
echo "  Output:  ${OUTPUT_FILE}"
echo ""

# --- Phase 1: Detect & Convert Swagger 2.0 -> OpenAPI 3.0.0 ---------------
echo "=== Phase 1: Detect & convert Swagger 2.0 files ==="

oas_version() {
    # Use oastools validate to reliably detect the OAS version
    oastools validate --format json -q "$1" 2>/dev/null | jq -r '.Version'
}

convert_if_needed() {
    local src="$1"
    local ver
    ver="$(oas_version "$src")"
    local base
    base="$(basename "$src")"
    if [[ "$ver" == "2.0" ]]; then
        local dir dst
        dir="$(dirname "$src")"
        # Strip extension, then append -converted.json
        dst="${dir}/${base%.*}-converted.json"
        echo "  ${base}: Swagger ${ver} -> converting to OpenAPI 3.0.0..." >&2
        oastools convert -t 3.0.0 -o "$dst" "$src" >&2
        INTERMEDIATES+=("$dst")
        echo "$dst"
    else
        echo "  ${base}: OpenAPI ${ver} — no conversion needed." >&2
        echo "$src"
    fi
}

# Convert main spec if needed
MAIN_READY="$(convert_if_needed "$MAIN_SPEC")"

# Convert additional specs
JOIN_FILES=()
for f in "${RESOLVED_ADDITIONAL[@]}"; do
    converted="$(convert_if_needed "$f")"
    JOIN_FILES+=("$converted")
done
echo ""

# --- Phase 2: Join with post-overlay ---------------------------------------
OVERLAY_FILE="${SCRIPT_DIR}/merge-overlay.yaml"
if [[ ! -f "$OVERLAY_FILE" ]]; then
    echo "Error: overlay file not found: $OVERLAY_FILE" >&2
    exit 1
fi

echo "=== Phase 2: Join specs (overlay: $(basename "$OVERLAY_FILE")) ==="

oastools join \
    -o "$OUTPUT_PATH" \
    --path-strategy fail \
    --collision-report \
    --semantic-dedup \
    --post-overlay "$OVERLAY_FILE" \
    "$MAIN_READY" \
    "${JOIN_FILES[@]}"

echo "Joined spec written to: ${OUTPUT_FILE}"
echo ""

# --- Phase 3: Post-processing with jq -------------------------------------
# Handles transforms the overlay cannot express:
#   - servers: overlay update appends to arrays, cannot replace a list
#   - info.version: dynamic value from -v flag, not expressible statically
echo "=== Phase 3: Post-processing (jq) ==="

TMP_JQ="${OUTPUT_PATH}.tmp"
INTERMEDIATES+=("$TMP_JQ")
jq --arg version "$API_VERSION" '
    .servers = [{"url": "https://api.blockscout.com"}]
    | .info.version = $version
' "$OUTPUT_PATH" > "$TMP_JQ" && mv "$TMP_JQ" "$OUTPUT_PATH"
echo "  servers: set to https://api.blockscout.com"
echo "  info.version: set to ${API_VERSION}"
echo ""

# --- Phase 4: Validate -----------------------------------------------------
echo "=== Phase 4: Validate merged spec ==="

oastools validate "$OUTPUT_PATH"

echo ""
echo "=== Success ==="
echo "Output: ${OUTPUT_PATH}"
