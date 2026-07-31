param(
    [switch]$NoWait,
    [switch]$SkipSnapshot,
    [switch]$SkipCPU,
    [switch]$SkipMemory,
    [switch]$SkipDisk,
    [switch]$SkipBattery,
    [switch]$SkipKeyboard,
    [switch]$SkipBatteryLife,
    [switch]$SkipEvents,
    [switch]$Json,
    [switch]$Help
)

if ($Help) {
    Write-Host @"
SystemTester.ps1 - system diagnostics and report generator

USAGE:
    .\SystemTester.ps1 [OPTIONS]

OPTIONS:
    -NoWait           Skip the 60-second battery drain wait
    -SkipSnapshot     Skip system snapshot
    -SkipCPU          Skip CPU checks
    -SkipMemory       Skip memory checks
    -SkipDisk         Skip disk checks
    -SkipBattery      Skip battery checks
    -SkipKeyboard     Skip keyboard checks
    -SkipBatteryLife  Skip battery life estimate
    -SkipEvents       Skip event log checks
    -Json             Also save structured data as JSON
    -Help             Show this help message

EXAMPLES:
    .\SystemTester.ps1
    .\SystemTester.ps1 -NoWait
    .\SystemTester.ps1 -SkipKeyboard -SkipBatteryLife
    .\SystemTester.ps1 -SkipSnapshot -SkipBattery -NoWait -Json
    .\SystemTester.ps1 -SkipEvents -SkipKeyboard -NoWait

"@
    exit
}

$ReportTxt = "SystemTester_Report_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').txt"
$ReportJson = "SystemTester_Report_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').json"
$Lines = @()
$JsonHash = @{}
$Admin = [bool]([Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

function Log($Text) {
    $script:Lines += $Text
    Write-Host $Text
}

function Section($Name) {
    Log ""
    Log ("=" * 55)
    Log "  $Name"
    Log ("=" * 55)
}

function Format-Time($Seconds) {
    if ($Seconds -lt 0 -or $Seconds -gt 315360000) { return "Unknown" }
    $t = [long]$Seconds
    $m = [int]($t / 60); $s = $t % 60
    $h = [int]($m / 60); $m = $m % 60
    $d = [int]($h / 24); $h = $h % 24
    if ($d) { return "${d}d ${h}h ${m}m" }
    if ($h) { return "${h}h ${m}m" }
    return "${m}m ${s}s"
}

function LogData($K, $V) {
    $script:JsonHash[$K] = $V
}

# --- Snapshot ---
if (-not $SkipSnapshot) {
Section "System Snapshot"
$os = Get-CimInstance Win32_OperatingSystem
Log "  OS: $($os.Caption) ($($os.Version))"
LogData 'OS' "$($os.Caption) $($os.Version)"
Log "  Last boot: $($os.LastBootUpTime)"
$uptime = (Get-Date) - $os.LastBootUpTime
Log "  Uptime: $(Format-Time $uptime.TotalSeconds)"

$cs = Get-CimInstance Win32_ComputerSystem
Log "  Manufacturer: $($cs.Manufacturer)"
LogData 'Manufacturer' $cs.Manufacturer
Log "  Model: $($cs.Model)"
LogData 'Model' $cs.Model

try {
    $bios = Get-CimInstance Win32_BIOS
    Log "  BIOS: $($bios.SMBIOSBIOSVersion) ($($bios.Manufacturer))"
    LogData 'BIOS' $bios.SMBIOSBIOSVersion
    Log "  Serial: $($bios.SerialNumber)"
    LogData 'Serial' $bios.SerialNumber
} catch { }

$cpu = Get-CimInstance Win32_Processor
Log "  CPU: $($cpu.Name)"
LogData 'CPU' $cpu.Name
Log "  Cores: $($cpu.NumberOfCores) physical, $($cpu.NumberOfLogicalProcessors) logical"
LogData 'Cores' "$($cpu.NumberOfCores)p/$($cpu.NumberOfLogicalProcessors)l"
Log "  Clock: $($cpu.CurrentClockSpeed) MHz (max $($cpu.MaxClockSpeed) MHz)"

$ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
$ramFree = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
$ramFreeGB = [math]::Round($ramFree, 2)
$ramUsed = [math]::Round($ramGB - $ramFreeGB, 2)
$ramPct = [math]::Round(($ramUsed / $ramGB) * 100)
Log "  RAM: ${ramGB}GB total, ${ramUsed}GB used (${ramPct}%)"
LogData 'RAM' "${ramGB}GB total, ${ramUsed}GB used (${ramPct}%)"

try {
    $physMem = Get-CimInstance Win32_PhysicalMemory | Sort-Object BankLabel
    $totalSlots = ($physMem | Measure-Object).Count
    $usedSlots = ($physMem | Where-Object { $_.Capacity -and $_.Capacity -gt 0 } | Measure-Object).Count
    $speeds = $physMem | Where-Object { $_.Speed -and $_.Speed -gt 0 } | Select-Object -ExpandProperty Speed -Unique
    $speedStr = if ($speeds) { ($speeds -join '/') + ' MT/s' } else { 'unknown' }
    Log "  RAM slots: ${usedSlots} used / ${totalSlots} total, $speedStr"
    $formFactors = $physMem | Where-Object { $_.FormFactor } | Select-Object -ExpandProperty FormFactor -Unique
    foreach ($ff in $formFactors) {
        $ffName = switch ($ff) { 8 { 'DIMM' } 9 { 'SODIMM' } 12 { 'SO-DIMM' } default { "type $ff" } }
        if ($ff -eq 8 -or $ff -eq 9 -or $ff -eq 12) { Log "  Form factor: $ffName" }
    }
    $i = 0
    foreach ($m in $physMem) {
        if ($m.Capacity -and $m.Capacity -gt 0) {
            $sz = [math]::Round($m.Capacity / 1GB, 1)
            Log "    Slot $($m.BankLabel): ${sz}GB $($m.Speed)MT/s $($m.Manufacturer)"
            $i++
        }
    }
} catch { }

$disk = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"
foreach ($d in $disk) {
    $free = [math]::Round($d.FreeSpace / 1GB, 1)
    $total = [math]::Round($d.Size / 1GB, 1)
    Log "  Drive $($d.DeviceID): ${total}GB (${free}GB free)"
}
if ($Admin) { Log "  (running as admin)" } else { Log "  (not admin - some data may be limited)" }
} # end SkipSnapshot

# --- CPU Checks ---
if (-not $SkipCPU) {
Section "CPU Checks"
$load = $cpu.LoadPercentage
if ($load -gt 70) { $desc = "heavy load" } elseif ($load -gt 30) { $desc = "moderate" } else { $desc = "mostly idle" }
Log "  Current usage: ${load}% ($desc)"

Log "  Temperatures:"
try {
    $tz = Get-CimInstance -Namespace root/WMI -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
    foreach ($t in $tz) {
        $c = [math]::Round($t.CurrentTemperature / 10 - 273.15, 1)
        Log "    Thermal zone: ${c}C"
    }
} catch { Log "    (run as admin to see temps)" }

Log "  Running prime calculation test (3s)..."
Write-Host "  Calculating..." -NoNewline
$end = (Get-Date).AddSeconds(3)
$count = 1; $n = 3
while ((Get-Date) -lt $end) {
    $prime = $true; $sqrt = [math]::Sqrt($n)
    for ($i = 3; $i -le $sqrt; $i += 2) { if ($n % $i -eq 0) { $prime = $false; break } }
    if ($prime) { $count++ }
    $n += 2
}
Log " $count primes found"
} # end SkipCPU

# --- Memory Checks ---
if (-not $SkipMemory) {
Section "Memory Checks"
Log "  Running RAM speed test (64 MB)..."
Write-Host "  Testing..." -NoNewline
$buf = New-Object byte[] (64 * 1024 * 1024)
$t0 = Get-Date
for ($i = 0; $i -lt $buf.Length; $i += 4096) { $buf[$i] = ($i / 4096) % 256 }
$checksum = 0
for ($i = 0; $i -lt $buf.Length; $i += 4096) { $checksum = ($checksum + $buf[$i]) % 1000000007 }
$dt = ((Get-Date) - $t0).TotalSeconds
Log " done in $([math]::Round($dt, 2))s (checksum=$checksum)"

Log "  Checking for memory errors in event log..."
try {
    $memErrors = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='*Memory*'} -MaxEvents 5 -ErrorAction SilentlyContinue
    if ($memErrors) {
        Log "    Found $($memErrors.Count) memory-related events (review recommended)"
    } else {
        Log "    No memory errors found"
    }
} catch { Log "    Event log unavailable" }
} # end SkipMemory

# --- Disk Checks ---
if (-not $SkipDisk) {
Section "Disk Checks"
Log "  Physical drives:"
try {
    $drives = Get-CimInstance Win32_DiskDrive
    foreach ($d in $drives) {
        $model = $d.Model
        $sz = [math]::Round($d.Size / 1GB, 1)
        $iface = $d.InterfaceType
        $rpm = $d.RotationsPerMinute
        if ($rpm -and $rpm -gt 0) { $type = "HDD (${rpm}RPM)" }
        elseif ($model -match "SSD|NVMe") { $type = "SSD" }
        elseif (-not $rpm) { $type = "SSD" }
        elseif ($iface -match "NVMe") { $type = "SSD (NVMe)" }
        else { $type = "HDD" }
        Log "    $model - ${sz}GB, $type"
    }
} catch { Log "    (unavailable)" }

Log "  SMART / health:"
try {
    if ($Admin) {
        $pds = Get-PhysicalDisk -ErrorAction Stop
        foreach ($pd in $pds) {
            $hlth = $pd.HealthStatus
            $op = $pd.OperationalStatus
            $w = Get-PhysicalDisk -FriendlyName $pd.FriendlyName | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
            $wear = if ($w -and $w.WearPercentage -ge 0) { "$($w.WearPercentage)%" } else { 'N/A' }
            $realloc = if ($w) { $w.ReadErrorsTotal } else { 'N/A' }
            Log "    $($pd.FriendlyName): health=$hlth, op=$op, wear=$wear, read errors=$realloc"
        }
    } else {
        Log "    (run as admin for SMART details)"
        foreach ($d in (Get-CimInstance Win32_DiskDrive)) {
            Log "    $($d.Model) - status unknown (admin required)"
        }
    }
} catch { Log "    (SMART unavailable)" }

$tf = "$env:TEMP\__systest.tmp"
Log '  Running disk speed test (20 MB) on drive C:...'
Write-Host "  Testing..." -NoNewline
$data = New-Object byte[] (20 * 1024 * 1024)
(New-Object Random).NextBytes($data)
$t0 = Get-Date
[System.IO.File]::WriteAllBytes($tf, $data)
$tw = ((Get-Date) - $t0).TotalSeconds
$t0 = Get-Date
$r = [System.IO.File]::ReadAllBytes($tf)
$tr = ((Get-Date) - $t0).TotalSeconds
Remove-Item $tf -ErrorAction SilentlyContinue
Log ' done'
$ws = '  Write: ' + [math]::Round(20 / $tw, 1) + ' MB/s (' + [math]::Round($tw, 2) + 's)'
$rs = '  Read:  ' + [math]::Round(20 / $tr, 1) + ' MB/s (' + [math]::Round($tr, 2) + 's)'
Log $ws; Log $rs
$diskWrite = [math]::Round(20 / $tw, 1)
$diskRead = [math]::Round(20 / $tr, 1)
LogData 'DiskWrite' "${diskWrite} MB/s"
LogData 'DiskRead' "${diskRead} MB/s"
} # end SkipDisk

# --- Battery Checks ---
if (-not $SkipBattery) {
Section "Battery Checks"
try {
    $batt = Get-CimInstance Win32_Battery -ErrorAction Stop
    if (-not $batt) { Log "  No battery found." }
    else {
        Log "  Charge: $($batt.EstimatedChargeRemaining)%"
        Log "  Status: $(if ($batt.BatteryStatus -eq 2) { 'Charging' } else { 'On battery' })"
        if ($batt.EstimatedRunTime -and $batt.EstimatedRunTime -gt 0 -and $batt.EstimatedRunTime -lt 1000000) {
            Log "  Est. time left: $(Format-Time ($batt.EstimatedRunTime * 60))"
        }
        $batHealthOk = $false
        $batFull = Get-CimInstance -Namespace root/WMI -ClassName BatteryStaticData -ErrorAction SilentlyContinue
        $batCycle = Get-CimInstance -Namespace root/WMI -ClassName BatteryCycleCount -ErrorAction SilentlyContinue
        $batStat = Get-CimInstance -Namespace root/WMI -ClassName BatteryStatus -ErrorAction SilentlyContinue
        if ($batFull) {
            foreach ($b in $batFull) {
                $d = $b.DesignedCapacity
                if ($d -and $d -gt 0 -and $d -lt 4294967295) {
                    $desCap = [math]::Round([double]$d / 1000)
                    if ($batStat) {
                        $f = $batStat[0].ChargeCapacity
                        if ($f -and $f -gt 0 -and $f -lt 4294967295) {
                            $fullCap = [math]::Round([double]$f / 1000)
                            $hp = [math]::Round(($fullCap / $desCap) * 100)
                            Log "  Design capacity: ${desCap}Wh, Full charge: ${fullCap}Wh"
                            Log "  Battery health: ${hp}%"
                        }
                    } else { Log "  Design capacity: ${desCap}Wh" }
                    $batHealthOk = $true
                }
            }
        }
        if ($batCycle) {
            $cc = $batCycle.CycleCount
            Log "  Cycle count: $cc"
            LogData 'BatteryCycleCount' $cc
        }
        if (-not $batHealthOk) { Log "  (battery health details unavailable)" }
    }
} catch { Log "  Battery: unavailable" }
} # end SkipBattery

# --- Keyboard Checks ---
if (-not $SkipKeyboard) {
Section "Keyboard Checks"
Log "  Press each key within 5 seconds:"
$keys = @(
    @{code='a'; label='A'}, @{code='b'; label='B'}, @{code='c'; label='C'},
    @{code='d'; label='D'}, @{code='e'; label='E'}, @{code='f'; label='F'},
    @{code='g'; label='G'}, @{code='h'; label='H'}, @{code='i'; label='I'},
    @{code='j'; label='J'}, @{code='1'; label='1'}, @{code='2'; label='2'},
    @{code='Escape'; label='Escape'}, @{code='F1'; label='F1'}, @{code='F2'; label='F2'},
    @{code='F3'; label='F3'}, @{code='F4'; label='F4'}, @{code='F5'; label='F5'},
    @{code='F6'; label='F6'}, @{code='F7'; label='F7'}, @{code='F8'; label='F8'},
    @{code='F9'; label='F9'}, @{code='F10'; label='F10'}, @{code='F11'; label='F11'},
    @{code='F12'; label='F12'}, @{code='Up'; label='Up'}, @{code='Down'; label='Down'},
    @{code='Left'; label='Left'}, @{code='Right'; label='Right'}, @{code='Space'; label='Space'}
)
$passed = 0; $failed = 0
foreach ($k in $keys) {
    Write-Host "  Press '$($k.label)' ... " -NoNewline
    $got = $null
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        if ($Host.UI.RawUI.KeyAvailable) {
            $got = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            break
        }
        Start-Sleep -Milliseconds 50
    }
    if ($got) {
        $ch = $got.Key.ToString()
        $ok = $ch -eq $k.code
        if ($k.code -eq 'Space') { $ok = $got.Key -eq 'Spacebar' }
        if (-not $ok) { $ok = $got.Character -eq $k.code }
    }
    if ($ok) {
        Write-Host "OK"; Log "    $($k.label): OK"; $passed++
    } else {
        Write-Host "missed"; Log "    $($k.label): missed"; $failed++
    }
}
Log "  Keys: $passed OK, $failed missed"
} # end SkipKeyboard

# --- Battery Life Estimate ---
if (-not $SkipBatteryLife) {
Section "Battery Life Estimate"
try {
    $batt = Get-CimInstance Win32_Battery -ErrorAction Stop
    if (-not $batt) { Log "  No battery found." }
    elseif ($batt.BatteryStatus -eq 2) { Log "  Plugged in - can't estimate." }
    else {
        $b1 = $batt.EstimatedChargeRemaining
        Log "  Starting: ${b1}%"
        if ($NoWait) { Log "  Skipped (use -NoWait to skip)" }
        else {
            Log "  Waiting 60 seconds..."
            for ($i = 60; $i -ge 1; $i--) {
                Write-Progress -Activity "Measuring discharge" -Status "${i}s remaining" -PercentComplete ((60-$i)/60*100)
                Start-Sleep 1
            }
            Write-Progress -Completed -Activity "Done"
            $batt2 = Get-CimInstance Win32_Battery
            $b2 = $batt2.EstimatedChargeRemaining
            $delta = $b1 - $b2
            if ($delta -le 0) { Log "  Battery didn't drop (sensor noise)." }
            else {
                $rate = $delta * 60
                $mins = ($b2 * 60) / $delta
                $hrs = [math]::Floor($mins / 60)
                $rm = [math]::Round($mins % 60)
                Log "  Dropped: ${b1}% -> ${b2}% (lost ${delta}%)"
                Log "  Drain rate: ~${rate}% per hour"
                Log "  Estimated runtime left: ~${hrs}h ${rm}m"
            }
        }
    }
} catch { Log "  Battery: unavailable" }
} # end SkipBatteryLife

# --- Event Log Checks ---
if (-not $SkipEvents) {
Section "Event Log Checks"
Log "  Checking for critical system events..."
try {
    $critical = Get-WinEvent -FilterHashtable @{LogName='System'; Level=1} -MaxEvents 10 -ErrorAction SilentlyContinue
    if ($critical) {
        Log "    Found $($critical.Count) critical events (last 10):"
        LogData 'CriticalEvents' $critical.Count
        foreach ($e in $critical) {
            Log "      $($e.TimeCreated) [$($e.ProviderName)] ID $($e.Id)"
        }
    } else { Log "    No critical events found"; LogData 'CriticalEvents' 0 }
} catch { Log "    Event log unavailable" }

Log "  Checking for unexpected shutdowns..."
try {
    $shutdowns = Get-WinEvent -FilterHashtable @{LogName='System'; ID=41} -MaxEvents 5 -ErrorAction SilentlyContinue
    if ($shutdowns) {
        Log "    $($shutdowns.Count) unexpected shutdown(s) (Kernel-Power ID 41):"
        LogData 'UnexpectedShutdowns' $shutdowns.Count
        foreach ($s in $shutdowns) { Log "      $($s.TimeCreated)" }
    } else { Log "    No unexpected shutdowns found"; LogData 'UnexpectedShutdowns' 0 }
} catch { }
} # end SkipEvents

# --- Summary ---
Section "Summary"
$issues = @()
if ($failed -and $failed -gt 0) { $issues += "Keyboard: $failed keys missed" }
if ($memErrors -and $memErrors.Count -gt 0) { $issues += "Memory errors in event log" }
if ($critical -and $critical.Count -gt 0) { $issues += "$($critical.Count) critical system events" }
if ($shutdowns -and $shutdowns.Count -gt 0) { $issues += "$($shutdowns.Count) unexpected shutdown(s)" }
if ($issues.Count -eq 0) { Log "  No major issues detected." }
else { Log "  Issues found:"; foreach ($m in $issues) { Log "    - $m" } }
Log "  Hostname: $env:COMPUTERNAME"
Log "  Report: $ReportTxt"
if ($Json) { Log "  JSON:   $ReportJson" }

# --- Save Report ---
$Lines = $Lines | Where-Object { $_ -ne $null }
$Lines | Out-File -FilePath $ReportTxt -Encoding utf8

if ($Json) {
    $JsonHash['Generated'] = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $JsonHash['Hostname'] = $env:COMPUTERNAME
    $JsonHash | ConvertTo-Json | Out-File -FilePath $ReportJson -Encoding utf8
}

Log ""
Log ("=" * 55)
Log "  Report saved to: $ReportTxt"
if ($Json) { Log "  JSON saved to:   $ReportJson" }
Log ("=" * 55)
