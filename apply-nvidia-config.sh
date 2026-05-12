#!/usr/bin/env bash
# apply-nvidia-config.sh
# Tune the Ollama service GPU settings in docker-compose.yml.
# Presets: CPU only, GPU 8/12/16/24 GB, or Custom.
#
# Usage:
#   ./apply-nvidia-config.sh                  # interactive menu
#   ./apply-nvidia-config.sh --preset auto    # pick preset from detected VRAM
#   ./apply-nvidia-config.sh --preset cpu     # cpu-only
#   ./apply-nvidia-config.sh --preset 8gb     # GPU 8 GB
#   ./apply-nvidia-config.sh --preset 12gb
#   ./apply-nvidia-config.sh --preset 16gb
#   ./apply-nvidia-config.sh --preset 24gb
#   ./apply-nvidia-config.sh --no-restart     # don't recreate ollama container

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$SCRIPT_DIR/docker-compose.yml"

PRESET_ARG=""
RESTART_FLAG=""    # "yes" | "no" | "" (ask)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --preset)      PRESET_ARG="$2"; shift 2 ;;
        --restart)     RESTART_FLAG="yes"; shift ;;
        --no-restart)  RESTART_FLAG="no"; shift ;;
        -h|--help)
            sed -n '2,16p' "$0"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# -------------------------------------------------------
# Detect GPU
# -------------------------------------------------------

GPU_NAME=""
GPU_VRAM_MIB=0
if command -v nvidia-smi &>/dev/null; then
    line=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || true)
    if [[ -n "$line" ]]; then
        GPU_NAME=$(echo "$line"   | awk -F',' '{print $1}' | sed 's/^ *//;s/ *$//')
        GPU_VRAM_MIB=$(echo "$line" | awk -F',' '{print $2}' | sed 's/^ *//;s/ *$//')
    fi
fi

# -------------------------------------------------------
# Presets (NumParallel, MaxLoaded, Flash, GpuOverheadMB, CtxLen, GpuMode)
# -------------------------------------------------------

apply_preset_values() {
    case "$1" in
        cpu)
            NUM_PARALLEL=1; MAX_LOADED=1; FLASH=0; OVERHEAD_MB=0;   CTX_LEN=8192;  GPU_MODE=false ;;
        8gb)
            NUM_PARALLEL=1; MAX_LOADED=1; FLASH=1; OVERHEAD_MB=512; CTX_LEN=16384; GPU_MODE=true ;;
        12gb)
            NUM_PARALLEL=1; MAX_LOADED=1; FLASH=1; OVERHEAD_MB=512; CTX_LEN=24576; GPU_MODE=true ;;
        16gb)
            NUM_PARALLEL=2; MAX_LOADED=1; FLASH=1; OVERHEAD_MB=1024; CTX_LEN=32768; GPU_MODE=true ;;
        24gb)
            NUM_PARALLEL=2; MAX_LOADED=2; FLASH=1; OVERHEAD_MB=2048; CTX_LEN=65536; GPU_MODE=true ;;
        *) echo "Unknown preset: $1" >&2; exit 1 ;;
    esac
}

auto_preset_name() {
    if [[ $GPU_VRAM_MIB -le 0 ]]; then echo "cpu"
    elif [[ $GPU_VRAM_MIB -lt 10000 ]]; then echo "8gb"
    elif [[ $GPU_VRAM_MIB -lt 14000 ]]; then echo "12gb"
    elif [[ $GPU_VRAM_MIB -lt 20000 ]]; then echo "16gb"
    else echo "24gb"
    fi
}

# -------------------------------------------------------
# Read current values
# -------------------------------------------------------

CUR_NUM_PARALLEL=1
CUR_MAX_LOADED=1
CUR_FLASH=1
CUR_OVERHEAD_MB=512
CUR_CTX_LEN=16384
CUR_GPU_MODE=true

if [[ -f "$COMPOSE" ]]; then
    ollama_block=$(awk '/^  ollama:/,/^    restart: unless-stopped/' "$COMPOSE")
    if [[ -n "$ollama_block" ]]; then
        echo "$ollama_block" | grep -q 'driver:\s*nvidia' || CUR_GPU_MODE=false
        v=$(echo "$ollama_block" | grep 'OLLAMA_NUM_PARALLEL=' | sed 's/.*=//' || true);          [[ -n "$v" ]] && CUR_NUM_PARALLEL=$v
        v=$(echo "$ollama_block" | grep 'OLLAMA_MAX_LOADED_MODELS=' | sed 's/.*=//' || true);     [[ -n "$v" ]] && CUR_MAX_LOADED=$v
        v=$(echo "$ollama_block" | grep 'OLLAMA_FLASH_ATTENTION=' | sed 's/.*=//' || true);       [[ -n "$v" ]] && CUR_FLASH=$v
        v=$(echo "$ollama_block" | grep 'OLLAMA_GPU_OVERHEAD=' | sed 's/.*=//' || true)
        if [[ -n "$v" ]]; then CUR_OVERHEAD_MB=$(( v / 1000000 )); fi
        v=$(echo "$ollama_block" | grep 'OLLAMA_CONTEXT_LENGTH=' | sed 's/.*=//' || true);        [[ -n "$v" ]] && CUR_CTX_LEN=$v
    fi
fi

# -------------------------------------------------------
# Choose preset
# -------------------------------------------------------

echo ""
echo "=============================================="
echo "  Ollama / NVIDIA Configuration"
echo "=============================================="
if [[ $GPU_VRAM_MIB -gt 0 ]]; then
    echo "  Detected: $GPU_NAME ($GPU_VRAM_MIB MiB VRAM)"
else
    echo "  No NVIDIA GPU detected — CPU only recommended"
fi
echo ""
echo "  Current:"
echo "    GPU mode:           $CUR_GPU_MODE"
echo "    OLLAMA_NUM_PARALLEL=$CUR_NUM_PARALLEL"
echo "    OLLAMA_MAX_LOADED_MODELS=$CUR_MAX_LOADED"
echo "    OLLAMA_FLASH_ATTENTION=$CUR_FLASH"
echo "    OLLAMA_GPU_OVERHEAD=${CUR_OVERHEAD_MB} MB"
echo "    OLLAMA_CONTEXT_LENGTH=$CUR_CTX_LEN"
echo ""

PRESET=""
if [[ -n "$PRESET_ARG" ]]; then
    PRESET=$(echo "$PRESET_ARG" | tr 'A-Z' 'a-z')
    if [[ "$PRESET" == "auto" ]]; then
        PRESET=$(auto_preset_name)
        echo "  Auto preset -> $PRESET"
    fi
else
    echo "  Pick a preset:"
    echo "    1) Auto ($(auto_preset_name))"
    echo "    2) CPU only"
    echo "    3) GPU 8 GB"
    echo "    4) GPU 12 GB"
    echo "    5) GPU 16 GB"
    echo "    6) GPU 24 GB+"
    echo "    7) Custom (you'll be prompted for each value)"
    read -rp "  Choice [1]: " choice
    choice="${choice:-1}"
    case "$choice" in
        1) PRESET=$(auto_preset_name) ;;
        2) PRESET="cpu" ;;
        3) PRESET="8gb" ;;
        4) PRESET="12gb" ;;
        5) PRESET="16gb" ;;
        6) PRESET="24gb" ;;
        7) PRESET="custom" ;;
        *) echo "Invalid choice." >&2; exit 1 ;;
    esac
fi

if [[ "$PRESET" == "custom" ]]; then
    read -rp "  GPU mode? [Y/n]: " ans; [[ "$ans" =~ ^[nN]$ ]] && GPU_MODE=false || GPU_MODE=true
    read -rp "  OLLAMA_NUM_PARALLEL [$CUR_NUM_PARALLEL]: " v; NUM_PARALLEL="${v:-$CUR_NUM_PARALLEL}"
    read -rp "  OLLAMA_MAX_LOADED_MODELS [$CUR_MAX_LOADED]: " v; MAX_LOADED="${v:-$CUR_MAX_LOADED}"
    read -rp "  OLLAMA_FLASH_ATTENTION (0/1) [$CUR_FLASH]: " v; FLASH="${v:-$CUR_FLASH}"
    read -rp "  OLLAMA_GPU_OVERHEAD in MB [$CUR_OVERHEAD_MB]: " v; OVERHEAD_MB="${v:-$CUR_OVERHEAD_MB}"
    read -rp "  OLLAMA_CONTEXT_LENGTH [$CUR_CTX_LEN]: " v; CTX_LEN="${v:-$CUR_CTX_LEN}"
else
    apply_preset_values "$PRESET"
fi

# Validate
for n in NUM_PARALLEL MAX_LOADED FLASH OVERHEAD_MB CTX_LEN; do
    val="${!n}"
    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
        echo "Error: $n must be a non-negative integer (got '$val')." >&2
        exit 1
    fi
done

# -------------------------------------------------------
# Build new ollama block
# -------------------------------------------------------

OVERHEAD_BYTES=$(( OVERHEAD_MB * 1000000 ))

NEW_BLOCK="  ollama:
    image: ollama/ollama:latest
    container_name: librechat-ollama
    volumes:
      - ollama_data:/root/.ollama
    healthcheck:
      test: [\"CMD-SHELL\", \"ollama list || exit 1\"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s
    environment:
      - OLLAMA_NUM_PARALLEL=$NUM_PARALLEL
      - OLLAMA_MAX_LOADED_MODELS=$MAX_LOADED
      - OLLAMA_FLASH_ATTENTION=$FLASH
      - OLLAMA_GPU_OVERHEAD=$OVERHEAD_BYTES
      - OLLAMA_CONTEXT_LENGTH=$CTX_LEN"

if [[ "$GPU_MODE" == "true" ]]; then
    NEW_BLOCK+="
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]"
fi

NEW_BLOCK+="
    restart: unless-stopped"

# -------------------------------------------------------
# Apply (replace ollama block in docker-compose.yml)
# -------------------------------------------------------

if [[ ! -f "$COMPOSE" ]]; then
    echo "Error: docker-compose.yml not found at $COMPOSE" >&2
    exit 1
fi

TMP_OUT="$(mktemp)"
TMP_BLOCK="$(mktemp)"
printf '%s\n' "$NEW_BLOCK" > "$TMP_BLOCK"

awk -v blockfile="$TMP_BLOCK" '
    BEGIN { in_ollama = 0; printed = 0 }
    /^  ollama:/ {
        if (!printed) {
            while ((getline line < blockfile) > 0) print line
            close(blockfile)
            printed = 1
        }
        in_ollama = 1
        next
    }
    in_ollama {
        if ($0 ~ /^    restart: unless-stopped/) { in_ollama = 0; next }
        next
    }
    { print }
' "$COMPOSE" > "$TMP_OUT"

mv "$TMP_OUT" "$COMPOSE"
rm -f "$TMP_BLOCK"

echo ""
echo "Applied:"
echo "  GPU mode:           $GPU_MODE"
echo "  OLLAMA_NUM_PARALLEL=$NUM_PARALLEL"
echo "  OLLAMA_MAX_LOADED_MODELS=$MAX_LOADED"
echo "  OLLAMA_FLASH_ATTENTION=$FLASH"
echo "  OLLAMA_GPU_OVERHEAD=$OVERHEAD_BYTES  (${OVERHEAD_MB} MB)"
echo "  OLLAMA_CONTEXT_LENGTH=$CTX_LEN"
echo ""

# -------------------------------------------------------
# Restart ollama container?
# -------------------------------------------------------

do_restart="$RESTART_FLAG"
if [[ -z "$do_restart" ]]; then
    read -rp "Recreate ollama container now? [Y/n]: " ans
    if [[ "$ans" =~ ^[nN]$ ]]; then do_restart="no"; else do_restart="yes"; fi
fi

if [[ "$do_restart" == "yes" ]]; then
    if command -v docker &>/dev/null; then
        docker compose -f "$COMPOSE" up -d ollama
        echo "ollama container recreated."
    else
        echo "Warning: docker not found — skipped restart." >&2
    fi
fi

echo ""
echo "Done."
