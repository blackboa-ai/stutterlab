# Monitor.ps1 — the timed sampling session.
#
# Samples once per second via a manual loop rather than one long Get-Counter
# call. The manual loop costs a little overhead but buys three things:
#   * all counters are sampled at the same instant, so CPU and disk spikes line up
#   * GPU instances can be aggregated per-adapter as they arrive
#   * a live progress readout is possible during a 60s wait
#
# Every series is stored raw so the report can chart it, plus summarised
# (mean/p95/max) for the rules engine.

# The fixed counter set. Kept as a literal array because a single misspelled
# counter name makes Get-Counter throw for the entire batch.
$script:MonitorCounters = @(
    '\Processor Information(*)\% Processor Time'
    '\Processor Information(_Total)\% DPC Time'
    '\Processor Information(_Total)\% Interrupt Time'
    '\Processor Information(_Total)\% Privileged Time'
    '\Processor Information(_Total)\DPCs Queued/sec'
    '\Processor Information(_Total)\% of Maximum Frequency'
    '\Processor Information(_Total)\Processor Frequency'
    '\Memory\Available MBytes'
    '\Memory\Pages/sec'
    '\Memory\% Committed Bytes In Use'
    '\PhysicalDisk(_Total)\Current Disk Queue Length'
    '\PhysicalDisk(_Total)\Avg. Disk sec/Transfer'
    '\PhysicalDisk(_Total)\Disk Bytes/sec'
    '\GPU Engine(*)\Utilization Percentage'
    '\GPU Adapter Memory(*)\Dedicated Usage'
)

function Get-ProcessCpuSnapshot {
    <# Returns pid -> cumulative CPU seconds, skipping processes that vanish. #>
    $map = @{}
    foreach ($p in (Get-Process -EA SilentlyContinue)) {
        try {
            $map[$p.Id] = @{ name = $p.ProcessName; cpu = $p.TotalProcessorTime.TotalSeconds }
        } catch { }
    }
    return $map
}

function Invoke-MonitorSession {
    param(
        [Parameter(Mandatory)][int]$Duration,
        [switch]$Quiet
    )

    Write-Log "Monitor session starting: ${Duration}s" -Level Info

    # Verify the counter set is readable before committing to a long run.
    $probe = Invoke-Safely 'monitor.probe' {
        Get-Counter -Counter $script:MonitorCounters -SampleInterval 1 -MaxSamples 1 -EA Stop | Out-Null
        $true
    }
    if (-not $probe.ok) {
        throw "Performance counters unavailable: $($probe.error)"
    }

    $before = Invoke-Safely 'monitor.procs.before' { Get-ProcessCpuSnapshot }
    if (-not $before.ok) { Write-Log 'Process snapshot failed; per-process CPU will be omitted' -Level Warn }

    $rows = New-Object System.Collections.ArrayList
    $failures = 0
    $start = Get-Date
    $deadline = $start.AddSeconds($Duration)
    $logical = [Environment]::ProcessorCount
    if ($logical -le 0) { $logical = 1 }

    # The counter engine will not sample faster than once per second, and each
    # read costs a few hundred milliseconds on top (the GPU Engine wildcard alone
    # expands to ~400 instances). Looping by wall clock instead of by iteration
    # count is what keeps "-Duration 10" near ten seconds rather than running for
    # twice that. Actual elapsed time and sample count are reported honestly.
    $i = 0
    while ((Get-Date) -lt $deadline) {
        $tickStart = Get-Date
        # A single retry. The counter engine occasionally reports a sample as
        # invalid (a provider raced the read, or an instance disappeared mid-call)
        # and the failure is transient. Losing a whole tick matters here because
        # a short run only has a handful of ticks to begin with.
        $sample = $null
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            try {
                $sample = Get-Counter -Counter $script:MonitorCounters -SampleInterval 1 -MaxSamples 1 -EA Stop
                break
            } catch {
                if ($attempt -eq 2) {
                    $failures++
                    Write-Log "Sample $i failed after retry: $($_.Exception.Message)" -Level Warn
                } else {
                    Write-Log "Sample $i invalid, retrying once: $($_.Exception.Message)" -Level Debug
                }
            }
        }
        if ($null -eq $sample) {
            $i++
            continue
        }

        $row = @{
            t           = [math]::Round(((Get-Date) - $start).TotalSeconds, 2)
            cpuTotal    = $null
            cpuCores    = @()
            dpc         = $null
            interrupt   = $null
            privileged  = $null
            dpcsQueued  = $null
            freqPct     = $null
            freqMhz     = $null
            memAvailMb  = $null
            pagesSec    = $null
            commitPct   = $null
            diskQueue   = $null
            diskLatMs   = $null
            diskBytesSec = $null
            gpuByEngine = @{}
            gpuByLuid   = @{}
            gpuDedicated = @{}
        }

        $coreValues = New-Object System.Collections.ArrayList

        foreach ($cs in $sample.CounterSamples) {
            $path = $cs.Path.ToLowerInvariant()
            $val = $cs.CookedValue

            # --- processor time: _total and per-core both arrive here ---------
            $m = [regex]::Match($path, '\\processor information\(([^)]+)\)\\% processor time$')
            if ($m.Success) {
                $inst = $m.Groups[1].Value
                if ($inst -eq '_total') { $row.cpuTotal = Round-Num $val 1 }
                else {
                    # Instances are formatted as "group,index"; take the index.
                    $parts = $inst -split ','
                    $idx = $parts[$parts.Count - 1]
                    [void]$coreValues.Add(@{ core = $idx; pct = (Round-Num $val 1) })
                }
                continue
            }

            if ($path -match '\\processor information\(_total\)\\% dpc time$') { $row.dpc = Round-Num $val 2; continue }
            if ($path -match '\\processor information\(_total\)\\% interrupt time$') { $row.interrupt = Round-Num $val 2; continue }
            if ($path -match '\\processor information\(_total\)\\% privileged time$') { $row.privileged = Round-Num $val 1; continue }
            if ($path -match '\\processor information\(_total\)\\dpcs queued/sec$') { $row.dpcsQueued = Round-Num $val 1; continue }
            if ($path -match '\\processor information\(_total\)\\% of maximum frequency$') { $row.freqPct = Round-Num $val 1; continue }
            if ($path -match '\\processor information\(_total\)\\processor frequency$') { $row.freqMhz = Round-Num $val 0; continue }

            if ($path -match '\\memory\\available mbytes$') { $row.memAvailMb = Round-Num $val 0; continue }
            if ($path -match '\\memory\\pages/sec$') { $row.pagesSec = Round-Num $val 1; continue }
            if ($path -match '\\memory\\% committed bytes in use$') { $row.commitPct = Round-Num $val 1; continue }

            if ($path -match '\\physicaldisk\(_total\)\\current disk queue length$') { $row.diskQueue = Round-Num $val 2; continue }
            if ($path -match '\\physicaldisk\(_total\)\\avg\. disk sec/transfer$') { $row.diskLatMs = Round-Num ($val * 1000) 2; continue }
            if ($path -match '\\physicaldisk\(_total\)\\disk bytes/sec$') { $row.diskBytesSec = Round-Num $val 0; continue }

            # --- GPU engine: sum utilisation per engine type and per adapter ----
            $g = [regex]::Match($path, '\\gpu engine\(pid_\d+_luid_(0x[0-9a-f]+_0x[0-9a-f]+)_phys_\d+_eng_\d+_engtype_(\w+)\)\\utilization percentage$')
            if ($g.Success) {
                $luid = $g.Groups[1].Value
                $eng = $g.Groups[2].Value
                if (-not $row.gpuByEngine.ContainsKey($eng)) { $row.gpuByEngine[$eng] = 0.0 }
                $row.gpuByEngine[$eng] += $val
                if (-not $row.gpuByLuid.ContainsKey($luid)) { $row.gpuByLuid[$luid] = 0.0 }
                $row.gpuByLuid[$luid] += $val
                continue
            }

            $gm = [regex]::Match($path, '\\gpu adapter memory\(luid_(0x[0-9a-f]+_0x[0-9a-f]+)_phys_\d+\)\\dedicated usage$')
            if ($gm.Success) {
                $row.gpuDedicated[$gm.Groups[1].Value] = $val
                continue
            }
        }

        # Collapse per-core data to the busiest core; per-core detail is noisy and
        # what matters for stutter is whether any one thread is pinned at 100%.
        # Note: $coreValues holds hashtables, and Measure-Object -Property cannot
        # read a hashtable key, so max/avg are computed by hand.
        $row.cpuCoreMax = $null
        $row.cpuCoreAvg = $null
        $row.cpuCores = @()
        if ($coreValues.Count -gt 0) {
            $maxPct = $null
            $sumPct = 0.0
            foreach ($cv in $coreValues) {
                $p = $cv['pct']
                if ($null -eq $p) { continue }
                $sumPct += [double]$p
                if ($null -eq $maxPct -or $p -gt $maxPct) { $maxPct = $p }
            }
            if ($null -ne $maxPct) {
                $row.cpuCoreMax = $maxPct
                $row.cpuCoreAvg = [math]::Round(($sumPct / $coreValues.Count), 1)
            }
            $row.cpuCores = @($coreValues | Sort-Object { $cv2 = $_; $cv2['pct'] } -Descending | Select-Object -First 1)
        }

        # Round GPU aggregates; engine-type sums can exceed 100% on multi-engine
        # adapters, which is expected and is why they stay separate from cpu.
        $eng = @{}
        foreach ($k in $row.gpuByEngine.Keys) { $eng[$k] = [math]::Round($row.gpuByEngine[$k], 1) }
        $row.gpuByEngine = $eng
        $lu = @{}
        foreach ($k in $row.gpuByLuid.Keys) { $lu[$k] = [math]::Round($row.gpuByLuid[$k], 1) }
        $row.gpuByLuid = $lu

        [void]$rows.Add($row)

        if (-not $Quiet) {
            $elapsed = [int](((Get-Date) - $start).TotalSeconds)
            $left = [math]::Max(0, $Duration - $elapsed)
            $mBar = if ($null -ne $row.cpuTotal) { '{0,3}%' -f [int]$row.cpuTotal } else { '  ?' }
            Write-Host ("`r  [2/4] Sampling {0,3}s remaining  cpu {1}  disk {2,6} ms  mem {3,4} MB   " -f `
                    $left, $mBar, ([int]($row.diskLatMs | ForEach-Object { if ($null -eq $_) { 0 } else { $_ } })), `
                    ([int]($row.memAvailMb | ForEach-Object { if ($null -eq $_) { 0 } else { $_ } }))) -NoNewline -ForegroundColor DarkGray
        }

        # Keep the cadence at one sample per second regardless of call overhead.
        $spent = ((Get-Date) - $tickStart).TotalMilliseconds
        $wait = 1000 - $spent
        if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) }
        $i++
    }

    Write-Host ''

    $after = Invoke-Safely 'monitor.procs.after' { Get-ProcessCpuSnapshot }

    $actual = ((Get-Date) - $start).TotalSeconds

    # ------------------------------------------------------------ summaries ---
    function Series($name) { @($rows | ForEach-Object { $_.$name }) }

    $summary = [ordered]@{
        duration      = $Duration
        actualSeconds = [math]::Round($actual, 1)
        sampleCount   = $rows.Count
        failures      = $failures
        logicalCpus   = $logical
    }

    foreach ($k in 'cpuTotal', 'cpuCoreMax', 'dpc', 'interrupt', 'privileged', 'dpcsQueued',
                   'freqPct', 'freqMhz', 'memAvailMb', 'pagesSec', 'commitPct',
                   'diskQueue', 'diskLatMs', 'diskBytesSec') {
        $summary[$k] = Get-Stats (Series $k)
    }

    # GPU series: total across engines per sample.
    $gpuTotal = @($rows | ForEach-Object {
            $sum = 0.0
            foreach ($v in $_.gpuByLuid.Values) { $sum += $v }
            [math]::Round($sum, 1)
        })
    $summary['gpuTotal'] = Get-Stats $gpuTotal

    # Identify the discrete adapter: the LUID that ever reported the most
    # dedicated (non-shared) memory is the dGPU. This is inferred, not read from
    # a name, so the report labels it honestly as "adapter with most dedicated VRAM".
    $luidMax = @{}
    foreach ($r in $rows) {
        foreach ($k in $r.gpuDedicated.Keys) {
            if (-not $luidMax.ContainsKey($k) -or $r.gpuDedicated[$k] -gt $luidMax[$k]) {
                $luidMax[$k] = $r.gpuDedicated[$k]
            }
        }
    }
    $discrete = $null
    if ($luidMax.Count) {
        $discrete = ($luidMax.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
    }
    $summary['gpuAdapterIds'] = @($luidMax.Keys)
    $summary['gpuDiscreteId'] = $discrete

    $gpuByAdapter = [ordered]@{}
    foreach ($luid in $luidMax.Keys) {
        $vals = @($rows | ForEach-Object { if ($_.gpuByLuid.ContainsKey($luid)) { $_.gpuByLuid[$luid] } else { 0 } })
        $gpuByAdapter[$luid] = Get-Stats $vals
    }
    $summary['gpuByAdapter'] = $gpuByAdapter

    $gpu3d = @($rows | ForEach-Object { if ($_.gpuByEngine.ContainsKey('3d')) { [math]::Round($_.gpuByEngine['3d'], 1) } else { 0 } })
    $summary['gpu3d'] = Get-Stats $gpu3d

    # --------------------------------------------------- per-process deltas ---
    $procCpu = @()
    if ($before.ok -and $after.ok -and $actual -gt 0) {
        $deltas = @()
        # NOTE: not $pid — that is a read-only automatic variable in PowerShell.
        foreach ($procId in $after.value.Keys) {
            if (-not $before.value.ContainsKey($procId)) { continue }
            $d = $after.value[$procId].cpu - $before.value[$procId].cpu
            if ($d -le 0) { continue }
            $deltas += @{
                name    = $after.value[$procId].name
                pid     = $procId
                cpuSec  = [math]::Round($d, 2)
                avgPct  = [math]::Round(($d / $actual / $logical) * 100, 1)
                corePct = [math]::Round(($d / $actual) * 100, 1)
            }
        }
        $procCpu = @($deltas | Sort-Object { $_.cpuSec } -Descending | Select-Object -First 15)
    }
    $summary['processCpu'] = $procCpu

    # ------------------------------------------------------------ hitch list --
    # Ticks where something was clearly wrong. The rules engine uses these counts;
    # the report shows them as spikes on the timeline.
    $flagged = @()
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        $reasons = @()
        if ($null -ne $r.diskLatMs -and $r.diskLatMs -ge 25) { $reasons += "disk ${($r.diskLatMs)}ms" }
        if ($null -ne $r.dpc -and $r.dpc -ge 5) { $reasons += "dpc $($r.dpc)%" }
        if ($null -ne $r.interrupt -and $r.interrupt -ge 2) { $reasons += "isr $($r.interrupt)%" }
        if ($null -ne $r.cpuTotal -and $r.cpuTotal -ge 95) { $reasons += "cpu $($r.cpuTotal)%" }
        if ($null -ne $r.memAvailMb -and $r.memAvailMb -le 1024) { $reasons += "mem $($r.memAvailMb)MB" }
        if ($null -ne $r.diskQueue -and $r.diskQueue -ge 2) { $reasons += "queue $($r.diskQueue)" }
        if ($reasons.Count) {
            $flagged += @{ t = $r.t; reasons = $reasons }
        }
    }
    $summary['flaggedTicks'] = $flagged
    $summary['flaggedCount'] = $flagged.Count

    Write-Log ("Monitor complete: {0} samples, {1} failures, {2} flagged ticks" -f $rows.Count, $failures, $flagged.Count) -Level Info

    return @{
        summary  = $summary
        samples  = $rows
    }
}
