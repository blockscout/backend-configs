# Blockscout Pro API — OpenAPI Specification Preparation Workflow

This document describes the end-to-end workflow for building a unified OpenAPI 3.0 specification for the **Blockscout Pro API** from four separate upstream Swagger/OpenAPI sources.

## Overview

The Pro API specification provides a single, multi-chain API surface that unifies:

| Service | Purpose | Spec Format |
|---------|---------|-------------|
| **Blockscout** (core explorer) | Addresses, transactions, blocks, tokens, NFTs, contracts | OpenAPI 3.0 |
| **Stats Service** | Chain statistics and charts | Swagger 2.0 |
| **Multichain Aggregator** | Cross-chain search (tokens, addresses, blocks, transactions, NFTs, domains) | Swagger 2.0 |
| **Metadata Service** | Token/address metadata | Swagger 2.0 |

The final output is a single OpenAPI 3.0.0 JSON file (`pro-api.json`) branded as "Blockscout Pro API", with two interchangeable auth methods (Bearer token in the `Authorization` header **or** `apikey` query parameter) and rate-limit response headers on every endpoint.

> **Scope note**: The spec does **not** include pure Pro API management endpoints (available at `https://api.blockscout.com/api/json/open_api`).

---

## Prerequisites

- **oastools** — CLI for parsing, overlaying, converting, joining, and validating OpenAPI specs. [Installation instructions](https://erraggy.github.io/oastools/developer-guide/#installation).
- **jq** (1.6+) — Used for transforms the OAS Overlay Specification cannot express (dynamic values, array-element filtering, map-key renames)
- **curl** — For downloading swagger files from GitHub
- **gh** (optional) — GitHub CLI; used for authenticated API calls when resolving commit hashes (higher rate limits). Falls back to unauthenticated `curl` if unavailable.

---

## Quick Start

The entire pipeline is orchestrated by `build-pro-api.sh`:

```
./build-pro-api.sh
```

This single command downloads source swaggers, runs all extraction scripts, merges the results, validates the output, and cleans up intermediate artifacts. Configuration is read from `config.json`.

### Common Options

```
./build-pro-api.sh                          # Full build with defaults
./build-pro-api.sh --dry-run                # Show what would happen
./build-pro-api.sh --force                  # Re-download even if cached
./build-pro-api.sh --keep-intermediates     # Keep extraction .json files
./build-pro-api.sh --cache-cleanup          # Remove all cached downloads
./build-pro-api.sh -c custom-config.json    # Use a different config
```

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Config error (missing/invalid config.json, missing dependencies) |
| 2 | Download failure (network, 404, GitHub API rate limit) |
| 3 | Extraction failure (handler script error) |
| 4 | Merge/validation failure |

---

## Configuration — `config.json`

`config.json` declares output settings and source services. Each source service can be configured in one of two ways:

- **Static**: pin a specific `swagger` URL inline. Used for sources that don't appear in `modules-config.json` (e.g. `blockscout`, `stats-service`).
- **From modules-config**: reference an entry in [`pro-api/prod/modules-config.json`](https://github.com/blockscout/backend-configs/blob/main/pro-api/prod/modules-config.json) by key. The `swagger_url` and `allowed_paths` regex allowlist are read from there at build time.

```json
{
  "output": {
    "filename": "pro-api.json",
    "version": "0.5.0"
  },
  "modules_config": {
    "url": "https://raw.githubusercontent.com/blockscout/backend-configs/main/pro-api/prod/modules-config.json"
  },
  "source": {
    "blockscout": {
      "swagger": "https://raw.githubusercontent.com/.../swagger.yaml",
      "handler": "blockscout-extract.sh"
    },
    "services": {
      "stats-service": {
        "swagger": "https://raw.githubusercontent.com/.../swagger.yaml",
        "handler": "stats-service-extract.sh"
      },
      "metadata": {
        "from_modules_config": "metadata",
        "handler": "extract-metadata.sh"
      },
      "multichain": {
        "from_modules_config": "multichain",
        "handler": "extract-multichain.sh"
      }
    }
  }
}
```

| Field | Description |
|-------|-------------|
| `output.filename` | Name of the final merged spec file |
| `output.version` | Value written to `info.version` in the output |
| `modules_config.url` | URL of the `modules-config.json` to use as the source of truth for services that opt in via `from_modules_config`. Required when any service uses `from_modules_config`. |
| `source.blockscout` | The primary spec (becomes the main input to merge) |
| `source.services.*` | Additional service specs (merged as `-a` inputs) |
| `*.swagger` | Raw GitHub URL to download the swagger YAML (static mode) |
| `*.from_modules_config` | Name of the service entry in `modules-config.json` whose `swagger_url` + `allowed_paths` should be used (modules-config mode). Mutually exclusive with `swagger`. |
| `*.handler` | Extraction script filename (must be in the same directory) |

### Why two modes?

`modules-config.json` is the production source of truth for which upstream service versions are deployed and which endpoint paths are exposed through the Pro API gateway. Pinning the spec build to it eliminates drift: when ops bumps a service version or extends `allowed_paths`, the next spec build picks the change up automatically, with no separate edit to this directory.

For services that are not (yet) listed in `modules-config.json` — currently `blockscout` and `stats-service` — the static `swagger` URL is used.

### Version Discovery (static-mode services only)

Source URLs in static-mode entries must include the correct version path segment:

- **Blockscout**: Always use `master` directory in `blockscout/swaggers` repo (contains all chain-type endpoints).
- **Stats Service**: Check latest `stats/<version>` release tag in [blockscout-rs releases](https://github.com/blockscout/blockscout-rs/releases).

Versions for `metadata` and `multichain` are no longer pinned here — they come from whatever `modules-config.json` references in production.

---

## Step 0: Fetch `modules-config.json`

When at least one service uses `from_modules_config`, `build-pro-api.sh` fetches the configured `modules_config.url` first and caches it as `modules-config.<commit-hash>.json` (same commit-hash caching as swagger files). The downloaded JSON is then consulted during source resolution to fill in:

- `swagger_url` → the URL passed to the swagger-download step
- `allowed_paths` → an array of regex strings exposed to the relevant extraction handler via the `EXTRACTION_PATH_REGEXES` environment variable

Example `modules-config.json` excerpt:

```json
{
  "services": {
    "multichain": {
      "swagger_url": "https://raw.githubusercontent.com/.../swagger.yaml",
      "allowed_paths": [
        "^/api/v1/search:quick$",
        "^/api/v1/clusters/[^/]+/search/(?:addresses|block-numbers|blocks|domains|nfts|tokens|transactions)$",
        "^/api/v1/clusters/[^/]+/search:quick$",
        "^/api/v1/clusters/[^/]+/chains$"
      ]
    },
    "metadata": {
      "swagger_url": "https://raw.githubusercontent.com/.../swagger.yaml",
      "allowed_paths": ["^/api/v1/metadata$"]
    }
  }
}
```

---

## Step 1: Download Source Specs

`build-pro-api.sh` downloads each swagger file (and `modules-config.json`, if referenced) with **commit-hash caching**.

### Caching Mechanism

Downloaded files are stored as `<name>.<commit-hash>.<ext>`, where `<commit-hash>` is the first 7 characters of the latest Git commit SHA that touched the file in its upstream repository.

| Cached file example | Meaning |
|---------------------|---------|
| `blockscout.aa8c6d4.yaml` | Blockscout swagger at commit `aa8c6d4` |
| `stats-service.47d6cfd.yaml` | Stats Service swagger at commit `47d6cfd` |
| `modules-config.3f1a902.json` | `modules-config.json` snapshot at commit `3f1a902` |

**Cache lookup flow:**

1. Parse the raw GitHub URL to extract `owner`, `repo`, and `path`
2. Query `gh api repos/{owner}/{repo}/commits?path={path}&per_page=1` for the latest commit SHA (falls back to unauthenticated `curl` if `gh` is unavailable)
3. If `<name>.<hash>.<ext>` already exists locally — cache hit, skip download
4. Otherwise download and save with the commit-hash filename; stale cached versions for the same name are removed automatically

**Flags affecting download:**

| Flag | Effect |
|------|--------|
| `--force` | Re-download even if the cached file exists |
| `--cache-cleanup` | Remove all cached swagger downloads and the `modules-config.*.json` cache, then exit |
| `--dry-run` | Show what would be downloaded without fetching |

If the commit hash cannot be determined (e.g., rate-limited), the file is downloaded as `<name>.unknown.<ext>` with a warning.

---

## Step 2: Purification & Standardization (Extract Scripts)

Each service has a dedicated extraction script that strips unwanted content, adds multi-chain routing parameters, and normalizes the spec for merging.

### 2a. Blockscout — `blockscout-extract.sh`

```
./blockscout-extract.sh blockscout.<hash>.yaml blockscout.json
```

**Pipeline**: `oastools parse` → `oastools overlay apply` (with `blockscout-overlay.yaml`) → `jq`

**What it does (6 transforms):**

| # | Transform | Tool | Why |
|---|-----------|------|-----|
| 1 | Remove `/v2/config/*` (or `/api/v2/config/*`) endpoints | jq | Config endpoints are instance-specific, not relevant for the Pro API. A regex covers both upstream formats; see "Format auto-detection" below. |
| 2 | Remove all non-GET operations (POST, PUT, PATCH, DELETE, OPTIONS, HEAD, TRACE) | Overlay | Pro API is read-only |
| 3 | Remove `key` and `apikey` query parameters | jq | Per-instance auth params replaced by Bearer/apikey at the merge stage; overlay can't filter array elements by value |
| 4 | Remove `x-struct` and `x-validate` vendor extensions | Overlay | Elixir-specific extensions; recursive-descent `$..field` remove drops them everywhere |
| 5 | Add required `{chain_id}` path parameter to all GET operations | Overlay + jq fixup | Overlay appends to existing `parameters` arrays; jq handles operations that lack a `parameters` key entirely |
| 6 | Normalise paths so they end up under `/{chain_id}/api/...` | jq | See "Format auto-detection" — the prefix is chosen dynamically. |

**Format auto-detection.** Two upstream Blockscout swagger formats coexist; the script handles both:

| Format | Path keys look like | Server URL | Detection rule | Applied prefix |
|--------|--------------------|------------|----------------|----------------|
| Legacy | `/v2/blocks` | `http://localhost/api` | No path key starts with `/api/` | `/{chain_id}/api` |
| Current | `/api/v2/blocks` | `http://localhost` | At least one path key starts with `/api/` | `/{chain_id}` |

Both formats normalise to identical output keys (e.g. `/{chain_id}/api/v2/blocks`).

**Overlay file** (`blockscout-overlay.yaml`): Handles map-key deletion (HTTP methods, vendor extensions) and array-append (chain_id parameter) — operations that the OAS Overlay Specification supports natively.

**Why the oastools + jq split?** The overlay handles structural removal and array append well, but the following operations require jq:
- Array element filtering by value (removing specific parameters leaves null holes in overlay)
- Removing config paths by pattern across two upstream formats (overlay would need format-specific literal targets)
- Dynamic key renaming (path prefix)

### 2b. Stats Service — `stats-service-extract.sh`

```
./stats-service-extract.sh stats-service.<hash>.yaml stats-service.json
```

**Pipeline**: `oastools parse` → `oastools overlay apply` (with `stats-service-overlay.yaml`) → `jq`

**What it does (7 transforms):**

| # | Transform | Tool |
|---|-----------|------|
| 1 | Remove `/health` endpoint | Overlay |
| 2 | Remove `/api/v1/update-status` endpoint (internal monitoring) | Overlay |
| 3 | Remove all non-GET operations + prune empty path items | Overlay + jq |
| 4 | BFS-traverse `$ref` pointers to find all transitively-needed definitions, prune the rest | jq |
| 5 | Remove tags not used by kept operations | jq |
| 6 | Add required `{chain_id}` path parameter to all GET operations | jq |
| 7 | Prefix all paths with `/{chain_id}/stats-service` | jq |

The overlay also removes `securityDefinitions` (Swagger 2.0 auth definitions), since auth will be unified at the merge stage.

After the overlay removes non-GET methods, some path items become empty objects (e.g., paths that only had POST). The jq pass prunes these with `select(.value | keys | length > 0)`.

Uses the same BFS `$ref` closure algorithm as the multichain and metadata scripts to ensure only transitively-reachable definitions are kept.

### 2c. Multichain Aggregator — `extract-multichain.sh`

```
./extract-multichain.sh multichain.<hash>.yaml multichain.json
```

**Pipeline**: `oastools parse` → `jq` (all transforms)

**What it does (4 transforms):**

| # | Transform |
|---|-----------|
| 1 | Keep only paths matching the regex allowlist |
| 2 | Prefix each kept path with `/services/multichain` |
| 3 | BFS-traverse `$ref` pointers to find all transitively-needed definitions, prune the rest |
| 4 | Remove tags not used by kept operations |

**Path selection.** The regex allowlist comes from one of two places:

- `EXTRACTION_PATH_REGEXES` env var (JSON array of regex strings) — set by `build-pro-api.sh` from the `multichain.allowed_paths` field of `modules-config.json` when the service is configured with `from_modules_config`.
- Hardcoded fallback `SOURCE_PATH_REGEXES` inside the script — used only when the script is invoked standalone without the env var. The fallback mirrors the production `modules-config.json` allowlist (kept in sync but not the source of truth).

Each path key in the input swagger is kept iff at least one regex matches it. If no path matches, the script fails fast.

**BFS definition closure**: The script doesn't just keep directly-referenced `#/definitions/` — it performs a breadth-first traversal to discover all transitively-reachable definitions. This ensures nested schema references (e.g., a response type referencing a pagination type referencing a link type) are all preserved.

> **Important**: This script operates on Swagger 2.0 input. The `$ref` prefix is `#/definitions/`. If the upstream ever migrates to OpenAPI 3.x, change `REF_PREFIX` to `#/components/schemas/`.

### 2d. Metadata Service — `extract-metadata.sh`

```
./extract-metadata.sh metadata.<hash>.yaml metadata.json
```

**Pipeline**: `oastools parse` → `jq` (all transforms)

**What it does (4 transforms):**

| # | Transform |
|---|-----------|
| 1 | Keep only paths matching the regex allowlist |
| 2 | Prefix each kept path with `/services/metadata` |
| 3 | BFS-traverse `$ref` to find and keep only transitively-needed definitions |
| 4 | Remove tags not used by kept operations |

Same regex-allowlist mechanism as `extract-multichain.sh`: `EXTRACTION_PATH_REGEXES` env var (set by `build-pro-api.sh` from `metadata.allowed_paths` in `modules-config.json`) wins over the hardcoded fallback. The default fallback matches the single `/api/v1/metadata` endpoint.

Uses the same BFS `$ref` closure algorithm as the multichain script.

---

## Step 3: Convert, Join, Enrich — `merge-specs.sh`

> **Note:** `merge-specs.sh` is not intended to be invoked directly. It is called
> by `build-pro-api.sh`, which pre-tracks converted intermediates and handles
> cleanup. Running it standalone may leave `*-converted.json` files behind
> because the Swagger 2.0 conversion tracking runs in a subshell and cannot
> propagate the intermediate list back to the parent process.

```
./merge-specs.sh blockscout.json -v 0.5.0 -a stats-service.json -a multichain.json -a metadata.json -o pro-api.json
```

This is a 4-phase pipeline that produces the final unified spec.

### Phase 1: Detect & Convert Swagger 2.0 → OpenAPI 3.0.0

Each input file is inspected via `oastools validate --format json` to detect its OAS version. Swagger 2.0 files are automatically converted to OpenAPI 3.0.0 using `oastools convert -t 3.0.0`. Converted files are saved as `*-converted.json` intermediates.

In this workflow, the blockscout spec (already OAS 3.0) passes through unchanged, while stats-service, multichain, and metadata specs (Swagger 2.0) are converted.

### Phase 2: Join Specs with Post-Overlay

All specs are joined using:

```
oastools join \
    --path-strategy fail \
    --collision-report \
    --post-overlay merge-overlay.yaml \
    <main-spec> <additional-specs...>
```

**Join flags:**
- `--path-strategy fail` — Fail if two specs define the same path (since each extraction script uses unique prefixes, this catches accidental overlap)
- `--collision-report` — Report any schema name collisions during merge
- `--post-overlay merge-overlay.yaml` — Apply branding, security, tag cleanup, and enrichment after joining

> **Note**: `--semantic-dedup` is intentionally **disabled** until [#363](https://github.com/erraggy/oastools/issues/363) is resolved. It consolidates schemas that share the same validation structure but differ in documentation fields (`description`, `title`, `example`), producing factually incorrect API docs (e.g. a 403 Forbidden response referencing a schema whose description says "request is invalid").

**Post-overlay** (`merge-overlay.yaml`) applies:

| Transform | Details |
|-----------|---------|
| **Tag cleanup** | Removes the top-level `tags` array (unused after join) |
| **Global security** | Sets root-level `security: [{bearerAuth: []}, {apiKeyAuth: []}]` so every operation accepts either a Bearer token or an `apikey` query parameter (security alternatives are OR'd) |
| **Branding** | Sets `info.title` to "Blockscout Pro API", adds summary and contact URL |
| **Security schemes** | Adds two entries to `components.securitySchemes`: `bearerAuth` (HTTP Bearer/JWT in the `Authorization` header) and `apiKeyAuth` (`apikey` query parameter) |
| **Rate-limit headers** | Adds 4 response headers to every GET 200 response: `x-credits-remaining`, `x-ratelimit-limit`, `x-ratelimit-remaining`, `x-ratelimit-reset` |

### Phase 3: Post-Processing (jq)

Two transforms that the OAS Overlay Specification cannot express are applied via jq:

| Transform | Reason for jq fallback |
|-----------|------------------------|
| `.servers = [{"url": "https://api.blockscout.com"}]` — Replace servers | Overlay `update` appends to arrays, cannot replace a list (by design) |
| `.info.version = $version` — Set API version | Dynamic value from `-v` flag, not expressible in a static overlay |

### Phase 4: Validate

The final spec is validated using `oastools validate` to ensure it conforms to the OpenAPI 3.0.0 specification.

**Cleanup**: Intermediate files (`*-converted.json`, temp jq output) are automatically removed unless `--keep-intermediates` is passed.

---

## Final Output

The resulting `pro-api.json` is a single OpenAPI 3.0.0 specification with:

- Paths across 4 service prefixes:
  - `/{chain_id}/api/v2/...` — Blockscout core explorer (read-only)
  - `/{chain_id}/stats-service/...` — Statistics and charts
  - `/services/multichain/...` — Cross-chain search
  - `/services/metadata/...` — Token/address metadata
- Component schemas — deduplicated across all source specs
- **Single server**: `https://api.blockscout.com`
- **Global auth**: either `bearerAuth` (Bearer token in `Authorization` header) or `apiKeyAuth` (`apikey` query parameter)
- **Rate-limit headers** on all 200 responses

---

## Path Prefix Summary

Understanding the path prefixes is key to the routing architecture:

| Prefix | Service | Notes |
|--------|---------|-------|
| `/{chain_id}/api/...` | Blockscout core | `chain_id` is a required path parameter |
| `/{chain_id}/stats-service/...` | Stats Service | `chain_id` is a required path parameter |
| `/services/multichain/api/v1/clusters/{cluster_id}/...` | Multichain Aggregator | Uses `cluster_id` from upstream spec |
| `/services/multichain/api/v1/...` | Multichain Aggregator (global search) | No cluster scoping |
| `/services/metadata/api/v1/...` | Metadata Service | Single endpoint |

---

## Artifact Lifecycle

Files in the working directory fall into four categories with different lifecycles:

| Category | Pattern | Created By | Cleaned By |
|----------|---------|------------|------------|
| **Tooling** | `*.sh`, `*-overlay.yaml`, `config.json`, `*.md` | Hand-authored | — (permanent) |
| **Cached swagger downloads** | `<service>.<hash>.yaml` | `build-pro-api.sh` Step 1 | `--cache-cleanup` flag |
| **Cached modules-config** | `modules-config.<hash>.json` | `build-pro-api.sh` Step 0 | `--cache-cleanup` flag |
| **Extraction intermediates** | `<service>.json` | Extract scripts (Step 2) | Automatic (default); kept with `--keep-intermediates` |
| **Merge intermediates** | `*-converted.json`, `*.tmp` | `merge-specs.sh` Phases 1 & 3 | Automatic (managed by `build-pro-api.sh`; see note below) |
| **Final output** | `pro-api.json` | `merge-specs.sh` Phase 4 | — (the deliverable) |

After a default run of `build-pro-api.sh`, only tooling, cached downloads, and the final output remain.

---

## File Inventory

| File | Type | Purpose |
|------|------|---------|
| `build-pro-api.sh` | Script | **Orchestrator** — full pipeline: download, extract, merge, cleanup |
| `config.json` | Config | Source URLs, handler mappings, output settings |
| `blockscout-extract.sh` | Script | Extract + transform Blockscout spec |
| `stats-service-extract.sh` | Script | Extract + transform Stats Service spec |
| `extract-multichain.sh` | Script | Extract + transform Multichain Aggregator spec |
| `extract-metadata.sh` | Script | Extract + transform Metadata Service spec |
| `merge-specs.sh` | Script | Convert, join, enrich, validate (called by `build-pro-api.sh`; not for standalone use) |
| `blockscout-overlay.yaml` | Overlay | Blockscout: remove non-GET methods, vendor extensions, add chain_id |
| `stats-service-overlay.yaml` | Overlay | Stats: remove /health, non-GET methods, securityDefinitions |
| `merge-overlay.yaml` | Overlay | Post-merge: branding, security schemes (bearerAuth + apiKeyAuth), rate-limit headers |
