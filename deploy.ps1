#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$EnvFile   = Join-Path $ScriptDir ".env"

Write-Host "=============================================="
Write-Host "  LibreChat + Ollama + Qlik MCP  --  Deploy"
Write-Host "=============================================="
Write-Host ""

# --- Prompt for Qlik credentials ---

$QlikTenantUrl = Read-Host "Qlik Cloud tenant URL (e.g. https://tenant.us.qlikcloud.com)"
$QlikTenantUrl = $QlikTenantUrl.TrimEnd("/")

if ([string]::IsNullOrWhiteSpace($QlikTenantUrl)) {
    Write-Error "Tenant URL cannot be empty."
    exit 1
}

$QlikApiKey = Read-Host "Qlik Cloud API key"

if ([string]::IsNullOrWhiteSpace($QlikApiKey)) {
    Write-Error "API key cannot be empty."
    exit 1
}

Write-Host ""

# --- Helper: generate random hex string ---

function New-HexSecret($Bytes) {
    $buf = New-Object byte[] $Bytes
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buf)
    return ($buf | ForEach-Object { $_.ToString("x2") }) -join ""
}

# --- Generate secrets if .env doesn't exist yet ---

if (Test-Path $EnvFile) {
    Write-Host "Existing .env found -- updating Qlik credentials only."
    $content = Get-Content $EnvFile -Raw
    $content = $content -replace "(?m)^QLIK_TENANT_URL=.*", "QLIK_TENANT_URL=$QlikTenantUrl"
    $content = $content -replace "(?m)^QLIK_API_KEY=.*",    "QLIK_API_KEY=$QlikApiKey"
    Set-Content -Path $EnvFile -Value $content -NoNewline
}
else {
    Write-Host "Generating new .env with fresh secrets..."

    $CredsKey         = New-HexSecret 16
    $CredsIV          = New-HexSecret 8
    $JwtSecret        = New-HexSecret 32
    $JwtRefreshSecret = New-HexSecret 32
    $MeiliMasterKey   = New-HexSecret 16
    $PgPassword       = New-HexSecret 16

    @"
#==============================================================#
#                    LibreChat + Ollama + Qlik MCP             #
#==============================================================#

QLIK_TENANT_URL=$QlikTenantUrl
QLIK_API_KEY=$QlikApiKey

CREDS_KEY=$CredsKey
CREDS_IV=$CredsIV
JWT_SECRET=$JwtSecret
JWT_REFRESH_SECRET=$JwtRefreshSecret
ALLOW_REGISTRATION=true

MONGO_URI=mongodb://mongodb:27017/LibreChat

MEILISEARCH_HOST=http://meilisearch:7700
MEILI_MASTER_KEY=$MeiliMasterKey

RAG_API_URL=http://rag_api:8000
VECTOR_DB_TYPE=pg
POSTGRES_DB=vectordb
POSTGRES_USER=vectordb
POSTGRES_PASSWORD=$PgPassword
DB_HOST=vectordb
DB_PORT=5432
"@ | Set-Content -Path $EnvFile -NoNewline
}

Write-Host ""
Write-Host "Qlik tenant:  $QlikTenantUrl"
Write-Host "Qlik API key: $($QlikApiKey.Substring(0, [Math]::Min(8, $QlikApiKey.Length)))..."
Write-Host ""

# --- Start the stack ---

Write-Host "Starting Docker Compose stack..."
docker compose -f "$ScriptDir\docker-compose.yml" up -d
if ($LASTEXITCODE -ne 0) { Write-Error "Docker Compose failed to start."; exit 1 }

Write-Host ""
Write-Host "Pulling Ollama models..."
Write-Host "  [1/2] llama3.2 (3B -- lightweight all-rounder)..."
docker compose -f "$ScriptDir\docker-compose.yml" exec -T ollama ollama pull llama3.2

Write-Host "  [2/2] glm4:9b (9B -- top reasoning & coding)..."
docker compose -f "$ScriptDir\docker-compose.yml" exec -T ollama ollama pull glm4:9b

Write-Host ""
Write-Host "=============================================="
Write-Host "  Ready!  Open http://localhost:3080"
Write-Host "=============================================="
