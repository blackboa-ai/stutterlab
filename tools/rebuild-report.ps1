<#
.SYNOPSIS
    Regenerates report.html from an existing data.json, without collecting again.

.DESCRIPTION
    Rules and rendering are pure functions over the captured run data, so a
    report can be rebuilt after either one changes. This never reads the
    machine: it only reads data.json and writes report.html beside it.

    Rehydration matters here. ConvertFrom-Json returns PSCustomObject, but the
    rule engine indexes its inputs as hashtables ($byRule[$key], $status[$k]).
    Feeding PSCustomObject in throws "Index operation failed; the array index
    evaluated to null." Converting the whole tree back to hashtables and arrays
    makes the rebuilt report follow the exact same code path as a fresh one.

.PARAMETER RunDir
    A run directory containing data.json. Defaults to the newest run.

.EXAMPLE
    .\tools\rebuild-report.ps1
    .\tools\rebuild-report.ps1 -RunDir .\runs\2026-11-14_045455
#>
[CmdletBinding()]
param(
    [string]$RunDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'modules\Common.ps1')
. (Join-Path $root 'modules\Rules.ps1')
. (Join-Path $root 'modules\Render.ps1')

function ConvertTo-HashtableDeep {
    param($Value)
    if ($null -eq $Value) { return $null }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Value.PSObject.Properties) {
            $h[$p.Name] = ConvertTo-HashtableDeep $p.Value
        }
        return $h
    }

    # A string is enumerable too, so exclude it before treating as a list.
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $Value) { [void]$list.Add((ConvertTo-HashtableDeep $item)) }
        return $list.ToArray()
    }

    return $Value
}

if (-not $RunDir) {
    $runsDir = Join-Path $root 'runs'
    if (-not (Test-Path $runsDir)) { throw "No runs directory at $runsDir" }
    $newest = Get-ChildItem $runsDir -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $newest) { throw 'No run directories found.' }
    $RunDir = $newest.FullName
}

if (-not (Test-Path $RunDir)) { throw "Run directory not found: $RunDir" }

$dataPath = Join-Path $RunDir 'data.json'
if (-not (Test-Path $dataPath)) { throw "No data.json in $RunDir" }

$raw = Get-Content $dataPath -Raw
$run = ConvertTo-HashtableDeep ($raw | ConvertFrom-Json)

$findings = Invoke-RulesEngine -Run $run
$run['findings'] = $findings

$html = Render-Dashboard -Run $run

$outPath = Join-Path $RunDir 'report.html'
[System.IO.File]::WriteAllText($outPath, $html, (New-Object System.Text.UTF8Encoding($false)))

$count = @($findings['findings']).Count
Write-Host ("Rebuilt {0}" -f $outPath) -ForegroundColor Green
Write-Host ("  findings : {0} ({1})" -f $count, (Get-Prop $findings 'headline'))
Write-Host ("  coverage : {0} note(s)" -f @($findings['coverage']).Count)
Write-Host ("  size     : {0:N0} bytes" -f $html.Length)
