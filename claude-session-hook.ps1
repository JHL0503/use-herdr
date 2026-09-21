$ErrorActionPreference = "SilentlyContinue"

# Claude Code hooks send one JSON object through stdin.
$InputText = [Console]::In.ReadToEnd()

if ([string]::IsNullOrWhiteSpace($InputText)) {
    exit 0
}

try {
    $Data = $InputText | ConvertFrom-Json
}
catch {
    exit 0
}

$SwarmRoot  = $PSScriptRoot
$ProjectRoot = Split-Path $SwarmRoot -Parent
$StateDir    = Join-Path $SwarmRoot "state"
$LogsDir     = Join-Path $SwarmRoot "logs"

New-Item -ItemType Directory -Force -Path $StateDir,$LogsDir | Out-Null

$CurrentClaudeFile = Join-Path $StateDir "current-claude.json"
$EventsFile        = Join-Path $LogsDir "events.jsonl"
$TraceFile         = Join-Path $StateDir "current-trace.json"
$ConfigFile        = Join-Path $SwarmRoot "config.json"

function Get-JsonFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content -Raw $Path | ConvertFrom-Json) }
    catch { return $null }
}

function Write-JsonFile([string]$Path, $Value) {
    $Value | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 $Path
}

function Append-OneEventFile([string]$Path,[string]$Line) {
    $Utf8 = New-Object System.Text.UTF8Encoding($false)

    for ($i=0; $i -lt 50; $i++) {
        $Fs=$null
        $Sw=$null

        try {
            $Fs = New-Object System.IO.FileStream(
                $Path,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::Read
            )

            $null = $Fs.Seek(0,[System.IO.SeekOrigin]::End)

            $Sw = New-Object System.IO.StreamWriter($Fs,$Utf8)
            $Sw.WriteLine($Line)
            $Sw.Flush()
            return
        }
        catch {
            Start-Sleep -Milliseconds 50
        }
        finally {
            if ($null -ne $Sw) {
                $Sw.Dispose()
            }
            elseif ($null -ne $Fs) {
                $Fs.Dispose()
            }
        }
    }
}

function Append-Event($Value) {
    $Line = $Value | ConvertTo-Json -Compress -Depth 30
    Append-OneEventFile $EventsFile $Line

    # Backward compatibility with the earlier V2 package.
    $OldCurrent = Join-Path $SwarmRoot "current-session.txt"

    if (Test-Path $OldCurrent) {
        $OldId = (Get-Content -Raw $OldCurrent).Trim()

        if (-not [string]::IsNullOrWhiteSpace($OldId)) {
            $LegacyDir = Join-Path (Join-Path $SwarmRoot "sessions") $OldId
            New-Item -ItemType Directory -Force -Path $LegacyDir | Out-Null
            $LegacyEventsFile = Join-Path $LegacyDir "events.jsonl"
            Append-OneEventFile $LegacyEventsFile $Line
        }
    }
}

# ------------------------------------------------------------
# Resolve Herdr session name
# ------------------------------------------------------------

$HerdrSession = $null
$Config = Get-JsonFile $ConfigFile

if ($null -ne $Config -and $Config.PSObject.Properties.Name -contains "herdr_session") {
    $HerdrSession = [string]$Config.herdr_session
}

if ([string]::IsNullOrWhiteSpace($HerdrSession)) {
    $HerdrSession = (Split-Path $ProjectRoot -Leaf).ToLowerInvariant().Replace("_","-").Replace(" ","-")
}

# ------------------------------------------------------------
# Resolve current Trace ID
# ------------------------------------------------------------

$TraceId = $null
$TraceObj = Get-JsonFile $TraceFile

if ($null -ne $TraceObj -and $TraceObj.PSObject.Properties.Name -contains "trace_id") {
    $TraceId = [string]$TraceObj.trace_id
}

# Compatibility with earlier V2.
if ([string]::IsNullOrWhiteSpace($TraceId)) {
    $OldCurrent = Join-Path $SwarmRoot "current-session.txt"

    if (Test-Path $OldCurrent) {
        $TraceId = (Get-Content -Raw $OldCurrent).Trim()
    }
}

# ------------------------------------------------------------
# Extract and persist Claude session ID
# ------------------------------------------------------------

$SessionId = $null
if ($null -ne $Data -and $Data.PSObject.Properties.Name -contains "session_id") {
    $SessionId = [string]$Data.session_id
}

if ([string]::IsNullOrWhiteSpace($SessionId)) { exit 0 }

$CurrentState = Get-JsonFile $CurrentClaudeFile
if ($null -eq $CurrentState) { $CurrentState = [pscustomobject]@{} }
$CurrentState | Add-Member -Force -NotePropertyName "session_id" -NotePropertyValue $SessionId
$CurrentState | Add-Member -Force -NotePropertyName "updated_at" -NotePropertyValue (Get-Date).ToString("o")
Write-JsonFile $CurrentClaudeFile $CurrentState

Append-Event ([ordered]@{
    ts            = (Get-Date).ToString("o")
    event         = "claude_session_active"
    herdr_session = $HerdrSession
    trace_id      = $TraceId
    session_id    = $SessionId
})

exit 0
