# LibreChat + Ollama + Qlik MCP

A self-contained Docker Compose stack that connects **LibreChat** (open-source chat UI), **Ollama** (local GPU-accelerated LLM inference), and **Qlik Cloud MCP** (Model Context Protocol for analytics data access).

## Architecture

| Service | Image | Purpose | Port |
|---|---|---|---|
| **api** | `ghcr.io/danny-avila/librechat:latest` | Chat UI + API backend | 3080 |
| **mongodb** | `mongo:8.0` | Conversations & user data | 27017 (internal) |
| **meilisearch** | `getmeili/meilisearch:v1.12.3` | Full-text search | 7700 (internal) |
| **vectordb** | `pgvector/pgvector:pg17` | RAG vector embeddings | 5432 (internal) |
| **rag_api** | `librechat-rag-api-dev-lite:latest` | RAG API layer | 8000 (internal) |
| **ollama** | `ollama/ollama:latest` | Local LLM inference (GPU) | 11434 (internal) |

## Prerequisites

- **Docker Desktop** with Docker Compose v2
- **NVIDIA GPU** with drivers installed (NVIDIA Container Toolkit configured)
- **Qlik Cloud** tenant with a Native OAuth client (for MCP integration)

### Qlik OAuth Setup

1. Go to your Qlik Cloud Administration activity center
2. Navigate to **OAuth** and create a **Native OAuth client**
3. Set scopes: `user_default`, `mcp:execute`
4. Set redirect URL: `http://localhost:3080/api/mcp/qlik/oauth/callback`
5. Copy the **Client ID** for configuration

## Quick Start

### Option 1: Deploy Script (Interactive)

**Windows (PowerShell):**
```powershell
.\deploy.ps1
```

**Linux/macOS (Bash):**
```bash
./deploy.sh
```

The script will prompt for your Qlik credentials, generate secrets, and start the stack.

### Option 2: Manual Setup

1. **Copy the environment file and edit it:**
   ```bash
   cp .env.example .env
   ```
   Edit `.env` and set your `QLIK_TENANT_URL` and `QLIK_OAUTH_CLIENT_ID`. Fresh cryptographic secrets must be generated:
   ```bash
   openssl rand -hex 16  # for CREDS_KEY, MEILI_MASTER_KEY, POSTGRES_PASSWORD
   openssl rand -hex 8   # for CREDS_IV
   openssl rand -hex 32  # for JWT_SECRET, JWT_REFRESH_SECRET
   ```

2. **Start the stack:**
   ```bash
   docker compose up -d
   ```

3. **Pull LLM models:**
   ```bash
   docker compose exec ollama ollama pull qwen3:8b
   docker compose exec ollama ollama pull llama3.1:8b
   docker compose exec ollama ollama pull llama3.2
   ```

4. **Open LibreChat:** http://localhost:3080

## LLM Models

Models are selected for an 8GB VRAM GPU (e.g., RTX 4070):

| Model | Size | Purpose |
|---|---|---|
| **qwen3:8b** | 5.2 GB | Primary model - best MCP tool-calling, hybrid thinking mode |
| **llama3.1:8b** | 4.9 GB | Stable fallback for tool/function calling |
| **glm4:9b** | 5.5 GB | Reasoning and coding |
| **llama3.2** | 2.0 GB | Lightweight 3B all-rounder, fast responses |

### Why Qwen3 8B for MCP?

- Native MCP support - explicitly designed for MCP agentic workflows
- Best-in-class tool/function calling for 8B models
- Outperforms Qwen2.5-14B on 15 benchmarks despite being smaller
- Hybrid thinking/non-thinking modes for flexible reasoning
- Fits comfortably in 8GB VRAM with room for context

### Pulling Additional Models

```bash
docker compose exec ollama ollama pull <model-name>
```

Models with `fetch: true` in `librechat.yaml` will auto-appear in the UI.

## GPU Configuration

GPU acceleration is enabled by default for the Ollama container:

```yaml
deploy:
  resources:
    reservations:
      devices:
        - driver: nvidia
          count: all
          capabilities: [gpu]
```

Performance tuning environment variables (in `docker-compose.yml`):

| Variable | Value | Purpose |
|---|---|---|
| `OLLAMA_NUM_PARALLEL` | 1 | Single concurrent request (maximizes VRAM for one model) |
| `OLLAMA_MAX_LOADED_MODELS` | 1 | Only one model in VRAM at a time |
| `OLLAMA_FLASH_ATTENTION` | 1 | Enable flash attention for faster inference |
| `OLLAMA_GPU_OVERHEAD` | 512000000 | Reserve 512MB for GPU overhead |
| `OLLAMA_CONTEXT_LENGTH` | 8192 | Default context window (increase if VRAM allows) |

### Verify GPU Access

```bash
docker exec librechat-ollama nvidia-smi
```

## Connecting Qlik MCP

1. Open LibreChat at http://localhost:3080
2. Click the **MCP Servers** dropdown in the chat interface
3. Select **qlik**
4. Click **Authenticate** to sign in via OAuth (PKCE S256)

The MCP connection uses `streamable-http` transport to `${QLIK_TENANT_URL}/api/ai/mcp`.

## Configuration Files

| File | Purpose |
|---|---|
| `.env` | Environment variables (secrets, credentials, DB config) |
| `librechat.yaml` | LibreChat config (Ollama endpoint, MCP servers) |
| `docker-compose.yml` | Service definitions and orchestration |
| `deploy.sh` / `deploy.ps1` | Interactive deployment scripts |

## Data Persistence

Six Docker volumes persist data across restarts:

- `mongodb_data` - Conversations, users
- `meilisearch_data` - Search indexes
- `vectordb_data` - RAG vector embeddings
- `ollama_data` - Downloaded LLM model weights
- `librechat_images` - User-uploaded images
- `librechat_logs` - Application logs

## Common Commands

```bash
# Start the stack
docker compose up -d

# Stop the stack
docker compose down

# View logs
docker compose logs -f api
docker compose logs -f ollama

# Restart a specific service
docker compose restart api

# Pull a new Ollama model
docker compose exec ollama ollama pull <model>

# List downloaded models
docker compose exec ollama ollama list

# Check GPU usage
docker exec librechat-ollama nvidia-smi
```

## Troubleshooting

### LibreChat won't start (config validation error)
If you haven't configured Qlik OAuth yet, add `CONFIG_BYPASS_VALIDATION=true` to the api environment in `docker-compose.yml`. Remove it once you've set valid Qlik credentials.

### RAG API keeps restarting
Ensure `VECTOR_DB_TYPE=pgvector` in `.env` (not `pg`).

### Ollama running on CPU instead of GPU
1. Verify NVIDIA Container Toolkit: `docker info | grep -i nvidia`
2. Check GPU inside container: `docker exec librechat-ollama nvidia-smi`
3. Ensure the `deploy.resources.reservations.devices` block exists in `docker-compose.yml`

### Model too slow / running out of VRAM
- Use `llama3.2` (2GB) for faster responses on limited VRAM
- Set `OLLAMA_MAX_LOADED_MODELS=1` to avoid loading multiple models
- Reduce `OLLAMA_CONTEXT_LENGTH` if needed

## Notes

- MongoDB runs with `--noauth` (local development only, not production)
- All images are pulled from public registries (no custom Dockerfiles)
- Containers use `restart: unless-stopped` for automatic recovery
