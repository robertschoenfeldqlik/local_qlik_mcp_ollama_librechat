#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
COMPOSE="$SCRIPT_DIR/docker-compose.yml"

QLIK_TENANT_URL_ARG=""
QLIK_OAUTH_CLIENT_ID_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tenant-url)
            QLIK_TENANT_URL_ARG="$2"
            shift 2
            ;;
        --client-id)
            QLIK_OAUTH_CLIENT_ID_ARG="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--tenant-url URL] [--client-id ID]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

echo ""
echo "=============================================="
echo "  LibreChat + Ollama + Qlik MCP  —  Deploy"
echo "=============================================="
echo ""

# -------------------------------------------------------
# 1. Pre-flight checks
# -------------------------------------------------------

echo "[1/6] Checking prerequisites..."

# Docker
if ! command -v docker &>/dev/null; then
    echo "Error: Docker is not installed or not in PATH." >&2
    exit 1
fi
if ! docker info &>/dev/null; then
    echo "Error: Docker daemon is not running." >&2
    exit 1
fi

# NVIDIA GPU (optional)
HAS_GPU=false
if command -v nvidia-smi &>/dev/null; then
    GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || true)
    if [[ -n "$GPU_INFO" ]]; then
        HAS_GPU=true
        echo "  GPU detected: $GPU_INFO"
    fi
fi
if [[ "$HAS_GPU" == false ]]; then
    echo "  No NVIDIA GPU detected -- Ollama will use CPU only."
fi

echo ""

# -------------------------------------------------------
# 2. Qlik credentials (from flags or prompt)
# -------------------------------------------------------

echo "[2/6] Qlik Cloud credentials..."

if [[ -n "$QLIK_TENANT_URL_ARG" ]]; then
    QLIK_TENANT_URL="$QLIK_TENANT_URL_ARG"
else
    read -rp "  Qlik Cloud tenant URL (e.g. https://tenant.us.qlikcloud.com): " QLIK_TENANT_URL
fi
QLIK_TENANT_URL="${QLIK_TENANT_URL%/}"

if [[ -z "$QLIK_TENANT_URL" ]]; then
    echo "Error: Tenant URL cannot be empty." >&2
    exit 1
fi

if [[ -n "$QLIK_OAUTH_CLIENT_ID_ARG" ]]; then
    QLIK_OAUTH_CLIENT_ID="$QLIK_OAUTH_CLIENT_ID_ARG"
else
    read -rp "  Qlik Cloud OAuth Client ID: " QLIK_OAUTH_CLIENT_ID
fi

if [[ -z "$QLIK_OAUTH_CLIENT_ID" ]]; then
    echo "Error: OAuth Client ID cannot be empty." >&2
    exit 1
fi

echo ""
echo "  Tenant:   $QLIK_TENANT_URL"
echo "  ClientID: ${QLIK_OAUTH_CLIENT_ID:0:8}..."
echo ""

# -------------------------------------------------------
# 3. Generate .env
# -------------------------------------------------------

echo "[3/6] Configuring environment..."

if [[ -f "$ENV_FILE" ]]; then
    echo "  Existing .env found — updating Qlik credentials only."
    sed -i "s|^QLIK_TENANT_URL=.*|QLIK_TENANT_URL=${QLIK_TENANT_URL}|" "$ENV_FILE"
    sed -i "s|^QLIK_OAUTH_CLIENT_ID=.*|QLIK_OAUTH_CLIENT_ID=${QLIK_OAUTH_CLIENT_ID}|" "$ENV_FILE"
    # Fix VECTOR_DB_TYPE if needed
    sed -i "s|^VECTOR_DB_TYPE=pg$|VECTOR_DB_TYPE=pgvector|" "$ENV_FILE"
else
    echo "  Generating new .env with fresh secrets..."
    cat > "$ENV_FILE" <<EOF
#==============================================================#
#                    LibreChat + Ollama + Qlik MCP             #
#==============================================================#

QLIK_TENANT_URL=${QLIK_TENANT_URL}
QLIK_OAUTH_CLIENT_ID=${QLIK_OAUTH_CLIENT_ID}

CREDS_KEY=$(openssl rand -hex 16)
CREDS_IV=$(openssl rand -hex 8)
JWT_SECRET=$(openssl rand -hex 32)
JWT_REFRESH_SECRET=$(openssl rand -hex 32)
ALLOW_REGISTRATION=true

MONGO_URI=mongodb://mongodb:27017/LibreChat

MEILISEARCH_HOST=http://meilisearch:7700
MEILI_MASTER_KEY=$(openssl rand -hex 16)

RAG_API_URL=http://rag_api:8000
VECTOR_DB_TYPE=pgvector
POSTGRES_DB=vectordb
POSTGRES_USER=vectordb
POSTGRES_PASSWORD=$(openssl rand -hex 16)
DB_HOST=vectordb
DB_PORT=5432
EOF
fi

# -------------------------------------------------------
# 4. Update librechat.yaml with user's Qlik credentials
# -------------------------------------------------------

echo "[4/6] Updating librechat.yaml with your Qlik credentials..."

YAML_FILE="$SCRIPT_DIR/librechat.yaml"
if [[ -f "$YAML_FILE" ]]; then
    # Replace tenant URL (all occurrences)
    sed -i "s|url: \"https://[^\"]*\/api\/ai\/mcp\"|url: \"${QLIK_TENANT_URL}/api/ai/mcp\"|" "$YAML_FILE"
    sed -i "s|authorization_url: \"https://[^\"]*\/oauth\/authorize\"|authorization_url: \"${QLIK_TENANT_URL}/oauth/authorize\"|" "$YAML_FILE"
    sed -i "s|token_url: \"https://[^\"]*\/oauth\/token\"|token_url: \"${QLIK_TENANT_URL}/oauth/token\"|" "$YAML_FILE"

    # Replace OAuth client ID (X-Agent-Id and client_id)
    sed -i "s|X-Agent-Id: \"[^\"]*\"|X-Agent-Id: \"${QLIK_OAUTH_CLIENT_ID}\"|" "$YAML_FILE"
    sed -i "s|client_id: \"[^\"]*\"|client_id: \"${QLIK_OAUTH_CLIENT_ID}\"|" "$YAML_FILE"

    echo "  Updated tenant URL and OAuth client ID in librechat.yaml"
fi

echo ""

# -------------------------------------------------------
# 5. Start Docker Compose stack
# -------------------------------------------------------

echo "[5/6] Starting Docker Compose stack..."
docker compose -f "$COMPOSE" up -d

# Wait for Ollama to be ready (poll instead of fixed sleep)
echo "  Waiting for Ollama to be ready..."
TIMEOUT=90
ELAPSED=0
READY=false
while [[ $ELAPSED -lt $TIMEOUT ]]; do
    if docker compose -f "$COMPOSE" exec -T ollama ollama list &>/dev/null; then
        READY=true
        break
    fi
    sleep 3
    ELAPSED=$((ELAPSED + 3))
done
if [[ "$READY" == false ]]; then
    echo "  Warning: Ollama did not become ready within ${TIMEOUT}s. Continuing anyway."
else
    echo "  Ollama is ready (after ${ELAPSED}s)."
fi

echo ""

# -------------------------------------------------------
# 6. Pull Ollama models + build nothinker variant
# -------------------------------------------------------

echo "[6/6] Pulling Ollama models (this may take several minutes)..."

echo "  [1/4] qwen3:8b (8B -- base model)..."
docker compose -f "$COMPOSE" exec -T ollama ollama pull qwen3:8b || echo "  Warning: Failed to pull qwen3:8b"

echo "  [2/4] qwen3:4b (4B -- recommended for <=4GB VRAM)..."
docker compose -f "$COMPOSE" exec -T ollama ollama pull qwen3:4b || echo "  Warning: Failed to pull qwen3:4b"

# Note: destination file is named *.mf (not /tmp/Modelfile.*) to work around an
# Ollama 0.23.x quirk where `ollama create -f /tmp/Modelfile.X` fails with
# "no Modelfile or safetensors files found." Anything else works fine.

echo "  [3/4] Building qwen3:8b-nothinker (thinking disabled)..."
MODELFILE="$SCRIPT_DIR/Modelfile.nothinker"
if [[ -f "$MODELFILE" ]]; then
    docker cp "$MODELFILE" librechat-ollama:/tmp/8b-nothinker.mf
    docker compose -f "$COMPOSE" exec -T ollama ollama create qwen3:8b-nothinker -f /tmp/8b-nothinker.mf || echo "  Warning: Failed to create qwen3:8b-nothinker"
else
    echo "  Warning: Modelfile.nothinker not found. Skipping."
fi

echo "  [4/4] Building qwen3:4b-nothinker (recommended default)..."
MODELFILE4B="$SCRIPT_DIR/Modelfile.4b-nothinker"
if [[ -f "$MODELFILE4B" ]]; then
    docker cp "$MODELFILE4B" librechat-ollama:/tmp/4b-nothinker.mf
    docker compose -f "$COMPOSE" exec -T ollama ollama create qwen3:4b-nothinker -f /tmp/4b-nothinker.mf || echo "  Warning: Failed to create qwen3:4b-nothinker"
else
    echo "  Warning: Modelfile.4b-nothinker not found. Skipping."
fi

echo ""

# -------------------------------------------------------
# Done
# -------------------------------------------------------

echo "=============================================="
echo "  DEPLOYMENT COMPLETE"
echo "=============================================="
echo ""
echo "  App:    http://localhost:3080"
echo "  Models: qwen3:4b-nothinker (default), qwen3:4b, qwen3:8b-nothinker, qwen3:8b"
echo "  Tools:  21 Qlik MCP tools (filtered from 53)"
echo ""
echo "  The MCP patch is applied via a docker-compose volume mount,"
echo "  so it persists across container restarts and recreations."
echo "  To update the patch, edit mcp_tools_patched.js and run:"
echo "    docker compose restart api"
echo ""
echo "  FIRST TIME SETUP:"
echo "  1. Open http://localhost:3080 and create an account"
echo "  2. Start a new chat, select 'qwen3:4b-nothinker' model"
echo "  3. Click the Qlik MCP plugin icon and click 'Authorize'"
echo "  4. Sign in to Qlik Cloud when redirected"
echo "  5. Ask: 'What apps do I have in Qlik?'"
echo ""
echo "  OAuth redirect URI (must be registered in Qlik Cloud):"
echo "    http://localhost:3080/api/mcp/qlik/oauth/callback"
echo "=============================================="
