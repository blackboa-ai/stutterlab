# Common.ps1 — logging, safety wrapper, small helpers.
# No state beyond the log path. Every other module depends on this one.

$script:LogPath = $null
$script:LogQuiet = $false

function Initialize-Log {
    param([Parameter(Mandatory)][string]$Path)
    $script:LogPath = $Path
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -EA SilentlyContinue }
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Debug', 'Info', 'Warn', 'Error')][string]$Level = 'Info'
    )
    if (-not $script:LogPath) { return }
    $line = '{0} [{1,-5}] {2}' -f (Get-Date).ToString('HH:mm:ss.fff'), $Level.ToUpper(), $Message
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
}

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

<#
    The core safety wrapper. Every collector call goes through Invoke-Safely so a
    single denied or broken data source degrades to a recorded failure instead of
    killing the run. This matters because Windows denies CIM/WMI hardware queries
    to non-elevated and sandboxed processes, and the tool must still produce a
    useful report from whatever it *can* read.
#>
function Invoke-Safely {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $value = & $Action
        $sw.Stop()
        Write-Log ("{0} ok ({1}ms)" -f $Name, $sw.ElapsedMilliseconds) -Level Debug
        return @{ ok = $true; value = $value; ms = $sw.ElapsedMilliseconds; error = $null }
    } catch {
        $sw.Stop()
        $msg = $_.Exception.Message
        if ($msg -match 'Access is denied|denied|UnauthorizedAccess|not authorized') {
            # Do not claim this needs elevation: a standard user can read most of
            # these WMI classes. Denial here means the calling process is confined
            # (sandbox, AppContainer, restricted token), so name that instead.
            if (Test-Admin) {
                $msg = 'Access denied (blocked by Windows, despite elevation)'
            } else {
                $msg = 'Access denied (blocked by process confinement or policy)'
            }
        }
        Write-Log ("{0} FAILED: {1}" -f $Name, $msg) -Level Warn
        return @{ ok = $false; value = $null; ms = $sw.ElapsedMilliseconds; error = $msg }
    }
}

# Pull .value out of an Invoke-Safely result, or a fallback.
function Get-Val {
    param($Result, $Default = $null)
    if ($null -eq $Result) { return $Default }
    if ($Result.ok) {
        if ($null -ne $Result.value) { return $Result.value }
    }
    return $Default
}

<#
    Safe property access. StrictMode makes missing members throw, and collected
    data is full of optional branches (a denied WMI query leaves a hole). This
    returns a default instead of exploding mid-report.
#>
function Get-Prop {
    param($Obj, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) {
            $v = $Obj[$Name]
            if ($null -ne $v) { return $v }
        }
        return $Default
    }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

# GlobalMemoryStatusEx reads total and available RAM without elevation, unlike
# Win32_PhysicalMemory, which is denied to a standard user. Add-Type is done once
# and cached; a failure returns $null so callers can degrade quietly.
$script:MemStatusReady = $false

function Get-MemoryStatus {
    if (-not $script:MemStatusReady) {
        $script:MemStatusReady = $true
        try {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class SLMemStatus {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public class MEMORYSTATUSEX {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
        public MEMORYSTATUSEX() { this.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX)); }
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX lpBuffer);
}
'@ -ErrorAction Stop
            $script:MemStatusOk = $true
        } catch {
            Write-Log "GlobalMemoryStatusEx unavailable: $($_.Exception.Message)" -Level Debug
            $script:MemStatusOk = $false
        }
    }
    if (-not $script:MemStatusOk) { return $null }
    try {
        $st = New-Object SLMemStatus+MEMORYSTATUSEX
        if (-not [SLMemStatus]::GlobalMemoryStatusEx($st)) { return $null }
        if ($st.ullTotalPhys -le 0) { return $null }
        return @{
            totalBytes = [double]$st.ullTotalPhys
            availBytes = [double]$st.ullAvailPhys
            loadPct    = [double]$st.dwMemoryLoad
        }
    } catch {
        return $null
    }
}

function Format-Bytes {
    param([Nullable[double]]$Bytes)
    if ($null -eq $Bytes -or $Bytes -le 0) { return '—' }
    $u = 'B', 'KB', 'MB', 'GB', 'TB'
    $i = 0; $v = [double]$Bytes
    while ($v -ge 1024 -and $i -lt 4) { $v /= 1024; $i++ }
    if ($i -eq 0) { return ('{0:N0} B' -f $v) }
    return ('{0:N1} {1}' -f $v, $u[$i])
}

function Format-Gb {
    param([Nullable[double]]$Bytes)
    if ($null -eq $Bytes) { return '—' }
    return ('{0:N1} GB' -f ($Bytes / 1GB))
}

# Round to N decimals, tolerating nulls (StrictMode complains otherwise).
function Round-Num {
    param($Value, [int]$Digits = 1)
    if ($null -eq $Value) { return $null }
    return [math]::Round([double]$Value, $Digits)
}

# Plain number for display, with an em dash for "we did not get this".
function Format-Number {
    param($Value, [string]$Format = 'N0')
    if ($null -eq $Value) { return '—' }
    try { return ([double]$Value).ToString($Format, [System.Globalization.CultureInfo]::InvariantCulture) }
    catch { return '—' }
}

function Get-Percentile {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][double[]]$Values,
        [Parameter(Mandatory)][double]$P
    )
    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 1) { return $sorted[0] }
    $idx = ($P / 100.0) * ($sorted.Count - 1)
    $lo = [math]::Floor($idx); $hi = [math]::Ceiling($idx)
    if ($lo -eq $hi) { return $sorted[[int]$lo] }
    $frac = $idx - $lo
    return $sorted[[int]$lo] * (1 - $frac) + $sorted[[int]$hi] * $frac
}

# Mean/min/max/p95/median for a numeric series, null-safe.
function Get-Stats {
    param([AllowEmptyCollection()]$Values)
    $nums = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($nums.Count -eq 0) {
        return @{ count = 0; mean = $null; min = $null; max = $null; p50 = $null; p95 = $null }
    }
    $m = ($nums | Measure-Object -Average -Minimum -Maximum)
    return @{
        count = $nums.Count
        mean  = [math]::Round($m.Average, 2)
        min   = [math]::Round($m.Minimum, 2)
        max   = [math]::Round($m.Maximum, 2)
        p50   = [math]::Round((Get-Percentile -Values $nums -P 50), 2)
        p95   = [math]::Round((Get-Percentile -Values $nums -P 95), 2)
    }
}
