#Requires -Version 5.1

param(
    [string]$QlikTenantUrl,
    [string]$QlikOAuthClientId
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$EnvFile   = Join-Path $ScriptDir ".env"
$Compose   = Join-Path $ScriptDir "docker-compose.yml"

Write-Host ""
Write-Host "=============================================="
Write-Host "  LibreChat + Ollama + Qlik MCP  --  Deploy"
Write-Host "=============================================="
Write-Host ""

# -------------------------------------------------------
# 1. Pre-flight checks
# -------------------------------------------------------

Write-Host "[1/6] Checking prerequisites..."

# Docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker is not installed or not in PATH."
    exit 1
}
docker info | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Docker daemon is not running. Start Docker Desktop first."
    exit 1
}

# NVIDIA GPU (optional)
$HasGPU = $false
try {
    $nvidiaOut = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>&1
    if ($LASTEXITCODE -eq 0) {
        $HasGPU = $true
        Write-Host "  GPU detected: $($nvidiaOut.Trim())"
    }
} catch {
    Write-Host "  No NVIDIA GPU detected -- Ollama will use CPU only."
}

Write-Host ""

# -------------------------------------------------------
# 2. Qlik credentials (from params or prompt)
# -------------------------------------------------------

Write-Host "[2/6] Qlik Cloud credentials..."

if ([string]::IsNullOrWhiteSpace($QlikTenantUrl)) {
    $QlikTenantUrl = Read-Host "  Qlik Cloud tenant URL (e.g. https://tenant.us.qlikcloud.com)"
}
$QlikTenantUrl = $QlikTenantUrl.TrimEnd("/")

if ([string]::IsNullOrWhiteSpace($QlikTenantUrl)) {
    Write-Error "Tenant URL cannot be empty."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($QlikOAuthClientId)) {
    $QlikOAuthClientId = Read-Host "  Qlik Cloud OAuth Client ID"
}

if ([string]::IsNullOrWhiteSpace($QlikOAuthClientId)) {
    Write-Error "OAuth Client ID cannot be empty."
    exit 1
}

Write-Host ""
Write-Host "  Tenant:   $QlikTenantUrl"
Write-Host "  ClientID: $($QlikOAuthClientId.Substring(0, [Math]::Min(8, $QlikOAuthClientId.Length)))..."
Write-Host ""

# -------------------------------------------------------
# 3. Generate .env
# -------------------------------------------------------

Write-Host "[3/6] Configuring environment..."

function New-HexSecret($Bytes) {
    $buf = New-Object byte[] $Bytes
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buf)
    return ($buf | ForEach-Object { $_.ToString("x2") }) -join ""
}

if (Test-Path $EnvFile) {
    Write-Host "  Existing .env found -- updating Qlik credentials only."
    $content = Get-Content $EnvFile -Raw
    $content = $content -replace "(?m)^QLIK_TENANT_URL=.*",      "QLIK_TENANT_URL=$QlikTenantUrl"
    $content = $content -replace "(?m)^QLIK_OAUTH_CLIENT_ID=.*",  "QLIK_OAUTH_CLIENT_ID=$QlikOAuthClientId"
    # Fix VECTOR_DB_TYPE if needed
    $content = $content -replace "(?m)^VECTOR_DB_TYPE=pg$",        "VECTOR_DB_TYPE=pgvector"
    Set-Content -Path $EnvFile -Value $content -NoNewline
}
else {
    Write-Host "  Generating new .env with fresh secrets..."
    @"
#==============================================================#
#                    LibreChat + Ollama + Qlik MCP             #
#==============================================================#

QLIK_TENANT_URL=$QlikTenantUrl
QLIK_OAUTH_CLIENT_ID=$QlikOAuthClientId

CREDS_KEY=$(New-HexSecret 16)
CREDS_IV=$(New-HexSecret 8)
JWT_SECRET=$(New-HexSecret 32)
JWT_REFRESH_SECRET=$(New-HexSecret 32)
ALLOW_REGISTRATION=true

MONGO_URI=mongodb://mongodb:27017/LibreChat

MEILISEARCH_HOST=http://meilisearch:7700
MEILI_MASTER_KEY=$(New-HexSecret 16)

RAG_API_URL=http://rag_api:8000
VECTOR_DB_TYPE=pgvector
POSTGRES_DB=vectordb
POSTGRES_USER=vectordb
POSTGRES_PASSWORD=$(New-HexSecret 16)
DB_HOST=vectordb
DB_PORT=5432
"@ | Set-Content -Path $EnvFile -NoNewline
}

# -------------------------------------------------------
# 4. Update librechat.yaml with user's Qlik credentials
# -------------------------------------------------------

Write-Host "[4/6] Updating librechat.yaml with your Qlik credentials..."

$yamlFile = Join-Path $ScriptDir "librechat.yaml"
if (Test-Path $yamlFile) {
    $yaml = Get-Content $yamlFile -Raw

    # Replace tenant URL
    $yaml = $yaml -replace 'url:\s*"https://[^"]+/api/ai/mcp"', "url: `"$QlikTenantUrl/api/ai/mcp`""
    $yaml = $yaml -replace 'authorization_url:\s*"https://[^"]+/oauth/authorize"', "authorization_url: `"$QlikTenantUrl/oauth/authorize`""
    $yaml = $yaml -replace 'token_url:\s*"https://[^"]+/oauth/token"', "token_url: `"$QlikTenantUrl/oauth/token`""

    # Replace OAuth client ID (in all 3 places)
    $yaml = $yaml -replace 'X-Agent-Id:\s*"[^"]+"', "X-Agent-Id: `"$QlikOAuthClientId`""
    $yaml = $yaml -replace 'client_id:\s*"[^"]+"', "client_id: `"$QlikOAuthClientId`""

    Set-Content -Path $yamlFile -Value $yaml -NoNewline
    Write-Host "  Updated tenant URL and OAuth client ID in librechat.yaml"
}

Write-Host ""

# -------------------------------------------------------
# 5. Start Docker Compose stack
# -------------------------------------------------------

Write-Host "[5/6] Starting Docker Compose stack..."
docker compose -f $Compose up -d
if ($LASTEXITCODE -ne 0) { Write-Error "Docker Compose failed to start."; exit 1 }

# Wait for Ollama to be ready (poll instead of fixed sleep)
Write-Host "  Waiting for Ollama to be ready..."
$timeout = 90
$elapsed = 0
$ready = $false
while ($elapsed -lt $timeout) {
    docker compose -f $Compose exec -T ollama ollama list 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $ready = $true
        break
    }
    Start-Sleep -Seconds 3
    $elapsed += 3
}
if (-not $ready) {
    Write-Host "  Warning: Ollama did not become ready within ${timeout}s. Continuing anyway."
} else {
    Write-Host "  Ollama is ready (after ${elapsed}s)."
}

Write-Host ""

# -------------------------------------------------------
# 6. Pull Ollama models + build nothinker variant
# -------------------------------------------------------

Write-Host "[6/6] Pulling Ollama models (this may take several minutes)..."

Write-Host "  [1/4] qwen3:8b (8B -- base model)..."
docker compose -f $Compose exec -T ollama ollama pull qwen3:8b
if ($LASTEXITCODE -ne 0) { Write-Host "  Warning: Failed to pull qwen3:8b" }

Write-Host "  [2/4] qwen3:4b (4B -- recommended for <=4GB VRAM)..."
docker compose -f $Compose exec -T ollama ollama pull qwen3:4b
if ($LASTEXITCODE -ne 0) { Write-Host "  Warning: Failed to pull qwen3:4b" }

# Note: destination file is named *.mf (not /tmp/Modelfile.*) to work around an
# Ollama 0.23.x quirk where `ollama create -f /tmp/Modelfile.X` fails with
# "no Modelfile or safetensors files found." Anything else works fine.

Write-Host "  [3/4] Building qwen3:8b-nothinker (thinking disabled)..."
$ModelfilePath = Join-Path $ScriptDir "Modelfile.nothinker"
if (Test-Path $ModelfilePath) {
    docker cp $ModelfilePath librechat-ollama:/tmp/8b-nothinker.mf
    docker compose -f $Compose exec -T ollama ollama create qwen3:8b-nothinker -f /tmp/8b-nothinker.mf
    if ($LASTEXITCODE -ne 0) { Write-Host "  Warning: Failed to create qwen3:8b-nothinker" }
} else {
    Write-Host "  Warning: Modelfile.nothinker not found. Skipping."
}

Write-Host "  [4/4] Building qwen3:4b-nothinker (recommended default)..."
$Modelfile4bPath = Join-Path $ScriptDir "Modelfile.4b-nothinker"
if (Test-Path $Modelfile4bPath) {
    docker cp $Modelfile4bPath librechat-ollama:/tmp/4b-nothinker.mf
    docker compose -f $Compose exec -T ollama ollama create qwen3:4b-nothinker -f /tmp/4b-nothinker.mf
    if ($LASTEXITCODE -ne 0) { Write-Host "  Warning: Failed to create qwen3:4b-nothinker" }
} else {
    Write-Host "  Warning: Modelfile.4b-nothinker not found. Skipping."
}

Write-Host ""

# -------------------------------------------------------
# Done
# -------------------------------------------------------

Write-Host "=============================================="
Write-Host "  DEPLOYMENT COMPLETE"
Write-Host "=============================================="
Write-Host ""
Write-Host "  App:    http://localhost:3080"
Write-Host "  Models: qwen3:4b-nothinker (default), qwen3:4b, qwen3:8b-nothinker, qwen3:8b"
Write-Host "  Tools:  21 Qlik MCP tools (filtered from 53)"
Write-Host ""
Write-Host "  The MCP patch is applied via a docker-compose volume mount,"
Write-Host "  so it persists across container restarts and recreations."
Write-Host "  To update the patch, edit mcp_tools_patched.js and run:"
Write-Host "    docker compose restart api"
Write-Host ""
Write-Host "  FIRST TIME SETUP:"
Write-Host "  1. Open http://localhost:3080 and create an account"
Write-Host "  2. Start a new chat, select 'qwen3:4b-nothinker' model"
Write-Host "  3. Click the Qlik MCP plugin icon and click 'Authorize'"
Write-Host "  4. Sign in to Qlik Cloud when redirected"
Write-Host "  5. Ask: 'What apps do I have in Qlik?'"
Write-Host ""
Write-Host "  OAuth redirect URI (must be registered in Qlik Cloud):"
Write-Host "    http://localhost:3080/api/mcp/qlik/oauth/callback"
Write-Host "=============================================="
