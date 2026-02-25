#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

echo "=============================================="
echo "  LibreChat + Ollama + Qlik MCP  —  Deploy"
echo "=============================================="
echo

# --- Prompt for Qlik credentials ---

read -rp "Qlik Cloud tenant URL (e.g. https://tenant.us.qlikcloud.com): " QLIK_TENANT_URL
# Strip trailing slash
QLIK_TENANT_URL="${QLIK_TENANT_URL%/}"

if [[ -z "$QLIK_TENANT_URL" ]]; then
  echo "Error: Tenant URL cannot be empty." >&2
  exit 1
fi

read -rp "Qlik Cloud OAuth Client ID: " QLIK_OAUTH_CLIENT_ID

if [[ -z "$QLIK_OAUTH_CLIENT_ID" ]]; then
  echo "Error: OAuth Client ID cannot be empty." >&2
  exit 1
fi

echo

# --- Generate secrets if .env doesn't exist yet ---

if [[ -f "$ENV_FILE" ]]; then
  echo "Existing .env found — updating Qlik credentials only."
  # Update the Qlik lines in-place
  sed -i "s|^QLIK_TENANT_URL=.*|QLIK_TENANT_URL=${QLIK_TENANT_URL}|" "$ENV_FILE"
  sed -i "s|^QLIK_OAUTH_CLIENT_ID=.*|QLIK_OAUTH_CLIENT_ID=${QLIK_OAUTH_CLIENT_ID}|" "$ENV_FILE"
else
  echo "Generating new .env with fresh secrets..."
  CREDS_KEY=$(openssl rand -hex 16)
  CREDS_IV=$(openssl rand -hex 8)
  JWT_SECRET=$(openssl rand -hex 32)
  JWT_REFRESH_SECRET=$(openssl rand -hex 32)
  MEILI_MASTER_KEY=$(openssl rand -hex 16)

  cat > "$ENV_FILE" <<EOF
#==============================================================#
#                    LibreChat + Ollama + Qlik MCP             #
#==============================================================#

QLIK_TENANT_URL=${QLIK_TENANT_URL}
QLIK_OAUTH_CLIENT_ID=${QLIK_OAUTH_CLIENT_ID}

CREDS_KEY=${CREDS_KEY}
CREDS_IV=${CREDS_IV}
JWT_SECRET=${JWT_SECRET}
JWT_REFRESH_SECRET=${JWT_REFRESH_SECRET}
ALLOW_REGISTRATION=true

MONGO_URI=mongodb://mongodb:27017/LibreChat

MEILISEARCH_HOST=http://meilisearch:7700
MEILI_MASTER_KEY=${MEILI_MASTER_KEY}

RAG_API_URL=http://rag_api:8000
VECTOR_DB_TYPE=pg
POSTGRES_DB=vectordb
POSTGRES_USER=vectordb
POSTGRES_PASSWORD=$(openssl rand -hex 16)
DB_HOST=vectordb
DB_PORT=5432
EOF
fi

echo
echo "Qlik tenant:    $QLIK_TENANT_URL"
echo "OAuth Client ID: ${QLIK_OAUTH_CLIENT_ID:0:8}..."
echo

# --- Start the stack ---

echo "Starting Docker Compose stack..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d

echo
echo "Pulling Ollama models..."
echo "  [1/2] llama3.2 (3B — lightweight all-rounder)..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T ollama ollama pull llama3.2
echo "  [2/2] glm4:9b (9B — top reasoning & coding)..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T ollama ollama pull glm4:9b

echo
echo "=============================================="
echo "  Ready!  Open http://localhost:3080"
echo ""
echo "  To connect Qlik MCP, click the MCP Servers"
echo "  dropdown in the chat, select 'qlik', then"
echo "  click Authenticate to sign in via OAuth."
echo "=============================================="
