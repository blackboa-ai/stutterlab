# Diagnostic helper: walks a PowerShell source file with a small state machine and
# reports the first line where quoting or parenthesis nesting goes wrong.
# Not part of the collector — used only while developing the modules.
param(
    [Parameter(Mandatory = $true)][string]$Path
)

$lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)

$mode = 'none'          # none | sq | dq | here
$hereQuote = ''         # ' or "
$depth = 0
$depthAtLine = New-Object System.Collections.ArrayList
$subStack = New-Object System.Collections.Generic.Stack[int]
$inSub = 0              # >0 when inside $( ) within a double-quoted string
$problems = New-Object System.Collections.ArrayList

for ($n = 0; $n -lt $lines.Count; $n++) {
    $lineNo = $n + 1
    $line = $lines[$n]
    $i = 0

    # here-string terminators are checked before normal scanning
    if ($mode -eq 'here') {
        if ($line.Trim() -eq ($hereQuote + '@')) {
            $mode = 'none'
            $hereQuote = ''
        }
        [void]$depthAtLine.Add($depth)
        continue
    }

    while ($i -lt $line.Length) {
        $c = $line[$i]
        $next = if ($i + 1 -lt $line.Length) { $line[$i + 1] } else { "`0" }

        if ($mode -eq 'sq') {
            if ($c -eq "'") {
                if ($next -eq "'") { $i += 2; continue }
                $mode = 'none'; $i++; continue
            }
            $i++; continue
        }

        if ($mode -eq 'dq') {
            if ($c -eq '`') { $i += 2; continue }
            if ($c -eq '"') {
                if ($next -eq '"') { $i += 2; continue }
                $mode = 'none'; $i++; continue
            }
            if ($c -eq '$' -and $next -eq '(') {
                $subStack.Push($depth)
                $depth++
                $inSub++
                $mode = 'none'
                $i += 2
                continue
            }
            $i++; continue
        }

        # ---- mode: none ----
        if ($c -eq '`') { $i += 2; continue }
        if ($c -eq '#') { break }                       # comment to end of line
        if ($c -eq "'") {
            # here-string opener? @' must be at end of line
            if ($i -gt 0 -and $line[$i - 1] -eq '@' -and $line.Substring($i + 1).Trim().Length -eq 0) {
                $mode = 'here'; $hereQuote = "'"; $i = $line.Length; continue
            }
            $mode = 'sq'; $i++; continue
        }
        if ($c -eq '"') {
            if ($i -gt 0 -and $line[$i - 1] -eq '@' -and $line.Substring($i + 1).Trim().Length -eq 0) {
                $mode = 'here'; $hereQuote = '"'; $i = $line.Length; continue
            }
            $mode = 'dq'; $i++; continue
        }
        if ($c -eq '(') { $depth++; $i++; continue }
        if ($c -eq ')') {
            $depth--
            if ($inSub -gt 0) {
                $inSub--
                $depth = $subStack.Pop()
                $mode = 'dq'
                $i++; continue
            }
            if ($depth -lt 0) {
                [void]$problems.Add("line ${lineNo}: depth went negative (extra ')')")
                $depth = 0
            }
            $i++; continue
        }
        $i++
    }

    if ($mode -eq 'sq' -or $mode -eq 'dq') {
        # a normal string must not span lines
        [void]$problems.Add("line ${lineNo}: unterminated $mode string opened on this line")
        $mode = 'none'
    }

    [void]$depthAtLine.Add($depth)
}

if ($depth -ne 0) {
    [void]$problems.Add("end of file: depth $depth (unclosed parentheses)")
}
if ($mode -eq 'here') {
    [void]$problems.Add("end of file: unterminated here-string")
}

if ($problems.Count -eq 0) {
    Write-Host "BALANCED   $([System.IO.Path]::GetFileName($Path))  ($($lines.Count) lines)" -ForegroundColor Green
    return $true
}

Write-Host "PROBLEMS in $([System.IO.Path]::GetFileName($Path)):" -ForegroundColor Red
foreach ($p in $problems) { Write-Host "  $p" -ForegroundColor Yellow }
return $false
