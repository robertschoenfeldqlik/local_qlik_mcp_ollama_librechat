#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
COMPOSE="$SCRIPT_DIR/docker-compose.yml"

echo ""
echo "=============================================="
echo "  LibreChat + Ollama + Qlik MCP  —  Deploy"
echo "=============================================="
echo ""

# -------------------------------------------------------
# 1. Pre-flight checks
# -------------------------------------------------------

echo "[1/7] Checking prerequisites..."

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
# 2. Prompt for Qlik credentials
# -------------------------------------------------------

echo "[2/7] Qlik Cloud credentials..."

read -rp "  Qlik Cloud tenant URL (e.g. https://tenant.us.qlikcloud.com): " QLIK_TENANT_URL
QLIK_TENANT_URL="${QLIK_TENANT_URL%/}"

if [[ -z "$QLIK_TENANT_URL" ]]; then
    echo "Error: Tenant URL cannot be empty." >&2
    exit 1
fi

read -rp "  Qlik Cloud OAuth Client ID: " QLIK_OAUTH_CLIENT_ID

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

echo "[3/7] Configuring environment..."

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

echo "[4/7] Updating librechat.yaml with your Qlik credentials..."

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

echo "[5/7] Starting Docker Compose stack..."
docker compose -f "$COMPOSE" up -d

# Wait for containers to be healthy
echo "  Waiting for services to start..."
sleep 15

echo ""

# -------------------------------------------------------
# 6. Pull Ollama models
# -------------------------------------------------------

echo "[6/7] Pulling Ollama models (this may take a few minutes)..."

echo "  [1/2] qwen3:8b (8B -- best for MCP tool calling)..."
docker compose -f "$COMPOSE" exec -T ollama ollama pull qwen3:8b || echo "  Warning: Failed to pull qwen3:8b"

echo "  [2/2] qwen3:14b (14B -- higher quality, needs more VRAM)..."
docker compose -f "$COMPOSE" exec -T ollama ollama pull qwen3:14b || echo "  Warning: Failed to pull qwen3:14b"

echo ""

# -------------------------------------------------------
# 7. Apply MCP tools patch
# -------------------------------------------------------

echo "[7/7] Applying MCP tools patch (OAuth fix + tool filter)..."

PATCH_FILE="$SCRIPT_DIR/mcp_tools_patched.js"
if [[ -f "$PATCH_FILE" ]]; then
    if docker cp "$PATCH_FILE" librechat:/app/api/server/services/Tools/mcp.js; then
        echo "  Patch applied successfully."
    else
        echo "  Warning: Failed to apply patch. You may need to run:"
        echo "    docker cp mcp_tools_patched.js librechat:/app/api/server/services/Tools/mcp.js"
    fi
else
    echo "  Warning: mcp_tools_patched.js not found. Skipping patch."
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
echo "  Models: qwen3:8b (default), qwen3:14b"
echo "  Tools:  21 Qlik MCP tools (filtered from 53)"
echo ""
echo "  FIRST TIME SETUP:"
echo "  1. Open http://localhost:3080 and create an account"
echo "  2. Start a new chat, select 'qwen3:8b' model"
echo "  3. Click the Qlik MCP plugin icon and click 'Authorize'"
echo "  4. Sign in to Qlik Cloud when redirected"
echo "  5. Ask: 'What apps do I have in Qlik?'"
echo ""
echo "  IMPORTANT: After any 'docker compose pull' or rebuild,"
echo "  re-apply the patch:"
echo "    docker cp mcp_tools_patched.js librechat:/app/api/server/services/Tools/mcp.js"
echo ""
echo "  OAuth redirect URI (must be registered in Qlik Cloud):"
echo "    http://localhost:3080/api/mcp/qlik/oauth/callback"
echo "=============================================="
