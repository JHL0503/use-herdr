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

# ── 2. Copy scripts and shared rules (always overwritten) ─────────────────────

$Files = @("delegate.ps1", "profile.ps1", "trace.ps1", "claude-session-hook.ps1", "RULES.md")
foreach ($f in $Files) {
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

# ── 4. CLAUDE.md (import shared rules; project notes are never touched) ──────

$Utf8NoBom   = [System.Text.UTF8Encoding]::new($false)
$rulesImport = "@.ai-swarm/RULES.md"
$claudeMdDst = Join-Path $Target "CLAUDE.md"
if (-not (Test-Path $claudeMdDst)) {
    $stub = "$rulesImport`n`n# Project-specific notes`n<!-- Add rules for this project below. install.ps1 never edits this section. -->`n"
    [System.IO.File]::WriteAllText($claudeMdDst, $stub, $Utf8NoBom)
    Write-Host "  [OK] CLAUDE.md (created, imports $rulesImport)"
} else {
    # Work on raw bytes so existing content keeps its exact encoding (the prefix is plain ASCII).
    $mdBytes = [System.IO.File]::ReadAllBytes($claudeMdDst)
    $isUtf16 = $mdBytes.Length -ge 2 -and (($mdBytes[0] -eq 0xFF -and $mdBytes[1] -eq 0xFE) -or ($mdBytes[0] -eq 0xFE -and $mdBytes[1] -eq 0xFF))
    $bomLen = if ($mdBytes.Length -ge 3 -and $mdBytes[0] -eq 0xEF -and $mdBytes[1] -eq 0xBB -and $mdBytes[2] -eq 0xBF) { 3 } else { 0 }
    $existingMd = [System.Text.Encoding]::UTF8.GetString($mdBytes, $bomLen, $mdBytes.Length - $bomLen)
    if ($existingMd -match "(?m)^\s*$([regex]::Escape($rulesImport))\s*$") {
        Write-Host "  [SKIP] CLAUDE.md (already imports $rulesImport)"
    } elseif ($isUtf16) {
        Write-Warning "  [SKIP] CLAUDE.md is UTF-16; add '$rulesImport' as its first line manually"
    } else {
        $nl = if ($existingMd.Contains("`r`n")) { "`r`n" } else { "`n" }
        $prefix = [System.Text.Encoding]::ASCII.GetBytes("$rulesImport$nl$nl")
        $out = New-Object byte[] ($mdBytes.Length + $prefix.Length)
        [Array]::Copy($mdBytes, 0, $out, 0, $bomLen)
        [Array]::Copy($prefix, 0, $out, $bomLen, $prefix.Length)
        [Array]::Copy($mdBytes, $bomLen, $out, $bomLen + $prefix.Length, $mdBytes.Length - $bomLen)
        # Write to a temp file first so a failed write never truncates the original.
        $tmpMd = "$claudeMdDst.ai-swarm-tmp"
        [System.IO.File]::WriteAllBytes($tmpMd, $out)
        # NullString: PS 5.1 would pass $null to a string parameter as "".
        [System.IO.File]::Replace($tmpMd, $claudeMdDst, [System.Management.Automation.Language.NullString]::Value)
        Write-Host "  [OK] CLAUDE.md (added $rulesImport at top)"
        Write-Host "       If this CLAUDE.md holds an old full copy of the rules, delete it to avoid duplicates." -ForegroundColor Yellow
    }
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

# ── 6. .gitignore — keep runtime output (worker I/O, logs) out of git ────────

$gitignorePath = Join-Path $Target ".gitignore"
$ignoreLines = @(
    ".ai-swarm/logs/",
    ".ai-swarm/state/",
    ".ai-swarm/tmp/",
    ".ai-swarm/reports/",
    ".ai-swarm/sessions/",
    ".ai-swarm/current-session.txt"
)
$existingIgnore = ""
if (Test-Path $gitignorePath) { $existingIgnore = [System.IO.File]::ReadAllText($gitignorePath) }
$present = @($existingIgnore -split "\r?\n" | ForEach-Object { $_.Trim() })
$missing = @($ignoreLines | Where-Object { $present -notcontains $_ })

if ($missing.Count -gt 0) {
    $nl = if ($existingIgnore.Contains("`r`n")) { "`r`n" } else { "`n" }
    $block = ""
    if ($existingIgnore.Length -gt 0 -and -not $existingIgnore.EndsWith("`n")) { $block += $nl }
    if ($existingIgnore.Length -gt 0) { $block += $nl }
    $block += "# ai-swarm runtime$nl" + (($missing | ForEach-Object { "$_$nl" }) -join "")
    [System.IO.File]::AppendAllText($gitignorePath, $block, $Utf8NoBom)
    Write-Host "  [OK] .gitignore ($($missing.Count) ai-swarm entries added)"
} else {
    Write-Host "  [SKIP] .gitignore (ai-swarm entries already present)"
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
