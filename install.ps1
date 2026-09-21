# AI Swarm Installer
# Deploys .ai-swarm infrastructure into any project directory.
#
# Usage (from project dir):
#   powershell -File C:\workspace\herdr설치\install.ps1
#
# Usage (with explicit target):
#   powershell -File C:\workspace\herdr설치\install.ps1 -Target C:\workspace\youtube

[CmdletBinding()]
param(
    [string]$Target       = "",   # project root (default: current directory)
    [string]$HerdrSession = ""    # override herdr session name
)

$ErrorActionPreference = "Stop"
$SourceDir = $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($Target)) { $Target = (Get-Location).Path }
$Target = (Resolve-Path $Target).Path
$Name   = Split-Path $Target -Leaf

if ([string]::IsNullOrWhiteSpace($HerdrSession)) {
    $HerdrSession = $Name.ToLowerInvariant() -replace '[_ ]', '-'
}

$SwarmDir  = Join-Path $Target ".ai-swarm"
$ClaudeDir = Join-Path $Target ".claude"

Write-Host ""
Write-Host "AI Swarm Install" -ForegroundColor Cyan
Write-Host "  Project      : $Target"
Write-Host "  Herdr session: $HerdrSession"
Write-Host ""

# ── 1. Directory structure ────────────────────────────────────────────────────

foreach ($d in @(
    $SwarmDir,
    "$SwarmDir\state",
    "$SwarmDir\logs",
    "$SwarmDir\reports",
    "$SwarmDir\tmp"
)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
Write-Host "  [OK] .ai-swarm/ directories"

# ── 2. Copy scripts ───────────────────────────────────────────────────────────

$Scripts = @("delegate.ps1", "profile.ps1", "trace.ps1", "claude-session-hook.ps1")
foreach ($f in $Scripts) {
    $src = Join-Path $SourceDir $f
    $dst = Join-Path $SwarmDir $f
    if (Test-Path $src) {
        Copy-Item $src $dst -Force
        Write-Host "  [OK] .ai-swarm\$f"
    } else {
        Write-Warning "  [MISSING] $f not found in $SourceDir"
    }
}

# ── 3. config.json ────────────────────────────────────────────────────────────

$configPath = Join-Path $SwarmDir "config.json"
$configJson = @{ herdr_session = $HerdrSession } | ConvertTo-Json
[System.IO.File]::WriteAllText($configPath, $configJson, [System.Text.UTF8Encoding]::new($false))
Write-Host "  [OK] .ai-swarm\config.json"

# ── 4. CLAUDE.md (skip if already exists) ────────────────────────────────────

$claudeMdDst = Join-Path $Target "CLAUDE.md"
if (-not (Test-Path $claudeMdDst)) {
    $claudeMdSrc = Join-Path $SourceDir "CLAUDE.md"
    if (Test-Path $claudeMdSrc) {
        Copy-Item $claudeMdSrc $claudeMdDst -Force
        Write-Host "  [OK] CLAUDE.md"
    } else {
        Write-Warning "  [MISSING] CLAUDE.md template not found in $SourceDir"
    }
} else {
    Write-Host "  [SKIP] CLAUDE.md (already exists)"
}

# ── 5. .claude/settings.json — register Claude session hook ──────────────────

New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
$settingsPath = Join-Path $ClaudeDir "settings.json"
# Forward slash on purpose: Claude Code runs hooks through Git Bash on Windows, which eats "\c".
$hookCmd = "powershell -NonInteractive -File .ai-swarm/claude-session-hook.ps1"
$legacyHookCmd = "powershell -NonInteractive -File .ai-swarm\claude-session-hook.ps1"

# Load or init
$settings = $null
if (Test-Path $settingsPath) {
    try { $settings = Get-Content -Raw $settingsPath | ConvertFrom-Json }
    catch { $settings = $null }
}
if ($null -eq $settings) { $settings = [pscustomobject]@{} }

# Ensure hooks.PreToolUse array exists
if (-not ($settings.PSObject.Properties.Name -contains "hooks")) {
    $settings | Add-Member -Force -NotePropertyName "hooks" -NotePropertyValue ([pscustomobject]@{})
}
if (-not ($settings.hooks.PSObject.Properties.Name -contains "PreToolUse")) {
    $settings.hooks | Add-Member -Force -NotePropertyName "PreToolUse" -NotePropertyValue @()
}

# Migrate entries written by older installers (backslash path is broken under Git Bash)
$migrated = $false
foreach ($e in @($settings.hooks.PreToolUse)) {
    if ($e.PSObject.Properties.Name -contains "hooks") {
        foreach ($h in @($e.hooks)) {
            if ([string]$h.command -eq $legacyHookCmd) { $h.command = $hookCmd; $migrated = $true }
        }
    }
}

# Check if hook already registered
$alreadyIn = @(
    $settings.hooks.PreToolUse | ForEach-Object {
        if ($_.PSObject.Properties.Name -contains "hooks") {
            $_.hooks | Where-Object { [string]$_.command -eq $hookCmd }
        }
    }
) | Where-Object { $null -ne $_ }

if ($alreadyIn.Count -eq 0) {
    $entry = [pscustomobject]@{
        matcher = ""
        hooks   = @([pscustomobject]@{ type = "command"; command = $hookCmd })
    }
    # Rebuild as plain array (PS object coercion workaround)
    $existing = @($settings.hooks.PreToolUse)
    $settings.hooks | Add-Member -Force -NotePropertyName "PreToolUse" -NotePropertyValue ($existing + $entry)
    $settings | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 $settingsPath
    Write-Host "  [OK] .claude/settings.json (hook registered)"
} elseif ($migrated) {
    $settings | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 $settingsPath
    Write-Host "  [OK] .claude/settings.json (hook path migrated to forward slash)"
} else {
    Write-Host "  [SKIP] Hook already in .claude/settings.json"
}

# ── Done ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "  Set Trace ID before starting work:"
Write-Host "    .\.ai-swarm\trace.ps1 -Set '$(Get-Date -Format yyyyMMdd)-task-name'"
Write-Host ""
Write-Host "  Start Claude:"
Write-Host "    claude"
Write-Host ""
Write-Host "  Profile after work:"
Write-Host "    .\.ai-swarm\profile.ps1"
Write-Host ""
