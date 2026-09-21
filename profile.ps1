[CmdletBinding()]
param(
    [string]$ProjectRoot     = "",
    [string]$TraceId         = "",
    [string]$ClaudeSessionId = "",
    [switch]$All
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
}

$SwarmRoot   = Join-Path $ProjectRoot ".ai-swarm"
$LogsDir     = Join-Path $SwarmRoot "logs"
$ReportsRoot = Join-Path $SwarmRoot "reports"
$EventsFile  = Join-Path $LogsDir "events.jsonl"

New-Item -ItemType Directory -Force -Path $ReportsRoot | Out-Null

function N($v) { if ($null -eq $v) { return 0 } else { return [int64]$v } }

if (-not (Test-Path $EventsFile)) {
    Write-Host "No events log found at: $EventsFile" -ForegroundColor Yellow
    exit 0
}

$ShowAllTraces = $All.IsPresent -or [string]::IsNullOrWhiteSpace($TraceId)

$AllEvents = @(
    Get-Content $EventsFile -Encoding UTF8 -ErrorAction SilentlyContinue |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { $null }
    } |
    Where-Object { $null -ne $_ }
)

$Delegations = @(
    $AllEvents | Where-Object event -eq "delegation_completed"
)

if (-not $ShowAllTraces) {
    $Delegations = @($Delegations | Where-Object trace_id -eq $TraceId)
}

if (-not [string]::IsNullOrWhiteSpace($ClaudeSessionId)) {
    $Delegations = @($Delegations | Where-Object parent_claude_session_id -eq $ClaudeSessionId)
}

$Fallbacks = @(
    $AllEvents |
    Where-Object event -eq "fallback_to_brain" |
    Where-Object {
        $ShowAllTraces -or ($_.trace_id -eq $TraceId)
    }
)

# ── Worker stats ──────────────────────────────────────────────────────────────

$WorkerRows = @()
foreach ($wg in @($Delegations | Group-Object worker)) {
    $calls = @($wg.Group)
    $WorkerRows += [pscustomobject]@{
        worker              = $wg.Name
        calls               = $calls.Count
        success             = @($calls | Where-Object status -eq "success").Count
        failures            = @($calls | Where-Object status -ne "success").Count
        fresh               = @($calls | Where-Object worker_session_mode -eq "fresh").Count
        sticky              = @($calls | Where-Object worker_session_mode -eq "sticky").Count
        input_tokens        = ($calls | Measure-Object input_tokens -Sum).Sum
        cached_input_tokens = ($calls | Measure-Object cached_input_tokens -Sum).Sum
        output_tokens       = ($calls | Measure-Object output_tokens -Sum).Sum
        reasoning_tokens    = ($calls | Measure-Object reasoning_tokens -Sum).Sum
        total_tokens        = ($calls | Measure-Object total_tokens -Sum).Sum
        duration_ms         = ($calls | Measure-Object duration_ms -Sum).Sum
    }
}

# ── Role distribution ─────────────────────────────────────────────────────────

$RoleRows = @()
foreach ($rg in @($Delegations | Group-Object role,worker)) {
    $parts = $rg.Name -split ', '
    $RoleRows += [pscustomobject]@{
        role   = $parts[0]
        worker = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        calls  = $rg.Count
    }
}

# ── Claude session breakdown ──────────────────────────────────────────────────

$ClaudeRows = @()
foreach ($cg in @($Delegations | Group-Object parent_claude_session_id)) {
    $calls = @($cg.Group)
    $fb    = @($Fallbacks | Where-Object parent_claude_session_id -eq $cg.Name)
    $ClaudeRows += [pscustomobject]@{
        claude_session_id      = $cg.Name
        worker_calls           = $calls.Count
        codex_calls            = @($calls | Where-Object worker -eq "codex").Count
        grok_calls             = @($calls | Where-Object worker -eq "grok").Count
        reported_worker_tokens = ($calls | Measure-Object total_tokens -Sum).Sum
        fallbacks              = $fb.Count
    }
}

# ── Sticky workers ────────────────────────────────────────────────────────────

$StickyRows = @()
foreach ($sg in @($Delegations | Where-Object worker_session_mode -eq "sticky" | Group-Object worker_key)) {
    $calls    = @($sg.Group)
    $sessions = @(
        $calls |
        Where-Object worker_session_id |
        Select-Object -ExpandProperty worker_session_id -Unique
    )

    $StickyRows += [pscustomobject]@{
        worker_key = $sg.Name
        worker = ($calls | Select-Object -First 1).worker
        calls = $calls.Count
        unique_worker_sessions = $sessions.Count
        worker_session_ids = ($sessions -join ", ")
        reported_tokens = ($calls | Measure-Object total_tokens -Sum).Sum
    }
}

# ------------------------------------------------------------
# Heuristic waste checks
# ------------------------------------------------------------

$Flags = New-Object System.Collections.Generic.List[string]

$DuplicatePrompts = @(
    $Delegations |
    Where-Object prompt_sha256 |
    Group-Object prompt_sha256 |
    Where-Object Count -gt 1
)

foreach ($d in $DuplicatePrompts) {
    $desc = ($d.Group | ForEach-Object { "$($_.worker):$($_.task_name)" }) -join ", "
    $Flags.Add("Identical delegated prompt repeated $($d.Count)x: $desc")
}

$LowValueCodexRoles = @("exploration","research","brainstorm","summary","search","general")
foreach ($c in @($Delegations | Where-Object worker -eq "codex")) {
    $role = ([string]$c.role).ToLowerInvariant()
    if ($LowValueCodexRoles -contains $role) {
        $Flags.Add("Codex used for potentially low-value/high-volume role '$($c.role)': $($c.task_name)")
    }
}

foreach ($c in @($Delegations | Where-Object status -ne "success")) {
    $Flags.Add("Worker failure: $($c.worker) / $($c.task_name) / status=$($c.status)")
}

foreach ($d in $DuplicatePrompts) {
    $quotaFails = @($d.Group | Where-Object status -eq "quota_or_rate_limit").Count
    if ($quotaFails -gt 1) {
        $Flags.Add("Possible waste: same prompt hit quota/rate limit more than once.")
    }
}

foreach ($s in $StickyRows) {
    if ($s.unique_worker_sessions -gt 1) {
        $Flags.Add("Sticky key '$($s.worker_key)' used more than one worker session; continuity may have broken.")
    }
}

# ------------------------------------------------------------
# Build report
# ------------------------------------------------------------

$SafeTrace = if ([string]::IsNullOrWhiteSpace($TraceId)) { "all" } else { ($TraceId -replace '[^\w\-\.]','_') }
$ReportDir = Join-Path $ReportsRoot $SafeTrace
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

$Summary = [ordered]@{
    generated_at = (Get-Date).ToString("o")
    project_root = $ProjectRoot
    trace_id = if ($ShowAllTraces) { "(all)" } else { $TraceId }
    claude_session_filter = $ClaudeSessionId
    delegation_calls = $Delegations.Count
    fallbacks_to_claude_brain = $Fallbacks.Count
    workers = $WorkerRows
    roles = $RoleRows
    claude_sessions = $ClaudeRows
    sticky_workers = $StickyRows
    heuristic_flags = @($Flags)
}

$JsonPath = Join-Path $ReportDir "profile.json"
$MdPath = Join-Path $ReportDir "profile.md"

$Summary | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 $JsonPath

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# AI Swarm Profile")
$md.Add("")
$md.Add("- Project: ``$ProjectRoot``")
$md.Add("- Trace ID: **$(if ($ShowAllTraces) {'ALL'} else {$TraceId})**")
if (-not [string]::IsNullOrWhiteSpace($ClaudeSessionId)) {
    $md.Add("- Claude session filter: ``$ClaudeSessionId``")
}
$md.Add("- Worker delegations: **$($Delegations.Count)**")
$md.Add("- Codex → Claude Brain fallbacks: **$($Fallbacks.Count)**")
$md.Add("")

$md.Add("## Worker usage")
$md.Add("")
$md.Add("| Worker | Calls | Success | Fail | Fresh | Sticky | Input | Cached | Output | Reasoning | Total reported | Time |")
$md.Add("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
foreach ($r in $WorkerRows) {
    $secs = [math]::Round((N $r.duration_ms)/1000.0,1)
    $md.Add("| $($r.worker) | $($r.calls) | $($r.success) | $($r.failures) | $($r.fresh) | $($r.sticky) | $(N $r.input_tokens) | $(N $r.cached_input_tokens) | $(N $r.output_tokens) | $(N $r.reasoning_tokens) | $(N $r.total_tokens) | ${secs}s |")
}
if ($WorkerRows.Count -eq 0) {
    $md.Add("| (none) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0s |")
}
$md.Add("")

$md.Add("## Work distribution")
$md.Add("")
$md.Add("| Role | Worker | Calls |")
$md.Add("|---|---|---:|")
foreach ($r in $RoleRows) {
    $md.Add("| $($r.role) | $($r.worker) | $($r.calls) |")
}
if ($RoleRows.Count -eq 0) {
    $md.Add("| (none) | (none) | 0 |")
}
$md.Add("")

$md.Add("## Claude context sessions")
$md.Add("")
$md.Add("| Parent Claude session | Worker calls | Codex | Grok | Worker reported tokens | Fallbacks |")
$md.Add("|---|---:|---:|---:|---:|---:|")
foreach ($r in $ClaudeRows) {
    $md.Add("| ``$($r.claude_session_id)`` | $($r.worker_calls) | $($r.codex_calls) | $($r.grok_calls) | $(N $r.reported_worker_tokens) | $($r.fallbacks) |")
}
if ($ClaudeRows.Count -eq 0) {
    $md.Add("| (none) | 0 | 0 | 0 | 0 | 0 |")
}
$md.Add("")

$md.Add("## Sticky workers")
$md.Add("")
$md.Add("| Worker key | Worker | Calls | Worker sessions | Reported tokens | Session IDs |")
$md.Add("|---|---|---:|---:|---:|---|")
foreach ($r in $StickyRows) {
    $md.Add("| $($r.worker_key) | $($r.worker) | $($r.calls) | $($r.unique_worker_sessions) | $(N $r.reported_tokens) | ``$($r.worker_session_ids)`` |")
}
if ($StickyRows.Count -eq 0) {
    $md.Add("| (none) | (none) | 0 | 0 | 0 | |")
}
$md.Add("")

$md.Add("## Potential waste / routing flags")
$md.Add("")
if ($Flags.Count -eq 0) {
    $md.Add("- No obvious duplicate/failure/routing waste detected by deterministic checks.")
} else {
    foreach ($f in $Flags) { $md.Add("- $f") }
}
$md.Add("")

$md.Add("## Routing interpretation")
$md.Add("")
$md.Add("- Codex should mainly handle implementation, hard debugging, focused tests, and precise/final review.")
$md.Add("- Grok should mainly handle exploration, research, alternatives, edge cases, and broad second opinions.")
$md.Add("- Fresh worker sessions are the default; sticky sessions should only be used for a continuous chain on the same problem.")
$md.Add("- A Codex quota/rate-limit failure should create one fallback event and should not be retried.")
$md.Add("- Worker token totals only include token usage reported by the worker CLI. Claude Brain's own interactive token usage is intentionally not fabricated here.")

$md | Set-Content -Encoding UTF8 $MdPath

# ------------------------------------------------------------
# Console summary
# ------------------------------------------------------------

Write-Host ""
Write-Host "AI SWARM PROFILE" -ForegroundColor Cyan
Write-Host "Project : $ProjectRoot"
Write-Host "Trace   : $(if ($ShowAllTraces) {'ALL'} else {$TraceId})"
if (-not [string]::IsNullOrWhiteSpace($ClaudeSessionId)) {
    Write-Host "Claude  : $ClaudeSessionId"
}
Write-Host "Calls   : $($Delegations.Count)"
Write-Host "Fallback: $($Fallbacks.Count)"
Write-Host ""

foreach ($r in $WorkerRows) {
    Write-Host ("{0,-8} calls={1,-3} fresh={2,-3} sticky={3,-3} tokens={4,-10} fail={5}" -f `
        $r.worker,$r.calls,$r.fresh,$r.sticky,(N $r.total_tokens),$r.failures)
}

Write-Host ""
Write-Host "Report  : $MdPath" -ForegroundColor Green
Write-Host "JSON    : $JsonPath" -ForegroundColor Green

if ($Flags.Count -gt 0) {
    Write-Host ""
    Write-Host "Flags:" -ForegroundColor Yellow
    foreach ($f in $Flags) {
        Write-Host " - $f"
    }
}
