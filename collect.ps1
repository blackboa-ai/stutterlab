#Requires -Version 5.1
<#
.SYNOPSIS
    StutterLab — read-only Windows stutter cause finder.

.DESCRIPTION
    Collects hardware/configuration facts, runs a timed contention monitor,
    correlates Windows event logs, applies a rules engine, and writes a
    self-contained HTML report.

    Makes no changes to the system. Writes only to runs\<timestamp>\.

.PARAMETER Duration
    Monitor window in seconds. Default 60.

.PARAMETER NoMonitor
    Skip the timed sampling session. Static facts and events only (~5s).

.PARAMETER Open
    Open the report in the default browser when finished.

.PARAMETER OutDir
    Override the output directory. Default: runs\<timestamp> under the tool root.

.EXAMPLE
    .\collect.ps1
    .\collect.ps1 -Duration 180 -Open
    .\collect.ps1 -NoMonitor
#>
[CmdletBinding()]
param(
    [ValidateRange(5, 3600)]
    [int]$Duration = 60,

    [switch]$NoMonitor,

    [switch]$Open,

    [string]$OutDir
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ToolRoot = $PSScriptRoot
$script:StartedAt = Get-Date

# ---------------------------------------------------------------- bootstrap ---

foreach ($m in 'Common', 'StaticFacts', 'Monitor', 'Events', 'Rules', 'Render') {
    $path = Join-Path $ToolRoot "modules\$m.ps1"
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "Missing module: $path" -ForegroundColor Red
        exit 1
    }
    . $path
}

if (-not $OutDir) {
    $OutDir = Join-Path $ToolRoot ('runs\' + $StartedAt.ToString('yyyy-MM-dd_HHmmss'))
}
$OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

Initialize-Log -Path (Join-Path $OutDir 'collect.log')
Write-Log "StutterLab started" -Level Info
Write-Log "PowerShell $($PSVersionTable.PSVersion) / $([Environment]::OSVersion.VersionString)" -Level Info

$isAdmin = Test-Admin
if ($isAdmin) { Write-Log 'Elevated: True' -Level Info }
else { Write-Log 'Elevated: False (standard user; the inventory below reads without it)' -Level Info }

# ------------------------------------------------------------------ collect ---

$run = [ordered]@{
    tool      = [ordered]@{
        name       = 'StutterLab'
        version    = '0.1.0'
        startedAt  = $StartedAt.ToString('o')
        duration   = $Duration
        monitor    = (-not $NoMonitor)
        elevated   = $isAdmin
        powershell = $PSVersionTable.PSVersion.ToString()
        os         = [Environment]::OSVersion.VersionString
        machine    = $env:COMPUTERNAME
        user       = $env:USERNAME
    }
    facts     = $null
    monitor   = $null
    events    = $null
    findings  = $null
    errors    = @()
}

Write-Host ''
Write-Host '  StutterLab 0.1.0' -ForegroundColor Cyan
Write-Host "  $($env:COMPUTERNAME) · $([Environment]::OSVersion.VersionString) · elevated=$isAdmin" -ForegroundColor DarkGray
Write-Host ''

# 1. Static facts -------------------------------------------------------------
Write-Host '  [1/4] Inventorying hardware and configuration...' -ForegroundColor Gray -NoNewline
try {
    $run.facts = Get-StaticFacts
    $st = $run.facts.status
    $total = @($st.Keys).Count
    $bad = @($st.Keys | Where-Object { -not $st[$_].ok }).Count
    Write-Host "`r  [1/4] Hardware and configuration          $($total - $bad)/$total ok" -ForegroundColor Gray
} catch {
    $run.errors += "StaticFacts: $($_.Exception.Message)"
    Write-Log "StaticFacts failed: $($_.Exception.Message)" -Level Error
    Write-Host "`r  [1/4] Hardware and configuration          FAILED" -ForegroundColor Red
}

# 2. Monitor session ----------------------------------------------------------
if (-not $NoMonitor) {
    Write-Host ''
    try {
        $run.monitor = Invoke-MonitorSession -Duration $Duration
        $s = $run.monitor.summary
        Write-Host "  [2/4] Sampled $($s.sampleCount) points over $([math]::Round($s.actualSeconds,1))s          ok" -ForegroundColor Gray
    } catch {
        $run.errors += "Monitor: $($_.Exception.Message)"
        Write-Log "Monitor failed: $($_.Exception.Message)" -Level Error
        Write-Host "  [2/4] Sampling session                   FAILED" -ForegroundColor Red
    }
} else {
    Write-Host '  [2/4] Sampling session                   skipped (-NoMonitor)' -ForegroundColor DarkGray
}

# 3. Events -------------------------------------------------------------------
Write-Host '  [3/4] Correlating event logs...' -ForegroundColor Gray -NoNewline
try {
    $run.events = Get-EventCorrelation -Days 7
    $n = $run.events.totalCount
    Write-Host "`r  [3/4] Event correlation                 $n events          " -ForegroundColor Gray
} catch {
    $run.errors += "Events: $($_.Exception.Message)"
    Write-Log "Events failed: $($_.Exception.Message)" -Level Error
    Write-Host "`r  [3/4] Event correlation                 FAILED" -ForegroundColor Red
}

# 4. Rules + render -----------------------------------------------------------
Write-Host '  [4/4] Evaluating findings...' -ForegroundColor Gray -NoNewline
try {
    $run.findings = Invoke-RulesEngine -Run $run
    $c = @($run.findings.counts.Keys | Where-Object { $run.findings.counts[$_] -gt 0 } |
            ForEach-Object { "$($run.findings.counts[$_]) $_" }) -join ', '
    if (-not $c) { $c = 'none' }
    Write-Host "`r  [4/4] Findings                          $c          " -ForegroundColor Gray
} catch {
    $run.errors += "Rules: $($_.Exception.Message)"
    Write-Log "Rules failed: $($_.Exception.Message)" -Level Error
    Write-Host "`r  [4/4] Findings                          FAILED" -ForegroundColor Red
}

$run.tool.finishedAt = (Get-Date).ToString('o')
$run.tool.elapsedSeconds = [math]::Round(((Get-Date) - $StartedAt).TotalSeconds, 2)

# ------------------------------------------------------------------- output ---

$jsonPath = Join-Path $OutDir 'data.json'
try {
    $run | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    Write-Log "Wrote $jsonPath" -Level Info
} catch {
    Write-Log "JSON write failed: $($_.Exception.Message)" -Level Error
}

$htmlPath = Join-Path $OutDir 'report.html'
try {
    $html = Render-Dashboard -Run $run
    Set-Content -LiteralPath $htmlPath -Value $html -Encoding UTF8
    Write-Log "Wrote $htmlPath" -Level Info
} catch {
    Write-Log "Render failed: $($_.Exception.Message)" -Level Error
    Write-Host "  Render failed: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ''
Write-Host "  Report: $htmlPath" -ForegroundColor Green
Write-Host "  Data:   $jsonPath" -ForegroundColor DarkGray
if ($run.errors.Count) {
    Write-Host "  Errors: $($run.errors.Count) (see collect.log)" -ForegroundColor Yellow
}
Write-Host ''

if ($Open -and (Test-Path -LiteralPath $htmlPath)) {
    Start-Process $htmlPath | Out-Null
}

if ($run.errors.Count -gt 0 -and -not (Test-Path -LiteralPath $htmlPath)) {
    exit 1
}
