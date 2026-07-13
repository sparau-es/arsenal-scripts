#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Auditoría reproducible de una IPSW y su dyld shared cache.
#
# Este script:
#   1. Verifica la IPSW esperada.
#   2. Extrae dyld_shared_cache_arm64e si todavía no existe.
#   3. Guarda hashes y metadatos de la cache.
#   4. Lista imágenes relevantes.
#   5. Recopila símbolos de JavaScriptCore, WebCore y dyld.
#
# No calcula ni aplica return-sites, slides runtime ni escrituras.
# ============================================================

readonly IPSW="/home/test/Desktop/ipwsPy/iPhone11,8_18.4.1_22E252_Restore.ipsw"
readonly EXPECTED_DEVICE="iPhone11,8"
readonly EXPECTED_VERSION="18.4.1"
readonly EXPECTED_BUILD="22E252"

readonly WORK_ROOT="/home/test/Desktop/ipwsPy/22E252_offset_audit"
readonly EXTRACT_ROOT="$WORK_ROOT/extracted"
readonly REPORT_ROOT="$WORK_ROOT/report"

# Directorio temporal dedicado. Go/ipsw respeta TMPDIR en Linux.
# Puede sobrescribirse al ejecutar:
#   IPSW_TMPDIR=/mnt/disco_grande/ipsw_tmp ./audit_22E252_offsets_v2.sh
readonly TMP_ROOT="${IPSW_TMPDIR:-$WORK_ROOT/tmp}"

# Si el find localiza más de una cache, se puede ejecutar así:
# DSC_OVERRIDE=/ruta/dyld_shared_cache_arm64e ./audit_22E252_offsets.sh
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
    printf '[ERROR] Fallo en la línea %s (exit=%s).\n' "$line_no" "$exit_code" >&2
    printf '[ERROR] Revisa: %s\n' "$REPORT_ROOT" >&2
    exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "No se encuentra el comando requerido: $1"
}

for cmd in ipsw find grep sed awk sha256sum sort tee wc df id; do
    require_command "$cmd"
done

# ------------------------------------------------------------
# Diagnóstico de espacio/cuota y configuración temporal
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
        echo "quota no está instalado"
    fi
} | tee "$REPORT_ROOT/storage-preflight.txt"

TMP_FREE_KB="$(df -Pk "$TMP_ROOT" | awk 'NR==2 {print $4}')"
TMP_FREE_GIB=$(( TMP_FREE_KB / 1024 / 1024 ))
log "TMPDIR dedicado: $TMPDIR (${TMP_FREE_GIB} GiB libres según df)"

if (( TMP_FREE_GIB < 20 )); then
    warn "Hay menos de 20 GiB libres en TMPDIR. La extracción puede necesitar bastante espacio temporal adicional."
fi

# Al ser un TMPDIR exclusivo de esta auditoría, se eliminan únicamente
# temporales antiguos del propio script antes de una nueva extracción.
find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -name 'ipsw_extract_*' -user "$(id -un)" -print -exec rm -rf -- {} + \
    > "$REPORT_ROOT/removed-stale-temp.txt" 2>&1 || true

[[ -f "$IPSW" ]] || fail "No existe la IPSW: $IPSW"
[[ -r "$IPSW" ]] || fail "No se puede leer la IPSW: $IPSW"

log "IPSW: $IPSW"
log "Directorio de trabajo: $WORK_ROOT"
log "Directorio temporal: $TMPDIR"

# ------------------------------------------------------------
# 1. Versión de la herramienta y huella de la IPSW
# ------------------------------------------------------------
{
    ipsw version 2>/dev/null || ipsw --version 2>/dev/null || true
} | tee "$REPORT_ROOT/ipsw-version.txt"

sha256sum "$IPSW" | tee "$REPORT_ROOT/ipsw-sha256.txt"

# ------------------------------------------------------------
# 2. Verificar metadatos de la IPSW
# ------------------------------------------------------------
log "Leyendo metadatos de la IPSW..."

ipsw info "$IPSW" \
    --json \
    --no-color \
    > "$REPORT_ROOT/ipsw-info.json" \
    2> "$REPORT_ROOT/ipsw-info.stderr.txt"

# Algunas versiones escriben la información de SystemVersion en stdout.
# Se conserva también stderr para diagnosticar diferencias entre versiones.
ipsw extract \
    --sys-ver \
    --no-color \
    "$IPSW" \
    > "$REPORT_ROOT/system-version.txt" \
    2> "$REPORT_ROOT/system-version.stderr.txt" || {
        warn "ipsw extract --sys-ver no terminó correctamente; se continuará usando ipsw-info.json."
    }

cat "$REPORT_ROOT/ipsw-info.json" "$REPORT_ROOT/system-version.txt" \
    > "$REPORT_ROOT/version-validation-input.txt"

for expected in "$EXPECTED_DEVICE" "$EXPECTED_VERSION" "$EXPECTED_BUILD"; do
    if ! grep -Fq "$expected" "$REPORT_ROOT/version-validation-input.txt"; then
        fail "No aparece '$expected' en los metadatos. No se continuará con una build no verificada."
    fi
done

log "Build verificada: $EXPECTED_DEVICE / iOS $EXPECTED_VERSION / $EXPECTED_BUILD"

# ------------------------------------------------------------
# 3. Extraer o localizar dyld_shared_cache_arm64e
# ------------------------------------------------------------
if [[ -n "$DSC_OVERRIDE" ]]; then
    [[ -f "$DSC_OVERRIDE" ]] || fail "DSC_OVERRIDE no apunta a un archivo: $DSC_OVERRIDE"
    DSC="$DSC_OVERRIDE"
else
    mapfile -t CACHES < <(
        find "$EXTRACT_ROOT" -type f -name 'dyld_shared_cache_arm64e' -print | sort
    )

    if (( ${#CACHES[@]} == 0 )); then
        log "Extrayendo dyld shared cache arm64e..."

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
        log "Se reutilizará la cache ya extraída."
    fi

    if (( ${#CACHES[@]} == 0 )); then
        fail "No se encontró dyld_shared_cache_arm64e después de la extracción."
    fi

    if (( ${#CACHES[@]} > 1 )); then
        {
            echo "Se encontraron varias caches candidatas:"
            printf '  %s\n' "${CACHES[@]}"
            echo
            echo "Ejecuta indicando una de ellas:"
            echo "  DSC_OVERRIDE=/ruta/dyld_shared_cache_arm64e $0"
        } | tee "$REPORT_ROOT/multiple-caches.txt" >&2
        exit 1
    fi

    DSC="${CACHES[0]}"
fi

readonly DSC
readonly DSC_DIR="$(dirname "$DSC")"
readonly DSC_BASE="$(basename "$DSC")"

log "Cache seleccionada: $DSC"
printf '%s\n' "$DSC" > "$REPORT_ROOT/selected-dsc.txt"

# Hash de la cache principal y sus subcaches.
find "$DSC_DIR" -maxdepth 1 -type f -name "${DSC_BASE}*" -print0 \
    | sort -z \
    | xargs -0 -r sha256sum \
    | tee "$REPORT_ROOT/dsc-sha256.txt"

# ------------------------------------------------------------
# 4. Metadatos y listado de imágenes de la cache
# ------------------------------------------------------------
log "Generando metadatos de la dyld shared cache..."

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
# 5. Volcado y filtrado de símbolos
# ------------------------------------------------------------
run_symaddr() {
    local label="$1"
    local image="$2"
    local pattern="$3"

    local raw="$REPORT_ROOT/${label}.symbols.txt"
    local err="$REPORT_ROOT/${label}.stderr.txt"
    local matches="$REPORT_ROOT/${label}.matches.txt"

    log "Recopilando símbolos: label=$label image=$image"

    if ipsw dyld symaddr "$DSC" \
        --image "$image" \
        --no-color \
        > "$raw" \
        2> "$err"; then

        grep -Ei "$pattern" "$raw" \
            | tee "$matches" \
            || true
    else
        warn "symaddr falló para '$image'. Revisa $err"
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

# dyld puede estar registrado como ruta completa o como nombre corto.
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
    warn "No se pudo volcar dyld con '/usr/lib/dyld' ni con 'dyld'."
    warn "Consulta relevant-images.txt e inténtalo con el nombre exacto mostrado por ipsw."
    : > "$REPORT_ROOT/dyld.matches.txt"
fi

# ------------------------------------------------------------
# 6. Resumen
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
Auditoría terminada.

Resultados:
  $REPORT_ROOT

Archivos principales:
  $REPORT_ROOT/ipsw-info.json
  $REPORT_ROOT/system-version.txt
  $REPORT_ROOT/dsc-sha256.txt
  $REPORT_ROOT/dyld-info.json
  $REPORT_ROOT/relevant-images.txt
  $REPORT_ROOT/JavaScriptCore.matches.txt
  $REPORT_ROOT/WebCore.matches.txt
  $REPORT_ROOT/dyld.matches.txt
  $REPORT_ROOT/summary.txt

El script solo recopila y valida metadatos/símbolos estáticos.
No calcula return-sites ni aplica modificaciones runtime.
============================================================
SUMMARY
