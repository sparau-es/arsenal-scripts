#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Reproducible audit of an IPSW and its dyld shared cache.
#
# This script:
#   1. Verifies the expected IPSW.
#   2. Extracts dyld_shared_cache_arm64e if it does not already exist.
#   3. Saves hashes and cache metadata.
#   4. Lists relevant images.
#   5. Collects symbols for JavaScriptCore, WebCore, and dyld.
#
# It does not calculate or apply return-sites, runtime slides, or writes.
# ============================================================

readonly IPSW="/home/test/Desktop/ipwsPy/iPhone11,8_18.4.1_22E252_Restore.ipsw"
readonly EXPECTED_DEVICE="iPhone11,8"
readonly EXPECTED_VERSION="18.4.1"
readonly EXPECTED_BUILD="22E252"

readonly WORK_ROOT="/home/test/Desktop/ipwsPy/22E252_offset_audit"
readonly EXTRACT_ROOT="$WORK_ROOT/extracted"
readonly REPORT_ROOT="$WORK_ROOT/report"

# Dedicated temporary directory. Go/ipsw respects TMPDIR on Linux.
# Can be overridden at execution:
#   IPSW_TMPDIR=/mnt/large_disk/ipsw_tmp ./audit_22E252_offsets_v2.sh
readonly TMP_ROOT="${IPSW_TMPDIR:-$WORK_ROOT/tmp}"

# If find locates more than one cache, it can be executed like this:
# DSC_OVERRIDE=/path/to/dyld_shared_cache_arm64e ./audit_22E252_offsets.sh
readonly DSC_OVERRIDE="${DSC_OVERRIDE:-}"

mkdir -p "$EXTRACT_ROOT" "$REPORT_ROOT" "$TMP_ROOT"
chmod 700 "$TMP_ROOT"
export TMPDIR="$TMP_ROOT"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

fail() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

on_error() {
    local exit_code=$?
    local line_no=${1:-unknown}
    printf '[ERROR] Failure on line %s (exit=%s).\n' "$line_no" "$exit_code" >&2
    printf '[ERROR] Check: %s\n' "$REPORT_ROOT" >&2
    exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

for cmd in ipsw find grep sed awk sha256sum sort tee wc df id; do
    require_command "$cmd"
done

# ------------------------------------------------------------
# Disk space/quota diagnostics and temporary configuration
# ------------------------------------------------------------
{
    echo "TMPDIR=$TMPDIR"
    echo
    echo "=== df -h ==="
    df -h "$TMP_ROOT" "$EXTRACT_ROOT" || true
    echo
    echo "=== df -i ==="
    df -i "$TMP_ROOT" "$EXTRACT_ROOT" || true
    echo
    echo "=== quota -s ==="
    if command -v quota >/dev/null 2>&1; then
        quota -s 2>&1 || true
    else
        echo "quota is not installed"
    fi
} | tee "$REPORT_ROOT/storage-preflight.txt"

TMP_FREE_KB="$(df -Pk "$TMP_ROOT" | awk 'NR==2 {print $4}')"
TMP_FREE_GIB=$(( TMP_FREE_KB / 1024 / 1024 ))
log "Dedicated TMPDIR: $TMPDIR (${TMP_FREE_GIB} GiB free according to df)"

if (( TMP_FREE_GIB < 20 )); then
    warn "Less than 20 GiB free in TMPDIR. Extraction might require significant additional temporary space."
fi

# As this is a dedicated TMPDIR for this audit, only old temporaries 
# from this script are removed before a new extraction.
find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -name 'ipsw_extract_*' -user "$(id -un)" -print -exec rm -rf -- {} + \
    > "$REPORT_ROOT/removed-stale-temp.txt" 2>&1 || true

[[ -f "$IPSW" ]] || fail "IPSW does not exist: $IPSW"
[[ -r "$IPSW" ]] || fail "Cannot read IPSW: $IPSW"

log "IPSW: $IPSW"
log "Working directory: $WORK_ROOT"
log "Temporary directory: $TMPDIR"

# ------------------------------------------------------------
# 1. Tool version and IPSW fingerprint
# ------------------------------------------------------------
{
    ipsw version 2>/dev/null || ipsw --version 2>/dev/null || true
} | tee "$REPORT_ROOT/ipsw-version.txt"

sha256sum "$IPSW" | tee "$REPORT_ROOT/ipsw-sha256.txt"

# ------------------------------------------------------------
# 2. Verify IPSW metadata
# ------------------------------------------------------------
log "Reading IPSW metadata..."

ipsw info "$IPSW" \
    --json \
    --no-color \
    > "$REPORT_ROOT/ipsw-info.json" \
    2> "$REPORT_ROOT/ipsw-info.stderr.txt"

# Some versions write SystemVersion info to stdout.
# Stderr is also kept to diagnose differences between versions.
ipsw extract \
    --sys-ver \
    --no-color \
    "$IPSW" \
    > "$REPORT_ROOT/system-version.txt" \
    2> "$REPORT_ROOT/system-version.stderr.txt" || {
        warn "ipsw extract --sys-ver did not finish correctly; continuing using ipsw-info.json."
    }

cat "$REPORT_ROOT/ipsw-info.json" "$REPORT_ROOT/system-version.txt" \
    > "$REPORT_ROOT/version-validation-input.txt"

for expected in "$EXPECTED_DEVICE" "$EXPECTED_VERSION" "$EXPECTED_BUILD"; do
    if ! grep -Fq "$expected" "$REPORT_ROOT/version-validation-input.txt"; then
        fail "'$expected' does not appear in metadata. Not proceeding with unverified build."
    fi
done

log "Verified build: $EXPECTED_DEVICE / iOS $EXPECTED_VERSION / $EXPECTED_BUILD"

# ------------------------------------------------------------
# 3. Extract or locate dyld_shared_cache_arm64e
# ------------------------------------------------------------
if [[ -n "$DSC_OVERRIDE" ]]; then
    [[ -f "$DSC_OVERRIDE" ]] || fail "DSC_OVERRIDE does not point to a file: $DSC_OVERRIDE"
    DSC="$DSC_OVERRIDE"
else
    mapfile -t CACHES < <(
        find "$EXTRACT_ROOT" -type f -name 'dyld_shared_cache_arm64e' -print | sort
    )

    if (( ${#CACHES[@]} == 0 )); then
        log "Extracting dyld shared cache arm64e..."

        ipsw extract \
            --dyld \
            --dyld-arch arm64e \
            --output "$EXTRACT_ROOT" \
            --no-color \
            "$IPSW" \
            2>&1 | tee "$REPORT_ROOT/extract-dyld.log"

        mapfile -t CACHES < <(
            find "$EXTRACT_ROOT" -type f -name 'dyld_shared_cache_arm64e' -print | sort
        )
    else
        log "Reusing already extracted cache."
    fi

    if (( ${#CACHES[@]} == 0 )); then
        fail "dyld_shared_cache_arm64e not found after extraction."
    fi

    if (( ${#CACHES[@]} > 1 )); then
        {
            echo "Multiple candidate caches found:"
            printf '  %s\n' "${CACHES[@]}"
            echo
            echo "Execute by indicating one of them:"
            echo "  DSC_OVERRIDE=/path/to/dyld_shared_cache_arm64e $0"
        } | tee "$REPORT_ROOT/multiple-caches.txt" >&2
        exit 1
    fi

    DSC="${CACHES[0]}"
fi

readonly DSC
readonly DSC_DIR="$(dirname "$DSC")"
readonly DSC_BASE="$(basename "$DSC")"

log "Selected cache: $DSC"
printf '%s\n' "$DSC" > "$REPORT_ROOT/selected-dsc.txt"

# Hash of the main cache and its subcaches.
find "$DSC_DIR" -maxdepth 1 -type f -name "${DSC_BASE}*" -print0 \
    | sort -z \
    | xargs -0 -r sha256sum \
    | tee "$REPORT_ROOT/dsc-sha256.txt"

# ------------------------------------------------------------
# 4. Cache metadata and image listing
# ------------------------------------------------------------
log "Generating dyld shared cache metadata..."

ipsw dyld info "$DSC" \
    --json \
    --no-color \
    > "$REPORT_ROOT/dyld-info.json" \
    2> "$REPORT_ROOT/dyld-info.stderr.txt"

ipsw dyld info "$DSC" \
    --dylibs \
    --no-color \
    > "$REPORT_ROOT/dyld-dylibs.txt" \
    2> "$REPORT_ROOT/dyld-dylibs.stderr.txt"

ipsw dyld image "$DSC" \
    --no-color \
    > "$REPORT_ROOT/images.txt" \
    2> "$REPORT_ROOT/images.stderr.txt"

grep -Ei 'JavaScriptCore|WebCore|(^|/)(dyld)([[:space:]]|$)|/usr/lib/dyld' \
    "$REPORT_ROOT/images.txt" \
    | tee "$REPORT_ROOT/relevant-images.txt" \
    || true

# ------------------------------------------------------------
# 5. Symbol dumping and filtering
# ------------------------------------------------------------
run_symaddr() {
    local label="$1"
    local image="$2"
    local pattern="$3"

    local raw="$REPORT_ROOT/${label}.symbols.txt"
    local err="$REPORT_ROOT/${label}.stderr.txt"
    local matches="$REPORT_ROOT/${label}.matches.txt"

    log "Collecting symbols: label=$label image=$image"

    if ipsw dyld symaddr "$DSC" \
        --image "$image" \
        --no-color \
        > "$raw" \
        2> "$err"; then

        grep -Ei "$pattern" "$raw" \
            | tee "$matches" \
            || true
    else
        warn "symaddr failed for '$image'. Check $err"
        : > "$matches"
        return 1
    fi
}

run_symaddr \
    "JavaScriptCore" \
    "JavaScriptCore" \
    'globalFuncParseFloat|jitAllowList' \
    || true

run_symaddr \
    "WebCore" \
    "WebCore" \
    'allScriptExecutionContextsMap|DedicatedWorkerGlobalScope|getPKContact|initPKContact|softLinkDDD|softLinkMedia|softLinkOTSVG|TelephoneNumber|WebProcess_singleton|WebProcess_ensureGPU|WebProcess_gpuProcess' \
    || true

# dyld can be registered as a full path or as a short name.
DYLD_OK=false
for dyld_image in '/usr/lib/dyld' 'dyld'; do
    label="dyld-$(printf '%s' "$dyld_image" | sed 's#[^A-Za-z0-9._-]#_#g')"

    if run_symaddr \
        "$label" \
        "$dyld_image" \
        'RuntimeState|emptySlot|dlopen'; then

        if [[ -s "$REPORT_ROOT/${label}.symbols.txt" ]]; then
            printf '%s\n' "$dyld_image" > "$REPORT_ROOT/selected-dyld-image.txt"
            cp "$REPORT_ROOT/${label}.symbols.txt" "$REPORT_ROOT/dyld.symbols.txt"
            cp "$REPORT_ROOT/${label}.matches.txt" "$REPORT_ROOT/dyld.matches.txt"
            cp "$REPORT_ROOT/${label}.stderr.txt" "$REPORT_ROOT/dyld.stderr.txt"
            DYLD_OK=true
            break
        fi
    fi
done

if [[ "$DYLD_OK" != true ]]; then
    warn "Could not dump dyld with '/usr/lib/dyld' or 'dyld'."
    warn "Check relevant-images.txt and try with the exact name shown by ipsw."
    : > "$REPORT_ROOT/dyld.matches.txt"
fi

# ------------------------------------------------------------
# 6. Summary
# ------------------------------------------------------------
count_lines() {
    local file="$1"
    if [[ -f "$file" ]]; then
        wc -l < "$file" | tr -d ' '
    else
        printf '0'
    fi
}

{
    echo "IPSW=$IPSW"
    echo "EXPECTED_DEVICE=$EXPECTED_DEVICE"
    echo "EXPECTED_VERSION=$EXPECTED_VERSION"
    echo "EXPECTED_BUILD=$EXPECTED_BUILD"
    echo "DSC=$DSC"
    echo "REPORT_ROOT=$REPORT_ROOT"
    echo "JSC_MATCHES=$(count_lines "$REPORT_ROOT/JavaScriptCore.matches.txt")"
    echo "WEBCORE_MATCHES=$(count_lines "$REPORT_ROOT/WebCore.matches.txt")"
    echo "DYLD_MATCHES=$(count_lines "$REPORT_ROOT/dyld.matches.txt")"
} | tee "$REPORT_ROOT/summary.txt"

cat <<SUMMARY

============================================================
Audit finished.

Results:
  $REPORT_ROOT

Main files:
  $REPORT_ROOT/ipsw-info.json
  $REPORT_ROOT/system-version.txt
  $REPORT_ROOT/dsc-sha256.txt
  $REPORT_ROOT/dyld-info.json
  $REPORT_ROOT/relevant-images.txt
  $REPORT_ROOT/JavaScriptCore.matches.txt
  $REPORT_ROOT/WebCore.matches.txt
  $REPORT_ROOT/dyld.matches.txt
  $REPORT_ROOT/summary.txt

The script only collects and validates static metadata/symbols.
It does not calculate return-sites or apply runtime modifications.
============================================================
SUMMARY
