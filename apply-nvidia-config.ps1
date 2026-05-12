#Requires -Version 5.1
<#
.SYNOPSIS
  GUI to tune the Ollama service GPU settings in docker-compose.yml.
  Picks an Auto preset based on detected VRAM, or accepts a custom config.

.DESCRIPTION
  Settings managed:
    - GPU passthrough on/off (the `deploy:` block in the ollama service)
    - OLLAMA_NUM_PARALLEL
    - OLLAMA_MAX_LOADED_MODELS
    - OLLAMA_FLASH_ATTENTION (checkbox)
    - OLLAMA_GPU_OVERHEAD (entered as MB, written as bytes)
    - OLLAMA_CONTEXT_LENGTH

  Optionally recreates the ollama container so changes take effect.
#>

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$Compose   = Join-Path $ScriptDir "docker-compose.yml"

# -------------------------------------------------------
# Detect NVIDIA GPU
# -------------------------------------------------------

$gpuName = ""
$gpuVramMiB = 0
try {
    $smiOut = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null
    if ($LASTEXITCODE -eq 0 -and $smiOut) {
        $firstLine = ($smiOut -split "`r?`n" | Where-Object { $_.Trim() })[0]
        $parts = $firstLine -split ',' | ForEach-Object { $_.Trim() }
        $gpuName = $parts[0]
        $gpuVramMiB = [int]$parts[1]
    }
} catch {}

# -------------------------------------------------------
# Presets
# -------------------------------------------------------

$Presets = @{
    "Custom"   = $null
    "Auto"     = $null
    "CPU only" = @{ GpuMode=$false; NumParallel=1; MaxLoaded=1; FlashAttention=$false; GpuOverheadMB=0;   ContextLength=8192  }
    "GPU 8 GB"  = @{ GpuMode=$true;  NumParallel=1; MaxLoaded=1; FlashAttention=$true;  GpuOverheadMB=512;  ContextLength=16384 }
    "GPU 12 GB" = @{ GpuMode=$true;  NumParallel=1; MaxLoaded=1; FlashAttention=$true;  GpuOverheadMB=512;  ContextLength=24576 }
    "GPU 16 GB" = @{ GpuMode=$true;  NumParallel=2; MaxLoaded=1; FlashAttention=$true;  GpuOverheadMB=1024; ContextLength=32768 }
    "GPU 24 GB+"= @{ GpuMode=$true;  NumParallel=2; MaxLoaded=2; FlashAttention=$true;  GpuOverheadMB=2048; ContextLength=65536 }
}

function Get-AutoPresetName {
    param([int]$VramMiB)
    if ($VramMiB -le 0)      { return "CPU only" }
    if ($VramMiB -lt 10000)  { return "GPU 8 GB" }
    if ($VramMiB -lt 14000)  { return "GPU 12 GB" }
    if ($VramMiB -lt 20000)  { return "GPU 16 GB" }
    return "GPU 24 GB+"
}

# -------------------------------------------------------
# Read current values from docker-compose.yml
# -------------------------------------------------------

$current = @{
    GpuMode        = $true
    NumParallel    = 1
    MaxLoaded      = 1
    FlashAttention = $true
    GpuOverheadMB  = 512
    ContextLength  = 16384
}

if (Test-Path $Compose) {
    $composeRaw = Get-Content $Compose -Raw
    if ($composeRaw -match '(?ms)^  ollama:.*?^    restart: unless-stopped') {
        $ollamaBlock = $Matches[0]

        $current.GpuMode = ($ollamaBlock -match 'driver:\s*nvidia')

        if ($ollamaBlock -match 'OLLAMA_NUM_PARALLEL=(\d+)')         { $current.NumParallel = [int]$Matches[1] }
        if ($ollamaBlock -match 'OLLAMA_MAX_LOADED_MODELS=(\d+)')    { $current.MaxLoaded = [int]$Matches[1] }
        if ($ollamaBlock -match 'OLLAMA_FLASH_ATTENTION=(\d+)')      { $current.FlashAttention = ([int]$Matches[1] -ne 0) }
        if ($ollamaBlock -match 'OLLAMA_GPU_OVERHEAD=(\d+)')         {
            $bytes = [long]$Matches[1]
            $current.GpuOverheadMB = [int]([math]::Round($bytes / 1000000))
        }
        if ($ollamaBlock -match 'OLLAMA_CONTEXT_LENGTH=(\d+)')       { $current.ContextLength = [int]$Matches[1] }
    }
}

# -------------------------------------------------------
# Apply function — rebuilds the ollama: block in docker-compose.yml
# -------------------------------------------------------

function New-OllamaBlock {
    param(
        [bool]$GpuMode,
        [int]$NumParallel,
        [int]$MaxLoaded,
        [bool]$FlashAttention,
        [int]$GpuOverheadMB,
        [int]$ContextLength
    )

    $flash = if ($FlashAttention) { 1 } else { 0 }
    $overheadBytes = [long]$GpuOverheadMB * 1000000

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("  ollama:")
    [void]$sb.AppendLine("    image: ollama/ollama:latest")
    [void]$sb.AppendLine("    container_name: librechat-ollama")
    [void]$sb.AppendLine("    volumes:")
    [void]$sb.AppendLine("      - ollama_data:/root/.ollama")
    [void]$sb.AppendLine("    healthcheck:")
    [void]$sb.AppendLine('      test: ["CMD-SHELL", "ollama list || exit 1"]')
    [void]$sb.AppendLine("      interval: 10s")
    [void]$sb.AppendLine("      timeout: 5s")
    [void]$sb.AppendLine("      retries: 12")
    [void]$sb.AppendLine("      start_period: 30s")
    [void]$sb.AppendLine("    environment:")
    [void]$sb.AppendLine("      - OLLAMA_NUM_PARALLEL=$NumParallel")
    [void]$sb.AppendLine("      - OLLAMA_MAX_LOADED_MODELS=$MaxLoaded")
    [void]$sb.AppendLine("      - OLLAMA_FLASH_ATTENTION=$flash")
    [void]$sb.AppendLine("      - OLLAMA_GPU_OVERHEAD=$overheadBytes")
    [void]$sb.AppendLine("      - OLLAMA_CONTEXT_LENGTH=$ContextLength")
    if ($GpuMode) {
        [void]$sb.AppendLine("    deploy:")
        [void]$sb.AppendLine("      resources:")
        [void]$sb.AppendLine("        reservations:")
        [void]$sb.AppendLine("          devices:")
        [void]$sb.AppendLine("            - driver: nvidia")
        [void]$sb.AppendLine("              count: all")
        [void]$sb.AppendLine("              capabilities: [gpu]")
    }
    [void]$sb.Append("    restart: unless-stopped")

    return $sb.ToString()
}

function Invoke-ApplyConfig {
    param([hashtable]$Settings)

    if (-not (Test-Path $Compose)) {
        throw "docker-compose.yml not found at $Compose"
    }

    $newBlock = New-OllamaBlock `
        -GpuMode        $Settings.GpuMode `
        -NumParallel    $Settings.NumParallel `
        -MaxLoaded      $Settings.MaxLoaded `
        -FlashAttention $Settings.FlashAttention `
        -GpuOverheadMB  $Settings.GpuOverheadMB `
        -ContextLength  $Settings.ContextLength

    $content = Get-Content $Compose -Raw
    $pattern = '(?ms)^  ollama:.*?^    restart: unless-stopped'
    if ($content -notmatch $pattern) {
        throw "Could not locate the ollama service block in docker-compose.yml."
    }
    # Use a scriptblock replacement so $newBlock isn't reinterpreted for backreferences.
    $content = [regex]::Replace($content, $pattern, { param($m) $newBlock })
    Set-Content -Path $Compose -Value $content -NoNewline
}

function Invoke-RecreateOllama {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    # up -d ollama picks up config changes (recreate) without touching other services
    docker compose -f $Compose up -d ollama | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# -------------------------------------------------------
# Build the form
# -------------------------------------------------------

$form               = New-Object System.Windows.Forms.Form
$form.Text          = "Ollama / NVIDIA Configuration"
$form.Size          = New-Object System.Drawing.Size(540, 520)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox   = $false
$form.MinimizeBox   = $false
$form.Font          = New-Object System.Drawing.Font("Segoe UI", 9)

# Heading
$heading = New-Object System.Windows.Forms.Label
$heading.Location = New-Object System.Drawing.Point(20, 15)
$heading.Size     = New-Object System.Drawing.Size(490, 22)
$heading.Text     = "Ollama GPU configuration"
$heading.Font     = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($heading)

# Detected GPU
$gpuInfo = New-Object System.Windows.Forms.Label
$gpuInfo.Location = New-Object System.Drawing.Point(20, 42)
$gpuInfo.Size     = New-Object System.Drawing.Size(490, 18)
if ($gpuVramMiB -gt 0) {
    $gpuInfo.Text = "Detected: $gpuName ($gpuVramMiB MiB VRAM)"
    $gpuInfo.ForeColor = [System.Drawing.Color]::DarkGreen
} else {
    $gpuInfo.Text = "No NVIDIA GPU detected (nvidia-smi missing or failed) — CPU only recommended"
    $gpuInfo.ForeColor = [System.Drawing.Color]::DarkOrange
}
$form.Controls.Add($gpuInfo)

# Preset
$presetLabel = New-Object System.Windows.Forms.Label
$presetLabel.Location = New-Object System.Drawing.Point(20, 75)
$presetLabel.Size     = New-Object System.Drawing.Size(150, 22)
$presetLabel.Text     = "Preset:"
$form.Controls.Add($presetLabel)

$presetBox = New-Object System.Windows.Forms.ComboBox
$presetBox.Location = New-Object System.Drawing.Point(180, 72)
$presetBox.Size     = New-Object System.Drawing.Size(330, 22)
$presetBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
foreach ($k in @("Custom","Auto","CPU only","GPU 8 GB","GPU 12 GB","GPU 16 GB","GPU 24 GB+")) {
    [void]$presetBox.Items.Add($k)
}
$presetBox.SelectedItem = "Custom"
$form.Controls.Add($presetBox)

# GPU mode radios
$modeLabel = New-Object System.Windows.Forms.Label
$modeLabel.Location = New-Object System.Drawing.Point(20, 110)
$modeLabel.Size     = New-Object System.Drawing.Size(150, 22)
$modeLabel.Text     = "Mode:"
$form.Controls.Add($modeLabel)

$radioGpu = New-Object System.Windows.Forms.RadioButton
$radioGpu.Location = New-Object System.Drawing.Point(180, 108)
$radioGpu.Size     = New-Object System.Drawing.Size(150, 22)
$radioGpu.Text     = "GPU passthrough"
$radioGpu.Checked  = $current.GpuMode
$form.Controls.Add($radioGpu)

$radioCpu = New-Object System.Windows.Forms.RadioButton
$radioCpu.Location = New-Object System.Drawing.Point(340, 108)
$radioCpu.Size     = New-Object System.Drawing.Size(170, 22)
$radioCpu.Text     = "CPU only"
$radioCpu.Checked  = -not $current.GpuMode
$form.Controls.Add($radioCpu)

# Fields
function New-LabelTextBox {
    param([string]$LabelText, [int]$Y, [string]$Value)
    $l = New-Object System.Windows.Forms.Label
    $l.Location = New-Object System.Drawing.Point(20, $Y)
    $l.Size     = New-Object System.Drawing.Size(280, 22)
    $l.Text     = $LabelText
    $form.Controls.Add($l)

    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point(310, ($Y - 2))
    $t.Size     = New-Object System.Drawing.Size(200, 22)
    $t.Text     = $Value
    $form.Controls.Add($t)

    return $t
}

$txtNumParallel  = New-LabelTextBox -LabelText "OLLAMA_NUM_PARALLEL"             -Y 150 -Value $current.NumParallel
$txtMaxLoaded    = New-LabelTextBox -LabelText "OLLAMA_MAX_LOADED_MODELS"        -Y 180 -Value $current.MaxLoaded
$txtOverhead     = New-LabelTextBox -LabelText "OLLAMA_GPU_OVERHEAD (MB)"        -Y 210 -Value $current.GpuOverheadMB
$txtContextLen   = New-LabelTextBox -LabelText "OLLAMA_CONTEXT_LENGTH (tokens)"  -Y 240 -Value $current.ContextLength

$flashCheck = New-Object System.Windows.Forms.CheckBox
$flashCheck.Location = New-Object System.Drawing.Point(20, 275)
$flashCheck.Size     = New-Object System.Drawing.Size(490, 22)
$flashCheck.Text     = "OLLAMA_FLASH_ATTENTION (faster inference, recommended on)"
$flashCheck.Checked  = $current.FlashAttention
$form.Controls.Add($flashCheck)

# Restart
$restartCheck = New-Object System.Windows.Forms.CheckBox
$restartCheck.Location = New-Object System.Drawing.Point(20, 320)
$restartCheck.Size     = New-Object System.Drawing.Size(490, 22)
$restartCheck.Text     = "Recreate the ollama container after applying (picks up config changes)"
$restartCheck.Checked  = $true
$form.Controls.Add($restartCheck)

# Status
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(20, 360)
$statusLabel.Size     = New-Object System.Drawing.Size(490, 60)
$statusLabel.Text     = ""
$form.Controls.Add($statusLabel)

# -------------------------------------------------------
# Wire preset → field auto-fill
# -------------------------------------------------------

$applyingPreset = $false  # guard so manual edits don't recursively switch to Custom

function Set-FieldsFromPreset {
    param([string]$Name)
    $key = $Name
    if ($Name -eq "Auto") {
        $key = Get-AutoPresetName -VramMiB $gpuVramMiB
    }
    $p = $Presets[$key]
    if ($null -eq $p) { return }

    $script:applyingPreset = $true
    if ($p.GpuMode) { $radioGpu.Checked = $true } else { $radioCpu.Checked = $true }
    $txtNumParallel.Text = $p.NumParallel
    $txtMaxLoaded.Text   = $p.MaxLoaded
    $txtOverhead.Text    = $p.GpuOverheadMB
    $txtContextLen.Text  = $p.ContextLength
    $flashCheck.Checked  = $p.FlashAttention
    $script:applyingPreset = $false
}

$presetBox.Add_SelectedIndexChanged({
    $sel = $presetBox.SelectedItem.ToString()
    if ($sel -eq "Custom") { return }
    Set-FieldsFromPreset -Name $sel
})

# When user manually edits a field, snap preset → Custom
$onManualEdit = {
    if (-not $script:applyingPreset -and $presetBox.SelectedItem -ne "Custom") {
        $presetBox.SelectedItem = "Custom"
    }
}
$txtNumParallel.Add_TextChanged($onManualEdit)
$txtMaxLoaded.Add_TextChanged($onManualEdit)
$txtOverhead.Add_TextChanged($onManualEdit)
$txtContextLen.Add_TextChanged($onManualEdit)
$flashCheck.Add_CheckedChanged($onManualEdit)
$radioGpu.Add_CheckedChanged($onManualEdit)
$radioCpu.Add_CheckedChanged($onManualEdit)

# -------------------------------------------------------
# Apply / Close buttons
# -------------------------------------------------------

$applyButton          = New-Object System.Windows.Forms.Button
$applyButton.Location = New-Object System.Drawing.Point(330, 440)
$applyButton.Size     = New-Object System.Drawing.Size(90, 30)
$applyButton.Text     = "Apply"
$applyButton.Add_Click({
    # Validate
    $parsed = @{}
    foreach ($pair in @(
        @{Key="NumParallel"; Tb=$txtNumParallel; Min=1; Max=64},
        @{Key="MaxLoaded";   Tb=$txtMaxLoaded;   Min=1; Max=16},
        @{Key="GpuOverheadMB"; Tb=$txtOverhead;  Min=0; Max=32768},
        @{Key="ContextLength"; Tb=$txtContextLen; Min=512; Max=262144}
    )) {
        $v = 0
        if (-not [int]::TryParse($pair.Tb.Text.Trim(), [ref]$v) -or $v -lt $pair.Min -or $v -gt $pair.Max) {
            $statusLabel.Text      = "Error: $($pair.Key) must be an integer between $($pair.Min) and $($pair.Max)."
            $statusLabel.ForeColor = [System.Drawing.Color]::Firebrick
            return
        }
        $parsed[$pair.Key] = $v
    }

    $settings = @{
        GpuMode        = $radioGpu.Checked
        NumParallel    = $parsed.NumParallel
        MaxLoaded      = $parsed.MaxLoaded
        FlashAttention = $flashCheck.Checked
        GpuOverheadMB  = $parsed.GpuOverheadMB
        ContextLength  = $parsed.ContextLength
    }

    $statusLabel.ForeColor = [System.Drawing.Color]::DimGray
    $statusLabel.Text      = "Applying..."
    $applyButton.Enabled   = $false
    $form.Refresh()

    try {
        Invoke-ApplyConfig -Settings $settings
        $msg = "Updated docker-compose.yml (ollama service)."
        if ($restartCheck.Checked) {
            $msg += "`nRecreating ollama container..."
            $statusLabel.Text = $msg
            $form.Refresh()
            $ok = Invoke-RecreateOllama
            if ($ok) { $msg = $msg.TrimEnd(".") + " done." }
            else     { $msg += " FAILED (run 'docker compose up -d ollama' manually)." }
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

$closeButton          = New-Object System.Windows.Forms.Button
$closeButton.Location = New-Object System.Drawing.Point(430, 440)
$closeButton.Size     = New-Object System.Drawing.Size(80, 30)
$closeButton.Text     = "Close"
$closeButton.Add_Click({ $form.Close() })
$form.Controls.Add($closeButton)

# Show
[void]$form.ShowDialog()
$form.Dispose()
