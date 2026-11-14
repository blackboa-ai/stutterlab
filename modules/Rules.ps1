# Rules.ps1 — the rules engine.
#
# Every rule answers three questions, in this order:
#   1. Is this abnormal?          (threshold, documented in docs/SCOPE.md)
#   2. Why does it cause stutter? (the mechanism, in plain English)
#   3. What would fix it?         (advice only — nothing is applied)
#
# A finding without a credible mechanism behind it is noise, so rules that cannot
# explain themselves are deliberately absent.

function New-Finding {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][ValidateSet('critical', 'warn', 'info', 'ok')][string]$Severity,
        [Parameter(Mandatory)][string]$Category,
        [string]$Summary = '',
        [string]$Why = '',
        [string[]]$Evidence = @(),
        [string]$Action = ''
    )
    return [ordered]@{
        id       = $Id
        title    = $Title
        severity = $Severity
        category = $Category
        summary  = $Summary
        why      = $Why
        evidence = @($Evidence)
        action   = $Action
    }
}

function Num {
    param($Value)
    if ($null -eq $Value) { return $null }
    try { return [double]$Value } catch { return $null }
}

# ============================================================ static facts =====

function Get-StaticFindings {
    param($Facts)
    $out = New-Object System.Collections.ArrayList

    # ---------------------------------------------------------------- memory --
    $mem = Get-Prop $Facts 'memory'
    $sticks = @(Get-Prop $mem 'sticks' @())
    $stickCount = Get-Prop $mem 'stickCount' 0
    $totalBytes = Num (Get-Prop $mem 'totalBytes')

    # Capacity is knowable even when per-stick detail is not: GlobalMemoryStatusEx
    # reports the total without elevation, whereas Win32_PhysicalMemory does not.
    # Keep this check outside the stickCount guard so a denied inventory does not
    # silently hide a machine that is short on RAM.
    if ($totalBytes -and $totalBytes -lt 15GB) {
        $slotNote = if ($stickCount -ge 1) { "Sticks populated: $stickCount" } else { 'Per-stick layout unavailable without elevation' }
        [void]$out.Add((New-Finding `
                    -Id 'ram-capacity-low' -Title 'Memory capacity is tight for gaming' `
                    -Severity 'warn' -Category 'memory' `
                    -Summary "$(Format-Gb $totalBytes) installed" `
                    -Why 'Modern games expect 16 GB. At 8 GB, Windows keeps the game in memory but pushes everything else to the page file, and background work that touches paged memory pulls the disk into the frame path. The visible effect is stutter that gets worse the longer you play, as the working set grows.' `
                    -Evidence @("Installed: $(Format-Gb $totalBytes)", $slotNote) `
                    -Action 'Upgrade to 16 GB (2 x 8 GB) if possible. Check the slot count before buying: a single 8 GB stick in a 2-slot laptop means one free slot.'))
    }

    if ($stickCount -ge 1) {
        $ratedList = @($sticks | ForEach-Object { Num (Get-Prop $_ 'speedRated') } | Where-Object { $null -ne $_ })
        $confList = @($sticks | ForEach-Object { Num (Get-Prop $_ 'speedConfig') } | Where-Object { $null -ne $_ })
        $rated = if ($ratedList.Count) { ($ratedList | Measure-Object -Maximum).Maximum } else { $null }
        $conf = if ($confList.Count) { ($confList | Measure-Object -Maximum).Maximum } else { $null }

        if ($stickCount -eq 1) {
            [void]$out.Add((New-Finding `
                        -Id 'ram-single-channel' -Title 'Single memory stick (single-channel)' `
                        -Severity 'warn' -Category 'memory' `
                        -Summary "1 stick installed, $(Format-Gb $totalBytes) total" `
                        -Why 'Two sticks let the memory controller read and write at the same time. With one stick, memory bandwidth is roughly halved. Games that stream textures and geometry are the workloads that notice this first, and the symptom is exactly what you would call stutter: brief stalls when new content is pulled in, worst while moving through a level or turning quickly.' `
                        -Evidence @("Slots populated: $stickCount", "Total: $(Format-Gb $totalBytes)", "Rated speed: $(if ($rated) { "$rated MT/s" } else { 'unknown' })") `
                        -Action 'Add a second matching 8 GB stick. This is the single highest-value hardware change for a machine in this state. Nothing in software fixes half the memory bandwidth.'))
        }

        if ($rated -and $conf -and $conf -lt $rated) {
            [void]$out.Add((New-Finding `
                        -Id 'ram-below-rated' -Title 'Memory running below its rated speed' `
                        -Severity 'warn' -Category 'memory' `
                        -Summary "Running at $conf MT/s, rated for $rated MT/s" `
                        -Why 'The sticks are capable of more than the memory controller is currently giving them, which means XMP/EXPO is off and the BIOS is using the JEDEC fallback speed. The result is lower bandwidth and higher latency than the hardware can do — the same class of problem as single-channel, just smaller in magnitude.' `
                        -Evidence @("Rated: $rated MT/s", "Configured: $conf MT/s") `
                        -Action 'Enable XMP (Intel) or EXPO/DOCP (AMD) in the BIOS. If the machine is unstable after enabling it, step down one speed rather than turning it off.'))
        }
    }

    # ----------------------------------------------------------------- power --
    $power = Get-Prop $Facts 'power'
    $planName = Get-Prop $power 'name'
    $planGuid = Get-Prop $power 'guid'
    $minState = Num (Get-Prop $power 'processorMinState')

    if ($planName) {
        $isHighPerf = $planGuid -in @('8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c', 'e9a42b02-d5df-448d-aa00-03f14749eb61')
        if (-not $isHighPerf) {
            [void]$out.Add((New-Finding `
                        -Id 'power-plan-balanced' -Title "Power plan is '$planName'" `
                        -Severity 'warn' -Category 'power' `
                        -Summary "Active plan: $planName" `
                        -Why 'Balanced lets Windows park cores and drop clocks to save power. The transition back up takes milliseconds, and a frame that arrives during that ramp misses its deadline. This is the mechanism behind the classic "first few seconds of a level are choppy, then it smooths out" pattern.' `
                        -Evidence @("Plan: $planName", "GUID: $planGuid") `
                        -Action 'Switch to High Performance (or Ultimate Performance) in Settings > System > Power. On a laptop, expect more heat and less battery life.'))
        }
    }

    if ($null -ne $minState -and $minState -le 5) {
        [void]$out.Add((New-Finding `
                    -Id 'power-min-processor-state' -Title "Processor minimum state is $minState%" `
                    -Severity 'warn' -Category 'power' `
                    -Summary "Minimum processor state: $minState%" `
                    -Why 'At a low minimum state the CPU is allowed to idle deeply. When a game thread suddenly needs cycles, the core has to wake and ramp before it can deliver them. The cost is paid in exactly the moment that matters: a spike in required work.' `
                    -Evidence @("Minimum processor state (AC): $minState%") `
                    -Action 'In the active power plan, set Processor power management > Minimum processor state to 50-100% on AC power.'))
    }

    $usbSuspend = Num (Get-Prop $power 'usbSelectiveSuspend')
    if ($null -ne $usbSuspend -and $usbSuspend -eq 1) {
        [void]$out.Add((New-Finding `
                    -Id 'power-usb-suspend' -Title 'USB selective suspend is enabled' `
                    -Severity 'info' -Category 'power' `
                    -Summary 'USB devices may be suspended when idle' `
                    -Why 'With selective suspend on, an idle controller or peripheral can be powered down. Waking it takes long enough to be felt as a hitch the moment you move the mouse or press a key after a pause. It also contributes to DPC activity while devices re-enumerate.' `
                    -Evidence @('USB selective suspend (AC): enabled') `
                    -Action 'Set USB settings > USB selective suspend to Disabled in the active power plan. Optional: only act on this if you notice input hitches.'))
    }

    # ---------------------------------------------------------- virtualisation --
    $tweaks = Get-Prop $Facts 'tweaks'
    $vbs = Num (Get-Prop $tweaks 'vbsStatus')
    $vbsSvc = @(Get-Prop $tweaks 'vbsServices' @())
    $hvci = Num (Get-Prop $tweaks 'hvciEnabled')

    $hvciRunning = ($vbsSvc -contains 2) -or ($hvci -eq 1)
    if ($vbs -eq 2 -or $hvciRunning) {
        $svcNames = @()
        if ($vbsSvc -contains 1) { $svcNames += 'Credential Guard' }
        if (($vbsSvc -contains 2) -or ($hvci -eq 1)) { $svcNames += 'Memory integrity (HVCI)' }
        [void]$out.Add((New-Finding `
                    -Id 'vbs-hvci' -Title 'Virtualisation-based security is running' `
                    -Severity 'warn' -Category 'security' `
                    -Summary ("Running: " + ($svcNames -join ', ')) `
                    -Why 'VBS runs a hypervisor underneath Windows, and memory integrity (HVCI) validates kernel code paths in that hypervisor. Every kernel transition the game makes is more expensive than it would be on bare metal. It is not a dramatic slowdown in average FPS, but it is a consistent tax on the code the render thread executes most often, and it can widen the tail of the frame-time distribution.' `
                    -Evidence (@("VBS status: $(if ($vbs -eq 2) { 'enabled and running' } elseif ($vbs -eq 1) { 'enabled, not running' } else { 'unknown' })") + @("Hypervisor services: $($vbsSvc -join ', ')") + @("HVCI registry: $(if ($null -ne $hvci) { $hvci } else { 'not set' })")) `
                    -Action 'Turning this off is a real security trade-off, not a free win. Only consider it if your other findings are clean and you accept the reduced protection (Windows Security > Device security > Core isolation).'))
    }

    # ------------------------------------------------------------------- gpu --
    $gpu = Get-Prop $Facts 'gpu'
    $cards = @(Get-Prop $gpu 'cards' @())
    $discrete = @($cards | Where-Object { $n = [string](Get-Prop $_ 'name'); $n -notmatch 'Intel|Radeon\(TM\) Graphics|Basic Display|Microsoft' })
    $igpu = @($cards | Where-Object { $n = [string](Get-Prop $_ 'name'); $n -match 'Intel|Radeon\(TM\) Graphics' })

    foreach ($c in $cards) {
        $dateStr = Get-Prop $c 'driverDate'
        if ($dateStr) {
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse($dateStr, [ref]$parsed)) {
                $ageDays = ((Get-Date) - $parsed).Days
                if ($ageDays -gt 365) {
                    [void]$out.Add((New-Finding `
                                -Id ("gpu-driver-old-" + ($c.name -replace '[^a-zA-Z0-9]', '')) `
                                -Title "Outdated GPU driver: $($c.name)" `
                                -Severity 'warn' -Category 'gpu' `
                                -Summary "Driver dated $dateStr ($ageDays days old)" `
                                -Why 'Game-specific performance fixes ship inside GPU drivers. A driver a year or more old is missing every optimisation, shader-compilation fix, and stutter workaround released since. Stutter in a newer game is frequently a driver issue before it is a hardware one.' `
                                -Evidence @("Card: $($c.name)", "Driver version: $(Get-Prop $c 'driverVer')", "Driver date: $dateStr") `
                                -Action 'Update the driver from the vendor (NVIDIA GeForce Experience or AMD Software). Prefer a clean install, since leftover settings from an old branch cause their own problems.'))
                }
            }
        }
    }

    if ($discrete.Count -ge 1 -and $igpu.Count -ge 1) {
        $dName = (Get-Prop $discrete[0] 'name')
        $iName = (Get-Prop $igpu[0] 'name')
        [void]$out.Add((New-Finding `
                    -Id 'gpu-dual-adapter' -Title 'Two graphics adapters present' `
                    -Severity 'info' -Category 'gpu' `
                    -Summary "$dName + $iName" `
                    -Why 'A laptop with an integrated and a discrete GPU sends work to one or the other depending on the app. If a game is routed to the integrated adapter it runs far below the discrete card''s capability, and if the display is wired through the integrated adapter, frames are copied across before they are shown. Both look like stutter rather than low FPS.' `
                    -Evidence @("Discrete: $dName", "Integrated: $iName") `
                    -Action 'In the NVIDIA Control Panel, set the game to use the high-performance NVIDIA processor. Also check the game''s own graphics settings for an adapter selector.'))
    }

    # --------------------------------------------------------------- display --
    $disp = Get-Prop $Facts 'display'
    $modes = @(Get-Prop $disp 'modes' @())
    $bestRefresh = Num (Get-Prop $disp 'maxRefresh')
    $curRefresh = $null
    $curW = $null; $curH = $null
    foreach ($c in $cards) {
        $r = Num (Get-Prop $c 'refresh'); $w = Num (Get-Prop $c 'width'); $h = Num (Get-Prop $c 'height')
        if ($r -and (-not $curRefresh -or $r -gt $curRefresh)) { $curRefresh = $r; $curW = $w; $curH = $h }
    }

    if ($curRefresh -and $bestRefresh -and $curRefresh -lt $bestRefresh -and $bestRefresh -ge 100) {
        [void]$out.Add((New-Finding `
                    -Id 'display-refresh' -Title "Display running at $curRefresh Hz, panel supports $bestRefresh Hz" `
                    -Severity 'warn' -Category 'display' `
                    -Summary "$([int]$curW)x$([int]$curH) @ $curRefresh Hz" `
                    -Why 'Every frame is held on screen for a full refresh interval. At 60 Hz that interval is 16.7 ms even when the frame is ready sooner, so the game looks and feels worse than it is running. It does not create new stutter, but it makes existing frame-time variation more visible and reduces how smooth the good frames feel.' `
                    -Evidence @("Current mode: $([int]$curW)x$([int]$curH) @ $curRefresh Hz", "Panel maximum: $bestRefresh Hz") `
                    -Action 'Set the refresh rate in Settings > System > Display > Advanced display. If the option is missing, install the monitor''s driver or check the cable (HDMI 1.4 caps 120 Hz at 1080p).'))
    }

    # ----------------------------------------------------------------- disks --
    $disks = Get-Prop $Facts 'disks'
    $phys = @(Get-Prop $disks 'physical' @())
    $vols = @(Get-Prop $disks 'volumes' @())

    foreach ($p in $phys) {
        $media = ([string](Get-Prop $p 'mediaType')).Trim()
        if ($media -match 'HDD|Unspecified' -and ([string](Get-Prop $p 'busType')) -match 'SATA|ATA|RAID') {
            [void]$out.Add((New-Finding `
                        -Id ("disk-hdd-" + (Get-Prop $p 'friendlyName' -replace '[^a-zA-Z0-9]', '')) `
                        -Title "Mechanical drive installed: $(Get-Prop $p 'friendlyName')" `
                        -Severity 'warn' -Category 'storage' `
                        -Summary "$(Format-Bytes (Num (Get-Prop $p 'size'))) $media drive" `
                        -Why 'A hard disk needs several milliseconds to seek, and during that time any read blocks. Games that stream assets hit seek latency constantly. This shows up as a stutter every time the game loads something new, and it is the single most common cause of streaming hitches.' `
                        -Evidence @("Device: $(Get-Prop $p 'friendlyName')", "Media: $media", "Bus: $(Get-Prop $p 'busType')") `
                        -Action 'Move the game to an SSD. If the game must stay on the hard disk, check whether the drive is the one being hammered during the stutter by looking at the disk section of the report.'))
        }

        $health = [string](Get-Prop $p 'health')
        if ($health -and $health -ne 'Healthy') {
            [void]$out.Add((New-Finding `
                        -Id ("disk-health-" + (Get-Prop $p 'friendlyName' -replace '[^a-zA-Z0-9]', '')) `
                        -Title "Drive reports $health health" `
                        -Severity 'critical' -Category 'storage' `
                        -Summary "$(Get-Prop $p 'friendlyName'): $health" `
                        -Why 'A drive with pending failures retries and remaps sectors, and every retry is an I/O that takes far longer than normal. On the game''s asset path that is experienced as a freeze. This is also the finding that matters most before anything else: a failing drive can end in data loss.' `
                        -Evidence @("Device: $(Get-Prop $p 'friendlyName')", "Health: $health", "Operational: $(Get-Prop $p 'operational')") `
                        -Action 'Back up now, then check the drive with the manufacturer''s tool (CrystalDiskInfo for SMART detail). Replace the drive before tuning anything else.'))
        }
    }

    foreach ($v in $vols) {
        $freePct = Num (Get-Prop $v 'freePct')
        $size = Num (Get-Prop $v 'size')
        if ($null -ne $freePct -and $freePct -lt 10 -and $size -gt 32GB) {
            [void]$out.Add((New-Finding `
                        -Id ("disk-free-" + ([string](Get-Prop $v 'letter') -replace '[^a-zA-Z0-9]', '')) `
                        -Title "Volume $(Get-Prop $v 'letter') is $freePct% free" `
                        -Severity 'warn' -Category 'storage' `
                        -Summary "$(Format-Gb (Num (Get-Prop $v 'free'))) free of $(Format-Gb $size)" `
                        -Why 'An SSD needs free space to spread writes and to run TRIM. Below about 10% the drive has few spare blocks, so every write must first erase, which is slower and less predictable. The game does not slow down uniformly; it hitches when it writes.' `
                        -Evidence @("Volume: $(Get-Prop $v 'letter') $(Get-Prop $v 'label')", "Free: $(Format-Gb (Num (Get-Prop $v 'free'))) / $(Format-Gb $size) ($freePct%)") `
                        -Action 'Free up at least 15% of the volume. Removing old game installs and Windows.old is usually enough.'))
        }
    }

    # -------------------------------------------------------------- pagefile --
    $pf = Get-Prop $Facts 'pagefile'
    $pfSettings = @(Get-Prop $pf 'settings' @())
    $pfUsage = @(Get-Prop $pf 'usage' @())
    $pfAuto = Get-Prop $pf 'automaticManaged'

    $pfAllocMb = 0
    foreach ($u in $pfUsage) { $a = Num (Get-Prop $u 'allocMb'); if ($a) { $pfAllocMb += $a } }

    if ($pfSettings.Count -eq 0 -and $pfUsage.Count -eq 0 -and $pfAuto -eq $false) {
        [void]$out.Add((New-Finding `
                    -Id 'pagefile-disabled' -Title 'Page file is disabled' `
                    -Severity 'critical' -Category 'memory' `
                    -Summary 'No page file configured' `
                    -Why 'With no page file, Windows cannot back committed memory with disk. When a game or a background process asks for memory it cannot get, the allocation fails or the system trims working sets aggressively, and the result is a hard stall rather than a slowdown. Some games also crash outright in this configuration.' `
                    -Evidence @('Automatic management: disabled', 'No page file settings found') `
                    -Action 'Re-enable a system-managed page file in System Properties > Advanced > Performance > Advanced > Virtual memory.'))
    } elseif ($pfAllocMb -gt 0 -and $pfAllocMb -lt 2048) {
        [void]$out.Add((New-Finding `
                    -Id 'pagefile-small' -Title "Page file is small ($pfAllocMb MB)" `
                    -Severity 'info' -Category 'memory' `
                    -Summary "$pfAllocMb MB allocated" `
                    -Why 'A small page file limits how much total memory the system can commit. On a machine with limited RAM, that ceiling is reached during heavy scenes, and reaching it forces working-set trimming in the middle of a frame.' `
                    -Evidence @("Allocated: $pfAllocMb MB") `
                    -Action 'Let Windows manage the page file size, or set it to at least 1.5x installed RAM.'))
    }

    # ---------------------------------------------------------- gaming switches --
    $gameDvr = Num (Get-Prop $tweaks 'gameDvr')
    if ($gameDvr -eq 1) {
        [void]$out.Add((New-Finding `
                    -Id 'game-dvr-enabled' -Title 'Game DVR background recording is on' `
                    -Severity 'warn' -Category 'software' `
                    -Summary 'GameDVR_Enabled = 1' `
                    -Why 'Background recording captures and encodes the frame buffer continuously while you play. The encode runs on the same GPU and the copy runs over the same memory bus the game is using. The cost is a steady overhead plus periodic spikes when the encoder flushes.' `
                    -Evidence @('HKCU\System\GameConfigStore\GameDVR_Enabled = 1') `
                    -Action 'Turn off background recording in Settings > Gaming > Captures.'))
    }

    $appCapture = Num (Get-Prop $tweaks 'appCapture')
    if ($appCapture -eq 1) {
        [void]$out.Add((New-Finding `
                    -Id 'game-capture-enabled' -Title 'Game capture is enabled' `
                    -Severity 'info' -Category 'software' `
                    -Summary 'AppCaptureEnabled = 1' `
                    -Why 'The Game Bar capture hook stays resident and can be triggered by a stray Win+G or a controller button. When it activates, it competes for GPU time exactly when the frame budget is already tight.' `
                    -Evidence @('HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR\AppCaptureEnabled = 1') `
                    -Action 'Disable Game Bar capture if you do not use it. Keep the Game Bar itself if you like the overlay.'))
    }

    $gameMode = Num (Get-Prop $tweaks 'gameMode')
    if ($gameMode -eq 0) {
        [void]$out.Add((New-Finding `
                    -Id 'game-mode-off' -Title 'Game Mode is disabled' `
                    -Severity 'info' -Category 'software' `
                    -Summary 'AutoGameModeEnabled = 0' `
                    -Why 'Game Mode suppresses background work while a game is in the foreground. With it off, Windows Update, indexing, and other scheduled tasks keep their normal priority during play.' `
                    -Evidence @('HKCU\Software\Microsoft\GameBar\AutoGameModeEnabled = 0') `
                    -Action 'Enable Game Mode in Settings > Gaming > Game Mode.'))
    }

    $hags = Num (Get-Prop $tweaks 'hags')
    if ($null -ne $hags) {
        $state = if ($hags -eq 2) { 'enabled' } else { 'disabled' }
        [void]$out.Add((New-Finding `
                    -Id 'hags-state' -Title "Hardware-accelerated GPU scheduling is $state" `
                    -Severity 'info' -Category 'gpu' `
                    -Summary "HwSchMode = $hags ($state)" `
                    -Why 'HAGS moves frame submission from the CPU to the GPU''s own scheduler. It helps some configurations and hurts others, and the difference is usually visible as smoother frame pacing either way. It is worth knowing which way this machine is set before changing it, because the effect is configuration-specific rather than universally good.' `
                    -Evidence @("HwSchMode = $hags") `
                    -Action 'If you are chasing frame pacing, this is a legitimate variable to test: change it, reboot, and compare. Do not change more than one variable at a time.'))
    }

    $visualFx = Num (Get-Prop $tweaks 'visualFx')
    if ($visualFx -eq 1 -or $visualFx -eq 3) {
        [void]$out.Add((New-Finding `
                    -Id 'visual-effects' -Title 'Visual effects set to appearance over performance' `
                    -Severity 'info' -Category 'software' `
                    -Summary "VisualFXSetting = $visualFx" `
                    -Why 'Window animations, shadows, and transparency are drawn by the desktop compositor, which shares the GPU with the game. The cost is small in isolation but it is present in every frame, and it competes with the frame that is already late.' `
                    -Evidence @("VisualFXSetting = $visualFx (1 = best appearance, 3 = custom)") `
                    -Action 'Set System Properties > Advanced > Performance > Adjust for best performance, then re-enable the two font-smoothing options so text stays readable.'))
    }

    $trimDisabled = Get-Prop $tweaks 'trimDisabled'
    if ($trimDisabled -eq $true) {
        [void]$out.Add((New-Finding `
                    -Id 'trim-disabled' -Title 'TRIM is disabled' `
                    -Severity 'warn' -Category 'storage' `
                    -Summary 'DisableDeleteNotify = 1' `
                    -Why 'Without TRIM, the SSD does not know which blocks are free, so writes must erase before writing. Over time this makes the drive slower and less consistent, and inconsistent storage is exactly what produces occasional hitches rather than uniform slowness.' `
                    -Evidence @('fsutil behavior query DisableDeleteNotify reports 1') `
                    -Action 'Run "fsutil behavior set DisableDeleteNotify 0" in an elevated prompt.'))
    }

    $fastStartup = Num (Get-Prop $tweaks 'fastStartup')
    if ($fastStartup -eq 1) {
        [void]$out.Add((New-Finding `
                    -Id 'fast-startup' -Title 'Fast startup is enabled' `
                    -Severity 'info' -Category 'software' `
                    -Summary 'HiberbootEnabled = 1' `
                    -Why 'Fast startup does not fully shut down; it hibernates the kernel and reloads it. Drivers keep the state they had when hibernated, so a driver that was misbehaving before shutdown stays misbehaving after boot. When diagnosing intermittent stutter, this makes "reboot and retest" unreliable.' `
                    -Evidence @('HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Power\HiberbootEnabled = 1') `
                    -Action 'Disable fast startup while diagnosing (Control Panel > Power Options > Choose what the power buttons do). Use Restart rather than Shut down in the meantime, since Restart is always a full boot.'))
    }

    $pending = Get-Prop $tweaks 'pendingReboot'
    if ($pending -eq $true) {
        [void]$out.Add((New-Finding `
                    -Id 'pending-reboot' -Title 'A reboot is pending' `
                    -Severity 'info' -Category 'software' `
                    -Summary 'Windows Update has staged changes' `
                    -Why 'Staged updates can leave installation work queued that runs after the next boot, which competes with a game session. Reporting is also less reliable while the system is mid-update.' `
                    -Evidence @('RebootPending / RebootRequired registry keys present') `
                    -Action 'Reboot, then re-run this tool so the baseline is clean.'))
    }

    # -------------------------------------------------------------- startup --
    $startup = Get-Prop $Facts 'startup'
    $startupItems = @(Get-Prop $startup 'items' @())
    if ($startupItems.Count -gt 8) {
        [void]$out.Add((New-Finding `
                    -Id 'startup-heavy' -Title "$($startupItems.Count) programs start with Windows" `
                    -Severity 'info' -Category 'software' `
                    -Summary (($startupItems | Select-Object -First 4 | ForEach-Object { Get-Prop $_ 'name' }) -join ', ') `
                    -Why 'Startup entries are not just a boot-time cost. Each one leaves a process and usually an updater or tray icon that wakes on a timer. Timed background work is the worst kind for gaming, because it fires whenever its schedule says so, including mid-frame.' `
                    -Evidence @($startupItems | Select-Object -First 10 | ForEach-Object { "$(Get-Prop $_ 'name') -> $(Get-Prop $_ 'cmd')" }) `
                    -Action 'Disable what you do not need in Task Manager > Startup. Prioritise anything with "update", "sync", or "assistant" in the name.'))
    }

    # ------------------------------------------------------------ antivirus --
    $av = Get-Prop $Facts 'antivirus'
    $avProducts = @(Get-Prop $av 'products' @())
    if ($avProducts.Count -gt 0) {
        [void]$out.Add((New-Finding `
                    -Id 'antivirus-active' -Title "Real-time protection active: $($avProducts -join ', ')" `
                    -Severity 'info' -Category 'security' `
                    -Summary ($avProducts -join ', ') `
                    -Why 'Real-time scanning intercepts file reads. When a game loads an asset, the scan runs before the read completes. A well-behaved product costs almost nothing; one that scans large game directories on every access causes measurable stalls. It is worth knowing which product is in the path before blaming the disk.' `
                    -Evidence @($avProducts | ForEach-Object { "Product: $_" }) `
                    -Action 'Do not disable protection. If you suspect scanning is the cause, exclude the game''s install folder and its save directory rather than turning protection off.'))
    }

    return @($out)
}

# ================================================================== monitor ====

function Get-MonitorFindings {
    param($Monitor)
    $out = New-Object System.Collections.ArrayList
    if (-not $Monitor) { return @($out) }

    $s = Get-Prop $Monitor 'summary'
    if (-not $s) { return @($out) }

    $samples = @(Get-Prop $Monitor 'samples' @())
    $sampleCount = Num (Get-Prop $s 'sampleCount')
    if (-not $sampleCount -or $sampleCount -lt 5) {
        [void]$out.Add((New-Finding `
                    -Id 'monitor-too-short' -Title 'Not enough samples for trend analysis' `
                    -Severity 'info' -Category 'monitor' `
                    -Summary "$sampleCount usable samples" `
                    -Why 'A few samples cannot distinguish a spike from a baseline. Per-second metrics need at least 30 samples before their percentile figures mean anything.' `
                    -Evidence @("Samples: $sampleCount") `
                    -Action 'Run again with a longer duration, ideally while the game is running.'))
        return @($out)
    }

    function Stat($name) { Get-Prop $s $name }

    $durationS = Num (Get-Prop $s 'actualSeconds')

    # ------------------------------------------------------------ disk latency --
    $lat = Stat 'diskLatMs'
    $latP95 = Num (Get-Prop $lat 'p95')
    $latMax = Num (Get-Prop $lat 'max')

    if ($latP95 -and $latP95 -gt 25) {
        [void]$out.Add((New-Finding `
                    -Id 'monitor-disk-latency' -Title 'Sustained disk latency is high' `
                    -Severity 'critical' -Category 'storage' `
                    -Summary "p95 $latP95 ms, peak $latMax ms" `
                    -Why 'Average disk transfer time is how long a read request waits before data comes back. A healthy SSD answers in well under a millisecond. At 25 ms, any code that reads from disk waits 25 ms, which is longer than an entire frame at 60 FPS. If the game streams assets from this disk, you get a stutter every time it does.' `
                    -Evidence @("p95 latency: $latP95 ms", "Peak latency: $latMax ms", "Mean: $(Num (Get-Prop $lat 'mean')) ms") `
                    -Action 'Check the disk section for queue depth at the same moments. If the queue is also elevated, something is saturating the drive (an updater, indexing, or a second program). If latency is high with a low queue, the drive itself is the problem.'))
    } elseif ($latMax -and $latMax -gt 50) {
        [void]$out.Add((New-Finding `
                    -Id 'monitor-disk-spikes' -Title 'Disk latency spikes during the session' `
                    -Severity 'warn' -Category 'storage' `
                    -Summary "Peak $latMax ms, p95 $latP95 ms" `
                    -Why 'A single 50 ms I/O does not slow everything down, but whichever thread issued it stops for 50 ms. In a game that thread may be the one loading an asset, and the frame it was preparing is delivered late. Occasional spikes are normal; several per minute are not.' `
                    -Evidence @("Peak: $latMax ms", "p95: $latP95 ms") `
                    -Action 'Re-run with a longer window to see whether the spikes are frequent or a one-off. Frequent spikes point at a background task or a drive problem.'))
    }

    $queue = Stat 'diskQueue'
    $qP95 = Num (Get-Prop $queue 'p95')
    if ($qP95 -and $qP95 -gt 2) {
        [void]$out.Add((New-Finding `
                    -Id 'monitor-disk-queue' -Title 'Disk queue is backed up' `
                    -Severity 'warn' -Category 'storage' `
                    -Summary "p95 queue depth $qP95" `
                    -Why 'Queue depth counts requests waiting for the drive. Above about 2, the drive cannot keep up with demand and everything downstream waits. This is the signature of something else on the machine using the disk while you are trying to play.' `
                    -Evidence @("p95 queue depth: $qP95", "Peak: $(Num (Get-Prop $queue 'max'))", "Mean: $(Num (Get-Prop $queue 'mean'))") `
                    -Action 'Cross-reference with the busiest-processes table. A background updater, a sync client, or indexing is the usual culprit.'))
    }

    # -------------------------------------------------------------------- dpc --
    $dpc = Stat 'dpc'
    $dpcP95 = Num (Get-Prop $dpc 'p95')
    if ($dpcP95 -and $dpcP95 -gt 5) {
        [void]$out.Add((New-Finding `
                    -Id 'monitor-dpc' -Title 'Deferred procedure call time is high' `
                    -Severity 'critical' -Category 'driver' `
                    -Summary "p95 $dpcP95% of CPU time, peak $(Num (Get-Prop $dpc 'max'))%" `
                    -Why 'DPCs are kernel work that runs at a priority above every user-mode thread, including the game. When a driver queues a lot of them, the game''s thread is pre-empted no matter what priority it has. This is the classic cause of stutter that no CPU graph explains, because total CPU usage can look low while the game is still being interrupted constantly.' `
                    -Evidence @("p95 DPC: $dpcP95%", "Peak DPC: $(Num (Get-Prop $dpc 'max'))%", "DPCs queued/sec: $(Num (Get-Prop (Stat 'dpcsQueued') 'p95'))") `
                    -Action 'The usual sources are network, audio, and USB drivers. Update the network and audio drivers from the laptop manufacturer rather than Windows Update, and disconnect unused USB devices to test.'))
    } elseif ($dpcP95 -and $dpcP95 -gt 2) {
        [void]$out.Add((New-Finding `
                    -Id 'monitor-dpc-elevated' -Title 'DPC time is mildly elevated' `
                    -Severity 'info' -Category 'driver' `
                    -Summary "p95 $dpcP95%" `
                    -Why 'Normal is well under 1%. Two to five percent suggests a driver is doing more deferred work than it should, but at this level the effect on frame times is usually small.' `
                    -Evidence @("p95 DPC: $dpcP95%") `
                    -Action 'Worth watching across runs. If it climbs, investigate drivers.'))
    }

    $isr = Stat 'interrupt'
    $isrP95 = Num (Get-Prop $isr 'p95')
    if ($isrP95 -and $isrP95 -gt 2) {
        [void]$out.Add((New-Finding `
                    -Id 'monitor-interrupt' -Title 'Interrupt time is high' `
                    -Severity 'warn' -Category 'driver' `
                    -Summary "p95 $isrP95%, peak $(Num (Get-Prop $isr 'max'))%" `
                    -Why 'Interrupts are hardware service routines, and they pre-empt everything. Above roughly 2% the device generating them is talking to the CPU too often. The device is usually a network adapter, a USB controller with a polling device, or an audio interface.' `
                    -Evidence @("p95 interrupts: $isrP95%", "Peak: $(Num (Get-Prop $isr 'max'))%") `
                    -Action 'Identify the device: check LatencyMon or Windows Performance Recorder for the per-driver breakdown. Update or replace the offending driver.'))
    }

    # -------------------------------------------------------------- cpu state --
    $cpu = Stat 'cpuTotal'
    $cpuP95 = Num (Get-Prop $cpu 'p95')
    $cpuCore = Stat 'cpuCoreMax'
    $coreP95 = Num (Get-Prop $cpuCore 'p95')

    if ($cpuP95 -and $cpuP95 -gt 90) {
        [void]$out.Add((New-Finding `
                    -Id 'monitor-cpu-saturated' -Title 'CPU was saturated for part of the session' `
                    -Severity 'warn' -Category 'cpu' `
                    -Summary "p95 $cpuP95%, peak $(Num (Get-Prop $cpu 'max'))%" `
                    -Why 'When the CPU is fully occupied, the scheduler has to choose which thread waits. The game''s render thread competes with everything else, and on a machine with few cores that choice is often the wrong one. Frames are delayed rather than dropped, which is felt as uneven pacing.' `
                    -Evidence @("p95 total CPU: $cpuP95%", "Mean: $(Num (Get-Prop $cpu 'mean'))%") `
                    -Action 'If this happened without a game running, something is working in the background. Check the busiest-processes table.'))
    }

    if ($coreP95 -and $coreP95 -gt 97) {
        [void]$out.Add((New-Finding `
                    -Id 'monitor-core-pinned' -Title 'At least one core was pinned at 100%' `
                    -Severity 'warn' -Category 'cpu' `
                    -Summary "p95 busiest-core $coreP95%" `
                    -Why 'A single saturated core is the signature of a thread that cannot be split across cores, and game render threads are exactly that. Total CPU can read as 25% while the thread that matters is waiting in line behind other work on its own core.' `
                    -Evidence @("p95 busiest core: $coreP95%", "Peak: $(Num (Get-Prop $cpuCore 'max'))%") `
                    -Action 'Look for a single process with high core-normalised CPU in the process table. That process competes with the game for the same hardware thread.'))
    }

    $freq = Stat 'freqPct'
    $freqP95 = Num (Get-Prop $freq 'p95')
    $freqMean = Num (Get-Prop $freq 'mean')
    if ($freqMean -and $freqMean -lt 80) {
        [void]$out.Add((New-Finding `
                    -Id 'monitor-freq-low' -Title 'CPU is running below its maximum frequency' `
                    -Severity 'warn' -Category 'power' `
                    -Summary "mean $freqMean% of max, p95 $freqP95%" `
                    -Why 'This measures the CPU against its own rated clock. Running at 60-70% means the processor is being held back, either by power limits or by temperature. A throttled CPU delivers every frame more slowly, and worse, the amount of throttling changes with load, so frame times become inconsistent rather than uniformly longer.' `
                    -Evidence @("Mean: $freqMean% of maximum", "p95: $freqP95%", "Peak: $(Num (Get-Prop $freq 'max'))%") `
                    -Action 'Check CPU temperature and whether the laptop is on battery or in a power-saving state. On a laptop, thermal throttling under sustained load is normal design behaviour, not a fault.'))
    }

    # ---------------------------------------------------------------- memory --
    $memAvail = Stat 'memAvailMb'
    $memP5 = Num (Get-Prop $memAvail 'min')
    $commit = Stat 'commitPct'
    $commitMax = Num (Get-Prop $commit 'max')

    if ($memP5 -and $memP5 -lt 1024) {
        [void]$out.Add((New-Finding `
                    -Id 'monitor-memory-pressure' -Title 'Available memory dropped below 1 GB' `
                    -Severity 'warn' -Category 'memory' `
                    -Summary "minimum $([int]$memP5) MB available" `
                    -Why 'When free memory runs out, Windows trims the working sets of running programs to make room. Trimming a game means its assets have to be read back from disk the next time they are needed, which is a stall inside the frame. The effect compounds: the more it trims, the more it needs the disk, the slower everything gets.' `
                    -Evidence @("Minimum available: $([int]$memP5) MB", "Mean: $([int](Num (Get-Prop $memAvail 'mean'))) MB") `
                    -Action 'This is the clearest argument for more RAM. In the meantime, close the browser before playing: it is usually the largest consumer after the game.'))
    }

    if ($commitMax -and $commitMax -gt 90) {
        [void]$out.Add((New-Finding `
                    -Id 'monitor-commit-high' -Title 'Committed memory reached the page file limit' `
                    -Severity 'warn' -Category 'memory' `
                    -Summary "peak $(Num (Get-Prop $commit 'max'))% committed" `
                    -Why 'Commit charge is how much memory the system has promised to programs. Near 100%, every new allocation must either page something out or fail. Paging out during a frame is the expensive case, and it produces the long, rare stutters that are hardest to reproduce on purpose.' `
                    -Evidence @("Peak committed: $(Num (Get-Prop $commit 'max'))%", "Mean: $(Num (Get-Prop $commit 'mean'))%") `
                    -Action 'Increase available memory or the page file size. Reducing the number of running applications helps in the short term.'))
    }

    $pages = Stat 'pagesSec'
    $pagesP95 = Num (Get-Prop $pages 'p95')
    if ($pagesP95 -and $pagesP95 -gt 500) {
        [void]$out.Add((New-Finding `
                    -Id 'monitor-paging' -Title 'Heavy paging activity during the session' `
                    -Severity 'warn' -Category 'memory' `
                    -Summary "p95 $pagesP95 pages/sec" `
                    -Why 'Pages/sec counts memory being read from or written to disk. Sustained values in the hundreds mean the system is using the disk as memory. Every one of those transfers waits on storage latency, and it happens on the critical path of whatever program triggered it.' `
                    -Evidence @("p95: $pagesP95 pages/sec", "Peak: $(Num (Get-Prop $pages 'max'))") `
                    -Action 'More RAM is the direct fix. A faster drive shortens the stall but does not remove it.'))
    }

    # -------------------------------------------------------------- coverage --
    # If nothing was rendering, the numbers describe a desktop, not a game. Saying
    # so is more useful than presenting idle figures as if they were a gameplay
    # baseline.
    $gpu3d = Stat 'gpu3d'
    $g3max = Num (Get-Prop $gpu3d 'max')
    $cpuMean = Num (Get-Prop $cpu 'mean')

    if ($null -ne $g3max -and $g3max -lt 5 -and $cpuMean -and $cpuMean -lt 25) {
        [void]$out.Add((New-Finding `
                    -Id 'monitor-idle-baseline' -Title 'Session captured an idle machine, not a game' `
                    -Severity 'info' -Category 'monitor' `
                    -Summary "GPU 3D peak $g3max%, CPU mean $cpuMean%" `
                    -Why 'Very little was rendering and the CPU was mostly idle, so these figures describe the desktop. They are a useful baseline, but they cannot predict what happens under a game load, where the contention that causes stutter actually appears.' `
                    -Evidence @("GPU 3D peak: $g3max%", "CPU mean: $cpuMean%", "Samples: $sampleCount") `
                    -Action 'Run the tool again with the game running, ideally during the part that stutters. That is when these numbers mean something.'))
    }

    return @($out)
}

# =================================================================== events ====

function Get-EventFindings {
    param($Events)
    $out = New-Object System.Collections.ArrayList
    if (-not $Events) { return @($out) }

    $byRule = Get-Prop $Events 'byRule'
    if (-not $byRule) { return @($out) }

    $windowDays = Get-Prop $Events 'windowDays' 7

    foreach ($key in @($byRule.Keys)) {
        $r = $byRule[$key]
        $count = Num (Get-Prop $r 'count') 0
        if (-not $count -or $count -le 0) { continue }

        $sev = [string](Get-Prop $r 'severity' 'info')
        $detail = [string](Get-Prop $r 'detail')
        $label = [string](Get-Prop $r 'label')
        $evts = @(Get-Prop $r 'events' @())

        $evidence = @("Occurrences in $windowDays days: $count")
        foreach ($e in ($evts | Select-Object -First 3)) {
            $evidence += "$(Get-Prop $e 'time') · id $(Get-Prop $e 'id') · $(Get-Prop $e 'source')"
        }

        [void]$out.Add((New-Finding `
                    -Id ("event-" + ($label -replace '[^a-zA-Z0-9]', '-').ToLower()) `
                    -Title "$label ×$count" `
                    -Severity $sev -Category ([string](Get-Prop $r 'category' 'event')) `
                    -Summary "Recorded $count times in the last $windowDays days" `
                    -Why $detail `
                    -Evidence $evidence `
                    -Action 'These are recorded facts, not inferences. If one of them lines up in time with the stutter you are chasing, that is your cause.'))
    }

    return @($out)
}

# ================================================================= coverage ====

function Get-CoverageNotes {
    param($Run)
    $notes = New-Object System.Collections.ArrayList

    $facts = Get-Prop $Run 'facts'
    $status = Get-Prop $facts 'status'
    if ($status) {
        foreach ($k in @($status.Keys)) {
            $st = $status[$k]
            if (-not (Get-Prop $st 'ok' $true)) {
                [void]$notes.Add(@{
                        source = $k
                        error  = [string](Get-Prop $st 'error' 'unavailable')
                    })
            }
        }
    }

    $tools = Get-Prop $Run 'tool'
    # Without administrator rights, say nothing unless something actually failed
    # to read. Reporting it unconditionally implied missing data even on runs
    # where every collector succeeded, and the earlier claim that hardware
    # inventory is blocked was simply wrong: a standard user reads all of it.
    if ((Get-Prop $tools 'elevated') -eq $false -and $notes.Count -gt 0) {
        [void]$notes.Add(@{
                source = 'elevation'
                error  = 'Standard user, not administrator. Some sources above were refused by Windows or by the calling process; running an elevated console may or may not help, since most inventory reads without it.'
            })
    }

    # This one is true on every run and is the tool's central limitation.
    [void]$notes.Add(@{
            source = 'frame timing'
            error  = 'Frame times were not captured. This run shows what the machine was doing, not what the game rendered, so a stutter confirmed here is a contention suspect rather than a measured drop.'
        })

    return @($notes)
}

# ================================================================== engine ====

function Invoke-RulesEngine {
    param([Parameter(Mandatory)]$Run)

    $facts = Get-Prop $Run 'facts'
    $monitor = Get-Prop $Run 'monitor'
    $events = Get-Prop $Run 'events'

    $all = New-Object System.Collections.ArrayList
    foreach ($f in (Get-StaticFindings -Facts $facts)) { [void]$all.Add($f) }
    foreach ($f in (Get-MonitorFindings -Monitor $monitor)) { [void]$all.Add($f) }
    foreach ($f in (Get-EventFindings -Events $events)) { [void]$all.Add($f) }

    # Rank by severity, then keep the original order within a severity so related
    # findings stay grouped.
    $order = @{ critical = 0; warn = 1; info = 2; ok = 3 }
    $indexed = @()
    for ($i = 0; $i -lt $all.Count; $i++) {
        $f = $all[$i]
        $indexed += [pscustomobject]@{ item = $f; rank = $order[$f.severity]; idx = $i }
    }
    $sorted = @($indexed | Sort-Object rank, idx | ForEach-Object { $_.item })

    # De-duplicate by id, keeping the first occurrence.
    $seen = @{}
    $final = New-Object System.Collections.ArrayList
    foreach ($f in $sorted) {
        if ($seen.ContainsKey($f.id)) { continue }
        $seen[$f.id] = $true
        [void]$final.Add($f)
    }

    $counts = @{ critical = 0; warn = 0; info = 0; ok = 0 }
    foreach ($f in $final) { $counts[$f.severity] = $counts[$f.severity] + 1 }

    $verdict = 'clean'
    $headline = 'No significant contention found.'
    if ($counts.critical -gt 0) {
        $verdict = 'critical'
        $headline = "$($counts.critical) critical issue$(if ($counts.critical -ne 1) { 's' }) found. Start there."
    } elseif ($counts.warn -gt 0) {
        $verdict = 'warn'
        $headline = "$($counts.warn) issue$(if ($counts.warn -ne 1) { 's' }) worth fixing, but nothing catastrophic."
    } elseif ($counts.info -gt 0) {
        $verdict = 'info'
        $headline = 'Nothing serious. A few things worth knowing.'
    }

    return [ordered]@{
        findings = @($final)
        counts   = $counts
        verdict  = $verdict
        headline = $headline
        coverage = (Get-CoverageNotes -Run $Run)
    }
}
