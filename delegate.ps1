[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("codex","grok")]
    [string]$Agent,

    [Parameter(Mandatory=$true)]
    [string]$Prompt,

    [string]$Role        = "general",
    [string]$TaskName    = "",
    [ValidateSet("read","write")]
    [string]$Mode        = "read",
    [ValidateSet("fresh","sticky")]
    [string]$SessionMode = "fresh",
    [string]$WorkerKey   = "",
    [string]$WorkDir     = "",
    [switch]$NoFallback
)

$ErrorActionPreference = "Stop"

# ── Paths ─────────────────────────────────────────────────────────────────────

$SwarmRoot   = $PSScriptRoot
$ProjectRoot = Split-Path $SwarmRoot -Parent
if ([string]::IsNullOrWhiteSpace($WorkDir)) { $WorkDir = $ProjectRoot }
$StateDir    = Join-Path $SwarmRoot "state"
$LogsDir     = Join-Path $SwarmRoot "logs"
$TmpDir      = Join-Path $SwarmRoot "tmp"

New-Item -ItemType Directory -Force -Path $StateDir,$LogsDir,$TmpDir | Out-Null

$ConfigFile        = Join-Path $SwarmRoot "config.json"
$CurrentClaudeFile = Join-Path $StateDir "current-claude.json"
$TraceFile         = Join-Path $StateDir "current-trace.json"
$StickyFile        = Join-Path $StateDir "sticky-workers.json"
$EventsFile        = Join-Path $LogsDir "events.jsonl"

$CallId = [guid]::NewGuid().ToString()
$RawOut = Join-Path $TmpDir "$CallId.stdout.txt"
$RawErr = Join-Path $TmpDir "$CallId.stderr.txt"

# ── Helpers ───────────────────────────────────────────────────────────────────

function Get-JsonFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content -Raw $Path | ConvertFrom-Json) }
    catch { return $null }
}

function Write-JsonFile([string]$Path,$Value) {
    $Value | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 $Path
}

function Get-PropertyRecursive($Obj,[string[]]$Names) {
    foreach ($n in $Names) {
        if ($null -ne $Obj -and $Obj.PSObject.Properties.Name -contains $n) {
            $v=$Obj.$n
            if ($null -ne $v) { return $v }
        }
    }
    return $null
}

function Append-OneEventFile([string]$Path,[string]$Line) {
    $Utf8=New-Object System.Text.UTF8Encoding($false)
    for ($i=0;$i -lt 50;$i++) {
        $Fs=$null;$Sw=$null
        try {
            $Fs=New-Object System.IO.FileStream(
                $Path,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::Read
            )
            $null=$Fs.Seek(0,[System.IO.SeekOrigin]::End)
            $Sw=New-Object System.IO.StreamWriter($Fs,$Utf8)
            $Sw.WriteLine($Line)
            $Sw.Flush()
            return
        } catch {
            Start-Sleep -Milliseconds 50
        } finally {
            if ($null -ne $Sw)  { $Sw.Dispose() }
            elseif ($null -ne $Fs) { $Fs.Dispose() }
        }
    }
}

function Append-Event($Value) {
    $Line=$Value | ConvertTo-Json -Compress -Depth 30
    Append-OneEventFile $EventsFile $Line

    # V2 backward compatibility
    $OldCurrent=Join-Path $SwarmRoot "current-session.txt"
    if (Test-Path $OldCurrent) {
        $OldId=(Get-Content -Raw $OldCurrent).Trim()
        if (-not [string]::IsNullOrWhiteSpace($OldId)) {
            $LegacyDir=Join-Path (Join-Path $SwarmRoot "sessions") $OldId
            New-Item -ItemType Directory -Force -Path $LegacyDir | Out-Null
            Append-OneEventFile (Join-Path $LegacyDir "events.jsonl") $Line
        }
    }
}

function Get-StickyRecord([string]$Key) {
    $s=Get-JsonFile $StickyFile
    if ($null -eq $s) { return $null }
    if ($s.PSObject.Properties.Name -contains $Key) { return $s.$Key }
    return $null
}

function Save-StickyRecord([string]$Key,[string]$Worker,[string]$SessionId) {
    $s=Get-JsonFile $StickyFile
    if ($null -eq $s) { $s=[pscustomobject]@{} }
    $s | Add-Member -Force -NotePropertyName $Key -NotePropertyValue ([pscustomobject]@{
        worker=$Worker
        session_id=$SessionId
        updated_at=(Get-Date).ToString("o")
    })
    Write-JsonFile $StickyFile $s
}

# ── Resolve context ───────────────────────────────────────────────────────────

$HerdrSession=$null
$Config=Get-JsonFile $ConfigFile
if ($null -ne $Config -and $Config.PSObject.Properties.Name -contains "herdr_session") {
    $HerdrSession=[string]$Config.herdr_session
}
if ([string]::IsNullOrWhiteSpace($HerdrSession)) {
    $HerdrSession=(Split-Path $ProjectRoot -Leaf).ToLowerInvariant() -replace '[_ ]','-'
}

$TraceId=$null
$TraceObj=Get-JsonFile $TraceFile
if ($null -ne $TraceObj -and $TraceObj.PSObject.Properties.Name -contains "trace_id") {
    $TraceId=[string]$TraceObj.trace_id
}
if ([string]::IsNullOrWhiteSpace($TraceId)) {
    $OldCurrent=Join-Path $SwarmRoot "current-session.txt"
    if (Test-Path $OldCurrent) { $TraceId=(Get-Content -Raw $OldCurrent).Trim() }
}

$ParentClaudeSession=$null
$ClaudeState=Get-JsonFile $CurrentClaudeFile
if ($null -ne $ClaudeState -and $ClaudeState.PSObject.Properties.Name -contains "session_id") {
    $ParentClaudeSession=[string]$ClaudeState.session_id
}

# ── Sticky session lookup ─────────────────────────────────────────────────────

if ([string]::IsNullOrWhiteSpace($WorkerKey)) { $WorkerKey="$Agent-$Role" }
$ExistingWorkerSession=$null
if ($SessionMode -eq "sticky") {
    $rec=Get-StickyRecord $WorkerKey
    if ($null -ne $rec -and $rec.PSObject.Properties.Name -contains "session_id") {
        $ExistingWorkerSession=[string]$rec.session_id
    }
}

# ── Prompt hash ───────────────────────────────────────────────────────────────

$Sha256=[System.Security.Cryptography.SHA256]::Create()
$PromptHash=([System.BitConverter]::ToString(
    $Sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Prompt))
)) -replace '-',''
$WorkerPrompt=$Prompt

# ── Log delegation_started ────────────────────────────────────────────────────

Append-Event ([ordered]@{
    ts=(Get-Date).ToString("o")
    event="delegation_started"
    herdr_session=$HerdrSession
    trace_id=$TraceId
    parent_claude_session_id=$ParentClaudeSession
    call_id=$CallId
    worker=$Agent
    role=$Role
    task_name=$TaskName
    mode=$Mode
    worker_session_mode=$SessionMode
    worker_key=$WorkerKey
    work_dir=$WorkDir
})

$ExitCode=999
$WorkerSessionId=$ExistingWorkerSession
$InputTokens=0
$CachedInputTokens=0
$OutputTokens=0
$ReasoningTokens=0
$TotalTokens=0
$TokenQuality="not-reported"
$ResultText=""
$Timer=[System.Diagnostics.Stopwatch]::StartNew()

Push-Location $WorkDir
# Windows PowerShell 5.1 turns any stderr line of a native command redirected with 2> into a
# terminating error under "Stop" (e.g. codex prints "Reading additional input from stdin...").
# Native exit codes are checked explicitly below, so relax it for the worker calls only.
$PrevErrorAction=$ErrorActionPreference
$ErrorActionPreference="Continue"
try {
    if ($Agent -eq "codex") {
        $Sandbox = if ($Mode -eq "write") { "workspace-write" } else { "read-only" }

        # Prompt goes through stdin ("-"): PS 5.1 does not escape embedded double quotes in native
        # arguments, so a prompt containing " gets split into extra args. Pipe as UTF-8 (5.1 default is ASCII).
        $PrevOutputEncoding=$OutputEncoding
        $OutputEncoding=[System.Text.UTF8Encoding]::new($false)
        try {
            if ($SessionMode -eq "sticky" -and -not [string]::IsNullOrWhiteSpace($ExistingWorkerSession)) {
                $Lines=$WorkerPrompt | & codex exec --json --skip-git-repo-check --sandbox $Sandbox resume $ExistingWorkerSession - 2> $RawErr
            } else {
                $Lines=$WorkerPrompt | & codex exec --json --skip-git-repo-check --sandbox $Sandbox - 2> $RawErr
            }
        } finally {
            $OutputEncoding=$PrevOutputEncoding
        }

        $ExitCode=$LASTEXITCODE
        @($Lines) | Set-Content -Encoding UTF8 $RawOut

        foreach ($Line in @($Lines)) {
            if ([string]::IsNullOrWhiteSpace([string]$Line)) { continue }
            try { $Obj=([string]$Line) | ConvertFrom-Json } catch { continue }

            if ($Obj.type -eq "thread.started" -and $Obj.thread_id) {
                $WorkerSessionId=[string]$Obj.thread_id
            }
            if ($Obj.type -eq "turn.completed" -and $Obj.usage) {
                if ($null -ne $Obj.usage.input_tokens) { $InputTokens += [int64]$Obj.usage.input_tokens }
                if ($null -ne $Obj.usage.cached_input_tokens) { $CachedInputTokens += [int64]$Obj.usage.cached_input_tokens }
                if ($null -ne $Obj.usage.output_tokens) { $OutputTokens += [int64]$Obj.usage.output_tokens }
                if ($null -ne $Obj.usage.reasoning_output_tokens) { $ReasoningTokens += [int64]$Obj.usage.reasoning_output_tokens }
                $TokenQuality="exact-reported"
            }
            if ($Obj.type -eq "item.completed" -and $Obj.item -and $Obj.item.type -eq "agent_message") {
                $ResultText=[string]$Obj.item.text
            }
        }
        $TotalTokens=$InputTokens+$OutputTokens
    }

    if ($Agent -eq "grok") {
        $Args=@("--no-auto-update")

        if ($SessionMode -eq "sticky") {
            if ([string]::IsNullOrWhiteSpace($ExistingWorkerSession)) {
                $WorkerSessionId=[guid]::NewGuid().ToString()
                $Args += @("--session-id",$WorkerSessionId)
            } else {
                $WorkerSessionId=$ExistingWorkerSession
                $Args += @("--resume",$WorkerSessionId)
            }
        } else {
            $WorkerSessionId=[guid]::NewGuid().ToString()
            $Args += @("--session-id",$WorkerSessionId)
        }

        # Prompt goes through a file, not -p: PS 5.1 does not escape embedded double quotes in native
        # arguments, so a prompt containing " gets split into extra args. Write UTF-8 without BOM.
        $PromptFile = Join-Path $TmpDir "$CallId.prompt.txt"
        [System.IO.File]::WriteAllText($PromptFile, $WorkerPrompt, [System.Text.UTF8Encoding]::new($false))
        $Args += @("--prompt-file",$PromptFile,"--output-format","json","--cwd",$WorkDir)
        if ($Mode -eq "write") { $Args += "--always-approve" }

        $Output=& grok @Args 2> $RawErr
        $ExitCode=$LASTEXITCODE
        @($Output) | Set-Content -Encoding UTF8 $RawOut
        $Joined=@($Output) -join "`n"

        try {
            $Obj=$Joined | ConvertFrom-Json
            $Usage=Get-PropertyRecursive $Obj @("usage")
            if ($null -ne $Usage) {
                $v=Get-PropertyRecursive $Usage @("input_tokens","prompt_tokens")
                if ($null -ne $v) { $InputTokens=[int64]$v }
                $v=Get-PropertyRecursive $Usage @("cached_tokens","cache_read_input_tokens")
                if ($null -ne $v) { $CachedInputTokens=[int64]$v }
                $v=Get-PropertyRecursive $Usage @("output_tokens","completion_tokens")
                if ($null -ne $v) { $OutputTokens=[int64]$v }
                $v=Get-PropertyRecursive $Usage @("reasoning_tokens")
                if ($null -ne $v) { $ReasoningTokens=[int64]$v }
                $v=Get-PropertyRecursive $Usage @("total_tokens")
                if ($null -ne $v) { $TotalTokens=[int64]$v } else { $TotalTokens=$InputTokens+$OutputTokens }
                if (($InputTokens+$OutputTokens+$TotalTokens) -gt 0) { $TokenQuality="reported-by-cli" }
            }
            $Candidate=Get-PropertyRecursive $Obj @("result","output_text","text","message")
            if ($Candidate -is [string]) { $ResultText=[string]$Candidate } else { $ResultText=$Joined }
        } catch {
            $ResultText=$Joined
        }
    }
}
finally {
    $ErrorActionPreference=$PrevErrorAction
    Pop-Location
    $Timer.Stop()
}

if ($SessionMode -eq "sticky" -and $ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($WorkerSessionId)) {
    Save-StickyRecord $WorkerKey $Agent $WorkerSessionId
}

$StdErrText=""
if (Test-Path $RawErr) { $StdErrText=Get-Content -Raw $RawErr -ErrorAction SilentlyContinue }
$StdOutText=""
if (Test-Path $RawOut) { $StdOutText=Get-Content -Raw $RawOut -ErrorAction SilentlyContinue }

$Combined="$StdErrText`n$StdOutText"
$LimitPattern='(?i)(quota|rate.?limit|usage.?limit|limit.?reached|too many requests|429|exhausted|weekly.?limit|insufficient.?quota|capacity)'
$QuotaFailure=($ExitCode -ne 0 -and $Combined -match $LimitPattern)

$Status = if ($ExitCode -eq 0) { "success" } elseif ($QuotaFailure) { "quota_or_rate_limit" } else { "error" }

Append-Event ([ordered]@{
    ts=(Get-Date).ToString("o")
    event="delegation_completed"
    herdr_session=$HerdrSession
    trace_id=$TraceId
    parent_claude_session_id=$ParentClaudeSession
    call_id=$CallId
    worker=$Agent
    role=$Role
    task_name=$TaskName
    mode=$Mode
    worker_session_mode=$SessionMode
    worker_key=$WorkerKey
    worker_session_id=$WorkerSessionId
    status=$Status
    exit_code=$ExitCode
    duration_ms=[int64]$Timer.ElapsedMilliseconds
    input_tokens=$InputTokens
    cached_input_tokens=$CachedInputTokens
    output_tokens=$OutputTokens
    reasoning_tokens=$ReasoningTokens
    total_tokens=$TotalTokens
    token_quality=$TokenQuality
    prompt_sha256=$PromptHash
    prompt_chars=$Prompt.Length
    result_chars=$ResultText.Length
    raw_stdout=$RawOut
    raw_stderr=$RawErr
})

if ($Agent -eq "codex" -and $QuotaFailure -and -not $NoFallback) {
    Append-Event ([ordered]@{
        ts=(Get-Date).ToString("o")
        event="fallback_to_brain"
        herdr_session=$HerdrSession
        trace_id=$TraceId
        parent_claude_session_id=$ParentClaudeSession
        call_id=$CallId
        from_worker="codex"
        to="claude-brain"
        reason="codex_quota_or_rate_limit"
        task_name=$TaskName
        role=$Role
    })

    Write-Output "AI_SWARM_FALLBACK_TO_BRAIN"
    Write-Output "Codex quota/rate-limit failure detected. Do NOT retry Codex. Claude Brain must perform this task itself."
    exit 20
}

if ($Status -ne "success") {
    Write-Output "AI_SWARM_WORKER_ERROR agent=$Agent status=$Status exit=$ExitCode"
    if (-not [string]::IsNullOrWhiteSpace($StdErrText)) { Write-Output $StdErrText }
    exit $ExitCode
}

Write-Output $ResultText
exit 0
