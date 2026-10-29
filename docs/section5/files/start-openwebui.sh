#!/usr/bin/env bash
set -eo pipefail

BASE="${BASE:-$SCRATCH/llm-stack}"
SIF="$BASE/sif"; DATA="$BASE/data"; LOGS="$BASE/logs"
mkdir -p "$SIF" "$LOGS" "$DATA"/{ollama,webui,tmp}

TIKA_PORT=9998
WEBUI_PORT=8080

if command -v module &>/dev/null; then
    module unload xalt
    module load tacc-apptainer
    module list
fi

# --- Build images once (on a node with internet access) ---
[[ -f $SIF/tika.sif  ]] || apptainer pull "$SIF/tika.sif"  docker://apache/tika:4.1.0-1-full
[[ -f $SIF/webui.sif ]] || apptainer pull "$SIF/webui.sif" docker://ghcr.io/open-webui/open-webui:0.12.3-ollama

wait_for() {  # name url
  for _ in $(seq 1 90); do
    curl -fs "$2" >/dev/null 2>&1 && { echo "$1 up"; return; }
    sleep 2
  done
  echo "$1 failed to start, see $LOGS/$1.log" >&2; return 1
}

# Define the cleanup function
cleanup() {
    echo "🧹 Running cleanup: Stopping Apptainer instances..."

    # Check and stop tika
    if apptainer instance list | grep -q "tika"; then
        echo "Stopping tika..."
        apptainer instance stop "tika"
    fi

    # Check and stop webui
    if apptainer instance list | grep -q "webui"; then
        echo "Stopping webui..."
        apptainer instance stop "webui"
    fi

    echo "✅ Cleanup complete."
}
trap cleanup EXIT INT TERM

# --- Tika ---
apptainer instance start --cleanenv "$SIF/tika.sif" tika
nohup apptainer run instance://tika > "$LOGS/tika.log" 2>&1 &
wait_for tika "http://127.0.0.1:$TIKA_PORT/tika"

# --- Open WebUI + bundled Ollama (drop --nv if no NVIDIA GPU) ---
apptainer instance start --cleanenv --nv --writable-tmpfs \
  --bind "$DATA/webui:/app/backend/data" \
  --bind "$DATA/ollama:/ollama-data" \
  --bind "$DATA/tmp:/tmp" \
  "$SIF/webui.sif" webui

export APPTAINERENV_PORT="$WEBUI_PORT"
export APPTAINERENV_HOST=127.0.0.1
export APPTAINERENV_DATA_DIR=/app/backend/data
export APPTAINERENV_OLLAMA_MODELS=/ollama-data
export APPTAINERENV_CONTENT_EXTRACTION_ENGINE=tika
export APPTAINERENV_TIKA_SERVER_URL="http://127.0.0.1:$TIKA_PORT"
export APPTAINERENV_WEBUI_SECRET_KEY="${WEBUI_SECRET_KEY:-$(openssl rand -hex 16)}"
export APPTAINERENV_HF_HUB_OFFLINE=0   # drop if the node can reach HuggingFace
export APPTAINERENV_USE_OLLAMA_DOCKER=true   # in case --cleanenv/env handling drops the image default
#export APPTAINERENV_ENABLE_RAG_HYBRID_SEARCH=true

nohup apptainer exec --pwd /app/backend instance://webui bash start.sh \
  > "$LOGS/webui.log" 2>&1 &

wait_for webui "http://127.0.0.1:$WEBUI_PORT/health"

# pull models for ollama
MODELS=(
    "llama3.3:latest"
    "nomic-embed-text:latest"
)

echo "🔍 Checking Ollama model installations..."
echo "----------------------------------------"

# Get a clean list of all currently installed model names once to save processing time
INSTALLED_MODELS=$(apptainer exec instance://webui ollama list | awk 'NR>1 {print $1}')

for MODEL in "${MODELS[@]}"; do
    if echo "$INSTALLED_MODELS" | grep -qx "$MODEL"; then
        echo "✅ $MODEL is already installed."
    else
        echo "📥 $MODEL not found. Pulling now..."
        apptainer exec instance://webui ollama pull "$MODEL"
    fi
done

echo "🎉 All models are verified and ready!"

echo "Open WebUI: http://127.0.0.1:$WEBUI_PORT"
echo "Ctrl-C to stop all instances"
wait
