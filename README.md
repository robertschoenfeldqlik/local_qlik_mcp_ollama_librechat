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

The script performs a **6-step automated deployment**:
1. Pre-flight checks (Docker, NVIDIA GPU detection)
2. Prompts for Qlik tenant URL + OAuth Client ID (or accepts them as CLI flags: `-QlikTenantUrl <url> -QlikOAuthClientId <id>` on Windows, `--tenant-url <url> --client-id <id>` on Linux/macOS)
3. Generates `.env` with cryptographic secrets
4. Auto-injects tenant URL + client ID into `librechat.yaml`
5. Starts the Docker Compose stack (waits for ollama healthcheck before model pulls)
6. Pulls Qwen3 base models (`qwen3:8b`, `qwen3:4b`) and builds the no-think variants (`qwen3:8b-nothinker`, `qwen3:4b-nothinker`)

The MCP patch is applied **via a `docker-compose.yml` bind mount** — there is no separate "apply patch" step, and it survives container recreation.

> **After the deploy:** to actually call Qlik MCP tools from a chat, you need to either
> (a) toggle the `qlik` MCP server **on** in the chat menu before sending a message, or
> (b) use a **saved Agent** that has the Qlik MCP tools attached. See [Agents Endpoint: Required Path for MCP Tools](#agents-endpoint-required-path-for-mcp-tools) below for why this is necessary.

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
   docker compose exec ollama ollama pull qwen3:4b
   ```
   For laptops / small GPUs (≤ 4 GB VRAM), prefer `qwen3:4b` — see [Model Selection](#7-qwen3-model-selection) below.

5. **Build the no-think variants** (note: temp filename must NOT start with `Modelfile.` — see [Modelfile.nothinker](#7b-modelfilenothinker--disabling-qwen3-reasoning-mode)):
   ```bash
   docker cp Modelfile.nothinker librechat-ollama:/tmp/8b-nothinker.mf
   docker compose exec ollama ollama create qwen3:8b-nothinker -f /tmp/8b-nothinker.mf
   docker cp Modelfile.4b-nothinker librechat-ollama:/tmp/4b-nothinker.mf
   docker compose exec ollama ollama create qwen3:4b-nothinker -f /tmp/4b-nothinker.mf
   ```

6. **The MCP patch is mounted automatically** via the `docker-compose.yml` volumes block — no manual `docker cp` needed. To update the patch later, edit `mcp_tools_patched.js` and run `docker compose restart api`.

7. **Open LibreChat:** http://localhost:3080 — and read [Agents Endpoint: Required Path for MCP Tools](#agents-endpoint-required-path-for-mcp-tools) before your first chat.

---

## Customizations Made to Get Qlik MCP Working

This section documents every customization required to make Qlik Cloud MCP work with LibreChat + Ollama. The upstream repo and LibreChat v0.8.5 (and v0.8.3-rc1 before it) have several issues that must be patched.

### Agents Endpoint: Required Path for MCP Tools

> **This is the most important thing to understand. If you skip it, the model will refuse to call tools and instead "explain" what it would do.**

In LibreChat v0.8.5, **MCP tools only flow through the Agents endpoint**. The codebase only ships three endpoint handlers — `agents/`, `assistants/`, `azureAssistants/` — and there is **no** custom-endpoint handler that injects MCP tools.

When you chat with a custom endpoint (the "Ollama" entry in `librechat.yaml`'s `endpoints.custom`), LibreChat constructs an **ephemeral agent** behind the scenes. Ephemeral agents only receive MCP tools when the frontend explicitly toggles a server on, which it does via `req.body.ephemeralAgent.mcp: ['qlik']`. Without that toggle, the model is sent zero tools, has nothing to call, and rationalizes itself into refusing.

**Two ways to get MCP tools attached:**

1. **Toggle the MCP server on in the chat composer** every time you start a new chat — look for a tools / wrench / plug icon near the message input that lists configured MCP servers.
2. **Use a saved Agent** that has the Qlik MCP tools permanently attached. This is the most reliable path. Use the helper script:
   ```bash
   # Find your user _id first
   docker exec librechat-mongodb mongosh LibreChat --quiet --eval \
     'db.users.find({}, {_id:1, email:1}).toArray()'

   # Create the agent (replace <user_object_id> with your _id)
   docker cp scripts/create-qlik-agent.js librechat:/tmp/create-qlik-agent.js
   docker exec librechat node /tmp/create-qlik-agent.js <user_object_id>
   ```
   The script inserts the agent with `qwen3:4b-nothinker`, the correct `_mcp_qlik`-suffixed tool names, temperature 0, and proper ACL entries (`agent_owner` + `remoteAgent_owner`). After refreshing the page, the agent appears in the sidebar.

#### MCP tool naming convention (`_mcp_qlik` suffix)

When LibreChat registers MCP tools with the LLM, it suffixes each tool name with `_mcp_<serverName>`. So the Qlik MCP server's `qlik_search` tool becomes **`qlik_search_mcp_qlik`** in the tools array sent to Ollama. From the model's perspective, that's the ONLY name that resolves.

The system prompt and the saved Agent's instructions therefore must reference the suffixed names. If your prompt says "use `qlik_search`" but the actual tool is named `qlik_search_mcp_qlik`, the model gets confused and gives up.

This is also why a user-visible "warn against `qlik_search_mcp`-like names" in the prompt is harmful — it tells the model not to use the real name.

---

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

**Why 16K context:** The MCP tool schemas consume approximately 4,500 tokens (9 filtered tools × ~500). With the system prompt, conversation, and tool results, 8K context was too small (caused "Message pruning removed all messages" / "truncating input prompt" errors). 16K provides enough room.

**VRAM budgets (Q4_K_M weights):**

| GPU tier | Recommended model | Weights | KV cache @ 16K | Total | GPU/CPU split |
|---|---|---|---|---|---|
| **4 GB** (RTX A500 / 3050 laptop) | `qwen3:4b` / `qwen3:4b-nothinker` | ~2.5 GB | ~2 GB | ~5 GB | ~40/60 |
| **8 GB** (RTX 4070 / 4060 Ti) | `qwen3:8b` / `qwen3:8b-nothinker` | ~5.2 GB | ~2 GB | ~7.5 GB | full GPU |
| **12 GB** (RTX 4070 Super) | same as 8 GB tier with larger context | | | | full GPU |
| **16 GB+** (RTX 4080 / 4090) | qwen3:14b possible | ~9 GB | ~3 GB | ~12 GB | full GPU |

For the 4 GB tier, ollama auto-splits layers between GPU and CPU (partial offload). Expect ~5-10 tokens/sec for `qwen3:4b-nothinker` vs ~30-40 tokens/sec when fully on GPU.

> **`apply-nvidia-config.ps1` / `apply-nvidia-config.sh`** retune `docker-compose.yml`'s Ollama service for a chosen VRAM tier interactively. See [Helper Scripts](#helper-scripts) below.

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

**Verification:** After applying the patch and opening a new chat that actually uses MCP (see [Agents Endpoint](#agents-endpoint-required-path-for-mcp-tools)), check the logs:
```bash
docker logs librechat 2>&1 | grep "Fetched.*filtered to"
```
You should see:
```
[MCP Reinitialize] Fetched 59 tools, filtered to 9 for qlik
```
(Counts may shift as the Qlik MCP server adds or removes tools — match against the count in `mcp_tools_patched.js`'s `ALLOWED_TOOLS`.)

If you only see `[MCP] Initialized with 1 configured server and 0 tools.` and never a `Fetched ... filtered to ...` line, the patch's `fetchTools` is firing only at startup (when no user has authorized yet) — start a chat that engages MCP to trigger the per-user reinit. See [Troubleshooting](#troubleshooting).

---

### 6. MCP Tool Filter (59 → 9 Tools)

**File:** `mcp_tools_patched.js`

**Problem:** The Qlik MCP server exposes 59 tools (count may grow over time). Each tool has a JSON schema (~400-500 tokens). With 59 tools, the schemas consume well over 25K tokens — exceeding the entire context window of any 4-8B model and causing:
- "Message pruning removed all messages" / "truncating input prompt" errors
- Operation timeouts / aborted requests
- The model unable to reason about which tool to use

**Fix:** An `ALLOWED_TOOLS` array filters to **9 read-only essentials**:

```javascript
const ALLOWED_TOOLS = [
  // Search & Discovery (2)
  'qlik_search',
  'qlik_describe_app',
  // Sheets (2)
  'qlik_list_sheets',
  'qlik_get_sheet_details',
  // Charts (2)
  'qlik_get_chart_info',
  'qlik_get_chart_data',
  // Dimensions & Measures (2)
  'qlik_list_dimensions',
  'qlik_list_measures',
  // Fields (1)
  'qlik_get_fields',
];
```

These names are the **raw tool names** as the Qlik MCP server reports them. When LibreChat registers them with the LLM, it appends the `_mcp_qlik` suffix (see [MCP tool naming convention](#mcp-tool-naming-convention-_mcp_qlik-suffix)) — so the model actually sees `qlik_search_mcp_qlik`, `qlik_describe_app_mcp_qlik`, etc. **Use the suffixed names in your system prompt and Agent instructions, but the raw names here in the patch filter.**

**Excluded categories** (available on the server but filtered out):
- All write/create/update/delete tools (sheet, chart, filter, dimension, measure, data product, glossary)
- Selection-state tools (current_selections / clear_selections / select_values / bookmarks)
- Dataset tools (11)
- Data Product tools (8 — all writes)
- Glossary tools (12)
- `qlik_search_spaces` — listed in earlier documentation but **does not actually exist** on the current Qlik MCP server (only 59 tools total are exposed; use `qlik_search` with `resourceType: "space"` instead)

Verify the filter is active in the logs:
```bash
docker logs librechat 2>&1 | grep "Fetched.*filtered to"
# Expected: [MCP Reinitialize] Fetched 59 tools, filtered to 9 for qlik
```

To add or remove tools, edit `ALLOWED_TOOLS` in `mcp_tools_patched.js` and `docker compose restart api`.

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
    - "qwen3:4b-nothinker"   # default — recommended for ≤ 4 GB VRAM
    - "qwen3:4b"
    - "qwen3:8b-nothinker"   # recommended for 8 GB VRAM
    - "qwen3:8b"
  fetch: false
```

**Choose based on your VRAM:**
- **≤ 4 GB VRAM** (laptop GPUs like RTX A500, RTX 3050): use **`qwen3:4b-nothinker`**. Fits with partial CPU offload; tool calls work cleanly. ~5-15 sec per simple tool call.
- **8 GB VRAM** (desktop RTX 4060 Ti / 4070): use **`qwen3:8b-nothinker`**. Fully on GPU at 16K context; ~1-3 sec per tool call.
- **`qwen3:14b` is intentionally not included** — too large for the typical hardware this stack targets; it was previously listed but caused OOM on 8 GB cards.

The `-nothinker` suffixed variants are custom Modelfile-built versions with thinking disabled and temperature baked to 0 — see [Modelfile.nothinker](#7b-modelfilenothinker--disabling-qwen3-reasoning-mode) below.

#### 7b. `Modelfile.nothinker` / `Modelfile.4b-nothinker` — disabling Qwen3 reasoning mode

Qwen3 has a built-in reasoning mode that emits `<think>...</think>` blocks before responses. For a tool-calling agent this wastes tokens and delays the first tool call. Two Modelfiles are included:

| File | Base | num_ctx | Built-in system prompt |
|---|---|---|---|
| `Modelfile.nothinker` | `qwen3:8b` | 16384 | `/no_think` |
| `Modelfile.4b-nothinker` | `qwen3:4b` | 16384 | `/no_think` |

Both also set `PARAMETER temperature 0` for maximum determinism.

The deploy scripts build both variants after pulling the base models. To rebuild manually after editing a Modelfile:

```bash
# Note the destination is /tmp/8b-nothinker.mf (NOT /tmp/Modelfile.nothinker)
docker cp Modelfile.nothinker librechat-ollama:/tmp/8b-nothinker.mf
docker compose exec ollama ollama create qwen3:8b-nothinker -f /tmp/8b-nothinker.mf

docker cp Modelfile.4b-nothinker librechat-ollama:/tmp/4b-nothinker.mf
docker compose exec ollama ollama create qwen3:4b-nothinker -f /tmp/4b-nothinker.mf
```

> **Why `*.mf` and not `Modelfile.*`?** Ollama 0.23.x has a parsing quirk: when you pass `-f /tmp/Modelfile.<anything>` it fails with `Error: no Modelfile or safetensors files found`. Any other filename (including no extension, or `.mf` / `.modelfile`) works. The deploy scripts use `/tmp/8b-nothinker.mf` and `/tmp/4b-nothinker.mf` as a workaround.

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

**Fix:** A direct prompt prefixed with `/no_think` to disable Qwen3's reasoning mode, followed by the explicit list of `_mcp_qlik`-suffixed tool names:

```yaml
promptPrefix: |
  /no_think
  You are a Qlik Cloud MCP tool-calling agent. Do NOT think or reason. IMMEDIATELY call a tool.

  You have NO internal knowledge about Qlik. You MUST call a tool for every question. Do NOT write text before calling a tool.

  The tools listed below are AVAILABLE right now. Their names end in "_mcp_qlik" — that suffix is required and correct. Call them exactly as written:

  - qlik_search_mcp_qlik — find apps, data products, spaces, or any resource. Use this first to find IDs.
  - qlik_describe_app_mcp_qlik — get app details (needs app ID)
  - qlik_list_sheets_mcp_qlik — list sheets (needs app ID)
  - qlik_get_sheet_details_mcp_qlik — sheet details (needs app ID + sheet ID)
  - qlik_get_chart_info_mcp_qlik — chart info (needs app ID + object ID)
  - qlik_get_chart_data_mcp_qlik — chart data (needs app ID + object ID)
  - qlik_list_dimensions_mcp_qlik — list dimensions (needs app ID)
  - qlik_list_measures_mcp_qlik — list measures (needs app ID)
  - qlik_get_fields_mcp_qlik — list fields (needs app ID)

  To find apps: call qlik_search_mcp_qlik with {"query": "...", "resourceType": "app"}.
  To find data products: qlik_search_mcp_qlik with {"resourceType": "dataproduct"}.
  To find spaces: qlik_search_mcp_qlik with {"resourceType": "space"}.
  Never ask the user for an ID — call qlik_search_mcp_qlik first to find it.
  Present results with counts and bullet points. If empty, say "No results found."
```

**Key design decisions:**
- **`_mcp_qlik` suffixed names** — these are the actual tool names LibreChat registers with the LLM (`tool_name + Constants.mcp_delimiter + serverName`). If your prompt lists `qlik_search` but the registered name is `qlik_search_mcp_qlik`, the model can't find it and either gives up or hallucinates. **Do not** put `NEVER use tool names like "qlik_search_mcp"` in your prompt — that's forbidding the real name.
- **`/no_think` prefix** — Qwen3-specific directive that disables reasoning-mode `<think>` blocks. Combined with `Modelfile.nothinker` (which bakes `/no_think` into the model's system prompt), this is belt-and-suspenders.
- **Explicit tool list with required args** — eliminates hallucinated tool names and prevents the model from inventing requirements (it loves to fabricate `space_id` arguments that aren't in the schema).
- **"NO internal knowledge"** — tells the model it cannot answer from memory, forcing tool use.
- **Concrete "how to find X" examples** — `resourceType="dataproduct"` / `"space"` / `"app"` for `qlik_search`, which is otherwise non-obvious.

**Note on `forcePrompt: true` + Agents:** when you use a saved Agent (recommended path), the Agent's own `instructions` field overrides this `promptPrefix`. The helper script `scripts/create-qlik-agent.js` writes the same prompt into the Agent's instructions.

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
```
(No re-apply needed — the patch is bind-mounted; see [Section 5](#5-librechat-mcp-oauth-bug-fix-critical).)

---

## Helper Scripts

Beyond the main `deploy.ps1` / `deploy.sh`, the repo ships small utilities for reconfiguring the stack after the initial deploy:

| Script | Purpose |
|---|---|
| `apply-qlik-config.ps1` | Windows Forms GUI to update tenant URL + OAuth Client ID in `.env` and `librechat.yaml`, with optional auto-restart of the `api` container. |
| `apply-qlik-config.sh` | CLI / Zenity-GUI equivalent for Linux/macOS. Supports `--tenant-url`, `--client-id`, `--restart`, `--no-restart`, `--gui`, `--cli` flags. |
| `apply-nvidia-config.ps1` | Windows Forms GUI to retune Ollama service in `docker-compose.yml`. Detects GPU via `nvidia-smi`, offers presets (CPU-only, 8/12/16/24 GB VRAM, Custom). Tunes `OLLAMA_NUM_PARALLEL`, `OLLAMA_MAX_LOADED_MODELS`, `OLLAMA_FLASH_ATTENTION`, `OLLAMA_GPU_OVERHEAD`, `OLLAMA_CONTEXT_LENGTH`, and the GPU `deploy:` block. Recreates the `ollama` container via `docker compose up -d ollama`. |
| `apply-nvidia-config.sh` | CLI version with `--preset <auto\|cpu\|8gb\|12gb\|16gb\|24gb>` flag. |
| `scripts/create-qlik-agent.js` | Node.js script that runs **inside** the `librechat` container. Inserts a saved Agent in MongoDB with `qwen3:4b-nothinker`, the correct `_mcp_qlik`-suffixed tool list, temperature 0, and proper ACL entries (`agent_owner` + `remoteAgent_owner`). The Agent appears in the sidebar after a page refresh. Use this when the chat-menu MCP toggle is unreliable or you want a known-good Agent. See [Agents Endpoint](#agents-endpoint-required-path-for-mcp-tools). |

Usage examples:
```bash
# Update tenant + client ID without re-running deploy
./apply-qlik-config.sh                                         # interactive
./apply-qlik-config.sh --tenant-url https://x.us.qlikcloud.com --client-id 01234... --restart

# Retune for the detected GPU
./apply-nvidia-config.sh --preset auto --restart

# Create the Qlik Agent (one-time per user)
docker exec librechat-mongodb mongosh LibreChat --quiet --eval \
  'db.users.find({}, {_id:1, email:1}).toArray()'             # find your user_id
docker cp scripts/create-qlik-agent.js librechat:/tmp/create-qlik-agent.js
docker exec librechat node /tmp/create-qlik-agent.js <user_object_id>
```

## Summary of All Modified Files

| File | What Changed | Why |
|---|---|---|
| `.env.example` | `VECTOR_DB_TYPE=pg` → `pgvector` | RAG API crash fix |
| `docker-compose.yml` | GPU support, Ollama tuning, 16K context, debug flags, ollama healthcheck, bind mount for `mcp_tools_patched.js` | GPU inference + persistent patch |
| `librechat.yaml` | Hardcoded URLs, OAuth config, **Agents endpoint enabled**, Qwen3 models (4b + 8b), `_mcp_qlik`-suffixed prompt, low temp, forcePrompt | Make MCP work end-to-end via Agents path |
| `mcp_tools_patched.js` | OAuth `fetchTools` fix + 9-tool filter | LibreChat bug fix + context budget for small models |
| `mcp_tools_original.js` | Backup of unpatched file | Reference / rollback |
| `Modelfile.nothinker` | `qwen3:8b` + `temperature 0` + `num_ctx 16384` + `SYSTEM /no_think` | Recommended for 8 GB GPUs |
| `Modelfile.4b-nothinker` | `qwen3:4b` + `temperature 0` + `num_ctx 16384` + `SYSTEM /no_think` | Recommended for ≤ 4 GB GPUs |
| `deploy.ps1` | 6-step Windows deploy (params + `.mf` temp filenames) | Automated setup |
| `deploy.sh` | 6-step Linux/macOS deploy (flags + `.mf` temp filenames) | Automated setup |
| `apply-qlik-config.{ps1,sh}` | Post-deploy Qlik creds update | Reconfigure without full re-deploy |
| `apply-nvidia-config.{ps1,sh}` | Post-deploy Ollama GPU tuning | Switch VRAM tiers / CPU mode cleanly |
| `scripts/create-qlik-agent.js` | Direct MongoDB Agent creation | Reliable saved-Agent path for MCP tool calling |
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

### Model "explains" instead of calling tools / refuses to call a tool / fabricates a `space_id` requirement
This is the single most common failure mode. The model has no tools available, so it pattern-matches off the system prompt and hallucinates a justification for not acting. **Cause:** you're chatting via the "Ollama" custom endpoint (an ephemeral agent) without the `qlik` MCP server toggled on.

**Fix (pick one):**
1. In the chat composer, toggle `qlik` on in the MCP/tools menu before sending a message.
2. Use a saved Agent — run `scripts/create-qlik-agent.js` (see [Agents Endpoint](#agents-endpoint-required-path-for-mcp-tools)) and chat with that Agent.

Verify the tool array is being attached: `docker logs librechat 2>&1 | grep "Fetched.*filtered to"` should show `Fetched 59 tools, filtered to 9 for qlik` when the MCP is active for that chat.

### Model uses a tool name like `qlik_search_mcp_qlik` and you're not sure that's right
**It is right.** LibreChat suffixes MCP tool names with `_mcp_<serverName>` when registering them with the LLM. See [MCP tool naming convention](#mcp-tool-naming-convention-_mcp_qlik-suffix). Make sure your system prompt and Agent instructions list the `_mcp_qlik`-suffixed names, not the raw ones.

### `ollama create` fails with `Error: no Modelfile or safetensors files found`
You're passing `-f /tmp/Modelfile.<something>`. Ollama 0.23.x has a parsing quirk on that filename pattern. Rename the destination file in the container to something else like `/tmp/8b-nothinker.mf`:
```bash
docker cp Modelfile.nothinker librechat-ollama:/tmp/8b-nothinker.mf
docker compose exec ollama ollama create qwen3:8b-nothinker -f /tmp/8b-nothinker.mf
```

### MCP shows 0 tools at startup / "Tools: undefined" in `[MCP][qlik]` log block
This is **expected** on startup for OAuth-required MCP servers — tool discovery happens per-user, after they complete the OAuth flow. The patched `reinitMCPServer` calls `fetchTools()` once a user-specific connection is established. You should later see `[MCP Reinitialize] Fetched 59 tools, filtered to 9 for qlik` when a user actually engages MCP in a chat.

If you still see 0 tools after authorizing in a chat, verify the patch is mounted:
```bash
docker compose exec librechat head -3 /app/api/server/services/Tools/mcp.js
```
The output should match the top of `mcp_tools_patched.js`. If not, check the `api.volumes` block in `docker-compose.yml`, then `docker compose up -d` to recreate the container.

### "Message pruning removed all messages" / `truncating input prompt`
Context window too small for the number of tool schemas + system prompt + conversation history. Either:
- Increase `OLLAMA_CONTEXT_LENGTH` in `docker-compose.yml` (and rebuild the relevant `*-nothinker` Modelfile with a higher `num_ctx`) — needs more VRAM
- Reduce the `ALLOWED_TOOLS` list in `mcp_tools_patched.js`
- Switch to the smaller `qwen3:4b-nothinker` model (more KV-cache budget per GB)

### Model asks for IDs instead of searching
The system prompt is not being injected. Ensure `forcePrompt: true` in `librechat.yaml` and restart LibreChat. If using a saved Agent, check the Agent's `instructions` field.

### 401 Authorization Required (on MCP requests, not OAuth)
OAuth tokens expired. Clear tokens from MongoDB and re-authorize (see [Expired OAuth Tokens](#expired-oauth-tokens)).

### "redirect_uri is not registered"
Your Qlik OAuth client doesn't have the redirect URI registered. Add `http://localhost:3080/api/mcp/qlik/oauth/callback` in the Qlik Cloud Management Console under your OAuth client settings.

### "agent_id is required in request body"
The `X-Agent-Id` header is missing from `librechat.yaml`. Add it under the `headers` section of the MCP server config — should be your OAuth Client ID.

### RAG API keeps restarting
Ensure `VECTOR_DB_TYPE=pgvector` in `.env` (not `pg`).

### Ollama running on CPU instead of GPU
1. Verify NVIDIA Container Toolkit: `docker info | grep -i nvidia`
2. Check GPU inside container: `docker exec librechat-ollama nvidia-smi`
3. Ensure the `deploy.resources.reservations.devices` block exists in `docker-compose.yml`
4. `docker exec librechat-ollama ollama ps` shows the loaded model's `PROCESSOR` split — `100/0 CPU/GPU` means it's fully on CPU

### Ollama partially on CPU even though GPU is detected
Expected on small-VRAM GPUs when the model + KV cache exceed available VRAM. The `PROCESSOR` column shows the split, e.g. `36%/64% CPU/GPU`. Either accept the slower inference, switch to a smaller model (e.g. `qwen3:4b-nothinker`), or reduce `OLLAMA_CONTEXT_LENGTH`.

## Notes

- MongoDB runs with `--noauth` (local development only, not production)
- All images are pulled from public registries (no custom Dockerfiles)
- Containers use `restart: unless-stopped` for automatic recovery
- The MCP patch was originally written for LibreChat v0.8.3-rc1 and re-validated against v0.8.5 (the bug persists). Future versions may fix the OAuth bug natively — check `/app/api/server/services/Tools/mcp.js` for `if (connection && !oauthRequired)` before applying.
- **Security:** the defaults (`ALLOW_REGISTRATION=true`, MongoDB `--noauth`, OAuth tokens stored without DB auth) make this safe only on `localhost`. After creating your first account, set `ALLOW_REGISTRATION=false` in `.env` and run `docker compose restart api` to disable open registration. Do not expose port 3080 to any network where untrusted users can reach it.
