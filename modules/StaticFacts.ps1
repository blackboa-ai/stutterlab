# StaticFacts.ps1 — one-shot inventory of hardware and configuration.
#
# Every sub-collection is wrapped in Invoke-Safely so a denied WMI class or a
# missing registry key degrades to a recorded 'unavailable' rather than aborting
# the run. The status map records exactly which sources worked, so the report can
# be explicit about what it could not see.

function Get-StaticFacts {
    $facts = [ordered]@{}
    $status = [ordered]@{}

    function Set-Fact {
        param([string]$Key, $Result)
        $status[$Key] = @{ ok = [bool]$Result.ok; error = $Result.error; ms = $Result.ms }
        return (Get-Val $Result)
    }

    # ---------------------------------------------------------------- system --
    # CIM is the richer source but is denied to a non-elevated caller, so each
    # field falls back to the registry, which needs no elevation. The report then
    # says what it saw instead of losing the whole collector.
    $os = Invoke-Safely 'os' {
        $o = $null
        try { $o = Get-CimInstance Win32_OperatingSystem -EA Stop } catch { }
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -EA SilentlyContinue
        $build = Get-Prop $cv 'CurrentBuild'
        $caption = Get-Prop $cv 'ProductName'
        $dispVer = Get-Prop $cv 'DisplayVersion'
        @{
            caption   = if ($o) { $o.Caption } else { $caption }
            version   = if ($o) { $o.Version } else { Get-Prop $cv 'CurrentVersion' }
            build     = if ($o) { $o.BuildNumber } else { $build }
            displayVersion = if ($o) { $null } else { $dispVer }
            arch      = if ($o) { $o.OSArchitecture } else { $env:PROCESSOR_ARCHITECTURE }
            bootTime  = if ($o -and $o.LastBootUpTime) { $o.LastBootUpTime.ToString('o') } else { $null }
            uptimeHrs = if ($o -and $o.LastBootUpTime) { [math]::Round(((Get-Date) - $o.LastBootUpTime).TotalHours, 1) } else { $null }
            totalRam  = if ($o) { $o.TotalVisibleMemorySize * 1KB } else { $null }
            freeRam   = if ($o) { $o.FreePhysicalMemory * 1KB } else { $null }
            source    = if ($o) { 'cim' } else { 'registry' }
        }
    }
    $facts.os = Set-Fact 'os' $os

    # ---------------------------------------------------------------- cpu ----
    $cpu = Invoke-Safely 'cpu' {
        $c = $null
        try { $c = Get-CimInstance Win32_Processor -EA Stop | Select-Object -First 1 } catch { }
        $reg = Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -EA SilentlyContinue
        $regName = Get-Prop $reg 'ProcessorNameString'
        $regMhz = Get-Prop $reg '~MHz'
        $regCount = @(Get-ChildItem 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor' -EA SilentlyContinue).Count
        @{
            name         = if ($c) { $c.Name } else { ($regName -as [string]).Trim() }
            manufacturer = if ($c) { $c.Manufacturer } else { Get-Prop $reg 'VendorIdentifier' }
            cores        = if ($c) { $c.NumberOfCores } else { $null }
            logical      = if ($c) { $c.NumberOfLogicalProcessors } else { $regCount }
            maxClockMhz  = if ($c) { $c.MaxClockSpeed } else { $regMhz }
            curClockMhz  = if ($c) { $c.CurrentClockSpeed } else { $null }
            l2Kb         = if ($c) { $c.L2CacheSize } else { $null }
            l3Kb         = if ($c) { $c.L3CacheSize } else { $null }
            socket       = if ($c) { $c.SocketDesignation } else { Get-Prop $reg 'Identifier' }
            virtualizationFirmware = if ($c) { $c.VirtualizationFirmwareEnabled } else { $null }
            source       = if ($c) { 'cim' } else { 'registry' }
        }
    }
    $facts.cpu = Set-Fact 'cpu' $cpu

    # -------------------------------------------------------------- memory ---
    # Per-stick detail matters: a single stick means single-channel, and
    # configured < rated means XMP/EXPO is off. Both are common stutter causes
    # that no live graph will ever show.
    #
    # Win32_PhysicalMemory needs elevation. GlobalMemoryStatusEx does not, so the
    # total/"in use" numbers survive a denial even though per-stick layout is lost.
    $mem = Invoke-Safely 'memory' {
        $sticks = New-Object System.Collections.ArrayList
        $slotsTotal = $null
        $maxCap = $null
        $src = 'cim'
        try {
            foreach ($s in @(Get-CimInstance Win32_PhysicalMemory -EA Stop)) {
                [void]$sticks.Add(@{
                            slot         = $s.DeviceLocator
                            bank         = $s.BankLabel
                            capacity     = $s.Capacity
                            speedRated   = $s.Speed
                            speedConfig  = $s.ConfiguredClockSpeed
                            manufacturer = $s.Manufacturer
                            partNumber   = ($s.PartNumber -as [string]).Trim()
                            formFactor   = $s.FormFactor
                            dataWidth    = $s.DataWidth
                            totalWidth   = $s.TotalWidth
                        })
            }
            $arr = Get-CimInstance Win32_PhysicalMemoryArray -EA Stop | Select-Object -First 1
            if ($arr) {
                $slotsTotal = $arr.MemoryDevices
                $maxCap = Get-Prop $arr 'MaxCapacityEx'
            }
        } catch {
            $src = 'GlobalMemoryStatusEx'
            Write-Log "Per-stick memory unavailable: $($_.Exception.Message)" -Level Debug
        }

        $totalBytes = $null
        $availBytes = $null
        $loadPct = $null
        if ($sticks.Count -gt 0) {
            $totalBytes = ($sticks | ForEach-Object { $_.capacity } | Measure-Object -Sum).Sum
        } else {
            $mi = Get-MemoryStatus
            if ($mi) {
                $totalBytes = $mi.totalBytes
                $availBytes = $mi.availBytes
                $loadPct = $mi.loadPct
            }
        }

        @{
            sticks      = @($sticks)
            stickCount  = $sticks.Count
            totalBytes  = $totalBytes
            availBytes  = $availBytes
            loadPct     = $loadPct
            slotsTotal  = $slotsTotal
            maxCapacity = $maxCap
            source      = $src
        }
    }
    $facts.memory = Set-Fact 'memory' $mem

    # ---------------------------------------------------------------- gpu ----
    # Both GPUs are collected; a laptop with a discrete GPU plus an iGPU can
    # inadvertently render or encode on the wrong one.
    $gpu = Invoke-Safely 'gpu' {
        $cards = @(Get-CimInstance Win32_VideoController | ForEach-Object {
            @{
                name         = $_.Name
                driverVer    = $_.DriverVersion
                driverDate   = if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { $null }
                driverDateRaw = if ($_.DriverDate) { $_.DriverDate.ToString('o') } else { $null }
                vramBytes    = if ($_.AdapterRAM -and $_.AdapterRAM -gt 0) { [int64]$_.AdapterRAM } else { $null }
                width        = $_.CurrentHorizontalResolution
                height       = $_.CurrentVerticalResolution
                refresh      = $_.CurrentRefreshRate
                maxRefresh   = $_.MaxRefreshRate
                minRefresh   = $_.MinRefreshRate
                bitsPerPixel = $_.CurrentBitsPerPixel
                videoProcessor = $_.VideoProcessor
                status       = $_.Status
                pnpId        = $_.PNPDeviceID
            }
        })
        @{ cards = $cards; count = $cards.Count }
    }
    $facts.gpu = Set-Fact 'gpu' $gpu

    # nvidia-smi adds detail CIM does not expose: driver branch, VRAM total,
    # current clocks, and the GPU's own temperature/power state. Optional.
    $nvsmi = Invoke-Safely 'nvidia-smi' {
        $exe = Join-Path $env:WINDIR 'System32\nvidia-smi.exe'
        if (-not (Test-Path -LiteralPath $exe)) { throw 'not installed' }
        $q = 'name,driver_version,memory.total,memory.used,temperature.gpu,power.draw,power.limit,utilization.gpu,clocks.current.graphics,clocks.max.graphics'
        $raw = & $exe --query-gpu=$q --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { throw "nvidia-smi exit $LASTEXITCODE" }
        $parts = ($raw -split ',') | ForEach-Object { $_.Trim() }
        @{
            name = $parts[0]; driver = $parts[1]
            vramTotalMb = $parts[2]; vramUsedMb = $parts[3]
            tempC = $parts[4]; powerW = $parts[5]; powerLimitW = $parts[6]
            utilPct = $parts[7]; clockMhz = $parts[8]; clockMaxMhz = $parts[9]
        }
    }
    $facts.nvidia = Set-Fact 'nvidia-smi' $nvsmi

    # --------------------------------------------------------------- disks ---
    # Physical disk inventory needs elevation; volume free space does not. They are
    # collected separately so a denied Get-PhysicalDisk cannot hide a full drive,
    # which is a real stutter cause (Windows thrashes and trims slow down).
    $disk = Invoke-Safely 'disks' {
        $phys = New-Object System.Collections.ArrayList
        try {
            foreach ($d in @(Get-PhysicalDisk -EA Stop)) {
                [void]$phys.Add(@{
                            friendlyName = $d.FriendlyName
                            mediaType    = $d.MediaType.ToString()
                            busType      = $d.BusType.ToString()
                            size         = $d.Size
                            health       = $d.HealthStatus.ToString()
                            operational  = (@($d.OperationalStatus) -join ',')
                            spindleSpeed = $d.SpindleSpeed
                        })
            }
        } catch {
            Write-Log "Physical disk inventory unavailable: $($_.Exception.Message)" -Level Debug
        }

        # DriveInfo needs no elevation at all, so volume free space always arrives.
        $vols = New-Object System.Collections.ArrayList
        try {
            foreach ($dv in @([System.IO.DriveInfo]::GetDrives())) {
                if ($null -eq $dv -or -not $dv.IsReady) { continue }
                if ($dv.DriveType -ne [System.IO.DriveType]::Fixed) { continue }
                $sz = $dv.TotalSize
                $fr = $dv.AvailableFreeSpace
                [void]$vols.Add(@{
                            letter  = $dv.Name
                            label   = $dv.VolumeLabel
                            fs      = $dv.DriveFormat
                            size    = $sz
                            free    = $fr
                            freePct = if ($sz -gt 0) { [math]::Round(($fr / $sz) * 100, 1) } else { $null }
                        })
            }
        } catch {
            Write-Log "Volume inventory failed: $($_.Exception.Message)" -Level Debug
        }
        @{ physical = @($phys); volumes = @($vols) }
    }
    $facts.disks = Set-Fact 'disks' $disk

    # -------------------------------------------------------------- display --
    # WmiMonitorBasicDisplayParams reports physical panel size in centimetres,
    # which is enough to derive the diagonal honestly. Modes come from the WMI
    # list of supported source modes, not from the active desktop, because the
    # point is what the panel can do rather than what it is doing right now.
    $disp = Invoke-Safely 'display' {
        $m = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -EA Stop |
            Select-Object -First 1
        $list = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorListedSupportedSourceModes -EA SilentlyContinue |
            Select-Object -First 1

        $modes = @()
        if ($list) {
            $modes = @($list.MonitorSourceModes | ForEach-Object {
                @{
                    width   = $_.HorizontalActivePixels
                    height  = $_.VerticalActivePixels
                    refresh = [math]::Round($_.VerticalRefreshRateNumerator / [math]::Max(1, $_.VerticalRefreshRateDenominator), 0)
                }
            } | Sort-Object width, height, refresh -Unique)
        }

        # WmiMonitorID stores text as a UInt16 array of ASCII codes, null-padded.
        # UserFriendlyName is frequently absent even when the rest is present, so
        # fall back to vendor + product code + year rather than reporting nothing.
        $name = $null
        try {
            $id = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -EA Stop | Select-Object -First 1
            if ($id) {
                $decode = {
                    param($arr)
                    if ($null -eq $arr) { return $null }
                    $chars = @($arr | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ })
                    if ($chars.Count -eq 0) { return $null }
                    return (-join $chars).Trim()
                }
                $friendly = & $decode $id.UserFriendlyName
                if ($friendly) {
                    $name = $friendly
                } else {
                    $vendor = & $decode $id.ManufacturerName
                    $product = & $decode $id.ProductCodeID
                    $year = $id.YearOfManufacture
                    $bits = @($vendor, $product) | Where-Object { $_ }
                    $built = ($bits -join ' ')
                    if ($built -and $year -gt 0) { $name = "$built ($year)" }
                    elseif ($built) { $name = $built }
                }
            }
        } catch { Write-Log 'display: WmiMonitorID unavailable' -Level Debug }

        # Measure-Object cannot read hashtable keys, so the maximum is taken by
        # hand. Doing it the cmdlet way throws and kills the whole collector.
        $maxRefresh = $null
        foreach ($mode in $modes) {
            if ($null -ne $mode.refresh -and ($null -eq $maxRefresh -or $mode.refresh -gt $maxRefresh)) {
                $maxRefresh = $mode.refresh
            }
        }

        $diagonal = $null
        if ($m -and $m.MaxHorizontalImageSize -gt 0 -and $m.MaxVerticalImageSize -gt 0) {
            $h = [double]$m.MaxHorizontalImageSize
            $v = [double]$m.MaxVerticalImageSize
            $diagonal = [math]::Round([math]::Sqrt(($h * $h) + ($v * $v)) / 2.54, 1)
        }

        @{
            name           = $name
            diagonalInches = $diagonal
            modes          = $modes
            modeCount      = $modes.Count
            maxRefresh     = $maxRefresh
        }
    }
    $facts.display = Set-Fact 'display' $disp

    # ------------------------------------------------------------- pagefile --
    # Each source is isolated: Win32_PageFileUsage is readable by a standard user
    # even when Win32_ComputerSystem is not, so one denial must not discard the
    # other. Usage alone is enough to tell whether the page file is being hit.
    $pf = Invoke-Safely 'pagefile' {
        $auto = $null
        try { $auto = (Get-CimInstance Win32_ComputerSystem -EA Stop).AutomaticManagedPagefile }
        catch { Write-Log 'pagefile: AutomaticManagedPagefile unavailable' -Level Debug }

        $settings = @()
        try {
            $settings = @(Get-CimInstance Win32_PageFileSetting -EA Stop | ForEach-Object {
                @{ name = $_.Name; initialMb = $_.InitialSize; maxMb = $_.MaximumSize }
            })
        } catch { Write-Log 'pagefile: Win32_PageFileSetting unavailable' -Level Debug }

        $usage = @()
        try {
            $usage = @(Get-CimInstance Win32_PageFileUsage -EA Stop | ForEach-Object {
                @{ name = $_.Name; allocMb = $_.AllocatedBaseSize; peakMb = $_.PeakUsage; currentMb = $_.CurrentUsage }
            })
        } catch { Write-Log 'pagefile: Win32_PageFileUsage unavailable' -Level Debug }

        # A system-managed page file has no Win32_PageFileSetting entry at all,
        # so an empty settings list is normal, not a failure. Usage still names
        # the backing file, which is what the report shows.
        if (-not $settings.Count -and -not $usage.Count -and $null -eq $auto) {
            throw 'no page file information available'
        }
        @{ automaticManaged = $auto; settings = $settings; usage = $usage }
    }
    $facts.pagefile = Set-Fact 'pagefile' $pf

    # ----------------------------------------------------------- power plan --
    $power = Invoke-Safely 'power' {
        $active = (& powercfg /getactivescheme) -join ' '
        $guid = $null
        if ($active -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
            $guid = $Matches[1]
        }
        $name = $null
        if ($active -match '\(([^)]+)\)') { $name = $Matches[1] }

        # Processor minimum state — the single most common cause of a CPU that
        # idles so deep it cannot ramp fast enough to absorb a frame-time spike.
        $minState = $null; $maxState = $null
        $out = (& powercfg /query SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN) -join "`n"
        if ($out -match '(?s)Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+)') { $minState = [Convert]::ToInt32($Matches[1], 16) }
        $out2 = (& powercfg /query SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX) -join "`n"
        if ($out2 -match '(?s)Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+)') { $maxState = [Convert]::ToInt32($Matches[1], 16) }

        # USB selective suspend can cause input-device wake latency (hitches).
        $usbSuspend = $null
        $out3 = (& powercfg /query SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226) -join "`n"
        if ($out3 -match '(?s)Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+)') { $usbSuspend = [Convert]::ToInt32($Matches[1], 16) }

        @{
            guid = $guid; name = $name
            processorMinState = $minState
            processorMaxState = $maxState
            usbSelectiveSuspend = $usbSuspend
            raw = $active
        }
    }
    $facts.power = Set-Fact 'power' $power

    # ------------------------------------------------- windows perf switches --
    # These registry/CIM reads are the difference between "your machine is slow"
    # and "HVCI is intercepting kernel calls in the render path".
    $tweaks = Invoke-Safely 'tweaks' {
        $t = @{}

        # Virtualization-based security / memory integrity. HVCI runs a hypervisor
        # over kernel memory; it is a measurable frame-time cost in games.
        try {
            $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -EA Stop
            $t.vbsStatus = $dg.VirtualizationBasedSecurityStatus          # 0 off, 1 enabled-not-running, 2 running
            $t.vbsServices = @($dg.SecurityServicesRunning)               # 1 cred guard, 2 HVCI
            $t.vbsConfigured = @($dg.SecurityServicesConfigured)
        } catch {
            $t.vbsStatus = $null; $t.vbsServices = @(); $t.vbsConfigured = @()
        }

        # StrictMode 2.0 raises on missing properties, so every registry value goes
        # through Get-Prop rather than dotted access.
        $hvci = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -EA SilentlyContinue
        $hvciVal = Get-Prop $hvci 'Enabled'
        $t.hvciEnabled = if ($null -ne $hvciVal) { [int]$hvciVal } else { $null }

        # Hardware-accelerated GPU scheduling.
        $hags = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -EA SilentlyContinue
        $hagsVal = Get-Prop $hags 'HwSchMode'
        $t.hags = if ($null -ne $hagsVal) { [int]$hagsVal } else { $null }  # 1 off, 2 on

        # Game Mode / Game Bar / DVR.
        $gb = Get-ItemProperty 'HKCU:\Software\Microsoft\GameBar' -EA SilentlyContinue
        $gmVal = Get-Prop $gb 'AutoGameModeEnabled'
        $t.gameMode = if ($null -ne $gmVal) { [int]$gmVal } else { $null }
        $gbarVal = Get-Prop $gb 'ShowStartupPanel'
        $t.gameBar = if ($null -ne $gbarVal) { [int]$gbarVal } else { $null }

        $dvr = Get-ItemProperty 'HKCU:\System\GameConfigStore' -EA SilentlyContinue
        $dvrVal = Get-Prop $dvr 'GameDVR_Enabled'
        $t.gameDvr = if ($null -ne $dvrVal) { [int]$dvrVal } else { $null }

        $app = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -EA SilentlyContinue
        $appVal = Get-Prop $app 'AppCaptureEnabled'
        $t.appCapture = if ($null -ne $appVal) { [int]$appVal } else { $null }

        # Visual effects: full animations cost compositor time.
        $ve = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -EA SilentlyContinue
        $veVal = Get-Prop $ve 'VisualFXSetting'
        $t.visualFx = if ($null -ne $veVal) { [int]$veVal } else { $null }   # 1 best appearance, 2 best perf, 3 custom
        $perf = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\VisualFxSetting' -EA SilentlyContinue
        $perfVal = Get-Prop $perf 'VisualFXSetting'
        if ($null -eq $t.visualFx -and $null -ne $perfVal) { $t.visualFx = [int]$perfVal }

        # Storage: TRIM + defrag state.
        $t.trimDisabled = $false
        try {
            $fsutil = (& fsutil behavior query DisableDeleteNotify) -join ' '
            if ($fsutil -match 'DisableDeleteNotify\s*=\s*1') { $t.trimDisabled = $true }
        } catch { }

        # Time since last Windows Update install, and pending reboot.
        $t.pendingReboot = $false
        foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
                       'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
            if (Test-Path $k) { $t.pendingReboot = $true }
        }

        # Fast startup (hiberboot) — can leave drivers in a half-initialised state.
        $pw = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -EA SilentlyContinue
        $pwVal = Get-Prop $pw 'HiberbootEnabled'
        $t.fastStartup = if ($null -ne $pwVal) { [int]$pwVal } else { $null }

        $t
    }
    $facts.tweaks = Set-Fact 'tweaks' $tweaks

    # ---------------------------------------------------------- startup load --
    $startup = Invoke-Safely 'startup' {
        $runKeys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        )
        $items = @()
        foreach ($rk in $runKeys) {
            $p = Get-ItemProperty $rk -EA SilentlyContinue
            if (-not $p) { continue }
            foreach ($name in $p.PSObject.Properties.Name) {
                if ($name -in 'PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider') { continue }
                $items += @{ name = $name; cmd = [string]$p.$name; hive = $rk }
            }
        }
        @{ items = $items; count = $items.Count }
    }
    $facts.startup = Set-Fact 'startup' $startup

    # ------------------------------------------------------- security soft. ---
    # Real-time AV scanning of game assets is a legitimate stutter source; worth
    # reporting which products are active without judging them.
    $av = Invoke-Safely 'antivirus' {
        try {
            $names = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -EA Stop |
                ForEach-Object { [string]$_.displayName })
        } catch {
            $names = @()
        }
        @{ products = $names; count = $names.Count }
    }
    $facts.antivirus = Set-Fact 'antivirus' $av

    $facts.status = $status
    return $facts
}
