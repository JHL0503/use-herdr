[CmdletBinding()]
param(
    [string]$Set   = "",
    [switch]$Show,
    [switch]$Clear
)

$SwarmRoot = $PSScriptRoot
$StateDir  = Join-Path $SwarmRoot "state"
$TraceFile = Join-Path $StateDir "current-trace.json"

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

if ($Clear) {
    if (Test-Path $TraceFile) { Remove-Item $TraceFile -Force }
    Write-Host "Trace ID cleared."
    exit 0
}

if (-not [string]::IsNullOrWhiteSpace($Set)) {
    @{ trace_id = $Set; set_at = (Get-Date).ToString("o") } |
        ConvertTo-Json | Set-Content -Encoding UTF8 $TraceFile
    Write-Host "Trace ID set: $Set"
    exit 0
}

# Default: show current
if (Test-Path $TraceFile) {
    try {
        $Obj = Get-Content -Raw $TraceFile | ConvertFrom-Json
        Write-Host "Current trace : $($Obj.trace_id)"
        Write-Host "Set at        : $($Obj.set_at)"
    } catch {
        Write-Host "Could not read trace file."
    }
} else {
    Write-Host "No active trace."
    Write-Host "Usage: .\.ai-swarm\trace.ps1 -Set '$(Get-Date -Format yyyyMMdd)-task-name'"
}
