# Render.ps1 — turns the run into one self-contained HTML file.
#
# Constraints that shaped this:
#   * no CDN, no external fonts, no JS libraries — the report must open offline
#     from the filesystem, possibly on a machine with no network
#   * charts are emitted as inline SVG at render time, because shipping a charting
#     library would violate the first constraint
#   * every number comes from the collected data; nothing is inferred here. All
#     judgement lives in Rules.ps1, so a bug in presentation cannot invent a
#     finding.

$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture

# ---------------------------------------------------------------- helpers -----

function ConvertTo-HtmlText {
    param([AllowNull()]$Text)
    if ($null -eq $Text) { return '' }
    $s = [string]$Text
    $s = $s -replace '&', '&amp;'
    $s = $s -replace '<', '&lt;'
    $s = $s -replace '>', '&gt;'
    $s = $s -replace '"', '&quot;'
    $s = $s -replace "'", '&#39;'
    return $s
}

# Locale-independent number formatting: an SVG coordinate written as "12,5" in a
# comma-decimal locale silently breaks the whole path.
function F {
    param($Value, [string]$Format = '0.##')
    if ($null -eq $Value) { return '0' }
    try {
        return ([double]$Value).ToString($Format, $script:Inv)
    } catch {
        return '0'
    }
}

function SevClass {
    param([string]$Severity)
    switch ($Severity) {
        'critical' { return 'sev-critical' }
        'warn' { return 'sev-warn' }
        'info' { return 'sev-info' }
        default { return 'sev-ok' }
    }
}

function SevLabel {
    param([string]$Severity)
    switch ($Severity) {
        'critical' { return 'CRITICAL' }
        'warn' { return 'WARNING' }
        'info' { return 'NOTE' }
        default { return 'OK' }
    }
}

function Get-Series {
    param($Samples, [string]$Name)
    $out = New-Object System.Collections.ArrayList
    foreach ($s in $Samples) { [void]$out.Add((Get-Prop $s $Name)) }
    return @($out)
}

# ------------------------------------------------------------------- chart ----

<#
    Builds one chart. Series is an array of hashtables so related metrics (DPC
    and interrupt time, for instance) can share an axis and be compared directly.
    preserveAspectRatio=none lets the chart fill the card width; non-scaling-stroke
    keeps the line a constant 1.5px so it does not smear when stretched.
#>
function New-SvgChart {
    param(
        [Parameter(Mandatory)][object[]]$Series,
        [double]$Max = 0,
        [double]$Min = 0,
        [double]$Threshold = -1,
        [string]$Unit = '',
        [int]$Height = 120
    )

    $W = 1000.0
    $H = [double]$Height
    $padTop = 12.0
    $padBottom = 4.0
    $plotH = $H - $padTop - $padBottom

    # Establish the value range across all series.
    $allVals = @()
    $maxCount = 0
    foreach ($s in $Series) {
        $vals = @()
        foreach ($v in $s.values) { if ($null -ne $v) { $vals += [double]$v } }
        $allVals += $vals
        if ($vals.Count -gt $maxCount) { $maxCount = $vals.Count }
    }

    if ($Max -le 0) {
        $Max = if ($allVals.Count) { ($allVals | Measure-Object -Maximum).Maximum } else { 1 }
    }
    if ($Threshold -gt 0 -and $Threshold -gt $Max) { $Max = $Threshold * 1.15 }
    if ($Max -le 0) { $Max = 1 }
    $Max = $Max * 1.12
    if ($Min -lt 0) { $Min = 0 }

    $span = $Max - $Min
    if ($span -le 0) { $span = 1 }

    $sb = New-Object System.Text.StringBuilder

    [void]$sb.Append("<svg class=""chart"" viewBox=""0 0 $(F $W 0) $(F $H 0)"" preserveAspectRatio=""none"" xmlns=""http://www.w3.org/2000/svg"">")

    # Horizontal grid: four bands, drawn from the top so the eye reads value -> y.
    for ($g = 0; $g -le 4; $g++) {
        $y = $padTop + ($plotH * ($g / 4.0))
        [void]$sb.Append("<line x1=""0"" y1=""$(F $y)"" x2=""$(F $W)"" y2=""$(F $y)"" class=""grid"" />")
    }

    if ($Threshold -gt 0 -and $Threshold -lt $Max) {
        $ty = $padTop + $plotH - (($Threshold - $Min) / $span) * $plotH
        [void]$sb.Append("<line x1=""0"" y1=""$(F $ty)"" x2=""$(F $W)"" y2=""$(F $ty)"" class=""thresh"" />")
    }

    foreach ($s in $Series) {
        $vals = @($s.values)
        $n = $vals.Count
        if ($n -lt 1) { continue }

        $points = New-Object System.Text.StringBuilder
        $area = New-Object System.Text.StringBuilder
        $inSegment = $false
        $segStartX = 0.0
        $lastX = 0.0

        for ($i = 0; $i -lt $n; $i++) {
            $v = $vals[$i]
            if ($null -eq $v) {
                $inSegment = $false
                continue
            }

            # A single sample still needs a valid x, so guard the divide.
            $x = if ($n -eq 1) { $W / 2 } else { ($i / [double]($n - 1)) * $W }
            $val = [double]$v
            if ($val -lt $Min) { $val = $Min }
            if ($val -gt $Max) { $val = $Max }
            $y = $padTop + $plotH - (($val - $Min) / $span) * $plotH

            if (-not $inSegment) {
                [void]$points.Append("M$(F $x) $(F $y)")
                if ($area.Length -gt 0) { $area.Append(' ') }
                [void]$area.Append("M$(F $x) $(F ($padTop + $plotH)) L$(F $x) $(F $y)")
                $segStartX = $x
                $inSegment = $true
            } else {
                [void]$points.Append(" L$(F $x) $(F $y)")
                [void]$area.Append(" L$(F $x) $(F $y)")
            }
            $lastX = $x

            # Close the area when the next value is a gap or the series ends.
            $isEnd = ($i -eq ($n - 1)) -or ($null -eq $vals[$i + 1])
            if ($isEnd) {
                [void]$area.Append(" L$(F $lastX) $(F ($padTop + $plotH)) Z")
                $inSegment = $false
            }
        }

        if ($area.Length -gt 0) {
            [void]$sb.Append("<path d=""$($area.ToString())"" fill=""$($s.color)"" fill-opacity=""0.14"" stroke=""none"" />")
        }
        if ($points.Length -gt 0) {
            [void]$sb.Append("<path d=""$($points.ToString())"" fill=""none"" stroke=""$($s.color)"" stroke-width=""1.5"" stroke-linejoin=""round"" vector-effect=""non-scaling-stroke"" />")
        }
    }

    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

<# Vertical markers where the sample loop flagged a problem, aligned to time. #>
function New-SvgSpikes {
    param($Flagged, [double]$ActualSeconds, [int]$Height = 120)
    if (-not $Flagged -or $Flagged.Count -eq 0 -or $ActualSeconds -le 0) { return '' }
    $W = 1000.0
    $H = [double]$Height
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg class=""chart spikes"" viewBox=""0 0 $(F $W 0) $(F $H 0)"" preserveAspectRatio=""none"" xmlns=""http://www.w3.org/2000/svg"">")
    foreach ($f in $Flagged) {
        $t = [double](Get-Prop $f 't' 0)
        $x = ($t / [double]$ActualSeconds) * $W
        if ($x -lt 0) { $x = 0 }
        if ($x -gt $W) { $x = $W }
        [void]$sb.Append("<line x1=""$(F $x)"" y1=""0"" x2=""$(F $x)"" y2=""$(F $H)"" stroke=""#f87171"" stroke-width=""1"" stroke-opacity=""0.45"" vector-effect=""non-scaling-stroke"" />")
    }
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

# ------------------------------------------------------------------ pieces ----

function New-ChartCard {
    param(
        [string]$Title,
        [string]$Sub = '',
        [string]$ChartHtml,
        [string]$Legend = '',
        [string]$Stats = ''
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="card chart-card">')
    [void]$sb.Append("<div class=""chart-head""><span class=""chart-title"">$(ConvertTo-HtmlText $Title)</span>")
    if ($Legend) { [void]$sb.Append("<span class=""legend"">$Legend</span>") }
    [void]$sb.Append('</div>')
    if ($Sub) { [void]$sb.Append("<div class=""chart-sub"">$(ConvertTo-HtmlText $Sub)</div>") }
    [void]$sb.Append("<div class=""chart-body"">$ChartHtml</div>")
    if ($Stats) { [void]$sb.Append("<div class=""chart-stats"">$Stats</div>") }
    [void]$sb.Append('</div>')
    return $sb.ToString()
}

function New-StatPill {
    param([string]$Label, [string]$Value, [string]$Tone = '')
    $cls = 'pill'
    if ($Tone) { $cls = "pill $Tone" }
    return "<span class=""$cls""><b>$(ConvertTo-HtmlText $Value)</b> $(ConvertTo-HtmlText $Label)</span>"
}

function New-FindingCard {
    param($Finding, [int]$Index)
    $sev = [string](Get-Prop $Finding 'severity' 'info')
    $cls = SevClass $sev
    $id = [string](Get-Prop $Finding 'id' "f$Index")

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<details class=""finding $cls"" id=""$(ConvertTo-HtmlText $id)"">")
    [void]$sb.Append('<summary>')
    [void]$sb.Append("<span class=""badge $(SevClass $sev)"">$(SevLabel $sev)</span>")
    [void]$sb.Append("<span class=""f-title"">$(ConvertTo-HtmlText (Get-Prop $Finding 'title'))</span>")
    $sum = [string](Get-Prop $Finding 'summary' '')
    if ($sum) { [void]$sb.Append("<span class=""f-summary"">$(ConvertTo-HtmlText $sum)</span>") }
    [void]$sb.Append('<span class="f-cat">' + (ConvertTo-HtmlText ([string](Get-Prop $Finding 'category' ''))) + '</span>')
    [void]$sb.Append('</summary>')
    [void]$sb.Append('<div class="f-body">')

    $why = [string](Get-Prop $Finding 'why' '')
    if ($why) {
        [void]$sb.Append('<div class="f-row"><div class="f-label">Why this causes stutter</div>')
        [void]$sb.Append("<div class=""f-text"">$(ConvertTo-HtmlText $why)</div></div>")
    }

    $ev = @(Get-Prop $Finding 'evidence' @())
    if ($ev.Count -gt 0) {
        [void]$sb.Append('<div class="f-row"><div class="f-label">Evidence</div><div class="f-text"><ul class="ev">')
        foreach ($e in $ev) { [void]$sb.Append("<li>$(ConvertTo-HtmlText $e)</li>") }
        [void]$sb.Append('</ul></div></div>')
    }

    $act = [string](Get-Prop $Finding 'action' '')
    if ($act) {
        [void]$sb.Append('<div class="f-row"><div class="f-label">What would address it</div>')
        [void]$sb.Append("<div class=""f-text f-action"">$(ConvertTo-HtmlText $act)</div></div>")
    }

    [void]$sb.Append('</div></details>')
    return $sb.ToString()
}

function New-Kv {
    param([string]$Key, [string]$Value)
    return "<div class=""kv""><span class=""k"">$(ConvertTo-HtmlText $Key)</span><span class=""v"">$(ConvertTo-HtmlText $Value)</span></div>"
}

# -------------------------------------------------------------------- css -----

function Get-Css {
    return @'
:root{
  --bg:#0b0e14; --panel:#121722; --panel2:#151b28; --line:#232c3d;
  --text:#e6edf7; --dim:#8b98ad; --dim2:#5d6a80;
  --crit:#f87171; --warn:#fbbf24; --info:#60a5fa; --ok:#34d399;
  --accent:#38bdf8;
}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{
  margin:0; background:var(--bg); color:var(--text);
  font:15px/1.6 "Segoe UI Variable Text","Segoe UI",system-ui,-apple-system,sans-serif;
  padding:0 0 80px;
}
.wrap{max-width:1120px;margin:0 auto;padding:0 28px}
h1,h2,h3{line-height:1.25;margin:0}
code,.mono{font-family:"Cascadia Mono",Consolas,"Courier New",monospace;font-size:.92em}

/* ---------- header ---------- */
header{border-bottom:1px solid var(--line);padding:34px 0 26px;margin-bottom:30px}
.brand{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap}
.brand h1{font-size:26px;font-weight:650;letter-spacing:-.02em}
.brand .ver{color:var(--dim2);font-size:13px;font-weight:500}
.machine{margin-top:8px;color:var(--dim);font-size:13.5px}
.machine b{color:var(--text);font-weight:600}

/* ---------- verdict ---------- */
.verdict{
  display:flex;align-items:flex-start;gap:16px;
  padding:20px 22px;border-radius:12px;border:1px solid var(--line);
  background:var(--panel);margin-bottom:8px;
}
.verdict .mark{width:5px;align-self:stretch;border-radius:3px;flex:0 0 5px;background:var(--ok)}
.verdict.critical .mark{background:var(--crit)}
.verdict.warn .mark{background:var(--warn)}
.verdict.info .mark{background:var(--info)}
.verdict h2{font-size:18px;font-weight:620;margin-bottom:4px}
.verdict p{margin:0;color:var(--dim);font-size:14px}
.counts{display:flex;gap:8px;margin:18px 0 34px;flex-wrap:wrap}
.count{
  display:flex;align-items:center;gap:8px;padding:8px 14px;border-radius:9px;
  background:var(--panel);border:1px solid var(--line);font-size:13.5px;color:var(--dim);
}
.count b{font-size:16px;font-weight:650;color:var(--text)}
.count.c-critical b{color:var(--crit)}
.count.c-warn b{color:var(--warn)}
.count.c-info b{color:var(--info)}

/* ---------- sections ---------- */
section{margin-bottom:38px}
.sec-head{display:flex;align-items:baseline;gap:12px;margin-bottom:14px;flex-wrap:wrap}
.sec-head h2{font-size:15px;font-weight:650;letter-spacing:.06em;text-transform:uppercase;color:var(--dim)}
.sec-head .note{color:var(--dim2);font-size:13px}

/* ---------- findings ---------- */
.finding{
  background:var(--panel);border:1px solid var(--line);border-left:3px solid var(--dim2);
  border-radius:10px;margin-bottom:10px;overflow:hidden;
}
.finding.sev-critical{border-left-color:var(--crit)}
.finding.sev-warn{border-left-color:var(--warn)}
.finding.sev-info{border-left-color:var(--info)}
.finding.sev-ok{border-left-color:var(--ok)}
.finding summary{
  display:flex;align-items:center;gap:11px;flex-wrap:wrap;
  padding:13px 16px;cursor:pointer;list-style:none;user-select:none;
}
.finding summary::-webkit-details-marker{display:none}
.finding summary:hover{background:var(--panel2)}
.badge{
  font-size:10.5px;font-weight:700;letter-spacing:.08em;padding:3px 7px;border-radius:5px;
  flex:0 0 auto;
}
.badge.sev-critical{background:rgba(248,113,113,.14);color:var(--crit)}
.badge.sev-warn{background:rgba(251,191,36,.14);color:var(--warn)}
.badge.sev-info{background:rgba(96,165,250,.14);color:var(--info)}
.badge.sev-ok{background:rgba(52,211,153,.14);color:var(--ok)}
.f-title{font-weight:600;font-size:14.5px}
.f-summary{color:var(--dim);font-size:13.5px}
.f-cat{margin-left:auto;color:var(--dim2);font-size:11.5px;letter-spacing:.05em;text-transform:uppercase}
.f-body{padding:4px 18px 18px;border-top:1px solid var(--line)}
.f-row{margin-top:16px}
.f-label{
  font-size:11px;font-weight:700;letter-spacing:.09em;text-transform:uppercase;
  color:var(--dim2);margin-bottom:5px;
}
.f-text{color:#cbd6e6;font-size:14px}
.f-action{color:var(--text)}
ul.ev{margin:0;padding-left:18px;color:var(--dim)}
ul.ev li{margin:2px 0}
ul.ev li::marker{color:var(--dim2)}

/* ---------- cards & charts ---------- */
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:16px 18px}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:12px}
@media (max-width:820px){.grid2{grid-template-columns:1fr}}
.chart-card{margin-bottom:12px;padding-bottom:14px}
.chart-head{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap;margin-bottom:2px}
.chart-title{font-size:13.5px;font-weight:600}
.legend{display:flex;gap:12px;margin-left:auto;font-size:11.5px;color:var(--dim)}
.legend i{display:inline-block;width:9px;height:9px;border-radius:2px;margin-right:5px;vertical-align:baseline}
.chart-sub{color:var(--dim2);font-size:12px;margin-bottom:6px}
.chart-body{position:relative;margin:6px 0 8px}
svg.chart{display:block;width:100%;height:auto}
svg.chart .grid{stroke:var(--line);stroke-width:1;vector-effect:non-scaling-stroke}
svg.chart .thresh{stroke:#f87171;stroke-width:1;stroke-dasharray:4 4;stroke-opacity:.55;vector-effect:non-scaling-stroke}
.chart-body{display:block}
.spikes-wrap{margin-top:-4px;opacity:.8}
.chart-stats{display:flex;gap:7px;flex-wrap:wrap;margin-top:2px}
.pill{
  font-size:12px;color:var(--dim);background:var(--panel2);border:1px solid var(--line);
  padding:3px 9px;border-radius:6px;
}
.pill b{color:var(--text);font-weight:600;margin-right:3px}
.pill.tone-warn b{color:var(--warn)}
.pill.tone-crit b{color:var(--crit)}

/* ---------- tables ---------- */
table{width:100%;border-collapse:collapse;font-size:13.5px}
th{
  text-align:left;font-size:11px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;
  color:var(--dim2);padding:0 10px 8px 0;border-bottom:1px solid var(--line);
}
td{padding:7px 10px 7px 0;border-bottom:1px solid rgba(35,44,61,.6);color:#cbd6e6}
tr:last-child td{border-bottom:none}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
.bar{
  height:5px;border-radius:3px;background:var(--accent);opacity:.75;
  min-width:2px;display:inline-block;vertical-align:middle;
}
td.wrap{white-space:normal;word-break:break-word;color:var(--dim);max-width:520px}

/* ---------- kv ---------- */
.kv{display:flex;justify-content:space-between;gap:16px;padding:5px 0;border-bottom:1px solid rgba(35,44,61,.55);font-size:13.5px}
.kv:last-child{border-bottom:none}
.kv .k{color:var(--dim);flex:0 0 auto}
.kv .v{color:var(--text);text-align:right;word-break:break-word}

/* ---------- notices ---------- */
.notice{
  border:1px solid var(--line);border-left:3px solid var(--info);border-radius:9px;
  background:var(--panel);padding:14px 18px;margin-bottom:10px;font-size:13.5px;color:var(--dim);
}
.notice b{color:var(--text)}
.notice.warn{border-left-color:var(--warn)}
.notice.crit{border-left-color:var(--crit)}
.notice ul{margin:8px 0 0;padding-left:18px}
.notice li{margin:3px 0}

.empty{
  border:1px dashed var(--line);border-radius:9px;padding:22px;text-align:center;
  color:var(--dim2);font-size:13.5px;
}

footer{margin-top:46px;padding-top:22px;border-top:1px solid var(--line);color:var(--dim2);font-size:12.5px}
footer p{margin:0 0 8px}

@media print{
  body{background:#fff;color:#111;padding:0}
  .card,.finding,.verdict,.count,.notice{border-color:#ccc;background:#fff}
  .f-text{color:#222}
  .badge{background:#eee !important;color:#000 !important}
  footer{color:#555}
}
'@
}

# ---------------------------------------------------------------- assemble ----

function Render-Dashboard {
    param([Parameter(Mandatory)]$Run)

    $tool = Get-Prop $Run 'tool'
    $facts = Get-Prop $Run 'facts'
    $monitor = Get-Prop $Run 'monitor'
    $events = Get-Prop $Run 'events'
    $findings = Get-Prop $Run 'findings'
    $errors = @(Get-Prop $Run 'errors' @())

    $machine = [string](Get-Prop $tool 'machine' 'unknown')
    $startedAt = [string](Get-Prop $tool 'startedAt' '')
    $startedDisplay = ''
    $dt = [datetime]::MinValue
    if ($startedAt -and [datetime]::TryParse($startedAt, [ref]$dt)) {
        $startedDisplay = $dt.ToString('yyyy-MM-dd HH:mm:ss')
    } else {
        $startedDisplay = $startedAt
    }

    $verdict = [string](Get-Prop $findings 'verdict' 'clean')
    $headline = [string](Get-Prop $findings 'headline' 'No findings.')
    $counts = Get-Prop $findings 'counts' @{}
    $findingList = @(Get-Prop $findings 'findings' @())
    $coverage = @(Get-Prop $findings 'coverage' @())

    $sb = New-Object System.Text.StringBuilder

    # ------------------------------------------------------------- document ---
    [void]$sb.Append('<!DOCTYPE html>')
    [void]$sb.Append('<html lang="en"><head>')
    [void]$sb.Append('<meta charset="utf-8">')
    [void]$sb.Append('<meta name="viewport" content="width=device-width,initial-scale=1">')
    [void]$sb.Append("<title>StutterLab — $(ConvertTo-HtmlText $machine)</title>")
    [void]$sb.Append('<style>')
    [void]$sb.Append((Get-Css))
    [void]$sb.Append('</style></head><body>')

    # --------------------------------------------------------------- header ---
    [void]$sb.Append('<header><div class="wrap">')
    [void]$sb.Append('<div class="brand"><h1>StutterLab</h1>')
    [void]$sb.Append("<span class=""ver"">v$(ConvertTo-HtmlText (Get-Prop $tool 'version' '0.1.0'))</span></div>")
    [void]$sb.Append('<div class="machine">')
    $osName = [string](Get-Prop (Get-Prop $facts 'os') 'caption' '')
    if (-not $osName) { $osName = [string](Get-Prop $tool 'os' 'Windows') }
    [void]$sb.Append("<b>$(ConvertTo-HtmlText $machine)</b> · $(ConvertTo-HtmlText $osName) · ")
    [void]$sb.Append("collected $(ConvertTo-HtmlText $startedDisplay)")
    [void]$sb.Append('</div></div></header>')

    [void]$sb.Append('<div class="wrap">')

    # -------------------------------------------------------------- verdict ---
    [void]$sb.Append("<div class=""verdict $verdict""><div class=""mark""></div><div>")
    [void]$sb.Append("<h2>$(ConvertTo-HtmlText $headline)</h2>")
    [void]$sb.Append('<p>Ranked by likely impact on frame pacing. Open any item for the mechanism behind it.</p>')
    [void]$sb.Append('</div></div>')

    [void]$sb.Append('<div class="counts">')
    foreach ($k in 'critical', 'warn', 'info') {
        $n = 0
        if ($counts -and $counts.Contains($k)) { $n = [int]$counts[$k] }
        $cls = switch ($k) { 'critical' { 'c-critical' } 'warn' { 'c-warn' } default { 'c-info' } }
        $lbl = switch ($k) { 'critical' { 'critical' } 'warn' { 'warnings' } default { 'notes' } }
        [void]$sb.Append("<div class=""count $cls""><b>$n</b> $lbl</div>")
    }
    [void]$sb.Append('</div>')

    # ------------------------------------------------------------- findings ---
    [void]$sb.Append('<section><div class="sec-head"><h2>Findings</h2>')
    [void]$sb.Append('<span class="note">click to expand</span></div>')
    if ($findingList.Count -eq 0) {
        [void]$sb.Append('<div class="empty">No findings. Nothing crossed a threshold in this run.</div>')
    } else {
        $i = 0
        foreach ($f in $findingList) {
            [void]$sb.Append((New-FindingCard -Finding $f -Index $i))
            $i++
        }
    }
    [void]$sb.Append('</section>')

    # ------------------------------------------------------ machine snapshot ---
    $cpu = Get-Prop $facts 'cpu'
    $mem = Get-Prop $facts 'memory'
    $gpu = Get-Prop $facts 'gpu'
    $disks = Get-Prop $facts 'disks'
    $power = Get-Prop $facts 'power'
    $disp = Get-Prop $facts 'display'

    [void]$sb.Append('<section><div class="sec-head"><h2>Machine</h2>')
    [void]$sb.Append('<span class="note">as reported by Windows at collection time</span></div>')
    [void]$sb.Append('<div class="grid2">')

    # CPU card
    [void]$sb.Append('<div class="card">')
    [void]$sb.Append('<div class="chart-title" style="margin-bottom:8px">Processor</div>')
    $cpuName = [string](Get-Prop $cpu 'name' 'Unavailable')
    [void]$sb.Append((New-Kv 'Model' $cpuName))
    $cores = Get-Prop $cpu 'cores'; $threads = Get-Prop $cpu 'logical'
    if ($cores) { [void]$sb.Append((New-Kv 'Cores / threads' "$cores / $threads")) }
    [void]$sb.Append((New-Kv 'Max clock' ("$(Format-Number (Get-Prop $cpu 'maxClockMhz')) MHz")))
    [void]$sb.Append('</div>')

    # Memory card
    [void]$sb.Append('<div class="card">')
    [void]$sb.Append('<div class="chart-title" style="margin-bottom:8px">Memory</div>')
    [void]$sb.Append((New-Kv 'Installed' (Format-Gb (Get-Prop $mem 'totalBytes'))))
    $sticks = @(Get-Prop $mem 'sticks' @())
    [void]$sb.Append((New-Kv 'Sticks' ("$(Get-Prop $mem 'stickCount' 0) of $(Get-Prop $mem 'slotsTotal' '?') slots")))
    foreach ($s in $sticks) {
        $slot = [string](Get-Prop $s 'slot' '?')
        $cap = Format-Gb (Get-Prop $s 'capacity')
        $spd = [string](Get-Prop $s 'speedConfig' '?')
        [void]$sb.Append((New-Kv "  $slot" "$cap @ $spd MT/s"))
    }
    [void]$sb.Append('</div>')

    # GPU card
    [void]$sb.Append('<div class="card">')
    [void]$sb.Append('<div class="chart-title" style="margin-bottom:8px">Graphics</div>')
    $cards = @(Get-Prop $gpu 'cards' @())
    if ($cards.Count -eq 0) {
        [void]$sb.Append((New-Kv 'Adapter' 'Unavailable'))
    }
    foreach ($c in $cards) {
        $cname = [string](Get-Prop $c 'name' 'Adapter')
        # The collector stores vramBytes; reading 'vram' here silently rendered '—'
        # for every adapter.
        $vram = Format-Bytes (Get-Prop $c 'vramBytes')
        [void]$sb.Append((New-Kv $cname "$vram · driver $(Get-Prop $c 'driverVer' '?')"))
    }
    $dispName = Get-Prop $disp 'name'
    $dispDiag = Get-Prop $disp 'diagonalInches'
    $panelBits = @()
    if ($dispName) { $panelBits += $dispName }
    if ($dispDiag) { $panelBits += "$dispDiag`"" }
    $curR = Get-Prop $disp 'maxRefresh'
    if ($curR) { $panelBits += "max $curR Hz" }
    if ($panelBits.Count) { [void]$sb.Append((New-Kv 'Panel' ($panelBits -join ' · '))) }
    [void]$sb.Append('</div>')

    # Storage card
    [void]$sb.Append('<div class="card">')
    [void]$sb.Append('<div class="chart-title" style="margin-bottom:8px">Storage</div>')
    foreach ($p in @(Get-Prop $disks 'physical' @())) {
        [void]$sb.Append((New-Kv ([string](Get-Prop $p 'friendlyName' 'Disk')) ("$(Format-Bytes (Get-Prop $p 'size')) · $(Get-Prop $p 'mediaType' '?') · $(Get-Prop $p 'health' '?')")))
    }
    foreach ($v in @(Get-Prop $disks 'volumes' @())) {
        $letter = [string](Get-Prop $v 'letter' '?')
        $freeG = Format-Gb (Get-Prop $v 'free')
        $sizeG = Format-Gb (Get-Prop $v 'size')
        $pct = Get-Prop $v 'freePct'
        [void]$sb.Append((New-Kv "Volume $letter" "$freeG free of $sizeG ($pct%)"))
    }

    # Page file. Collected since the first version, but until now never rendered:
    # the values were present in every run's data.json and in none of its HTML.
    # Relevant to stutter because a small or nearly-full page file turns memory
    # pressure into synchronous disk waits on the render thread.
    $pf = Get-Prop $facts 'pagefile'
    if ($pf) {
        $pfUsage = @(Get-Prop $pf 'usage' @())
        if ($pfUsage.Count -eq 0) {
            [void]$sb.Append((New-Kv 'Page file' 'none in use'))
        }
        foreach ($u in $pfUsage) {
            $uName = [string](Get-Prop $u 'name' 'Page file')
            $bits = @()
            $uAlloc = Get-Prop $u 'allocMb'
            $uCur = Get-Prop $u 'currentMb'
            $uPeak = Get-Prop $u 'peakMb'
            if ($null -ne $uAlloc) { $bits += "$(Format-Number $uAlloc) MB allocated" }
            if ($null -ne $uCur) { $bits += "$(Format-Number $uCur) MB in use" }
            if ($null -ne $uPeak) { $bits += "peak $(Format-Number $uPeak) MB" }
            if ($bits.Count) { [void]$sb.Append((New-Kv $uName ($bits -join ' · '))) }
        }
        if ((Get-Prop $pf 'automaticManaged') -eq $true) {
            [void]$sb.Append((New-Kv 'Page file mode' 'Automatic (Windows-managed)'))
        }
    }
    [void]$sb.Append('</div>')

    # Power card
    [void]$sb.Append('<div class="card">')
    [void]$sb.Append('<div class="chart-title" style="margin-bottom:8px">Power</div>')
    [void]$sb.Append((New-Kv 'Active plan' ([string](Get-Prop $power 'name' 'Unavailable'))))
    $minSt = Get-Prop $power 'processorMinState'
    if ($null -ne $minSt) { [void]$sb.Append((New-Kv 'Min processor state' "$minSt%")) }
    $maxSt = Get-Prop $power 'processorMaxState'
    if ($null -ne $maxSt) { [void]$sb.Append((New-Kv 'Max processor state' "$maxSt%")) }
    [void]$sb.Append('</div>')

    # Session card
    [void]$sb.Append('<div class="card">')
    [void]$sb.Append('<div class="chart-title" style="margin-bottom:8px">Session</div>')
    $mon = Get-Prop $monitor 'summary'
    if ($mon) {
        [void]$sb.Append((New-Kv 'Samples' ([string](Get-Prop $mon 'sampleCount' 0))))
        [void]$sb.Append((New-Kv 'Duration' ("$(Get-Prop $mon 'actualSeconds' 0) s")))
        [void]$sb.Append((New-Kv 'Flagged ticks' ([string](Get-Prop $mon 'flaggedCount' 0))))
    } else {
        [void]$sb.Append((New-Kv 'Monitor' 'skipped'))
    }
    [void]$sb.Append((New-Kv 'Events (7d)' ([string](Get-Prop $events 'totalCount' 0))))
    $elapsed = Get-Prop $tool 'elapsedSeconds'
    if ($elapsed) { [void]$sb.Append((New-Kv 'Collection time' "$elapsed s")) }
    [void]$sb.Append('</div>')

    [void]$sb.Append('</div></section>')

    # ---------------------------------------------------------- monitor charts
    # NOTE: $mon is the *summary* node (assigned above for the Session card), so the
    # samples array must be read from $monitor itself. Reading it from $mon is what
    # silently produced the "session was skipped" notice on a run with samples.
    if ($monitor -and (Get-Prop $monitor 'samples')) {
        $samples = @(Get-Prop $monitor 'samples' @())
        $actual = [double](Get-Prop $mon 'actualSeconds' 60)
        if ($actual -le 0) { $actual = 60 }

        $cpuS = Get-Series $samples 'cpuTotal'
        $coreS = Get-Series $samples 'cpuCoreMax'
        $dpcS = Get-Series $samples 'dpc'
        $isrS = Get-Series $samples 'interrupt'
        $latS = Get-Series $samples 'diskLatMs'
        $qS = Get-Series $samples 'diskQueue'
        $memS = Get-Series $samples 'memAvailMb'
        $commitS = Get-Series $samples 'commitPct'
        $freqS = Get-Series $samples 'freqPct'
        $diskBytesS = Get-Series $samples 'diskBytesSec'

        $flagged = @(Get-Prop $mon 'flaggedTicks' @())
        $spikes = New-SvgSpikes -Flagged $flagged -ActualSeconds $actual -Height 34

        $gpuTotals = @()
        foreach ($s in $samples) {
            $sum = 0.0
            $byLuid = Get-Prop $s 'gpuByLuid' @{}
            foreach ($k in @($byLuid.Keys)) { $sum += [double]$byLuid[$k] }
            $gpuTotals += [math]::Round($sum, 1)
        }

        [void]$sb.Append('<section><div class="sec-head"><h2>Timeline</h2>')
        [void]$sb.Append("<span class=""note"">$([math]::Round($actual,1))s window · 1 sample per second · red ticks mark flagged seconds</span></div>")

        # CPU
        $cpuStats = Get-Prop $mon 'summary'
        $cS = Get-Prop $cpuStats 'cpuTotal'
        [void]$sb.Append((New-ChartCard -Title 'CPU utilisation' -Sub 'total across all logical processors' `
                    -ChartHtml (New-SvgChart -Series @(
                        @{ values = $cpuS; color = '#38bdf8'; label = 'total' },
                        @{ values = $coreS; color = '#a78bfa'; label = 'busiest core' }
                    ) -Max 100 -Threshold 90) `
                    -Legend '<span><i style="background:#38bdf8"></i>total</span><span><i style="background:#a78bfa"></i>busiest core</span><span><i style="background:#f87171"></i>90% threshold</span>' `
                    -Stats ((New-StatPill 'mean' "$(Get-Prop $cS 'mean')%" ) + (New-StatPill 'p95' "$(Get-Prop $cS 'p95')%") + (New-StatPill 'peak' "$(Get-Prop $cS 'max')%") + $spikes)))

        # Kernel time
        $dS = Get-Prop (Get-Prop $mon 'summary') 'dpc'
        $iS = Get-Prop (Get-Prop $mon 'summary') 'interrupt'
        [void]$sb.Append((New-ChartCard -Title 'Kernel preemption — DPC and interrupt time' -Sub 'time spent in kernel routines that outrank the game thread' `
                    -ChartHtml (New-SvgChart -Series @(
                        @{ values = $dpcS; color = '#fbbf24'; label = 'DPC' },
                        @{ values = $isrS; color = '#f472b6'; label = 'interrupt' }
                    ) -Threshold 5) `
                    -Legend '<span><i style="background:#fbbf24"></i>DPC</span><span><i style="background:#f472b6"></i>interrupt</span><span><i style="background:#f87171"></i>5% threshold</span>' `
                    -Stats ((New-StatPill 'DPC p95' "$(Get-Prop $dS 'p95')%") + (New-StatPill 'DPC peak' "$(Get-Prop $dS 'max')%") + (New-StatPill 'ISR p95' "$(Get-Prop $iS 'p95')%"))))

        # Disk latency
        $lS = Get-Prop (Get-Prop $mon 'summary') 'diskLatMs'
        [void]$sb.Append((New-ChartCard -Title 'Disk latency' -Sub 'average time per transfer — the wait before data arrives' `
                    -ChartHtml (New-SvgChart -Series @(
                        @{ values = $latS; color = '#34d399'; label = 'latency' }
                    ) -Threshold 25) `
                    -Legend '<span><i style="background:#34d399"></i>ms per transfer</span><span><i style="background:#f87171"></i>25 ms threshold</span>' `
                    -Stats ((New-StatPill 'median' "$(F (Get-Prop $lS 'p50')) ms") + (New-StatPill 'p95' "$(F (Get-Prop $lS 'p95')) ms") + (New-StatPill 'peak' "$(F (Get-Prop $lS 'max')) ms" 'tone-warn'))))

        # Disk queue + throughput
        $qS2 = Get-Prop (Get-Prop $mon 'summary') 'diskQueue'
        [void]$sb.Append((New-ChartCard -Title 'Disk queue depth' -Sub 'requests waiting for the drive' `
                    -ChartHtml (New-SvgChart -Series @(
                        @{ values = $qS; color = '#60a5fa'; label = 'queue' }
                    ) -Threshold 2) `
                    -Legend '<span><i style="background:#60a5fa"></i>queue depth</span><span><i style="background:#f87171"></i>2 threshold</span>' `
                    -Stats ((New-StatPill 'mean' (F (Get-Prop $qS2 'mean'))) + (New-StatPill 'p95' (F (Get-Prop $qS2 'p95'))) + (New-StatPill 'peak' (F (Get-Prop $qS2 'max'))))))

        # Memory
        $mS = Get-Prop (Get-Prop $mon 'summary') 'memAvailMb'
        [void]$sb.Append((New-ChartCard -Title 'Available memory' -Sub 'megabytes free for programs — the floor matters more than the average' `
                    -ChartHtml (New-SvgChart -Series @(
                        @{ values = $memS; color = '#22d3ee'; label = 'available' }
                    )) `
                    -Legend '<span><i style="background:#22d3ee"></i>MB available</span>' `
                    -Stats ((New-StatPill 'min' "$([int](Get-Prop $mS 'min')) MB") + (New-StatPill 'mean' "$([int](Get-Prop $mS 'mean')) MB") + (New-StatPill 'max' "$([int](Get-Prop $mS 'max')) MB"))))

        # Frequency
        $fS = Get-Prop (Get-Prop $mon 'summary') 'freqPct'
        [void]$sb.Append((New-ChartCard -Title 'CPU frequency vs maximum' -Sub 'below 100% means the processor is holding back — power limits or thermals' `
                    -ChartHtml (New-SvgChart -Series @(
                        @{ values = $freqS; color = '#f59e0b'; label = 'frequency' }
                    ) -Max 110 -Threshold 80) `
                    -Legend '<span><i style="background:#f59e0b"></i>% of max clock</span><span><i style="background:#f87171"></i>80% line</span>' `
                    -Stats ((New-StatPill 'mean' "$(Get-Prop $fS 'mean')%") + (New-StatPill 'min' "$(Get-Prop $fS 'min')%") + (New-StatPill 'peak' "$(Get-Prop $fS 'max')%"))))

        # GPU
        $gS = Get-Prop (Get-Prop $mon 'summary') 'gpuTotal'
        [void]$sb.Append((New-ChartCard -Title 'GPU utilisation (all adapters)' -Sub 'summed across engine types — can exceed 100% when several engines are busy' `
                    -ChartHtml (New-SvgChart -Series @(
                        @{ values = $gpuTotals; color = '#a78bfa'; label = 'gpu' }
                    )) `
                    -Legend '<span><i style="background:#a78bfa"></i>utilisation</span>' `
                    -Stats ((New-StatPill 'mean' "$(Get-Prop $gS 'mean')%") + (New-StatPill 'p95' "$(Get-Prop $gS 'p95')%") + (New-StatPill 'peak' "$(Get-Prop $gS 'max')%"))))

        [void]$sb.Append('</section>')

        # ----------------------------------------------------------- processes --
        $procs = @(Get-Prop (Get-Prop $mon 'summary') 'processCpu' @())
        if ($procs.Count -gt 0) {
            $maxCore = 0.0
            foreach ($p in $procs) {
                $v = Get-Prop $p 'corePct'
                if ($null -ne $v -and [double]$v -gt $maxCore) { $maxCore = [double]$v }
            }
            if ($maxCore -le 0) { $maxCore = 1 }

            [void]$sb.Append('<section><div class="sec-head"><h2>Busiest processes</h2>')
            [void]$sb.Append("<span class=""note"">CPU seconds consumed during the $([int]$actual)s window</span></div>")
            [void]$sb.Append('<div class="card" style="padding:16px 18px 8px"><table><thead><tr>')
            [void]$sb.Append('<th>Process</th><th class="num">CPU time</th><th class="num">All cores</th><th>Share of one core</th>')
            [void]$sb.Append('</tr></thead><tbody>')
            foreach ($p in $procs) {
                $name = ConvertTo-HtmlText ([string](Get-Prop $p 'name' '?'))
                $cpuSec = Get-Prop $p 'cpuSec'
                $avg = Get-Prop $p 'avgPct'
                $corePct = Get-Prop $p 'corePct'
                $w = 0.0
                if ($null -ne $corePct) { $w = ([double]$corePct / $maxCore) * 100.0 }
                [void]$sb.Append("<tr><td>$name</td>")
                [void]$sb.Append("<td class=""num"">$(F $cpuSec '0.0') s</td>")
                [void]$sb.Append("<td class=""num"">$(F $avg '0.0')%</td>")
                [void]$sb.Append("<td><span class=""bar"" style=""width:$(F $w '0.0')%""></span> $(F $corePct '0.0')%</td></tr>")
            }
            [void]$sb.Append('</tbody></table></div>')
            [void]$sb.Append('<div class="notice" style="margin-top:10px">"All cores" divides consumption across every logical processor, so a single-threaded program that is fully saturating one core still reads near 8% on a 12-thread machine. Read the last column for contention: a process above ~90% of one core is competing with the game for that same core.</div>')
            [void]$sb.Append('</section>')
        }
    } else {
        [void]$sb.Append('<section><div class="sec-head"><h2>Timeline</h2></div>')
        [void]$sb.Append('<div class="empty">The timed sampling session was skipped, so there is no timeline for this run. Re-run without <code>-NoMonitor</code> to collect one.</div>')
        [void]$sb.Append('</section>')
    }

    # --------------------------------------------------------------- events ---
    $eventList = @(Get-Prop $events 'events' @())
    $since = [string](Get-Prop $events 'since' '')
    [void]$sb.Append('<section><div class="sec-head"><h2>Event log correlation</h2>')
    if ($since) {
        $sd = [datetime]::MinValue
        $sinceText = if ([datetime]::TryParse($since, [ref]$sd)) { $sd.ToString('yyyy-MM-dd') } else { $since }
        [void]$sb.Append("<span class=""note"">since $(ConvertTo-HtmlText $sinceText)</span>")
    }
    [void]$sb.Append('</div>')

    if ($eventList.Count -eq 0) {
        [void]$sb.Append('<div class="empty">No matching events. Nothing in the log points at hardware or driver faults in this window.</div>')
    } else {
        [void]$sb.Append('<div class="card" style="padding:16px 18px 8px"><table><thead><tr>')
        [void]$sb.Append('<th style="width:150px">When</th><th style="width:60px">ID</th><th>What happened</th>')
        [void]$sb.Append('</tr></thead><tbody>')
        foreach ($e in ($eventList | Select-Object -First 25)) {
            $t = [string](Get-Prop $e 'time' '')
            $td = [datetime]::MinValue
            if ($t -and [datetime]::TryParse($t, [ref]$td)) { $t = $td.ToString('MM-dd HH:mm:ss') }
            $msg = [string](Get-Prop $e 'message' '')
            if ($msg.Length -gt 190) { $msg = $msg.Substring(0, 190) + '…' }
            [void]$sb.Append("<tr><td class=""mono"">$(ConvertTo-HtmlText $t)</td>")
            [void]$sb.Append("<td class=""num"">$(ConvertTo-HtmlText (Get-Prop $e 'id' ''))</td>")
            [void]$sb.Append("<td class=""wrap"">$(ConvertTo-HtmlText (Get-Prop $e 'label' '')) — $(ConvertTo-HtmlText $msg)</td></tr>")
        }
        [void]$sb.Append('</tbody></table></div>')
        if ($eventList.Count -gt 25) {
            [void]$sb.Append("<div class=""notice"" style=""margin-top:10px"">Showing 25 of $($eventList.Count) matched events. The full set is in <code>data.json</code>.</div>")
        }
    }
    [void]$sb.Append('</section>')

    # ------------------------------------------------------------- coverage ---
    # Two different kinds of note land in coverage, and calling both "failed or
    # denied" was wrong: the frame-timing note is a permanent scope limitation,
    # not a collection failure. Splitting them keeps the claim honest.
    if ($coverage.Count -gt 0) {
        $defects = @()
        $limits = @()
        foreach ($c in $coverage) {
            if ([string](Get-Prop $c 'source' '') -eq 'frame timing') { $limits += $c } else { $defects += $c }
        }

        [void]$sb.Append('<section><div class="sec-head"><h2>What this run could not see</h2></div>')

        if ($defects.Count -gt 0) {
            [void]$sb.Append('<div class="notice warn"><b>Incomplete coverage.</b> These sources failed or were refused, so any conclusion drawn without them is weaker:')
            [void]$sb.Append('<ul>')
            foreach ($c in $defects) {
                $src = [string](Get-Prop $c 'source' '?')
                $err = [string](Get-Prop $c 'error' 'unknown')
                [void]$sb.Append("<li><code>$(ConvertTo-HtmlText $src)</code> — $(ConvertTo-HtmlText $err)</li>")
            }
            [void]$sb.Append('</ul></div>')
        }

        if ($limits.Count -gt 0) {
            [void]$sb.Append('<div class="notice"><b>Outside what this tool measures.</b>')
            [void]$sb.Append('<ul>')
            foreach ($c in $limits) {
                $err = [string](Get-Prop $c 'error' 'unknown')
                [void]$sb.Append("<li>$(ConvertTo-HtmlText $err)</li>")
            }
            [void]$sb.Append('</ul></div>')
        }

        [void]$sb.Append('</section>')
    }

    if ($errors.Count -gt 0) {
        [void]$sb.Append('<section><div class="sec-head"><h2>Collector errors</h2></div>')
        [void]$sb.Append('<div class="notice crit"><ul>')
        foreach ($e in $errors) { [void]$sb.Append("<li>$(ConvertTo-HtmlText $e)</li>") }
        [void]$sb.Append('</ul></div></section>')
    }

    # --------------------------------------------------------------- footer ---
    [void]$sb.Append('<footer>')
    [void]$sb.Append('<p><b>What this measures, honestly.</b> This tool samples hardware contention once per second: CPU time split three ways, kernel preemption, disk waits, memory pressure, GPU load, and the Windows event log. It does <b>not</b> measure frame times, and it cannot tell you what your frame rate was. Its job is to find <i>why</i> frame pacing might break, not to score how broken it is.</p>')
    [void]$sb.Append('<p>A clean report is not proof that nothing is wrong. It means nothing this tool can see crossed a threshold during this window. Session-specific problems — a game''s shader compilation on first load, a thermal event twenty minutes in, a background task on a timer — need a longer window or a captured frame-time trace.</p>')
    [void]$sb.Append('<p><b>Read-only.</b> This run changed nothing on the machine. It wrote only to this folder. Every recommendation above is advice for you to apply, not something the tool did.</p>')
    $elapsed2 = Get-Prop $tool 'elapsedSeconds'
    [void]$sb.Append("<p style=""margin-top:14px"">StutterLab $(ConvertTo-HtmlText (Get-Prop $tool 'version' '0.1.0')) · $(ConvertTo-HtmlText $machine) · $(ConvertTo-HtmlText $startedDisplay) · collected in $(ConvertTo-HtmlText $elapsed2)s</p>")
    [void]$sb.Append('</footer>')

    [void]$sb.Append('</div></body></html>')

    return $sb.ToString()
}
