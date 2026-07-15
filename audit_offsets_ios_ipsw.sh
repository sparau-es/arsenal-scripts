#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Reproducible audit of an IPSW and its dyld shared cache.
#
# This script:
#   1. Verifies the expected IPSW.
#   2. Extracts dyld_shared_cache_arm64e if it doesn't exist yet.
#   3. Saves hashes and metadata of the cache.
#   4. Lists relevant images.
#   5. Collects symbols from JavaScriptCore, WebCore and dyld.
#
# It does not compute or apply return-sites, runtime slides, or writes.
# ============================================================

readonly IPSW="/home/test/Desktop/ipwsPy/iPhone11,8_18.4.1_22E252_Restore.ipsw"
readonly EXPECTED_DEVICE="iPhone11,8"
readonly EXPECTED_VERSION="18.4.1"
readonly EXPECTED_BUILD="22E252"

readonly WORK_ROOT="/home/test/Desktop/ipwsPy/22E252_offset_audit"
readonly EXTRACT_ROOT="$WORK_ROOT/extracted"
readonly REPORT_ROOT="$WORK_ROOT/report"

# ------------------------------------------------------------
# Target symbols per image. Add/remove here, not in the script
# body: they're used both for the combined pattern and for the
# per-term match breakdown.
# ------------------------------------------------------------
readonly JSC_PATTERNS=(
    'globalFuncParseFloat'
    'jitAllowList'
    'emptyStringData'
)

readonly WEBCORE_PATTERNS=(
    'allScriptExecutionContextsMap'
    'DedicatedWorkerGlobalScope'
    'getPKContact'
    'initPKContact'
    'softLinkDDD'
    'softLinkMedia'
    'softLinkOTSVG'
    'TelephoneNumber'
    'WebProcess_singleton'
    'WebProcess_ensureGPU'
    'WebProcess_gpuProcess'
)

readonly DYLD_PATTERNS=(
    'RuntimeState'
    'emptySlot'
    'dlopen'
    'signPointer'
)

readonly AVFAUDIO_PATTERNS=(
    'AVLoadSpeechSynthesisImplementation'
    'AVSpeechSynthesisMarker'
    'AVSpeechSynthesisProviderRequest'
    'AVSpeechSynthesisVoice'
    'AVSpeechUtterance'
    'SystemLibraryTextToSpeech'
)

readonly AXCOREUTILITIES_PATTERNS=(
    'DefaultLoader'
)

readonly CFNETWORK_PATTERNS=(
    'gConstantCFStringValueTable'
)

readonly CMPHOTO_PATTERNS=(
    'CMPhotoCompression'
    'kCMPhotoTranscodeOption'
)

readonly FOUNDATION_PATTERNS=(
    'NSBundleTables'
    'bundleTables'
)

readonly IMAGEIO_PATTERNS=(
    'IIOLoadCMPhotoSymbols'
    'gFunc_CMPhoto'
    'gImageIOLogProc'
)

readonly MEDIAACCESSIBILITY_PATTERNS=(
    'MACaptionAppearanceGetDisplayType'
)

readonly SECURITY_PATTERNS=(
    'SecKeychainBackupSyncable'
    'SecOTRSessionProcessPacketRemote'
    'gSecurityd'
)

readonly TEXTTOSPEECH_PATTERNS=(
    'TTSMagicFirstPartyAudioUnit'
)

readonly LIBDYLD_PATTERNS=(
    'dlopen'
    'dlsym'
    'gAPIs'
)

readonly LIBSYSTEM_C_PATTERNS=(
    'atexit_mutex'
)

readonly LIBSYSTEM_KERNEL_PATTERNS=(
    'thread_suspend'
)

readonly HOMEUI_PATTERNS=(
    'HOMEUI'
)

readonly PERFPOWERSERVICESREADER_PATTERNS=(
    'PerfPowerServicesReader'
)

readonly LIBARI_PATTERNS=(
    'libARI'
)

readonly LIBGPUCOMPILERIMPLLAZY_PATTERNS=(
    'invoker'
)

readonly DESKTOPSERVICESPRIV_PATTERNS=(
    'DesktopServicesPriv'
)

readonly LIBSYSTEM_PTHREAD_PATTERNS=(
    'pthread_head'
    'mainRunLoop'
    'emptyString'
    'free_slabs'
    'GetCurrentThreadTLSIndex'
    'mach_task_self'
)

# Specific patterns (mangled name fragments) to avoid matching the
# repeated "WebKit" library column on every line.
readonly WEBKIT_PATTERNS=(
    'WebKit10WebProcess9singletonEvE7process'
    'WebKit10WebProcess9singletonEv'
    'WebKit10WebProcess26gpuProcessConnectionClosedEv'
    'WebKit10WebProcess26ensureGPUProcessConnectionEv'
    'WebKit10GPUProcess9singletonEv'
    'WebKit10GPUProcess9singletonEvE10gpuProcess'
)

readonly START_TS="$(date +%s)"

# Dedicated temp directory. Go/ipsw respects TMPDIR on Linux.
# Can be overridden when running:
#   IPSW_TMPDIR=/mnt/big_disk/ipsw_tmp ./audit_22E252_offsets_v2.sh
readonly TMP_ROOT="${IPSW_TMPDIR:-$WORK_ROOT/tmp}"

# If find locates more than one cache, run it like this:
# DSC_OVERRIDE=/path/dyld_shared_cache_arm64e ./audit_22E252_offsets.sh
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
    printf '[ERROR] Failed at line %s (exit=%s).\n' "$line_no" "$exit_code" >&2
    printf '[ERROR] Check: %s\n' "$REPORT_ROOT" >&2
    exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

for cmd in ipsw find grep sed awk sha256sum sort tee wc df id xargs; do
    require_command "$cmd"
done

# ------------------------------------------------------------
# Space/quota diagnostics and temp configuration
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
log "Dedicated TMPDIR: $TMPDIR (${TMP_FREE_GIB} GiB free per df)"

if (( TMP_FREE_GIB < 20 )); then
    warn "Less than 20 GiB free in TMPDIR. Extraction may need substantial extra temp space."
fi

# Since this TMPDIR is exclusive to this audit, only stale temp dirs
# from this script itself are removed before a new extraction.
find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -name 'ipsw_extract_*' -user "$(id -un)" -print -exec rm -rf -- {} + \
    > "$REPORT_ROOT/removed-stale-temp.txt" 2>&1 || true

[[ -f "$IPSW" ]] || fail "IPSW does not exist: $IPSW"
[[ -r "$IPSW" ]] || fail "Cannot read IPSW: $IPSW"

log "IPSW: $IPSW"
log "Working directory: $WORK_ROOT"
log "Temp directory: $TMPDIR"

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
# stderr is kept too, to diagnose differences between versions.
ipsw extract \
    --sys-ver \
    --no-color \
    "$IPSW" \
    > "$REPORT_ROOT/system-version.txt" \
    2> "$REPORT_ROOT/system-version.stderr.txt" || {
        warn "ipsw extract --sys-ver did not finish cleanly; continuing with ipsw-info.json."
    }

cat "$REPORT_ROOT/ipsw-info.json" "$REPORT_ROOT/system-version.txt" \
    > "$REPORT_ROOT/version-validation-input.txt"

for expected in "$EXPECTED_DEVICE" "$EXPECTED_VERSION" "$EXPECTED_BUILD"; do
    if ! grep -Fq "$expected" "$REPORT_ROOT/version-validation-input.txt"; then
        fail "'$expected' does not appear in metadata. Will not continue with an unverified build."
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
        log "Reusing already-extracted cache."
    fi

    if (( ${#CACHES[@]} == 0 )); then
        fail "dyld_shared_cache_arm64e not found after extraction."
    fi

    if (( ${#CACHES[@]} > 1 )); then
        {
            echo "Found multiple candidate caches:"
            printf '  %s\n' "${CACHES[@]}"
            echo
            echo "Run specifying one of them:"
            echo "  DSC_OVERRIDE=/path/dyld_shared_cache_arm64e $0"
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
# 5. Symbol dump and filtering
# ------------------------------------------------------------
# Receives the pattern array's name (by reference, via nameref)
# instead of an already-joined pattern, so matches can be broken
# down per term.
run_symaddr() {
    local label="$1"
    local image="$2"
    local -n patterns_ref="$3"

    local raw="$REPORT_ROOT/${label}.symbols.txt"
    local err="$REPORT_ROOT/${label}.stderr.txt"
    local matches="$REPORT_ROOT/${label}.matches.txt"
    local counts="$REPORT_ROOT/${label}.match-counts.txt"
    local pattern
    pattern="$(IFS='|'; echo "${patterns_ref[*]}")"

    log "Collecting symbols: label=$label image=$image"

    if ipsw dyld symaddr "$DSC" \
        --image "$image" \
        --no-color \
        > "$raw" \
        2> "$err"; then

        grep -Ei "$pattern" "$raw" \
            | tee "$matches" \
            || true

        {
            for term in "${patterns_ref[@]}"; do
                printf '%s\t%s\n' \
                    "$(grep -Eic -- "$term" "$raw" || true)" \
                    "$term"
            done
        } | sort -rn > "$counts"
    else
        warn "symaddr failed for '$image'. Check $err"
        : > "$matches"
        : > "$counts"
        return 1
    fi
}

run_symaddr \
    "JavaScriptCore" \
    "JavaScriptCore" \
    JSC_PATTERNS \
    || true

run_symaddr \
    "WebCore" \
    "/System/Library/PrivateFrameworks/WebCore.framework/WebCore" \
    WEBCORE_PATTERNS \
    || true

# dyld may be registered as a full path or as a short name.
DYLD_OK=false
for dyld_image in '/usr/lib/dyld' 'dyld'; do
    label="dyld-$(printf '%s' "$dyld_image" | sed 's#[^A-Za-z0-9._-]#_#g')"

    if run_symaddr \
        "$label" \
        "$dyld_image" \
        DYLD_PATTERNS; then

        if [[ -s "$REPORT_ROOT/${label}.symbols.txt" ]]; then
            printf '%s\n' "$dyld_image" > "$REPORT_ROOT/selected-dyld-image.txt"
            cp "$REPORT_ROOT/${label}.symbols.txt" "$REPORT_ROOT/dyld.symbols.txt"
            cp "$REPORT_ROOT/${label}.matches.txt" "$REPORT_ROOT/dyld.matches.txt"
            cp "$REPORT_ROOT/${label}.stderr.txt" "$REPORT_ROOT/dyld.stderr.txt"
            cp "$REPORT_ROOT/${label}.match-counts.txt" "$REPORT_ROOT/dyld.match-counts.txt"
            DYLD_OK=true
            break
        fi
    fi
done

if [[ "$DYLD_OK" != true ]]; then
    warn "Could not dump dyld with '/usr/lib/dyld' nor with 'dyld'."
    warn "Check relevant-images.txt and try the exact name shown by ipsw."
    : > "$REPORT_ROOT/dyld.matches.txt"
fi

# ------------------------------------------------------------
# 5b. Additional dyld shared cache images (extended scope)
# ------------------------------------------------------------
run_symaddr "AVFAudio"           "AVFAudio"           AVFAUDIO_PATTERNS           || true
run_symaddr "AXCoreUtilities"    "AXCoreUtilities"    AXCOREUTILITIES_PATTERNS    || true
run_symaddr "CFNetwork"          "CFNetwork"          CFNETWORK_PATTERNS          || true
run_symaddr "CMPhoto"            "CMPhoto"            CMPHOTO_PATTERNS            || true
run_symaddr "Foundation"         "Foundation"         FOUNDATION_PATTERNS         || true
run_symaddr "ImageIO"            "ImageIO"            IMAGEIO_PATTERNS            || true
run_symaddr "MediaAccessibility" "MediaAccessibility" MEDIAACCESSIBILITY_PATTERNS || true
run_symaddr "Security"           "Security"           SECURITY_PATTERNS           || true
run_symaddr "TextToSpeech"       "TextToSpeech"       TEXTTOSPEECH_PATTERNS       || true
run_symaddr "libdyld"            "libdyld.dylib"      LIBDYLD_PATTERNS            || true
run_symaddr "libsystem_c"        "libsystem_c.dylib"      LIBSYSTEM_C_PATTERNS       || true
run_symaddr "libsystem_kernel"   "libsystem_kernel.dylib" LIBSYSTEM_KERNEL_PATTERNS  || true
run_symaddr "HOMEUI"                    "/System/Library/PrivateFrameworks/HomeUI.framework/HomeUI" HOMEUI_PATTERNS || true
run_symaddr "PerfPowerServicesReader"   "PerfPowerServicesReader"    PERFPOWERSERVICESREADER_PATTERNS || true
run_symaddr "libARI"                    "libARI.dylib"               LIBARI_PATTERNS                  || true
run_symaddr "libGPUCompilerImplLazy"    "libGPUCompilerImplLazy.dylib" LIBGPUCOMPILERIMPLLAZY_PATTERNS || true
run_symaddr "DesktopServicesPriv"       "DesktopServicesPriv"        DESKTOPSERVICESPRIV_PATTERNS      || true
run_symaddr "libsystem_pthread"         "libsystem_pthread.dylib"    LIBSYSTEM_PTHREAD_PATTERNS        || true
run_symaddr "WebKit" "/System/Library/Frameworks/WebKit.framework/WebKit" WEBKIT_PATTERNS || true

# ------------------------------------------------------------
# 5c. Disassembly-based cross-references (symaddr isn't enough:
#     static locals with no exported symbol, or code gadgets
#     that need to be seen in context). Each dylib is extracted
#     individually (faster than indexing the whole DSC with
#     --force in `ipsw macho disass`).
# ------------------------------------------------------------
readonly DYLIB_OUT="$WORK_ROOT/dylibs"
mkdir -p "$DYLIB_OUT"
readonly CROSSREF="$REPORT_ROOT/crossref-resolved.txt"
: > "$CROSSREF"

extract_dylib() {
    local image="$1"
    local base
    base="$(basename "$image")"
    if [[ ! -f "$DYLIB_OUT/$base" ]]; then
        log "Extracting individual dylib: $image"
        ipsw dyld extract "$DSC" "$image" -o "$DYLIB_OUT" --no-color \
            > "$REPORT_ROOT/extract-${base}.log" 2>&1 || {
                warn "Could not extract $image, skipping its cross-reference."
                return 1
            }
    fi
}

disasm_symbol() {
    local dylib_base="$1"
    local symbol="$2"
    local out_file="$3"
    ipsw macho disass "$DYLIB_OUT/$dylib_base" --symbol "$symbol" \
        --force --no-color > "$out_file" 2>&1 || true
}

disasm_vaddr() {
    local dylib_base="$1"
    local vaddr="$2"
    local count="$3"
    local out_file="$4"
    ipsw macho disass "$DYLIB_OUT/$dylib_base" --vaddr "$vaddr" --count "$count" \
        --force --no-color > "$out_file" 2>&1 || true
}

# jitAllowList: "adrp x0, 0xBASE" followed by "add x0, x0, #0xOFF"
# (the x0 argument passed to the FunctionAllowlist::FunctionAllowlist constructor)
resolve_jit_allowlist() {
    local f="$1" base off
    base="$(grep -oP 'adrp\s+x0, 0x\K[0-9a-f]+' "$f" | head -1)"
    off="$(grep -oP 'add\s+x0, x0, #0x\K[0-9a-f]+' "$f" | head -1)"
    [[ -n "$base" && -n "$off" ]] && printf '%d' "$(( 0x$base + 0x$off ))"
}

# mainRunLoop: last "adrp x8, 0xBASE" before "ldr x0, [x8, #0xOFF]"
# (the CFRunLoopRef value that CFRunLoopGetMain returns)
resolve_main_run_loop() {
    local f="$1" base off
    off="$(grep -oP 'ldr\s+x0, \[x8, #0x\K[0-9a-f]+(?=\])' "$f" | head -1)"
    base="$(awk '/adrp[ \t]+x8, 0x/{b=$0} /ldr[ \t]+x0, \[x8, #0x/{print b; exit}' "$f" \
        | grep -oP 'adrp\s+x8, 0x\K[0-9a-f]+')"
    [[ -n "$base" && -n "$off" ]] && printf '%d' "$(( 0x$base + 0x$off ))"
}

# -- ensureGlobalJITAllowlist: real address of jitAllowList --
if extract_dylib "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore"; then
    JSC_PROXY_SYM='__ZNSt3__117__call_once_proxyB8sn190102INS_5tupleIJOZN3JSC5LLIntL24ensureGlobalJITAllowlistEvE3$_0EEEEEvPv'
    disasm_symbol "JavaScriptCore" "$JSC_PROXY_SYM" \
        "$REPORT_ROOT/crossref-jitAllowList.disasm.txt"
    JIT_ADDR="$(resolve_jit_allowlist "$REPORT_ROOT/crossref-jitAllowList.disasm.txt")"
    if [[ -n "${JIT_ADDR:-}" ]]; then
        printf 'JavaScriptCore__jitAllowList: 0x%xn,\n' "$JIT_ADDR" >> "$CROSSREF"
    fi
fi

# -- CFRunLoopGetMain: real address of mainRunLoop --
if extract_dylib "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"; then
    disasm_symbol "CoreFoundation" "_CFRunLoopGetMain" \
        "$REPORT_ROOT/crossref-mainRunLoop.disasm.txt"
    RUNLOOP_ADDR="$(resolve_main_run_loop "$REPORT_ROOT/crossref-mainRunLoop.disasm.txt")"
    if [[ -n "${RUNLOOP_ADDR:-}" ]]; then
        printf 'mainRunLoop: 0x%xn,\n' "$RUNLOOP_ADDR" >> "$CROSSREF"
    fi
fi

# -- dlopen_from lambda: confirm that dlopen_from_lambda_ret lands on
#    a valid epilogue/return (does not compute an address, just evidence) --
if extract_dylib "/usr/lib/dyld"; then
    DLOPEN_LAMBDA_SYM='__ZZN5dyld412RuntimeLocks37withLoadersWriteLockAndProtectedStackIZZNS_4APIs11dlopen_fromEPKciPvENK3$_0clEvEUlvE_EEvT_ENKUlvE_clEv'
    disasm_symbol "dyld" "$DLOPEN_LAMBDA_SYM" \
        "$REPORT_ROOT/crossref-dlopen_from_lambda_ret.disasm.txt"
fi

# -- gadgets: disassemble each address in its real dylib for
#    manual inspection (a "valid gadget" cannot be classified
#    automatically without a model of what's being searched for) --
if extract_dylib "/usr/lib/system/libdyld.dylib"; then
    disasm_vaddr "libdyld.dylib" "0x1ad44eac8" 10 \
        "$REPORT_ROOT/crossref-gadget_control_2.disasm.txt"
fi
if extract_dylib "/System/Library/Health/FeedItemPlugins/Highlights.healthplugin/Highlights"; then
    disasm_vaddr "Highlights" "0x23f2c42ec" 12 \
        "$REPORT_ROOT/crossref-gadget_control_1.disasm.txt"
fi
if extract_dylib "/usr/lib/CarrierBundleUtilities.dylib"; then
    disasm_vaddr "CarrierBundleUtilities.dylib" "0x21f256150" 10 \
        "$REPORT_ROOT/crossref-gadget_control_3.disasm.txt"
fi
if extract_dylib "/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore"; then
    disasm_vaddr "UIKitCore" "0x1865f818c" 12 \
        "$REPORT_ROOT/crossref-gadget_loop_1.disasm.txt"
fi
if extract_dylib "/usr/lib/libiconv.2.dylib"; then
    disasm_vaddr "libiconv.2.dylib" "0x20d23dda8" 12 \
        "$REPORT_ROOT/crossref-gadget_loop_2.disasm.txt"
fi
if extract_dylib "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"; then
    disasm_vaddr "CoreGraphics" "0x184d29f1c" 12 \
        "$REPORT_ROOT/crossref-gadget_loop_3.disasm.txt"
fi
if extract_dylib "/System/Library/Frameworks/Accelerate.framework/Frameworks/vecLib.framework/libLAPACK.dylib"; then
    disasm_vaddr "libLAPACK.dylib" "0x20dfb616c" 20 \
        "$REPORT_ROOT/crossref-gadget_set_all_registers.disasm.txt"
fi

log "Resolved cross-references saved to: $CROSSREF"
log "Raw disassembly for each case in: $REPORT_ROOT/crossref-*.disasm.txt"

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
    echo "AVFAUDIO_MATCHES=$(count_lines "$REPORT_ROOT/AVFAudio.matches.txt")"
    echo "AXCOREUTILITIES_MATCHES=$(count_lines "$REPORT_ROOT/AXCoreUtilities.matches.txt")"
    echo "CFNETWORK_MATCHES=$(count_lines "$REPORT_ROOT/CFNetwork.matches.txt")"
    echo "CMPHOTO_MATCHES=$(count_lines "$REPORT_ROOT/CMPhoto.matches.txt")"
    echo "FOUNDATION_MATCHES=$(count_lines "$REPORT_ROOT/Foundation.matches.txt")"
    echo "IMAGEIO_MATCHES=$(count_lines "$REPORT_ROOT/ImageIO.matches.txt")"
    echo "MEDIAACCESSIBILITY_MATCHES=$(count_lines "$REPORT_ROOT/MediaAccessibility.matches.txt")"
    echo "SECURITY_MATCHES=$(count_lines "$REPORT_ROOT/Security.matches.txt")"
    echo "TEXTTOSPEECH_MATCHES=$(count_lines "$REPORT_ROOT/TextToSpeech.matches.txt")"
    echo "LIBDYLD_MATCHES=$(count_lines "$REPORT_ROOT/libdyld.matches.txt")"
    echo "LIBSYSTEM_C_MATCHES=$(count_lines "$REPORT_ROOT/libsystem_c.matches.txt")"
    echo "LIBSYSTEM_KERNEL_MATCHES=$(count_lines "$REPORT_ROOT/libsystem_kernel.matches.txt")"
    echo "HOMEUI_MATCHES=$(count_lines "$REPORT_ROOT/HOMEUI.matches.txt")"
    echo "PERFPOWERSERVICESREADER_MATCHES=$(count_lines "$REPORT_ROOT/PerfPowerServicesReader.matches.txt")"
    echo "LIBARI_MATCHES=$(count_lines "$REPORT_ROOT/libARI.matches.txt")"
    echo "LIBGPUCOMPILERIMPLLAZY_MATCHES=$(count_lines "$REPORT_ROOT/libGPUCompilerImplLazy.matches.txt")"
    echo "DESKTOPSERVICESPRIV_MATCHES=$(count_lines "$REPORT_ROOT/DesktopServicesPriv.matches.txt")"
    echo "LIBSYSTEM_PTHREAD_MATCHES=$(count_lines "$REPORT_ROOT/libsystem_pthread.matches.txt")"
    echo "WEBKIT_MATCHES=$(count_lines "$REPORT_ROOT/WebKit.matches.txt")"
    echo "DURATION_SECONDS=$(( $(date +%s) - START_TS ))"
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
  $REPORT_ROOT/JavaScriptCore.matches.txt (+ .match-counts.txt per term)
  $REPORT_ROOT/WebCore.matches.txt (+ .match-counts.txt per term)
  $REPORT_ROOT/dyld.matches.txt (+ .match-counts.txt per term)
  $REPORT_ROOT/summary.txt

This script only collects and validates static metadata/symbols.
It does not compute return-sites nor apply runtime modifications.
============================================================
SUMMARY
