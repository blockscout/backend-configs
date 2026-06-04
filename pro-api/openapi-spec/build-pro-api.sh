#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-pro-api.sh
#
# Orchestrates the full Blockscout Pro API specification build pipeline:
#   1. Resolve sources (static config.json + optional modules-config.json)
#   2. Download source swagger files (with commit-hash caching)
#   3. Run per-service extraction scripts
#   4. Merge into a single OpenAPI 3.0.0 spec
#   5. Clean up intermediate artifacts
#
# Sources can be declared in two ways:
#   - Statically:  source.<name>.swagger = "<url>"
#   - Externally:  source.<name>.from_modules_config = "<key>"
#                  ↳ swagger_url (and allowed_paths for services) are read
#                    from modules_config.url (modules-config.json).
#                  Supported key formats:
#                    "blockscout"           → mc.blockscout.swagger_url
#                    "blockscout.<service>" → mc.blockscout.services[<service>].swagger_url
#                    "<service>"            → mc.services[<service>].swagger_url
#
# When a service references modules-config, the orchestrator expands its
# allowed_paths regex array against the swagger's path keys and passes the
# resulting concrete list to the handler via EXTRACTION_PATH_REGEXES.
#
# Usage:
#   ./build-pro-api.sh [options]
#
# Options:
#   -c, --config <file>       Config file path (default: config.json in script dir)
#   --keep-intermediates      Keep extraction output JSON files
#   --cache-cleanup           Remove all cached swagger downloads and exit
#   --dry-run                 Show what would happen without doing it
#   --force                   Force re-download even if cache exists
#   -h, --help                Show this help message
#
# Exit codes:
#   0  Success
#   1  Config error (missing/invalid config.json)
#   2  Download failure (network, 404, API rate limit)
#   3  Extraction failure (handler script failed)
#   4  Merge/validation failure
# ---------------------------------------------------------------------------
set -euo pipefail

# --- Exit codes --------------------------------------------------------------
readonly EXIT_SUCCESS=0
readonly EXIT_CONFIG_ERROR=1
readonly EXIT_DOWNLOAD_FAILURE=2
readonly EXIT_EXTRACTION_FAILURE=3
readonly EXIT_MERGE_FAILURE=4

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Defaults ----------------------------------------------------------------
CONFIG_FILE="${SCRIPT_DIR}/config.json"
KEEP_INTERMEDIATES=false
CACHE_CLEANUP=false
DRY_RUN=false
FORCE_DOWNLOAD=false
DEFAULT_SERVICE_HANDLER="extract-service-module.sh"

# --- Usage -------------------------------------------------------------------
usage() {
    cat <<'USAGE'
Usage: build-pro-api.sh [options]

Orchestrates the full Pro API specification build pipeline:
resolve sources → download → extract → merge → validate → cleanup

Options:
  -c, --config <file>       Config file path (default: config.json in script dir)
  --keep-intermediates      Keep extraction output JSON files
  --cache-cleanup           Remove all cached swagger downloads and exit
  --dry-run                 Show what would happen without doing it
  --force                   Force re-download even if cache exists
  -h, --help                Show this help message

Exit codes:
  0  Success
  1  Config error
  2  Download failure
  3  Extraction failure
  4  Merge/validation failure
USAGE
    exit "${1:-0}"
}

# --- Parse arguments ---------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)          usage 0 ;;
        -c|--config)
            [[ $# -lt 2 ]] && { echo "Error: -c requires a file argument" >&2; exit $EXIT_CONFIG_ERROR; }
            CONFIG_FILE="$2"; shift 2 ;;
        --keep-intermediates) KEEP_INTERMEDIATES=true; shift ;;
        --cache-cleanup)      CACHE_CLEANUP=true; shift ;;
        --dry-run)            DRY_RUN=true; shift ;;
        --force)              FORCE_DOWNLOAD=true; shift ;;
        *)
            echo "Unknown option: $1" >&2; usage $EXIT_CONFIG_ERROR ;;
    esac
done

# --- Resolve config path -----------------------------------------------------
if [[ "${CONFIG_FILE}" != /* ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
fi

# --- Logging helpers ---------------------------------------------------------
info()  { echo "  $*"; }
warn()  { echo "  WARNING: $*" >&2; }
error() { echo "  ERROR: $*" >&2; }

# --- Preflight checks --------------------------------------------------------
preflight() {
    local missing=()
    for cmd in jq oastools curl; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "required commands not found: ${missing[*]}"
        exit $EXIT_CONFIG_ERROR
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "config file not found: $CONFIG_FILE"
        exit $EXIT_CONFIG_ERROR
    fi

    # Validate config JSON: top-level required fields and per-service shape.
    # Each entry in source.services must have either .swagger or .from_modules_config.
    # Service handlers are optional and default to extract-service-module.sh.
    # If any service uses from_modules_config, modules_config.url must be set.
    if ! jq -e '
        .output.filename and .output.version
        and (.source.blockscout.swagger or .source.blockscout.from_modules_config)
        and ((.source.blockscout | ((.swagger and .from_modules_config) | not)))
        and .source.services
        and (.source.services | to_entries | all(.value.swagger or .value.from_modules_config))
        and (
            (
                .source.blockscout.from_modules_config
                or (.source.services | to_entries | any(.value.from_modules_config))
            | not)
            or .modules_config.url
        )
        and (.source.services | to_entries | all((.value.swagger and .value.from_modules_config) | not))
    ' "$CONFIG_FILE" >/dev/null 2>&1; then
        error "config file invalid (require: output.filename, output.version; source.blockscout must have exactly one of .swagger or .from_modules_config; each source.services entry must have exactly one of .swagger or .from_modules_config; modules_config.url required when from_modules_config is used)"
        exit $EXIT_CONFIG_ERROR
    fi
}

# --- Config readers ----------------------------------------------------------
cfg_output_filename() { jq -r '.output.filename' "$CONFIG_FILE"; }
cfg_output_version()  { jq -r '.output.version'  "$CONFIG_FILE"; }
cfg_modules_config_url() { jq -r '.modules_config.url // ""' "$CONFIG_FILE"; }

# Returns true (exit 0) when at least one service references modules-config.
cfg_uses_modules_config() {
    jq -e '
        .source.blockscout.from_modules_config
        or (.source.services | to_entries | any(.value.from_modules_config))
    ' "$CONFIG_FILE" >/dev/null 2>&1
}

# Names of all services in config.json (blockscout + .source.services keys).
# Used by cache cleanup, which doesn't need full source resolution.
cfg_all_service_names() {
    jq -r '"blockscout", (.source.services | keys[])' "$CONFIG_FILE"
}

# --- GitHub URL parsing ------------------------------------------------------
# Parses a raw.githubusercontent.com URL into owner, repo, and file path.
#
# Input:  https://raw.githubusercontent.com/{owner}/{repo}/{ref...}/{path}
# Output: three space-separated values: owner repo path
#
# Handles refs like "refs/heads/master" (3 segments) and plain SHAs (1 segment).
parse_raw_github_url() {
    local url="$1"
    local rest="${url#https://raw.githubusercontent.com/}"

    # Split on /
    IFS='/' read -ra parts <<< "$rest"

    local owner="${parts[0]}"
    local repo="${parts[1]}"

    # Determine where the ref ends and the file path begins
    local path_start
    if [[ "${parts[2]:-}" == "refs" ]]; then
        # refs/heads/<branch> or refs/tags/<tag> = 3 segments
        path_start=5
    else
        # Plain branch name or commit SHA = 1 segment
        path_start=3
    fi

    # Join remaining segments as the file path
    local path=""
    for ((i=path_start; i<${#parts[@]}; i++)); do
        [[ -n "$path" ]] && path="$path/"
        path="$path${parts[$i]}"
    done

    echo "$owner" "$repo" "$path"
}

# --- Commit hash lookup ------------------------------------------------------
# Returns the first 7 characters of the latest commit SHA that touched the file.
# Tries gh CLI first (authenticated, higher rate limit), falls back to curl.
# Returns empty string on failure.
get_commit_hash() {
    local url="$1"
    local owner repo path
    read -r owner repo path <<< "$(parse_raw_github_url "$url")"

    local sha=""
    local api_path="repos/${owner}/${repo}/commits?path=${path}&per_page=1"

    # Try gh CLI first (authenticated — 5000 req/hr)
    if command -v gh &>/dev/null; then
        sha=$(gh api "$api_path" --jq '.[0].sha' 2>/dev/null || true)
    fi

    # Fall back to unauthenticated curl (60 req/hr)
    if [[ -z "$sha" || "$sha" == "null" ]]; then
        sha=$(curl -sf "https://api.github.com/${api_path}" 2>/dev/null \
              | jq -r '.[0].sha // empty' 2>/dev/null || true)
    fi

    if [[ -z "$sha" || "$sha" == "null" ]]; then
        echo ""
        return 1
    fi

    echo "${sha:0:7}"
}

# --- Cache operations --------------------------------------------------------
# Find a cached file: <name>.<7-char-hash>.<ext>
find_cached() {
    local name="$1"
    local ext="${2:-yaml}"
    local found
    found=$(find "$SCRIPT_DIR" -maxdepth 1 -name "${name}.[0-9a-f]??????.${ext}" -print -quit 2>/dev/null || true)
    echo "$found"
}

# Find ALL cached files for a name (for cleanup)
find_all_cached() {
    local name="$1"
    local ext="${2:-yaml}"
    {
        find "$SCRIPT_DIR" -maxdepth 1 -name "${name}.[0-9a-f]??????.${ext}" -print 2>/dev/null || true
        find "$SCRIPT_DIR" -maxdepth 1 -name "${name}.unknown.${ext}" -print 2>/dev/null || true
    }
}

# --- Cache cleanup mode ------------------------------------------------------
do_cache_cleanup() {
    echo "=== Cache Cleanup ==="
    local count=0

    # Service swagger caches (.yaml). Source resolution isn't needed here —
    # we only want service names, regardless of whether they reference
    # modules-config or are statically configured.
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        while IFS= read -r cached; do
            [[ -z "$cached" ]] && continue
            if [[ "$DRY_RUN" == true ]]; then
                info "[dry-run] Would remove: $(basename "$cached")"
            else
                rm -f "$cached"
                info "Removed: $(basename "$cached")"
            fi
            ((count++))
        done <<< "$(find_all_cached "$name" yaml)"
    done <<< "$(cfg_all_service_names)"

    # modules-config cache (.json)
    while IFS= read -r cached; do
        [[ -z "$cached" ]] && continue
        if [[ "$DRY_RUN" == true ]]; then
            info "[dry-run] Would remove: $(basename "$cached")"
        else
            rm -f "$cached"
            info "Removed: $(basename "$cached")"
        fi
        ((count++))
    done <<< "$(find_all_cached "modules-config" json)"

    if [[ $count -eq 0 ]]; then
        info "No cached files found."
    else
        info "Cleaned $count cached file(s)."
    fi
}

# --- Generic download with caching -------------------------------------------
# Downloads a file by URL, caches by commit hash. Sets DOWNLOAD_RESULT.
# Args: <name> <url> [<ext>=yaml]
download_with_cache() {
    local name="$1"
    local url="$2"
    local ext="${3:-yaml}"

    # Look up the commit hash for cache keying
    local hash=""
    hash=$(get_commit_hash "$url" || true)

    if [[ -z "$hash" ]]; then
        warn "Could not determine commit hash for $name — checking local cache"
        local cached
        cached=$(find_cached "$name" "$ext")
        if [[ -n "$cached" ]]; then
            info "Using cached file: $(basename "$cached") (commit hash unavailable)"
            DOWNLOAD_RESULT="$cached"
            return
        fi
        warn "No cached file found for $name — downloading without cache"
        local target="${SCRIPT_DIR}/${name}.unknown.${ext}"
        if [[ "$DRY_RUN" == true ]]; then
            info "[dry-run] Would download: $url -> $(basename "$target")"
            DOWNLOAD_RESULT="$target"
            return
        fi
        curl -sSfL -o "$target" "$url" || { error "Failed to download $name from $url"; exit $EXIT_DOWNLOAD_FAILURE; }
        info "Downloaded: $(basename "$target") (no commit hash available)"
        DOWNLOAD_RESULT="$target"
        return
    fi

    local target="${SCRIPT_DIR}/${name}.${hash}.${ext}"

    # Check cache
    if [[ -f "$target" && "$FORCE_DOWNLOAD" == false ]]; then
        info "Cache hit: $(basename "$target")"
        # Clean up any leftover .unknown.<ext> from a previous failed hash lookup
        rm -f "${SCRIPT_DIR}/${name}.unknown.${ext}"
        DOWNLOAD_RESULT="$target"
        return
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[dry-run] Would download: $url -> $(basename "$target")"
        DOWNLOAD_RESULT="$target"
        return
    fi

    # Remove older cached versions for this name before downloading new one
    while IFS= read -r old; do
        [[ -z "$old" ]] && continue
        [[ "$old" == "$target" ]] && continue
        rm -f "$old"
        info "Removed stale cache: $(basename "$old")"
    done <<< "$(find_all_cached "$name" "$ext")"

    curl -sSfL -o "$target" "$url" || { error "Failed to download $name from $url"; exit $EXIT_DOWNLOAD_FAILURE; }
    info "Downloaded: $(basename "$target")"
    DOWNLOAD_RESULT="$target"
}

# --- Source resolution -------------------------------------------------------
# MODULES_CONFIG_FILE is set by the main flow once modules-config.json has been
# downloaded (or stays empty if no service references it).
MODULES_CONFIG_FILE=""

# Emits one TSV row per source: name<TAB>url<TAB>handler<TAB>allowed_paths_json
# allowed_paths_json is "null" (the JSON literal) for static services and a
# JSON array of regex strings for services resolved via modules_config.
resolve_sources_tsv() {
    local mc_arg=()
    if [[ -n "$MODULES_CONFIG_FILE" && -f "$MODULES_CONFIG_FILE" ]]; then
        mc_arg=(--slurpfile mc "$MODULES_CONFIG_FILE")
    else
        # Empty placeholder so $mc[0] is null when no modules-config is loaded.
        mc_arg=(--argjson mc 'null')
    fi

    jq -r "${mc_arg[@]}" --arg default_service_handler "$DEFAULT_SERVICE_HANDLER" '
        # Normalise the modules-config slurp into a single object (or null).
        # When --slurpfile is used, $mc is an array of one object; when --argjson
        # is used to pass null, $mc itself is null.
        ( ($mc | if type == "array" then .[0] else . end) // null ) as $mc_root |

        # Resolve a from_modules_config key to {swagger_url, allowed_paths?}.
        # Supported key formats:
        #   "blockscout"              → mc.blockscout
        #   "blockscout.<service>"    → mc.blockscout.services[<service>]
        #   "<service>"               → mc.services[<service>]
        def lookup_mc($key):
            if $mc_root == null then
                error("modules-config not loaded but source references it: \($key)")
            elif $key == "blockscout" then
                ($mc_root.blockscout // null) as $entry |
                if $entry == null then
                    error("modules-config has no blockscout entry")
                else $entry end
            elif ($key | startswith("blockscout.")) then
                ($key | ltrimstr("blockscout.")) as $svc |
                ($mc_root.blockscout.services[$svc] // null) as $entry |
                if $entry == null then
                    error("modules-config has no blockscout service: \($svc)")
                else $entry end
            else
                ($mc_root.services[$key] // null) as $entry |
                if $entry == null then
                    error("modules-config has no service named: \($key)")
                else $entry end
            end;

        ([
            if .source.blockscout.from_modules_config then
                lookup_mc(.source.blockscout.from_modules_config) as $mcs |
                {
                    name: "blockscout",
                    swagger: $mcs.swagger_url,
                    handler: .source.blockscout.handler,
                    allowed_paths: null
                }
            else
                {
                    name: "blockscout",
                    swagger: .source.blockscout.swagger,
                    handler: .source.blockscout.handler,
                    allowed_paths: null
                }
            end
        ] + [
            .source.services | to_entries[] |
            if .value.from_modules_config then
                lookup_mc(.value.from_modules_config) as $mcs |
                {
                    name: .key,
                    swagger: $mcs.swagger_url,
                    handler: (.value.handler // $default_service_handler),
                    allowed_paths: ($mcs.allowed_paths // [])
                }
            else
                {
                    name: .key,
                    swagger: .value.swagger,
                    handler: (.value.handler // $default_service_handler),
                    allowed_paths: null
                }
            end
        ])
        | .[]
        | [.name, .swagger, .handler, (.allowed_paths | tojson)]
        | @tsv
    ' "$CONFIG_FILE"
}

# --- Extraction --------------------------------------------------------------
run_extraction() {
    local service="$1"
    local input="$2"
    local handler="$3"
    local allowed_paths_json="$4"  # JSON: "null" or array of regex strings
    local output="${SCRIPT_DIR}/${service}.json"

    local handler_path="${SCRIPT_DIR}/${handler}"
    if [[ ! -x "$handler_path" ]]; then
        error "Handler not found or not executable: $handler_path"
        exit $EXIT_EXTRACTION_FAILURE
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[dry-run] Would extract: $handler $(basename "$input") -> $(basename "$output")"
        [[ "$allowed_paths_json" != "null" ]] && info "[dry-run]   with EXTRACTION_PATH_REGEXES=$allowed_paths_json"
        EXTRACT_RESULT="$output"
        return
    fi

    info "Extracting: $handler $(basename "$input") -> $(basename "$output")"
    if [[ "$allowed_paths_json" != "null" ]]; then
        SERVICE_MODULE_NAME="$service" EXTRACTION_PATH_REGEXES="$allowed_paths_json" "$handler_path" "$input" "$output" \
            || { error "Extraction failed for $service"; exit $EXIT_EXTRACTION_FAILURE; }
    else
        SERVICE_MODULE_NAME="$service" "$handler_path" "$input" "$output" \
            || { error "Extraction failed for $service"; exit $EXIT_EXTRACTION_FAILURE; }
    fi
    EXTRACT_RESULT="$output"
}

# --- Merge -------------------------------------------------------------------
run_merge() {
    local main_spec="$1"
    shift
    local additional_specs=("$@")

    local output_file
    output_file="$(cfg_output_filename)"
    local api_version
    api_version="$(cfg_output_version)"

    local merge_script="${SCRIPT_DIR}/merge-specs.sh"
    if [[ ! -x "$merge_script" ]]; then
        error "merge-specs.sh not found or not executable: $merge_script"
        exit $EXIT_MERGE_FAILURE
    fi

    # Build -a flags
    local add_flags=()
    for spec in "${additional_specs[@]}"; do
        add_flags+=("-a" "$spec")
    done

    if [[ "$DRY_RUN" == true ]]; then
        info "[dry-run] Would merge: merge-specs.sh $(basename "$main_spec") ${add_flags[*]} -v $api_version -o $output_file"
        return
    fi

    # Pre-track potential *-converted.json files as intermediates.
    # merge-specs.sh converts Swagger 2.0 inputs to *-converted.json but cannot
    # clean them up itself: the INTERMEDIATES+= assignment inside convert_if_needed
    # runs in a command-substitution subshell and is lost when the subshell exits.
    # We add all candidate paths here; [[ -f ]] in cleanup silently skips non-existent ones.
    for spec in "$main_spec" "${additional_specs[@]}"; do
        local dir base
        dir="$(dirname "$spec")"
        base="$(basename "${spec%.*}")"
        INTERMEDIATES+=("${dir}/${base}-converted.json")
    done

    info "Merging into $output_file (version $api_version)..."
    "$merge_script" "$main_spec" "${add_flags[@]}" -v "$api_version" -o "$output_file" \
        || { error "Merge failed"; exit $EXIT_MERGE_FAILURE; }
}

# --- Intermediate cleanup ----------------------------------------------------
INTERMEDIATES=()

cleanup_intermediates() {
    [[ ${#INTERMEDIATES[@]} -eq 0 ]] && return

    echo ""
    if [[ "$KEEP_INTERMEDIATES" == true ]]; then
        info "Keeping intermediate files (--keep-intermediates):"
        for f in "${INTERMEDIATES[@]}"; do
            [[ -f "$f" ]] && info "  $(basename "$f")"
        done
        return
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "Would clean up intermediate files:"
        for f in "${INTERMEDIATES[@]}"; do
            info "  [dry-run] $(basename "$f")"
        done
        return
    fi

    info "Cleaning up intermediate files..."
    for f in "${INTERMEDIATES[@]}"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            info "  Removed $(basename "$f")"
        fi
    done
}

# ===========================================================================
# Main
# ===========================================================================

preflight

# --- Handle --cache-cleanup early -------------------------------------------
if [[ "$CACHE_CLEANUP" == true ]]; then
    do_cache_cleanup
    exit $EXIT_SUCCESS
fi

echo "=== Blockscout Pro API Build ==="
info "Config:  $(basename "$CONFIG_FILE")"
info "Output:  $(cfg_output_filename)"
info "Version: $(cfg_output_version)"
[[ "$DRY_RUN" == true ]]        && info "Mode:    DRY RUN"
[[ "$FORCE_DOWNLOAD" == true ]] && info "Mode:    FORCE DOWNLOAD"
echo ""

# --- Step 0: Fetch modules-config.json (if any service references it) ------
if cfg_uses_modules_config; then
    echo "=== Step 0: Fetch modules-config.json ==="
    MODULES_CONFIG_URL="$(cfg_modules_config_url)"
    info "URL:    $MODULES_CONFIG_URL"
    DOWNLOAD_RESULT=""
    download_with_cache "modules-config" "$MODULES_CONFIG_URL" "json"
    MODULES_CONFIG_FILE="$DOWNLOAD_RESULT"
    # Dry-run does not write the target file; jq --slurpfile needs a real path.
    if [[ "$DRY_RUN" == true && -n "$MODULES_CONFIG_FILE" && ! -f "$MODULES_CONFIG_FILE" ]]; then
        DRY_RUN_MODULES_CONFIG_PLACEHOLDER="$(mktemp "${TMPDIR:-/tmp}/modules-config.dry-run.XXXXXX.json")"
        trap 'rm -f "$DRY_RUN_MODULES_CONFIG_PLACEHOLDER"' EXIT
        jq -n --slurpfile cfg "$CONFIG_FILE" '
            ($cfg[0].source.services | to_entries
                | map(select(.value.from_modules_config))
                | map({key: .value.from_modules_config, value: {
                    swagger_url: "https://dry-run.invalid/swagger.yaml",
                    allowed_paths: []
                }})) as $svc_entries |

            # Separate entries: top-level services vs blockscout.*
            ($svc_entries | map(select(.key | startswith("blockscout.") | not))
                | map({(.key): .value}) | add) as $svcs |
            ($svc_entries | map(select(.key | startswith("blockscout.")))
                | map({(.key | ltrimstr("blockscout.")): .value}) | add) as $bs_svcs |

            # Blockscout entry if from_modules_config is set on blockscout itself
            (if $cfg[0].source.blockscout.from_modules_config then
                { swagger_url: "https://dry-run.invalid/swagger.yaml",
                  services: ($bs_svcs // {}) }
            elif $bs_svcs then
                { services: $bs_svcs }
            else null end) as $bs |

            { services: ($svcs // {}) }
            + if $bs then { blockscout: $bs } else {} end
        ' > "$DRY_RUN_MODULES_CONFIG_PLACEHOLDER"
        MODULES_CONFIG_FILE="$DRY_RUN_MODULES_CONFIG_PLACEHOLDER"
    fi
    echo ""
fi

# --- Step 1: Download swagger files -----------------------------------------
echo "=== Step 1: Download swagger files ==="

# Collect resolved source info into arrays for ordered processing
declare -a SOURCE_NAMES=()
declare -a SOURCE_URLS=()
declare -a SOURCE_HANDLERS=()
declare -a SOURCE_ALLOWED_PATHS=()
declare -a DOWNLOADED_FILES=()

while IFS=$'\t' read -r name url handler allowed_paths; do
    SOURCE_NAMES+=("$name")
    SOURCE_URLS+=("$url")
    SOURCE_HANDLERS+=("$handler")
    SOURCE_ALLOWED_PATHS+=("$allowed_paths")
done <<< "$(resolve_sources_tsv)"

for i in "${!SOURCE_NAMES[@]}"; do
    DOWNLOAD_RESULT=""
    download_with_cache "${SOURCE_NAMES[$i]}" "${SOURCE_URLS[$i]}" "yaml"
    DOWNLOADED_FILES+=("$DOWNLOAD_RESULT")
done
echo ""

# --- Step 2: Run extraction scripts -----------------------------------------
echo "=== Step 2: Extract specs ==="

declare -a EXTRACTED_FILES=()

for i in "${!SOURCE_NAMES[@]}"; do
    EXTRACT_RESULT=""
    run_extraction \
        "${SOURCE_NAMES[$i]}" \
        "${DOWNLOADED_FILES[$i]}" \
        "${SOURCE_HANDLERS[$i]}" \
        "${SOURCE_ALLOWED_PATHS[$i]}"
    EXTRACTED_FILES+=("$EXTRACT_RESULT")
    INTERMEDIATES+=("$EXTRACT_RESULT")
done
echo ""

# --- Step 3: Merge -----------------------------------------------------------
echo "=== Step 3: Merge specs ==="

# First extracted file is the main spec (blockscout), rest are additional
MAIN_SPEC="${EXTRACTED_FILES[0]}"
ADDITIONAL_SPECS=("${EXTRACTED_FILES[@]:1}")

run_merge "$MAIN_SPEC" "${ADDITIONAL_SPECS[@]}"
echo ""

# --- Cleanup -----------------------------------------------------------------
cleanup_intermediates

# --- Summary -----------------------------------------------------------------
if [[ "$DRY_RUN" != true ]]; then
    OUTPUT_PATH="${SCRIPT_DIR}/$(cfg_output_filename)"
    PATHS=$(jq '.paths | length' "$OUTPUT_PATH")
    SCHEMAS=$(jq '.components.schemas | length' "$OUTPUT_PATH")
    echo ""
    echo "=== Build Complete ==="
    info "Output:  $(cfg_output_filename)"
    info "Version: $(cfg_output_version)"
    info "Paths:   $PATHS"
    info "Schemas: $SCHEMAS"
fi

exit $EXIT_SUCCESS
