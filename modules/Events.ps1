# Events.ps1 — event log correlation.
#
# Live counters show load; the event log shows failures. A display driver reset
# (TDR) or a storage retry is a frame-time spike that no sampling loop will
# catch unless it happens to fire inside the sampling window. Correlating the last
# 7 days catches what the 60-second window misses.

# Each entry: log name, id list, friendly label, why it stutters, severity.
$script:EventRules = @(
    @{ log = 'System'; ids = @(4101, 4103); label = 'Display driver reset (TDR)'
       detail = 'The GPU stopped responding and Windows reset it. The screen freezes for 2+ seconds while this happens.'
       severity = 'critical'; category = 'gpu' }

    @{ log = 'System'; ids = @(7, 11, 51, 153); label = 'Storage error'
       detail = 'A read or write to the drive failed and was retried. Retries stall asset streaming for tens of milliseconds.'
       severity = 'critical'; category = 'storage' }

    @{ log = 'System'; ids = @(129); label = 'Storage controller reset'
       detail = 'The disk controller reset a device. Every pending I/O waits for it to come back.'
       severity = 'critical'; category = 'storage' }

    @{ log = 'System'; ids = @(17, 18, 19, 20, 47); label = 'Hardware error (WHEA)'
       detail = 'The CPU, memory, or PCIe bus reported a corrected hardware error. Corrected errors usually mean a failing component.'
       severity = 'critical'; category = 'hardware' }

    @{ log = 'System'; ids = @(41); label = 'Unexpected shutdown'
       detail = 'The machine lost power or hard-locked without shutting down cleanly. Repeats point at a PSU or thermal problem.'
       severity = 'warn'; category = 'hardware' }

    @{ log = 'System'; ids = @(6008); label = 'Unexpected shutdown (logged)'
       detail = 'The previous shutdown was not clean. Correlates with event 41.'
       severity = 'warn'; category = 'hardware' }

    @{ log = 'System'; ids = @(1001); label = 'Bug check (blue screen)'
       detail = 'The system crashed. Kernel faults usually originate in a driver.'
       severity = 'critical'; category = 'hardware' }

    @{ log = 'Application'; ids = @(1000); label = 'Application crash'
       detail = 'A program crashed. If it is your game, this is the cause, not a symptom.'
       severity = 'info'; category = 'software' }

    @{ log = 'Application'; ids = @(1002); label = 'Application hang'
       detail = 'A program stopped responding. Hangs in a game usually mean an unresponsive driver or a stalled I/O.'
       severity = 'info'; category = 'software' }

    @{ log = 'System'; ids = @(219); label = 'Driver load failure'
       detail = 'A driver failed to load. A driver that half-initialises can cause intermittent stalls.'
       severity = 'warn'; category = 'driver' }
)

function Get-EventCorrelation {
    param([int]$Days = 7)

    $start = (Get-Date).AddDays(-$Days)
    $found = New-Object System.Collections.ArrayList
    $perRule = [ordered]@{}

    foreach ($rule in $script:EventRules) {
        $key = $rule.label
        $result = Invoke-Safely "events.$($rule.category).$($rule.ids -join '_')" {
            $filter = @{
                LogName      = $rule.log
                Id           = $rule.ids
                StartTime    = $start
                ErrorAction  = 'Stop'
            }
            # Get-WinEvent throws when a filter matches nothing. That is the normal
            # case for rare events (a healthy machine has no TDRs or bug checks),
            # so it is swallowed here rather than surfacing as a collector failure.
            $events = @()
            try {
                $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents 200 -EA Stop)
            } catch {
                if ($_.Exception.Message -notmatch 'No events were found|No matching events') { throw }
            }
            $mapped = @($events | ForEach-Object {
                @{
                    time     = $_.TimeCreated.ToString('o')
                    id       = $_.Id
                    source   = $_.ProviderName
                    message  = (($_.Message -split "`r?`n")[0]).Trim()
                }
            })
            $mapped
        }

        if (-not $result.ok) {
            # "No events were found" is a clean result, not a failure.
            $isClean = $result.error -match 'No events were found|No matching events'
            $perRule[$key] = @{
                label    = $rule.label
                severity = $rule.severity
                category = $rule.category
                detail   = $rule.detail
                count    = 0
                ok       = $isClean
                error    = if ($isClean) { $null } else { $result.error }
                events   = @()
            }
            continue
        }

        $evts = @($result.value)
        $perRule[$key] = @{
            label    = $rule.label
            severity = $rule.severity
            category = $rule.category
            detail   = $rule.detail
            count    = $evts.Count
            ok       = $true
            error    = $null
            events   = @($evts | Sort-Object { $_.time } -Descending | Select-Object -First 10)
        }

        foreach ($e in $evts) {
            [void]$found.Add(@{
                    time     = $e.time
                    id       = $e.id
                    source   = $e.source
                    label    = $rule.label
                    severity = $rule.severity
                    category = $rule.category
                    message  = $e.message
                })
        }
    }

    return @{
        windowDays = $Days
        since      = $start.ToString('o')
        totalCount = $found.Count
        byRule     = $perRule
        events     = @($found | Sort-Object { $_.time } -Descending | Select-Object -First 60)
    }
}
