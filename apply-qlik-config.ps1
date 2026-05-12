#Requires -Version 5.1
<#
.SYNOPSIS
  GUI to update Qlik tenant URL + OAuth Client ID in .env and librechat.yaml.
  Optionally restarts the LibreChat container so changes take effect.

.DESCRIPTION
  Run anytime after deploy.ps1 to change which Qlik tenant or OAuth client
  the stack points to. Pre-fills the dialog from the existing .env values.
#>

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$EnvFile   = Join-Path $ScriptDir ".env"
$YamlFile  = Join-Path $ScriptDir "librechat.yaml"
$Compose   = Join-Path $ScriptDir "docker-compose.yml"

# -------------------------------------------------------
# Read existing values from .env (if present)
# -------------------------------------------------------

$existingTenant = ""
$existingClient = ""
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        if ($_ -match '^QLIK_TENANT_URL=(.*)$')      { $existingTenant = $Matches[1] }
        if ($_ -match '^QLIK_OAUTH_CLIENT_ID=(.*)$') { $existingClient = $Matches[1] }
    }
}

# -------------------------------------------------------
# Apply function — updates .env + librechat.yaml
# -------------------------------------------------------

function Invoke-ApplyConfig {
    param(
        [string]$TenantUrl,
        [string]$ClientId
    )

    $TenantUrl = $TenantUrl.TrimEnd('/')
    $changes = @()

    # .env
    if (Test-Path $EnvFile) {
        $content = Get-Content $EnvFile -Raw
        $content = $content -replace "(?m)^QLIK_TENANT_URL=.*",      "QLIK_TENANT_URL=$TenantUrl"
        $content = $content -replace "(?m)^QLIK_OAUTH_CLIENT_ID=.*", "QLIK_OAUTH_CLIENT_ID=$ClientId"
        Set-Content -Path $EnvFile -Value $content -NoNewline
        $changes += ".env"
    }

    # librechat.yaml
    if (Test-Path $YamlFile) {
        $yaml = Get-Content $YamlFile -Raw
        $yaml = $yaml -replace 'url:\s*"https://[^"]+/api/ai/mcp"',                "url: `"$TenantUrl/api/ai/mcp`""
        $yaml = $yaml -replace 'authorization_url:\s*"https://[^"]+/oauth/authorize"', "authorization_url: `"$TenantUrl/oauth/authorize`""
        $yaml = $yaml -replace 'token_url:\s*"https://[^"]+/oauth/token"',         "token_url: `"$TenantUrl/oauth/token`""
        $yaml = $yaml -replace 'X-Agent-Id:\s*"[^"]+"',                            "X-Agent-Id: `"$ClientId`""
        $yaml = $yaml -replace 'client_id:\s*"[^"]+"',                             "client_id: `"$ClientId`""
        Set-Content -Path $YamlFile -Value $yaml -NoNewline
        $changes += "librechat.yaml"
    }

    return $changes
}

function Invoke-RestartApi {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    docker compose -f $Compose restart api | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# -------------------------------------------------------
# Build the form
# -------------------------------------------------------

$form               = New-Object System.Windows.Forms.Form
$form.Text          = "Qlik MCP Configuration"
$form.Size          = New-Object System.Drawing.Size(540, 340)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox   = $false
$form.MinimizeBox   = $false
$form.Font          = New-Object System.Drawing.Font("Segoe UI", 9)

# Heading
$heading = New-Object System.Windows.Forms.Label
$heading.Location = New-Object System.Drawing.Point(20, 15)
$heading.Size     = New-Object System.Drawing.Size(490, 22)
$heading.Text     = "Update Qlik Cloud credentials"
$heading.Font     = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($heading)

$subheading = New-Object System.Windows.Forms.Label
$subheading.Location = New-Object System.Drawing.Point(20, 40)
$subheading.Size     = New-Object System.Drawing.Size(490, 18)
$subheading.Text     = "Writes to .env and librechat.yaml. Optionally restarts the api container."
$subheading.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($subheading)

# Tenant URL
$tenantLabel = New-Object System.Windows.Forms.Label
$tenantLabel.Location = New-Object System.Drawing.Point(20, 75)
$tenantLabel.Size     = New-Object System.Drawing.Size(490, 18)
$tenantLabel.Text     = "Tenant URL (e.g. https://your-tenant.us.qlikcloud.com)"
$form.Controls.Add($tenantLabel)

$tenantBox          = New-Object System.Windows.Forms.TextBox
$tenantBox.Location = New-Object System.Drawing.Point(20, 95)
$tenantBox.Size     = New-Object System.Drawing.Size(490, 22)
$tenantBox.Text     = $existingTenant
$form.Controls.Add($tenantBox)

# OAuth Client ID
$clientLabel = New-Object System.Windows.Forms.Label
$clientLabel.Location = New-Object System.Drawing.Point(20, 130)
$clientLabel.Size     = New-Object System.Drawing.Size(490, 18)
$clientLabel.Text     = "OAuth Client ID"
$form.Controls.Add($clientLabel)

$clientBox          = New-Object System.Windows.Forms.TextBox
$clientBox.Location = New-Object System.Drawing.Point(20, 150)
$clientBox.Size     = New-Object System.Drawing.Size(490, 22)
$clientBox.Text     = $existingClient
$form.Controls.Add($clientBox)

# Restart checkbox
$restartCheck = New-Object System.Windows.Forms.CheckBox
$restartCheck.Location = New-Object System.Drawing.Point(20, 185)
$restartCheck.Size     = New-Object System.Drawing.Size(490, 22)
$restartCheck.Text     = "Restart LibreChat (api) container after applying"
$restartCheck.Checked  = $true
$form.Controls.Add($restartCheck)

# Status
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(20, 215)
$statusLabel.Size     = New-Object System.Drawing.Size(490, 40)
$statusLabel.Text     = ""
$form.Controls.Add($statusLabel)

# Apply
$applyButton          = New-Object System.Windows.Forms.Button
$applyButton.Location = New-Object System.Drawing.Point(330, 265)
$applyButton.Size     = New-Object System.Drawing.Size(90, 30)
$applyButton.Text     = "Apply"
$applyButton.Add_Click({
    $url      = $tenantBox.Text.Trim().TrimEnd('/')
    $clientId = $clientBox.Text.Trim()

    if ($url -notmatch '^https?://') {
        $statusLabel.Text = "Error: Tenant URL must start with https://"
        $statusLabel.ForeColor = [System.Drawing.Color]::Firebrick
        return
    }
    if ([string]::IsNullOrWhiteSpace($clientId)) {
        $statusLabel.Text = "Error: OAuth Client ID cannot be empty."
        $statusLabel.ForeColor = [System.Drawing.Color]::Firebrick
        return
    }

    $statusLabel.ForeColor = [System.Drawing.Color]::DimGray
    $statusLabel.Text      = "Applying..."
    $applyButton.Enabled   = $false
    $form.Refresh()

    try {
        $changed = Invoke-ApplyConfig -TenantUrl $url -ClientId $clientId
        $msg     = "Updated: " + ($changed -join ", ")

        if ($restartCheck.Checked) {
            $msg += "`nRestarting api container..."
            $statusLabel.Text = $msg
            $form.Refresh()
            $ok = Invoke-RestartApi
            if ($ok) {
                $msg = $msg.TrimEnd(".") + " done."
            } else {
                $msg += " FAILED (run 'docker compose restart api' manually)."
            }
        }

        $statusLabel.Text      = $msg
        $statusLabel.ForeColor = [System.Drawing.Color]::ForestGreen
    } catch {
        $statusLabel.Text      = "Error: $($_.Exception.Message)"
        $statusLabel.ForeColor = [System.Drawing.Color]::Firebrick
    } finally {
        $applyButton.Enabled = $true
    }
})
$form.Controls.Add($applyButton)

# Close
$closeButton          = New-Object System.Windows.Forms.Button
$closeButton.Location = New-Object System.Drawing.Point(430, 265)
$closeButton.Size     = New-Object System.Drawing.Size(80, 30)
$closeButton.Text     = "Close"
$closeButton.Add_Click({ $form.Close() })
$form.Controls.Add($closeButton)

# Show
[void]$form.ShowDialog()
$form.Dispose()
