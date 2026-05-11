# Detailed Change Log — Qlik MCP + LibreChat Customizations

This document provides an exact line-by-line record of every file modified, what the original value was, what it was changed to, and why.

---

## Image versions (latest update 2026-05-11)

| Image | Pinned tag | Resolved digest at last update | Version |
|---|---|---|---|
| `ghcr.io/danny-avila/librechat` | `latest` | `sha256:a46254938507971e0d4f7ed3f9d116bd9b118f4810b5b75eb716baf575645068` | v0.8.5 (built 2026-04-22) |
| `ollama/ollama` | `latest` | `sha256:d00473cb58f0082c07cd6ed0d326a8a86f443ab69c51f8fc2b1a41687d45c661` | 0.23.2 (built 2026-05-07) |

**LibreChat upgrade notes (v0.8.3-rc1 → v0.8.5):**
- `/app/api/server/services/Tools/mcp.js` was substantially refactored upstream (added MCP servers registry, server config inspection, reinspection flow). The line count grew from 183 → 229.
- The OAuth `fetchTools` bug (`if (connection && !oauthRequired)`) still exists in v0.8.5 — moved from line 122 to line 168. The patch was re-derived against v0.8.5.
- `mcp_tools_original.js` was updated to track the v0.8.5 baseline.
- `mcp_tools_patched.js` was rebuilt against v0.8.5 (286 lines, was 240).

---

## File 1: `.env.example`

**Location:** `/.env.example`
**Lines changed:** 1

| Line | Setting | Original Value | New Value | Reason |
|---|---|---|---|---|
| 53 | `VECTOR_DB_TYPE` | `pg` | `pgvector` | RAG API crash-looped on startup. The pgvector driver requires the string `pgvector`, not `pg`. |

Additionally, the original file referenced `QLIK_API_KEY` for API key authentication. This was replaced with `QLIK_OAUTH_CLIENT_ID` for OAuth authentication in commit `ba32379`.

---

## File 2: `docker-compose.yml`

**Location:** `/docker-compose.yml`
**Lines changed:** 16 lines added, 1 line modified

### Change 2a: LibreChat API environment variables (lines 25-29)

**Original (lines 25-26):**
```yaml
    environment:
      ...
      - QLIK_API_KEY=${QLIK_API_KEY}
```

**Changed to (lines 25-29):**
```yaml
    environment:
      ...
      - QLIK_TENANT_URL=${QLIK_TENANT_URL}
      - QLIK_OAUTH_CLIENT_ID=${QLIK_OAUTH_CLIENT_ID}
      - CONFIG_BYPASS_VALIDATION=true
      - DEBUG_MCP=true
      - DEBUG=librechat:mcp*
```

| Variable | Value | Purpose |
|---|---|---|
| `QLIK_API_KEY` → `QLIK_OAUTH_CLIENT_ID` | User's OAuth client ID | Switched from API key auth to OAuth auth |
| `CONFIG_BYPASS_VALIDATION` | `true` | Prevents LibreChat from failing on startup if config has unsupported fields |
| `DEBUG_MCP` | `true` | Enables MCP-specific debug logging in LibreChat |
| `DEBUG` | `librechat:mcp*` | Enables verbose transport-level MCP logging (connection, auth, tool discovery) |

### Change 2b: Ollama GPU support and tuning (lines 86-98)

**Original (lines 81-84):**
```yaml
  ollama:
    image: ollama/ollama:latest
    container_name: librechat-ollama
    volumes:
      - ollama_data:/root/.ollama
    restart: unless-stopped
```

**Changed to (lines 81-99):**
```yaml
  ollama:
    image: ollama/ollama:latest
    container_name: librechat-ollama
    volumes:
      - ollama_data:/root/.ollama
    environment:
      - OLLAMA_NUM_PARALLEL=1
      - OLLAMA_MAX_LOADED_MODELS=1
      - OLLAMA_FLASH_ATTENTION=1
      - OLLAMA_GPU_OVERHEAD=512000000
      - OLLAMA_CONTEXT_LENGTH=16384
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    restart: unless-stopped
```

| Variable | Value | Purpose |
|---|---|---|
| `OLLAMA_NUM_PARALLEL` | `1` | Process one request at a time to maximize VRAM for a single model |
| `OLLAMA_MAX_LOADED_MODELS` | `1` | Keep only one model loaded in VRAM (prevents OOM with 8GB) |
| `OLLAMA_FLASH_ATTENTION` | `1` | Enable flash attention kernel for faster inference |
| `OLLAMA_GPU_OVERHEAD` | `512000000` | Reserve 512MB VRAM for CUDA/driver overhead |
| `OLLAMA_CONTEXT_LENGTH` | `16384` | 16K token context window. Originally `8192`, increased because 21 tool schemas consume ~6K-8K tokens and 8K wasn't enough (caused "Message pruning removed all messages" error) |
| `deploy.resources.reservations.devices` | nvidia/all/gpu | Passes all NVIDIA GPUs into the container via Docker Container Toolkit |

---

## File 3: `librechat.yaml`

**Location:** `/librechat.yaml`
**Lines changed:** Extensive rewrite — 26 lines original → 70 lines current

### Change 3a: Model list (lines 10-13)

**Original:**
```yaml
      models:
        default:
          - "llama3.2"
          - "mistral"
          - "codellama"
          - "phi3"
          - "gemma2"
        fetch: true
```

**Changed to:**
```yaml
      models:
        default:
          - "qwen3:8b"
          - "qwen3:14b"
        fetch: false
```

| Setting | Original | New | Reason |
|---|---|---|---|
| Model list | 5 generic models | 2 Qwen3 models | Qwen3 had the best MCP tool-calling results. Other models either hallucinated tool names, asked users for IDs instead of searching, or timed out. |
| `fetch` | `true` | `false` | `true` showed all models in Ollama (including non-tool-calling ones). `false` restricts the UI to only the two configured models. |

**Models tested and rejected:**
- `llama3.2` (3B) — too small, couldn't handle 21 tool schemas in context
- `llama3.1:8b` (8B) — inconsistent tool calling, sometimes answered from memory
- `glm4:9b` (9B) — decent but slower than Qwen3
- `llama3-groq-tool-use:8b` (8B) — purpose-built for tool calling but didn't reliably trigger with Qlik's schema format
- `mistral:7b` (7B) — inconsistent, sometimes ignored tools

### Change 3b: forcePrompt (line 17)

| Setting | Original | New | Reason |
|---|---|---|---|
| `forcePrompt` | `false` | `true` | Ensures the system prompt is always injected into every request, even if the user sets a custom prompt in the UI. Without this, the model could "forget" it's a tool-calling agent. |

### Change 3c: temperature (line 19)

| Setting | Original | New | Reason |
|---|---|---|---|
| `temperature` | not set (default ~0.7) | `0.2` | Lower temperature = less randomness = more deterministic tool selection. The model picks the same tool for the same question every time instead of randomly deciding to answer from memory. |

### Change 3d: promptPrefix — system prompt (lines 20-50)

**Original:**
```yaml
      # (no promptPrefix was set)
```

**Changed to:**
```yaml
      promptPrefix: |
        <role>You are a Qlik Cloud MCP tool-calling agent. Your ONLY job is to call MCP tools
        and return their results. You have NO internal knowledge about the user's Qlik
        environment.</role>

        <mandatory>
        EVERY response to a Qlik-related question MUST start with a tool call. You are
        FORBIDDEN from answering any Qlik question without first calling a tool. If you
        respond with text instead of a tool call, you have failed.
        </mandatory>

        <workflow>
        Step 1: User asks question → IMMEDIATELY call a tool. Do not write any text first.
        Step 2: If you need an ID, call qlik_search first to find it.
        Step 3: After getting tool results, present them clearly with counts and bullet points.
        Step 4: If no results, say "No results found." Never invent data.
        </workflow>

        <tools>
        SEARCH: qlik_search (find anything), qlik_search_spaces, qlik_search_users, qlik_describe_app
        SHEETS: qlik_list_sheets, qlik_create_sheet, qlik_get_sheet_details
        CHARTS: qlik_get_chart_info, qlik_get_chart_data, qlik_add_chart, qlik_add_filter
        DIMS/MEASURES: qlik_list_dimensions, qlik_create_dimension, qlik_list_measures, qlik_create_measure
        FIELDS: qlik_get_fields, qlik_get_field_values, qlik_search_field_values
        SELECTIONS: qlik_get_current_selections, qlik_select_values, qlik_clear_selections
        </tools>

        <rules>
        - ALWAYS call a tool first. Never answer from memory.
        - Never ask the user for IDs. Use qlik_search to find them yourself.
        - One tool at a time. Wait for result before next action.
        - Only use tool names listed above. Never invent tool names.
        - Include counts when asked "how many".
        - If a tool fails, fix parameters and retry once.
        </rules>
```

**Design decisions in the prompt:**

| Element | What it does | Why it's needed |
|---|---|---|
| `<role>` tag | Defines the model as a "tool-calling agent" with "NO internal knowledge" | Prevents the model from answering Qlik questions from its training data instead of calling tools |
| `<mandatory>` tag | "FORBIDDEN from answering without a tool call" / "you have failed" | Strong negative framing that Qwen3 responds well to. Without this, the model would sometimes skip tool calls |
| `<workflow>` tag | Step-by-step procedure: question → tool call → present results | Gives the model a clear execution flow instead of leaving it to decide |
| `<tools>` tag | Lists all 21 available tools by category | Prevents the model from hallucinating tool names. Maps user intent to specific tools |
| `<rules>` tag | "Never ask the user for IDs" / "Use qlik_search to find them yourself" | Without this rule, the model would ask "What's the app ID?" instead of calling qlik_search |
| XML tags overall | `<role>`, `<mandatory>`, `<workflow>`, `<tools>`, `<rules>` | Qwen3 handles XML-structured sections better than plain text. Clear section boundaries reduce instruction-skipping |

### Change 3e: MCP server config — auth method (lines 52-70)

**Original:**
```yaml
mcpServers:
  qlik:
    type: streamable-http
    url: "${QLIK_TENANT_URL}/api/ai/mcp"
    headers:
      Authorization: "Bearer ${QLIK_API_KEY}"
    chatMenu: true
    startup: true
```

**Changed to:**
```yaml
mcpServers:
  qlik:
    type: streamable-http
    url: "https://your-tenant.us.qlikcloud.com/api/ai/mcp"
    headers:
      X-Agent-Id: "your-oauth-client-id"
    requiresOAuth: true
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
    chatMenu: true
    startup: true
```

| Setting | Original | New | Reason |
|---|---|---|---|
| `url` | `"${QLIK_TENANT_URL}/api/ai/mcp"` | Hardcoded URL | LibreChat does NOT interpolate `${ENV_VAR}` in librechat.yaml. The literal string `${QLIK_TENANT_URL}` was sent as the URL. |
| `headers.Authorization` | `"Bearer ${QLIK_API_KEY}"` | Removed | Switched from API key to OAuth |
| `headers.X-Agent-Id` | not set | OAuth Client ID | Qlik MCP requires `agent_id` in every request. Without this header, Qlik returns `"agent_id is required in request body"` |
| `requiresOAuth` | not set | `true` | Tells LibreChat this server needs OAuth authentication |
| `oauth.*` | not set | Full OAuth config | Authorization code + PKCE (S256) flow configuration |
| `oauth.client_id` | not set | User's OAuth Client ID | Must match a Native OAuth client registered in Qlik Cloud with the correct redirect URI |
| `oauth.redirect_uri` | not set | `http://localhost:3080/api/mcp/qlik/oauth/callback` | LibreChat's OAuth callback endpoint. Must be registered in the Qlik Cloud OAuth client settings |
| `oauth.scope` | not set | `"user_default mcp:execute"` | `user_default` = access user's resources. `mcp:execute` = permission to execute MCP tool calls |
| `oauth.code_challenge_methods_supported` | not set | `["S256"]` | PKCE with SHA-256 challenge, required by Qlik Cloud |

---

## File 4: `mcp_tools_patched.js`

**Location:** `/mcp_tools_patched.js`
**Applies to:** `/app/api/server/services/Tools/mcp.js` inside the LibreChat container
**Baseline:** Originally written against LibreChat v0.8.3-rc1, re-derived against v0.8.5 (the same bug persists, but the surrounding file was substantially refactored upstream — `mcp_tools_original.js` now tracks the v0.8.5 file).
**Lines changed (v0.8.5):** Lines 168-170 (3 lines) replaced with lines 168-228 (~61 lines)

### Change 4a: OAuth fetchTools bug fix

**Original code (`mcp_tools_original.js`, line 168 in v0.8.5; line 122 in v0.8.3-rc1):**
```javascript
    if (connection && !oauthRequired) {
      tools = await connection.fetchTools();
    }
```

**Patched code (`mcp_tools_patched.js`, line 203 in v0.8.5):**
```javascript
    if (connection) {
      try {
        const fetchedTools = await connection.fetchTools();
        // ... filtering logic ...
      } catch (fetchErr) {
        logger.debug(
          `[MCP Reinitialize] fetchTools failed for ${serverName}: ${fetchErr?.message ?? String(fetchErr)}`,
        );
      }
    }
```

| What changed | Detail |
|---|---|
| Condition | `if (connection && !oauthRequired)` → `if (connection)` |
| Effect | The `!oauthRequired` check caused LibreChat to **skip tool discovery** for any MCP server that used OAuth. Even after successful OAuth authentication with valid tokens, `fetchTools()` was never called. Result: 0 tools discovered, model had no tools available. |
| Error handling | Added try/catch around `fetchTools()`. Original code had no error handling — a failed fetch would crash the reinit process. |
| This is a bug in | LibreChat v0.8.3-rc1 through v0.8.5, file `/app/api/server/services/Tools/mcp.js`, function `reinitMCPServer()` (line 122 in v0.8.3-rc1, line 168 in v0.8.5) |

### Change 4b: Tool filter — ALLOWED_TOOLS array (lines 174-201 in v0.8.5)

**Original:** No tool filtering existed. All tools from the MCP server were passed to the model.

**Added:**
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

**Filtering logic (lines 210-214 in v0.8.5):**
```javascript
    if (ALLOWED_TOOLS.length > 0) {
      tools = fetchedTools.filter(t => ALLOWED_TOOLS.includes(t.name));
      logger.info(
        `[MCP Reinitialize] Fetched ${fetchedTools.length} tools, filtered to ${tools.length} for ${serverName}`,
      );
    }
```

| What changed | Detail |
|---|---|
| Tool count | 53 → 21 tools |
| Reason | Each tool has a JSON schema (~200-400 tokens). 53 tools × ~300 tokens = ~15,900 tokens of tool schemas alone. This exceeded the entire context window of an 8B model at 8K or even 16K context, causing "Message pruning removed all messages" errors and operation timeouts. |
| Included categories | Search & Discovery (4), Sheets (3), Charts & Visualizations (4), Dimensions & Measures (4), Fields & Selections (6) |
| Excluded categories | Datasets (11 tools), Data Products (8 tools), Glossary (12 tools), Other (1 tool) |

### Change 4c: Debug logging (line 208 in v0.8.5)

**Added:**
```javascript
    logger.info(`[MCP Reinitialize] ALL TOOLS: ${fetchedTools.map(t => t.name).join(', ')}`);
```

Logs all 53 available tool names on every reinit for debugging and reference.

### How to apply the patch

```bash
docker cp mcp_tools_patched.js librechat:/app/api/server/services/Tools/mcp.js
```

**Must be re-applied after:** `docker compose pull`, `docker compose up --build`, `docker compose down && docker compose up`, or any action that recreates the `librechat` container.

### How to verify the patch is active

```bash
docker logs librechat --tail 20
```

**Success:** `[MCP Reinitialize] Fetched 53 tools, filtered to 21 for qlik`
**Patch not applied:** `[MCP] Initialized with 1 configured server and 0 tools.` or `Tools: undefined`

---

## File 5: `.env`

**Location:** `/.env` (not committed — contains secrets)
**Generated by:** `deploy.ps1` or `deploy.sh`

| Setting | Original Template | Deployed Value | Reason |
|---|---|---|---|
| `QLIK_TENANT_URL` | `https://your-tenant.us.qlikcloud.com` | `https://<your-tenant>.us.qlikcloud.com` | Set to your actual Qlik Cloud tenant by the deploy script |
| `QLIK_API_KEY` | `your_qlik_api_key_here` | Removed | Switched to OAuth — API key no longer used |
| `QLIK_OAUTH_CLIENT_ID` | not in original | `<your-oauth-client-id>` | Your Qlik Cloud OAuth client ID, set by the deploy script |
| `VECTOR_DB_TYPE` | `pg` | `pgvector` | Fixed RAG API crash |
| `CREDS_KEY` | placeholder | Auto-generated 32-char hex | `openssl rand -hex 16` |
| `CREDS_IV` | placeholder | Auto-generated 16-char hex | `openssl rand -hex 8` |
| `JWT_SECRET` | placeholder | Auto-generated 64-char hex | `openssl rand -hex 32` |
| `JWT_REFRESH_SECRET` | placeholder | Auto-generated 64-char hex | `openssl rand -hex 32` |
| `MEILI_MASTER_KEY` | placeholder | Auto-generated 32-char hex | `openssl rand -hex 16` |
| `POSTGRES_PASSWORD` | placeholder | Auto-generated 32-char hex | `openssl rand -hex 16` |

---

## New Files Created

| File | Purpose | Size |
|---|---|---|
| `mcp_tools_patched.js` | Patched version of LibreChat's `/app/api/server/services/Tools/mcp.js` with OAuth fix + tool filter | ~7 KB |
| `mcp_tools_original.js` | Backup of the original unpatched file from the LibreChat container | ~6 KB |
| `README.md` | Full setup guide and customization documentation | ~15 KB |
| `CHANGES.md` | This file — detailed line-by-line change log | ~12 KB |
| `deploy.ps1` | Windows PowerShell deployment script (7-step automated setup) | ~5 KB |
| `deploy.sh` | Linux/macOS Bash deployment script (7-step automated setup) | ~4 KB |

---

## Complete Diff Summary

```
Files modified:    3  (.env.example, docker-compose.yml, librechat.yaml)
Files created:     6  (mcp_tools_patched.js, mcp_tools_original.js, README.md, CHANGES.md, deploy.ps1, deploy.sh)
Lines added:     ~750
Lines removed:    ~25
Container patch:   1  (mcp.js inside librechat container)
```
