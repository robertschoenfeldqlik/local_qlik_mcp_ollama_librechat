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

The script performs a **7-step automated deployment**:
1. Pre-flight checks (Docker, NVIDIA GPU detection)
2. Prompts for Qlik tenant URL + OAuth Client ID
3. Generates `.env` with cryptographic secrets
4. Auto-injects tenant URL + client ID into `librechat.yaml`
5. Starts the Docker Compose stack
6. Pulls Qwen3 models (8b + 14b)
7. Applies the MCP tools patch (OAuth fix + tool filter)

### Option 2: Manual Setup

1. **Copy the environment file and edit it:**
   ```bash
   cp .env.example .env
   ```
   Edit `.env` and set your `QLIK_TENANT_URL` and `QLIK_OAUTH_CLIENT_ID`. Generate fresh secrets:
   ```bash
   openssl rand -hex 16  # for CREDS_KEY, MEILI_MASTER_KEY, POSTGRES_PASSWORD
   openssl rand -hex 8   # for CREDS_IV
   openssl rand -hex 32  # for JWT_SECRET, JWT_REFRESH_SECRET
   ```

2. **Update `librechat.yaml`** — replace all tenant URLs and OAuth client IDs (see [Customizations](#customizations-made-to-get-qlik-mcp-working) section below).

3. **Start the stack:**
   ```bash
   docker compose up -d
   ```

4. **Pull LLM models:**
   ```bash
   docker compose exec ollama ollama pull qwen3:8b
   docker compose exec ollama ollama pull qwen3:14b
   ```

5. **The MCP patch is mounted automatically** via the `docker-compose.yml` volumes block — no manual `docker cp` needed. To update the patch later, edit `mcp_tools_patched.js` and run `docker compose restart api`.

6. **Open LibreChat:** http://localhost:3080

---

## Customizations Made to Get Qlik MCP Working

This section documents every customization required to make Qlik Cloud MCP work with LibreChat + Ollama. The upstream repo and LibreChat v0.8.5 (and v0.8.3-rc1 before it) have several issues that must be patched.

### 1. VECTOR_DB_TYPE Bug Fix

**File:** `.env` / `.env.example`

**Problem:** The original repo set `VECTOR_DB_TYPE=pg`, which caused the RAG API container to crash-loop on startup. The pgvector driver expects the value `pgvector`.

**Fix:**
```env
# Before (broken)
VECTOR_DB_TYPE=pg

# After (fixed)
VECTOR_DB_TYPE=pgvector
```

---

### 2. NVIDIA GPU Support for Ollama

**File:** `docker-compose.yml`

**Problem:** The original repo had no GPU configuration. Ollama ran on CPU only, making inference extremely slow for 8B+ models.

**Fix:** Added NVIDIA GPU passthrough and performance tuning environment variables:

```yaml
ollama:
  image: ollama/ollama:latest
  container_name: librechat-ollama
  volumes:
    - ollama_data:/root/.ollama
  environment:
    - OLLAMA_NUM_PARALLEL=1        # One request at a time (maximizes VRAM)
    - OLLAMA_MAX_LOADED_MODELS=1   # Only one model in VRAM
    - OLLAMA_FLASH_ATTENTION=1     # Faster inference
    - OLLAMA_GPU_OVERHEAD=512000000 # Reserve 512MB for GPU overhead
    - OLLAMA_CONTEXT_LENGTH=16384  # 16K context for tool schemas
  deploy:
    resources:
      reservations:
        devices:
          - driver: nvidia
            count: all
            capabilities: [gpu]
  restart: unless-stopped
```

**Why 16K context:** The 21 MCP tool schemas consume approximately 6,000-8,000 tokens. With the system prompt and conversation, 8K context was too small (caused "Message pruning removed all messages" errors). 16K provides enough room.

**VRAM budget (RTX 4070 8GB):**
- Qwen3:8b model weights (Q4_K_M): ~5.2 GB
- KV cache at 16K context: ~1.5-2 GB
- GPU overhead: ~0.5 GB
- Total: ~7.2 GB (fits in 8 GB)

---

### 3. Hardcoded Qlik URLs in librechat.yaml

**File:** `librechat.yaml`

**Problem:** The original repo used environment variable placeholders like `${QLIK_TENANT_URL}` in `librechat.yaml`. LibreChat does **not** interpolate environment variables in its YAML config file. The MCP server would not appear in the UI because the URLs were literal strings like `${QLIK_TENANT_URL}/api/ai/mcp`.

**Fix:** Hardcode the actual tenant URL directly in `librechat.yaml`. The deploy scripts (`deploy.ps1` / `deploy.sh`) automate this by performing sed/regex replacements after prompting for the tenant URL.

```yaml
# Before (broken -- LibreChat doesn't interpolate env vars)
url: "${QLIK_TENANT_URL}/api/ai/mcp"

# After (working)
url: "https://your-tenant.us.qlikcloud.com/api/ai/mcp"
```

This applies to all 3 URL fields: `url`, `authorization_url`, and `token_url`.

---

### 4. X-Agent-Id Header Required by Qlik MCP

**File:** `librechat.yaml`

**Problem:** Qlik's MCP endpoint returns `"agent_id is required in request body"` if no agent ID is provided. This is a Qlik Cloud requirement for all MCP connections.

**Fix:** Add the `X-Agent-Id` header using the OAuth Client ID as the value:

```yaml
mcpServers:
  qlik:
    type: streamable-http
    url: "https://your-tenant.us.qlikcloud.com/api/ai/mcp"
    headers:
      X-Agent-Id: "your-oauth-client-id"
```

---

### 5. LibreChat MCP OAuth Bug Fix (CRITICAL)

**File:** `mcp_tools_patched.js` (patches `/app/api/server/services/Tools/mcp.js` inside the LibreChat container)

**Problem:** LibreChat (v0.8.3-rc1 through at least v0.8.5) has a bug in the MCP server initialization code. In the `reinitMCPServer()` function (line 122 in v0.8.3-rc1, line 168 in v0.8.5):

```javascript
if (connection && !oauthRequired) {
```

This condition **skips the `fetchTools()` call** for any MCP server that requires OAuth authentication. The result: LibreChat connects to Qlik successfully but discovers **0 tools**. The model then has no tools available and hallucinated tool names based on the system prompt.

**Fix:** Remove the `!oauthRequired` condition so tools are fetched regardless of auth method:

```javascript
// Before (broken -- skips fetchTools for OAuth servers)
if (connection && !oauthRequired) {

// After (fixed -- always fetches tools when connected)
if (connection) {
```

**How to apply:** The patch is mounted automatically via a `docker-compose.yml` bind mount on the `api` service:

```yaml
volumes:
  - ./mcp_tools_patched.js:/app/api/server/services/Tools/mcp.js:ro
```

It persists across `docker compose pull`, container recreation, and host reboots — **no manual re-application needed**. To update the patch, edit `mcp_tools_patched.js` locally and run `docker compose restart api`.

**Verification:** After applying the patch and opening a new chat, check the logs:
```bash
docker logs librechat --tail 20
```
You should see:
```
[MCP Reinitialize] Fetched 53 tools, filtered to 21 for qlik
```
If you see `Tools: undefined` or `0 tools`, the patch was not applied or the container was rebuilt.

---

### 6. MCP Tool Filter (53 → 21 Tools)

**File:** `mcp_tools_patched.js`

**Problem:** Qlik's MCP server exposes 53 tools. Each tool has a JSON schema that gets injected into the LLM's context window. With 53 tools, the schemas consume the entire context of an 8B model, causing:
- "Message pruning removed all messages" errors
- Operation timeouts / aborted requests
- The model unable to reason about which tool to use

**Fix:** Added an `ALLOWED_TOOLS` array in the patch that filters to 21 tools across 5 categories:

```javascript
const ALLOWED_TOOLS = [
  // Search & Discovery (4)
  'qlik_search',
  'qlik_search_spaces',
  'qlik_search_users',
  'qlik_describe_app',
  // Sheets (3)
  'qlik_list_sheets',
  'qlik_create_sheet',
  'qlik_get_sheet_details',
  // Charts & Visualizations (4)
  'qlik_get_chart_info',
  'qlik_get_chart_data',
  'qlik_add_chart',
  'qlik_add_filter',
  // Dimensions & Measures (4)
  'qlik_list_dimensions',
  'qlik_create_dimension',
  'qlik_list_measures',
  'qlik_create_measure',
  // Fields & Selections (6)
  'qlik_get_fields',
  'qlik_get_field_values',
  'qlik_search_field_values',
  'qlik_get_current_selections',
  'qlik_clear_selections',
  'qlik_select_values',
];
```

**Excluded categories** (available but filtered out to save context):
- **Datasets** (11 tools): `qlik_get_dataset`, `qlik_get_dataset_schema`, `qlik_get_dataset_profile`, `qlik_get_dataset_sample`, `qlik_get_dataset_trust_score`, `qlik_get_lineage`, `qlik_update_dataset_metadata`, `qlik_update_dataset_quality`, `qlik_get_dataset_memberships`, `qlik_get_dataset_quality_computation_status`, `qlik_get_dataset_freshness`
- **Data Products** (8 tools): `qlik_get_data_product`, `qlik_get_data_product_documentation`, `qlik_create_data_product`, `qlik_update_data_product`, `qlik_delete_data_product`, `qlik_update_data_product_space`, `qlik_update_activate_data_product`, `qlik_update_deactivate_data_product`
- **Glossary** (12 tools): `qlik_search_glossary_terms`, `qlik_get_glossary_term`, `qlik_get_glossary_categories`, `qlik_create_glossary`, `qlik_create_glossary_term`, `qlik_update_glossary_term`, `qlik_delete_glossary_term`, `qlik_get_glossary_term_links`, `qlik_create_glossary_term_links`, `qlik_update_term_status`, `qlik_create_glossary_category`, `qlik_get_full_glossary_export`
- **Other** (1 tool): `qlik_create_data_object`

To add more tools, edit the `ALLOWED_TOOLS` array in `mcp_tools_patched.js` and re-apply the patch.

---

### 7. Qwen3 Model Selection

**File:** `librechat.yaml`

**Problem:** Several models were tested for MCP tool calling on 8GB VRAM:
- `llama3.2` (3B) — too small, couldn't handle tool schemas
- `llama3.1:8b` (8B) — reasonable but inconsistent tool calling
- `glm4:9b` (9B) — decent but slow
- `llama3-groq-tool-use:8b` (8B) — purpose-built for tool calling but didn't reliably trigger tools with Qlik's schema format
- `qwen3:8b` (8B) — **best results**: consistent tool calling, good instruction following

**Fix:** Set Qwen3 as the only available models:

```yaml
models:
  default:
    - "qwen3:8b-nothinker"   # custom variant, see below
    - "qwen3:8b"
    - "qwen3:14b"
  fetch: false
```

`qwen3:8b-nothinker` is the recommended default — a custom Modelfile-built variant with thinking disabled and temperature baked to 0 for the most consistent tool calls. `qwen3:8b` is the unmodified base. `qwen3:14b` provides higher quality but requires more VRAM (may cause OOM on 8GB cards with large context).

#### 7b. `Modelfile.nothinker` — disabling Qwen3 reasoning mode

Qwen3 has a built-in reasoning mode that emits `<think>...</think>` blocks before responses. For a tool-calling agent this wastes tokens and delays the first tool call. The included `Modelfile.nothinker` builds a variant of `qwen3:8b` with:

- `SYSTEM /no_think` baked in (disables reasoning mode)
- `temperature 0` (maximum determinism)
- `num_ctx 16384` (matches `OLLAMA_CONTEXT_LENGTH`)

The deploy scripts run `ollama create qwen3:8b-nothinker -f Modelfile.nothinker` after pulling the base model. To rebuild manually after editing `Modelfile.nothinker`:

```bash
docker cp Modelfile.nothinker librechat-ollama:/tmp/Modelfile.nothinker
docker compose exec ollama ollama create qwen3:8b-nothinker -f /tmp/Modelfile.nothinker
```

---

### 8. Low Temperature for Consistent Tool Calls

**File:** `librechat.yaml`

**Problem:** At the default temperature (~0.7), the model would sometimes answer from memory instead of calling tools, or call different tools for the same question on repeated attempts.

**Fix:**
```yaml
temperature: 0.2
```

Lower temperature = less randomness = the model consistently picks the correct tool for the same question every time.

---

### 9. Force System Prompt

**File:** `librechat.yaml`

**Problem:** With `forcePrompt: false`, the system prompt could be overridden by user-set custom prompts in the LibreChat UI, causing the model to "forget" it's a tool-calling agent.

**Fix:**
```yaml
forcePrompt: true
```

This ensures the system prompt is always injected, even if the user sets a custom prompt.

---

### 10. No-Think System Prompt with Explicit Tool List

**File:** `librechat.yaml`

**Problem:** Generic text prompts didn't reliably compel the model to call MCP tools. The model would often:
- Ask the user for IDs instead of searching for them
- Answer from memory instead of calling tools
- Hallucinate tool names like `qlik_search_mcp` that don't exist
- Emit long `<think>...</think>` reasoning blocks (Qwen3's default behavior) before finally calling a tool

**Fix:** A direct prompt prefixed with `/no_think` to disable Qwen3's reasoning mode, followed by an exhaustive list of tool names and their required arguments:

```yaml
promptPrefix: |
  /no_think
  You are a Qlik Cloud MCP tool-calling agent. Do NOT think or reason. IMMEDIATELY call a tool.

  IMPORTANT: You have NO internal knowledge about Qlik. You MUST call a tool for every question. Do NOT write text before calling a tool. Do NOT invent tool names.

  TOOL NAMES (use ONLY these exact names):
  - qlik_search — find apps, data products, or any resource
  - qlik_search_spaces — find spaces
  - qlik_search_users — find users
  - qlik_describe_app — get app details (needs app ID)
  - qlik_list_sheets — list sheets (needs app ID)
  - qlik_create_sheet — create a sheet
  - qlik_get_sheet_details — sheet details (needs app ID + sheet ID)
  - qlik_get_chart_info — chart info (needs app ID + object ID)
  - qlik_get_chart_data — chart data (needs app ID + object ID)
  - qlik_add_chart — add a chart (needs app ID + sheet ID)
  - qlik_add_filter — add a filter (needs app ID + sheet ID)
  - qlik_list_dimensions — list dimensions (needs app ID)
  - qlik_create_dimension — create a dimension
  - qlik_list_measures — list measures (needs app ID)
  - qlik_create_measure — create a measure
  - qlik_get_fields — list fields (needs app ID)
  - qlik_get_field_values — field values (needs app ID + field name)
  - qlik_search_field_values — search field values
  - qlik_get_current_selections — current selections (needs app ID)
  - qlik_select_values — make selections (needs app ID + field + values)
  - qlik_clear_selections — clear selections (needs app ID)

  NEVER use tool names like "qlik_search_mcp" or any name not listed above.
  To find data products: call qlik_search with resourceType="dataproduct".
  To find an ID: call qlik_search first, then use the ID in follow-up calls.
  Present results with counts and bullet points. If empty, say "No results found."
```

**Key design decisions:**
- **`/no_think` prefix** — Qwen3-specific directive that disables its built-in reasoning mode. Without this, the model emits `<think>...</think>` blocks that waste tokens, delay the first tool call, and frequently second-guess themselves into not calling a tool at all. Combined with `Modelfile.nothinker` (which bakes `/no_think` into the model's system prompt), this is belt-and-suspenders.
- **Explicit tool list with required args** — eliminates hallucinated tool names. Without it, the model would invent plausible-sounding names like `qlik_search_mcp` or `qlik_list_apps`.
- **"NO internal knowledge"** — tells the model it cannot answer from memory, forcing tool use.
- **Concrete "how to find X" examples** — `resourceType="dataproduct"` for the data-product case (which is otherwise non-obvious), and "qlik_search first, then ID" for any lookup workflow.

**Earlier iteration:** A prior version used `<role>`, `<mandatory>`, `<workflow>`, `<tools>`, `<rules>` XML tags. It was replaced by the current flat-text version after observing that Qwen3 was equally responsive to the explicit tool list and the `/no_think` directive — at lower prompt-token cost.

---

### 11. Debug and Validation Flags

**File:** `docker-compose.yml`

**Problem:** MCP connection failures were silent. Config validation errors blocked startup when Qlik credentials weren't yet configured.

**Fix:** Added debug flags to the LibreChat container:

```yaml
environment:
  - CONFIG_BYPASS_VALIDATION=true  # Skip config validation on startup
  - DEBUG_MCP=true                 # Enable MCP debug logging
  - DEBUG=librechat:mcp*           # Verbose MCP transport logs
```

These are useful during setup and troubleshooting. `CONFIG_BYPASS_VALIDATION` can be removed once everything is configured.

---

### 12. OAuth Client Configuration

**File:** `librechat.yaml`

**Problem:** The initial setup used a pre-registered OAuth client ID that didn't have the correct redirect URI registered, resulting in `"redirect_uri is not registered"` errors.

**Fix:** Use your own Qlik Cloud OAuth client with the correct redirect URI:

```yaml
oauth:
  authorization_url: "https://your-tenant.us.qlikcloud.com/oauth/authorize"
  token_url: "https://your-tenant.us.qlikcloud.com/oauth/token"
  client_id: "your-oauth-client-id"
  redirect_uri: "http://localhost:3080/api/mcp/qlik/oauth/callback"
  scope: "user_default mcp:execute"
  grant_types_supported: ["authorization_code", "refresh_token"]
  token_endpoint_auth_methods_supported: ["none"]
  response_types_supported: ["code"]
  code_challenge_methods_supported: ["S256"]
```

**Your Qlik OAuth client must have:**
- Grant type: `authorization_code`
- PKCE: Required (S256)
- Redirect URI: `http://localhost:3080/api/mcp/qlik/oauth/callback`
- Scopes: `user_default`, `mcp:execute`
- Token endpoint auth: `none` (public client)

### Expired OAuth Tokens

If you get `401 Authorization Required` errors after the token expires, clear the stale tokens from MongoDB:

```bash
docker exec librechat-mongodb mongosh --quiet --eval "
  db = db.getSiblingDB('LibreChat');
  db.tokens.deleteMany({ type: { \$regex: /mcp/ } });
"
```

Then restart LibreChat and re-authorize:
```bash
docker compose restart api
# Wait 10 seconds, then re-apply the patch
docker cp mcp_tools_patched.js librechat:/app/api/server/services/Tools/mcp.js
```

---

## Summary of All Modified Files

| File | What Changed | Why |
|---|---|---|
| `.env.example` | `VECTOR_DB_TYPE=pg` → `pgvector` | RAG API crash fix |
| `docker-compose.yml` | Added GPU support, Ollama tuning, debug flags, 16K context | GPU inference, fit tool schemas |
| `librechat.yaml` | Hardcoded URLs, OAuth config, Qwen3 models, XML prompt, low temp, forcePrompt | Make MCP work end-to-end |
| `mcp_tools_patched.js` | OAuth fetchTools fix + 21-tool filter | LibreChat bug fix + context management |
| `mcp_tools_original.js` | Backup of unpatched file | Reference / rollback |
| `deploy.ps1` | Full 7-step Windows deployment | Automated setup |
| `deploy.sh` | Full 7-step Linux/Mac deployment | Automated setup |
| `README.md` | This documentation | Setup guide + customization details |

## Common Commands

```bash
# Start the stack
docker compose up -d

# Stop the stack
docker compose down

# View LibreChat logs (MCP debug)
docker compose logs -f api

# View Ollama logs
docker compose logs -f ollama

# Restart LibreChat (patch is auto-applied via the docker-compose volume mount)
docker compose restart api

# Pull a new Ollama model
docker compose exec ollama ollama pull <model>

# List downloaded models
docker compose exec ollama ollama list

# Check GPU usage
docker exec librechat-ollama nvidia-smi

# Clear expired OAuth tokens
docker exec librechat-mongodb mongosh --quiet --eval "db.getSiblingDB('LibreChat').tokens.deleteMany({})"
```

## Troubleshooting

### MCP shows 0 tools / "Tools: undefined"
Verify the patch is mounted into the container:
```bash
docker compose exec api head -3 /app/api/server/services/Tools/mcp.js
```
The output should match the top of your local `mcp_tools_patched.js`. If it doesn't, the `docker-compose.yml` volume mount for `mcp_tools_patched.js` is missing — check the `api.volumes` block, then `docker compose up -d` to recreate the container and open a new chat to trigger tool discovery.

### "Message pruning removed all messages"
Context window too small for the number of tool schemas. Either:
- Increase `OLLAMA_CONTEXT_LENGTH` in `docker-compose.yml` (needs more VRAM)
- Reduce the `ALLOWED_TOOLS` list in `mcp_tools_patched.js`

### Model asks for IDs instead of searching
The system prompt is not being injected. Ensure `forcePrompt: true` in `librechat.yaml` and restart LibreChat.

### Model hallucinating tool names
The tool filter is not applied or 0 tools were discovered. Check logs for the `Fetched X tools, filtered to Y` message. If missing, re-apply the patch.

### 401 Authorization Required
OAuth tokens expired. Clear tokens from MongoDB and re-authorize (see [Expired OAuth Tokens](#expired-oauth-tokens)).

### "redirect_uri is not registered"
Your Qlik OAuth client doesn't have the redirect URI registered. Add `http://localhost:3080/api/mcp/qlik/oauth/callback` in the Qlik Cloud Management Console under your OAuth client settings.

### "agent_id is required in request body"
The `X-Agent-Id` header is missing from `librechat.yaml`. Add it under the `headers` section of the MCP server config.

### RAG API keeps restarting
Ensure `VECTOR_DB_TYPE=pgvector` in `.env` (not `pg`).

### Ollama running on CPU instead of GPU
1. Verify NVIDIA Container Toolkit: `docker info | grep -i nvidia`
2. Check GPU inside container: `docker exec librechat-ollama nvidia-smi`
3. Ensure the `deploy.resources.reservations.devices` block exists in `docker-compose.yml`

## Notes

- MongoDB runs with `--noauth` (local development only, not production)
- All images are pulled from public registries (no custom Dockerfiles)
- Containers use `restart: unless-stopped` for automatic recovery
- The MCP patch was originally written for LibreChat v0.8.3-rc1 and re-validated against v0.8.5 (the bug persists). Future versions may fix the OAuth bug natively — check `/app/api/server/services/Tools/mcp.js` for `if (connection && !oauthRequired)` before applying.
- **Security:** the defaults (`ALLOW_REGISTRATION=true`, MongoDB `--noauth`, OAuth tokens stored without DB auth) make this safe only on `localhost`. After creating your first account, set `ALLOW_REGISTRATION=false` in `.env` and run `docker compose restart api` to disable open registration. Do not expose port 3080 to any network where untrusted users can reach it.
