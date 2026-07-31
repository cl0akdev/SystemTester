# SystemTester GUI - zero-dependency Windows diagnostics (runs entirely in memory)
# One-liner:  irm <URL>/SystemTester-GUI.ps1 | iex
# Leaves no files behind. Reports only written when you click Save.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:Lines   = [System.Collections.Generic.List[string]]::new()
$script:Q       = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:Json    = [System.Collections.Generic.Dictionary[string,object]]::new()
$script:KeyHits = [System.Collections.Concurrent.ConcurrentDictionary[string,int]]::new()

$script:SharedLines   = $script:Lines
$script:SharedQueue   = $script:Q
$script:SharedJson    = $script:Json
$script:SharedKeyHits = $script:KeyHits

$script:Admin = [bool]([Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
$script:ScriptDir = ''
if ($PSCommandPath) {
    try { $script:ScriptDir = (Resolve-Path (Split-Path $PSCommandPath)).Path } catch { }
}
$script:NoWait = $false
$script:Running = $false
$script:PS = $null
$script:RS = $null
$script:Handle = $null

function Write-Log($Text) {
    $SharedLines.Add($Text) | Out-Null
    $SharedQueue.Enqueue($Text) | Out-Null
}

function Write-Section($Name) {
    Write-Log ''
    Write-Log ('=' * 55)
    Write-Log "  $Name"
    Write-Log ('=' * 55)
}

function Format-Time($Seconds) {
    if ($Seconds -lt 0 -or $Seconds -gt 315360000) { return 'Unknown' }
    $t = [long]$Seconds
    $m = [int]($t / 60); $s = $t % 60
    $h = [int]($m / 60); $m = $m % 60
    $d = [int]($h / 24); $h = $h % 24
    if ($d) { return "${d}d ${h}h ${m}m" }
    if ($h) { return "${h}h ${m}m" }
    return "${m}m ${s}s"
}

function LogData($K, $V) { $SharedJson[$K] = $V }

# ---------------------------------------------------------------------------
function Test-Snapshot {
    Write-Section 'System Snapshot'
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Log "  OS: $($os.Caption) ($($os.Version))"
    LogData 'OS' "$($os.Caption) $($os.Version)"
    Write-Log "  Last boot: $($os.LastBootUpTime)"
    $uptime = (Get-Date) - $os.LastBootUpTime
    Write-Log "  Uptime: $(Format-Time $uptime.TotalSeconds)"

    $cs = Get-CimInstance Win32_ComputerSystem
    Write-Log "  Manufacturer: $($cs.Manufacturer)"
    LogData 'Manufacturer' $cs.Manufacturer
    Write-Log "  Model: $($cs.Model)"
    LogData 'Model' $cs.Model

    try {
        $bios = Get-CimInstance Win32_BIOS
        Write-Log "  BIOS: $($bios.SMBIOSBIOSVersion) ($($bios.Manufacturer))"
        LogData 'BIOS' $bios.SMBIOSBIOSVersion
        Write-Log "  Serial: $($bios.SerialNumber)"
        LogData 'Serial' $bios.SerialNumber
    } catch { }

    $cpu = Get-CimInstance Win32_Processor
    Write-Log "  CPU: $($cpu.Name)"
    LogData 'CPU' $cpu.Name
    Write-Log "  Cores: $($cpu.NumberOfCores) physical, $($cpu.NumberOfLogicalProcessors) logical"
    LogData 'Cores' "$($cpu.NumberOfCores)p/$($cpu.NumberOfLogicalProcessors)l"
    Write-Log "  Clock: $($cpu.CurrentClockSpeed) MHz (max $($cpu.MaxClockSpeed) MHz)"

    $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
    $ramFree = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
    $ramFreeGB = [math]::Round($ramFree, 2)
    $ramUsed = [math]::Round($ramGB - $ramFreeGB, 2)
    $ramPct = [math]::Round(($ramUsed / $ramGB) * 100)
    Write-Log "  RAM: ${ramGB}GB total, ${ramUsed}GB used (${ramPct}%)"
    LogData 'RAM' "${ramGB}GB total, ${ramUsed}GB used (${ramPct}%)"

    try {
        $physMem = Get-CimInstance Win32_PhysicalMemory | Sort-Object BankLabel
        $totalSlots = ($physMem | Measure-Object).Count
        $usedSlots = ($physMem | Where-Object { $_.Capacity -and $_.Capacity -gt 0 } | Measure-Object).Count
        $speeds = $physMem | Where-Object { $_.Speed -and $_.Speed -gt 0 } | Select-Object -ExpandProperty Speed -Unique
        $speedStr = if ($speeds) { ($speeds -join '/') + ' MT/s' } else { 'unknown' }
        Write-Log "  RAM slots: ${usedSlots} used / ${totalSlots} total, $speedStr"
        $formFactors = $physMem | Where-Object { $_.FormFactor } | Select-Object -ExpandProperty FormFactor -Unique
        foreach ($ff in $formFactors) {
            $ffName = switch ($ff) { 8 { 'DIMM' } 9 { 'SODIMM' } 12 { 'SO-DIMM' } default { "type $ff" } }
            if ($ff -eq 8 -or $ff -eq 9 -or $ff -eq 12) { Write-Log "  Form factor: $ffName" }
        }
        foreach ($m in $physMem) {
            if ($m.Capacity -and $m.Capacity -gt 0) {
                $sz = [math]::Round($m.Capacity / 1GB, 1)
                Write-Log "    Slot $($m.BankLabel): ${sz}GB $($m.Speed)MT/s $($m.Manufacturer)"
            }
        }
    } catch { }

    $disk = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3'
    foreach ($d in $disk) {
        $free = [math]::Round($d.FreeSpace / 1GB, 1)
        $total = [math]::Round($d.Size / 1GB, 1)
        Write-Log "  Drive $($d.DeviceID): ${total}GB (${free}GB free)"
    }
    if ($SharedAdmin) { Write-Log '  (running as admin)' } else { Write-Log '  (not admin - some data may be limited)' }
}

# ---------------------------------------------------------------------------
function Test-CPU {
    Write-Section 'CPU Checks'
    $cpu = Get-CimInstance Win32_Processor
    $load = $cpu.LoadPercentage
    if ($load -gt 70) { $desc = 'heavy load' } elseif ($load -gt 30) { $desc = 'moderate' } else { $desc = 'mostly idle' }
    Write-Log "  Current usage: ${load}% ($desc)"

    Write-Log '  Temperatures:'
    try {
        $tz = Get-CimInstance -Namespace root/WMI -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
        foreach ($t in $tz) {
            $c = [math]::Round($t.CurrentTemperature / 10 - 273.15, 1)
            Write-Log "    Thermal zone: ${c}C"
        }
    } catch { Write-Log '    (run as admin to see temps)' }

    Write-Log '  Running prime calculation test (3s)...'
    $end = (Get-Date).AddSeconds(3)
    $count = 1; $n = 3
    while ((Get-Date) -lt $end) {
        $prime = $true; $sqrt = [math]::Sqrt($n)
        for ($i = 3; $i -le $sqrt; $i += 2) { if ($n % $i -eq 0) { $prime = $false; break } }
        if ($prime) { $count++ }
        $n += 2
    }
    Write-Log "  $count primes found"
}

# ---------------------------------------------------------------------------
function Test-Memory {
    Write-Section 'Memory Checks'
    Write-Log '  Running RAM speed test (64 MB)...'
    $buf = New-Object byte[] (64 * 1024 * 1024)
    $t0 = Get-Date
    for ($i = 0; $i -lt $buf.Length; $i += 4096) { $buf[$i] = ($i / 4096) % 256 }
    $checksum = 0
    for ($i = 0; $i -lt $buf.Length; $i += 4096) { $checksum = ($checksum + $buf[$i]) % 1000000007 }
    $dt = ((Get-Date) - $t0).TotalSeconds
    Write-Log "  done in $([math]::Round($dt, 2))s (checksum=$checksum)"

    Write-Log '  Checking for memory errors in event log...'
    try {
        $script:MemErrors = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='*Memory*'} -MaxEvents 5 -ErrorAction SilentlyContinue
        if ($script:MemErrors) {
            Write-Log "    Found $($script:MemErrors.Count) memory-related events (review recommended)"
        } else {
            Write-Log '    No memory errors found'
        }
    } catch { Write-Log '    Event log unavailable' }
}

# ---------------------------------------------------------------------------
function Test-Disk {
    Write-Section 'Disk Checks'
    Write-Log '  Physical drives:'
    try {
        $drives = Get-CimInstance Win32_DiskDrive
        foreach ($d in $drives) {
            $model = $d.Model
            $sz = [math]::Round($d.Size / 1GB, 1)
            $iface = $d.InterfaceType
            $rpm = $d.RotationsPerMinute
            if ($rpm -and $rpm -gt 0) { $type = "HDD (${rpm}RPM)" }
            elseif ($model -match 'SSD|NVMe') { $type = 'SSD' }
            elseif (-not $rpm) { $type = 'SSD' }
            elseif ($iface -match 'NVMe') { $type = 'SSD (NVMe)' }
            else { $type = 'HDD' }
            Write-Log "    $model - ${sz}GB, $type"
        }
    } catch { Write-Log '    (unavailable)' }

    Write-Log '  SMART / health:'
    try {
        if ($SharedAdmin) {
            $pds = Get-PhysicalDisk -ErrorAction Stop
            foreach ($pd in $pds) {
                $hlth = $pd.HealthStatus
                $op = $pd.OperationalStatus
                $w = Get-PhysicalDisk -FriendlyName $pd.FriendlyName | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
                $wear = if ($w -and $w.WearPercentage -ge 0) { "$($w.WearPercentage)%" } else { 'N/A' }
                $realloc = if ($w) { $w.ReadErrorsTotal } else { 'N/A' }
                Write-Log "    $($pd.FriendlyName): health=$hlth, op=$op, wear=$wear, read errors=$realloc"
            }
        } else {
            Write-Log '    (run as admin for SMART details)'
            foreach ($d in (Get-CimInstance Win32_DiskDrive)) {
                Write-Log "    $($d.Model) - status unknown (admin required)"
            }
        }
    } catch { Write-Log '    (SMART unavailable)' }

    $tf = "$env:TEMP\__systest.tmp"
    Write-Log '  Running disk speed test (20 MB) on drive C:...'
    $data = New-Object byte[] (20 * 1024 * 1024)
    (New-Object Random).NextBytes($data)
    $t0 = Get-Date
    [System.IO.File]::WriteAllBytes($tf, $data)
    $tw = ((Get-Date) - $t0).TotalSeconds
    $t0 = Get-Date
    $r = [System.IO.File]::ReadAllBytes($tf)
    $tr = ((Get-Date) - $t0).TotalSeconds
    Remove-Item $tf -ErrorAction SilentlyContinue
    Write-Log ' done'
    Write-Log ('  Write: ' + [math]::Round(20 / $tw, 1) + ' MB/s (' + [math]::Round($tw, 2) + 's)')
    Write-Log ('  Read:  ' + [math]::Round(20 / $tr, 1) + ' MB/s (' + [math]::Round($tr, 2) + 's)')
    LogData 'DiskWrite' "$([math]::Round(20 / $tw, 1)) MB/s"
    LogData 'DiskRead' "$([math]::Round(20 / $tr, 1)) MB/s"
}

# ---------------------------------------------------------------------------
function Test-Battery {
    Write-Section 'Battery Checks'
    try {
        $batt = Get-CimInstance Win32_Battery -ErrorAction Stop
        if (-not $batt) { Write-Log '  No battery found.' }
        else {
            Write-Log "  Charge: $($batt.EstimatedChargeRemaining)%"
            Write-Log "  Status: $(if ($batt.BatteryStatus -eq 2) { 'Charging' } else { 'On battery' })"
            if ($batt.EstimatedRunTime -and $batt.EstimatedRunTime -gt 0 -and $batt.EstimatedRunTime -lt 1000000) {
                Write-Log "  Est. time left: $(Format-Time ($batt.EstimatedRunTime * 60))"
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
                                Write-Log "  Design capacity: ${desCap}Wh, Full charge: ${fullCap}Wh"
                                Write-Log "  Battery health: ${hp}%"
                            }
                        } else { Write-Log "  Design capacity: ${desCap}Wh" }
                        $batHealthOk = $true
                    }
                }
            }
            if ($batCycle) {
                $cc = $batCycle.CycleCount
                Write-Log "  Cycle count: $cc"
                LogData 'BatteryCycleCount' $cc
            }
            if (-not $batHealthOk) { Write-Log '  (battery health details unavailable)' }
        }
    } catch { Write-Log '  Battery: unavailable' }
}

# ---------------------------------------------------------------------------
function Test-Keyboard {
    Write-Section 'Keyboard Checks'
    Write-Log '  Click the SystemTester window, then press each key within 5 seconds.'
    Write-Log '  F-keys: if they fail, the F-row is set to media keys (FnLock).'
    Write-Log '  Hold Fn while pressing, or toggle FnLock (usually Fn+Esc).'

    $keys = @('A','B','C','D','E','F','G','H','I','J','1','2','Escape',
              'F1','F2','F3','F4','F5','F6','F7','F8','F9','F10','F11','F12',
              'Up','Down','Left','Right','Space')
    $passed = 0; $failed = 0; $missedF = 0
    foreach ($k in $keys) {
        Write-Log "  Press '$k' ..."
        $SharedKeyHits.TryRemove($k, [ref]$null) | Out-Null
        $deadline = (Get-Date).AddSeconds(5)
        $hit = $false
        while ((Get-Date) -lt $deadline) {
            if ($SharedKeyHits.ContainsKey($k)) { $hit = $true; break }
            Start-Sleep -Milliseconds 40
        }
        if ($hit) { Write-Log "    $k : OK"; $passed++ }
        else {
            Write-Log "    $k : missed"; $failed++
            if ($k -match '^F\d+$') { $missedF++ }
        }
    }
    Write-Log "  Keys: $passed OK, $failed missed"
    if ($missedF) {
        Write-Log '  Note: F-keys missed - the F-row is sending media codes, not F-key'
        Write-Log '  scan codes (FnLock on). This is normal laptop behaviour; the keys'
        Write-Log '  are not broken. Hold Fn or toggle FnLock (Fn+Esc) and re-run.'
    }
    $script:LastFailed = $failed
}

# ---------------------------------------------------------------------------
function Test-BatteryLife {
    Write-Section 'Battery Life Estimate'
    try {
        $batt = Get-CimInstance Win32_Battery -ErrorAction Stop
        if (-not $batt) { Write-Log '  No battery found.' }
        elseif ($batt.BatteryStatus -eq 2) { Write-Log "  Plugged in - can't estimate." }
        else {
            $b1 = $batt.EstimatedChargeRemaining
            Write-Log "  Starting: ${b1}%"
            if ($SharedNoWait) { Write-Log '  Skipped (Skip 60s wait checked)' }
            else {
                Write-Log '  Waiting 60 seconds...'
                for ($i = 60; $i -ge 1; $i--) {
                    if ($i % 15 -eq 0) { Write-Log "    ...${i}s left" }
                    Start-Sleep 1
                }
                $batt2 = Get-CimInstance Win32_Battery
                $b2 = $batt2.EstimatedChargeRemaining
                $delta = $b1 - $b2
                if ($delta -le 0) { Write-Log "  Battery didn't drop (sensor noise)." }
                else {
                    $rate = $delta * 60
                    $mins = ($b2 * 60) / $delta
                    $hrs = [math]::Floor($mins / 60)
                    $rm = [math]::Round($mins % 60)
                    Write-Log "  Dropped: ${b1}% -> ${b2}% (lost ${delta}%)"
                    Write-Log "  Drain rate: ~${rate}% per hour"
                    Write-Log "  Estimated runtime left: ~${hrs}h ${rm}m"
                }
            }
        }
    } catch { Write-Log '  Battery: unavailable' }
}

# ---------------------------------------------------------------------------
function Test-Events {
    Write-Section 'Event Log Checks'
    Write-Log '  Checking for critical system events...'
    try {
        $script:Critical = Get-WinEvent -FilterHashtable @{LogName='System'; Level=1} -MaxEvents 10 -ErrorAction SilentlyContinue
        if ($script:Critical) {
            Write-Log "    Found $($script:Critical.Count) critical events (last 10):"
            LogData 'CriticalEvents' $script:Critical.Count
            foreach ($e in $script:Critical) {
                Write-Log "      $($e.TimeCreated) [$($e.ProviderName)] ID $($e.Id)"
            }
        } else { Write-Log '    No critical events found'; LogData 'CriticalEvents' 0 }
    } catch { Write-Log '    Event log unavailable' }

    Write-Log '  Checking for unexpected shutdowns...'
    try {
        $script:Shutdowns = Get-WinEvent -FilterHashtable @{LogName='System'; ID=41} -MaxEvents 5 -ErrorAction SilentlyContinue
        if ($script:Shutdowns) {
            Write-Log "    $($script:Shutdowns.Count) unexpected shutdown(s) (Kernel-Power ID 41):"
            LogData 'UnexpectedShutdowns' $script:Shutdowns.Count
            foreach ($s in $script:Shutdowns) { Write-Log "      $($s.TimeCreated)" }
        } else { Write-Log '    No unexpected shutdowns found'; LogData 'UnexpectedShutdowns' 0 }
    } catch { }
}

# ---------------------------------------------------------------------------
function Test-Summary {
    Write-Section 'Summary'
    $issues = @()
    if ($script:LastFailed -and $script:LastFailed -gt 0) { $issues += "Keyboard: $script:LastFailed keys missed" }
    if ($script:MemErrors -and $script:MemErrors.Count -gt 0) { $issues += 'Memory errors in event log' }
    if ($script:Critical -and $script:Critical.Count -gt 0) { $issues += "$($script:Critical.Count) critical system events" }
    if ($script:Shutdowns -and $script:Shutdowns.Count -gt 0) { $issues += "$($script:Shutdowns.Count) unexpected shutdown(s)" }
    if ($issues.Count -eq 0) { Write-Log '  No major issues detected.' }
    else { Write-Log '  Issues found:'; foreach ($m in $issues) { Write-Log "    - $m" } }
    Write-Log "  Hostname: $env:COMPUTERNAME"
    Write-Log '  Click "Save Report" to export the full report.'
}

# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'SystemTester'
$form.Size = New-Object System.Drawing.Size(960, 700)
$form.MinimumSize = New-Object System.Drawing.Size(700, 500)
$form.StartPosition = 'CenterScreen'
$form.KeyPreview = $true

$form.Add_KeyDown({
    param($s, $e)
    $keyName = $e.KeyCode.ToString()
    if ($keyName -match '^D(\d)$') { $keyName = $Matches[1] }
    if ($keyName -eq 'Spacebar') { $keyName = 'Space' }
    $script:KeyHits[$keyName] = 1
})

# --- top toolbar ---
$top = New-Object System.Windows.Forms.FlowLayoutPanel
$top.Dock = 'Top'
$top.AutoSize = $true
$top.Padding = New-Object System.Windows.Forms.Padding(6, 6, 6, 2)
$form.Controls.Add($top)

$btnRunAll = New-Object System.Windows.Forms.Button
$btnRunAll.Text = 'Run All Tests'
$btnRunAll.Size = New-Object System.Drawing.Size(110, 30)
$btnRunAll.BackColor = [System.Drawing.Color]::FromArgb(0, 128, 0)
$btnRunAll.ForeColor = 'White'
$btnRunAll.FlatStyle = 'Flat'
$top.Controls.Add($btnRunAll)

$chkNoWait = New-Object System.Windows.Forms.CheckBox
$chkNoWait.Text = 'Skip 60s battery wait'
$chkNoWait.AutoSize = $true
$chkNoWait.Margin = New-Object System.Windows.Forms.Padding(12, 8, 0, 0)
$top.Controls.Add($chkNoWait)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Save Report'
$btnSave.Size = New-Object System.Drawing.Size(95, 30)
$btnSave.Margin = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
$btnSave.BackColor = [System.Drawing.Color]::FromArgb(23, 121, 186)
$btnSave.ForeColor = 'White'
$btnSave.FlatStyle = 'Flat'
$top.Controls.Add($btnSave)

$btnSaveJson = New-Object System.Windows.Forms.Button
$btnSaveJson.Text = 'Save JSON'
$btnSaveJson.Size = New-Object System.Drawing.Size(95, 30)
$btnSaveJson.Margin = New-Object System.Windows.Forms.Padding(4, 0, 0, 0)
$btnSaveJson.BackColor = [System.Drawing.Color]::FromArgb(23, 121, 186)
$btnSaveJson.ForeColor = 'White'
$btnSaveJson.FlatStyle = 'Flat'
$top.Controls.Add($btnSaveJson)

# --- section toggles ---
$sec = New-Object System.Windows.Forms.FlowLayoutPanel
$sec.Dock = 'Top'
$sec.AutoSize = $true
$sec.Padding = New-Object System.Windows.Forms.Padding(6, 2, 6, 2)
$form.Controls.Add($sec)

$sectionChecks = @()
$sectionDefs = @(
    @{ key = 'Snapshot';     label = 'Snapshot' },
    @{ key = 'CPU';          label = 'CPU' },
    @{ key = 'Memory';       label = 'Memory' },
    @{ key = 'Disk';         label = 'Disk' },
    @{ key = 'Battery';      label = 'Battery' },
    @{ key = 'Keyboard';     label = 'Keyboard' },
    @{ key = 'BatteryLife';  label = 'Battery Life' },
    @{ key = 'Events';       label = 'Events' }
)
foreach ($def in $sectionDefs) {
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $def.label
    $cb.Tag = $def.key
    $cb.Checked = $true
    $cb.AutoSize = $true
    $cb.Margin = New-Object System.Windows.Forms.Padding(4, 4, 4, 2)
    $sec.Controls.Add($cb)
    $sectionChecks += $cb
}

# --- status bar ---
$status = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = 'Ready'
$status.Items.Add($statusLabel) | Out-Null
$form.Controls.Add($status)

# --- output ---
$textBox = New-Object System.Windows.Forms.TextBox
$textBox.Multiline = $true
$textBox.ReadOnly = $true
$textBox.ScrollBars = 'Vertical'
$textBox.Dock = 'Fill'
$textBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$textBox.BackColor = 'White'
$textBox.BorderStyle = 'FixedSingle'
$form.Controls.Add($textBox)
$textBox.BringToFront()

# --- helpers ---
function Start-Tests {
    param([string[]]$Sections)
    $funcs = @('Write-Log','Write-Section','Format-Time','LogData',
               'Test-Snapshot','Test-CPU','Test-Memory','Test-Disk','Test-Battery',
               'Test-Keyboard','Test-BatteryLife','Test-Events','Test-Summary')
    $defs = @()
    foreach ($f in $funcs) {
        $defs += "function $f {`n$((Get-Item "function:$f").Definition)`n}"
    }
    $body = $defs -join "`n`n"
    foreach ($s in $Sections) { $body += "`nTest-$s" }
    $body += "`nTest-Summary"

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('SharedQueue', $script:Q)
    $rs.SessionStateProxy.SetVariable('SharedLines', $script:Lines)
    $rs.SessionStateProxy.SetVariable('SharedJson', $script:Json)
    $rs.SessionStateProxy.SetVariable('SharedKeyHits', $script:KeyHits)
    $rs.SessionStateProxy.SetVariable('SharedNoWait', $script:NoWait)
    $rs.SessionStateProxy.SetVariable('SharedAdmin', $script:Admin)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($body)
    $script:RS = $rs
    $script:PS = $ps
    $script:Handle = $ps.BeginInvoke()
}

function Save-Report {
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'Text files (*.txt)|*.txt'
    $dlg.FileName = "SystemTester_Report_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').txt"
    if ($dlg.ShowDialog() -eq 'OK') {
        [System.IO.File]::WriteAllLines($dlg.FileName, $script:Lines)
        $statusLabel.Text = "Saved: $($dlg.FileName)"
    }
}

function Save-Json {
    if ($script:Json.Count -eq 0) {
        $statusLabel.Text = 'No data to save - run tests first.'
        return
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'JSON files (*.json)|*.json'
    $dlg.FileName = "SystemTester_Report_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').json"
    if ($dlg.ShowDialog() -eq 'OK') {
        $script:Json['Generated'] = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        $script:Json['Hostname'] = $env:COMPUTERNAME
        $script:Json | ConvertTo-Json | Out-File -FilePath $dlg.FileName -Encoding utf8
        $statusLabel.Text = "Saved: $($dlg.FileName)"
    }
}

# --- events ---
$btnRunAll.Add_Click({
    if ($script:Running) { return }
    $script:Running = $true
    $btnRunAll.Enabled = $false
    $textBox.Clear()
    $script:Lines.Clear()
    $script:Json.Clear()
    $script:KeyHits.Clear()
    $script:NoWait = $chkNoWait.Checked
    $enabled = @()
    foreach ($cb in $sectionChecks) { if ($cb.Checked) { $enabled += $cb.Tag } }
    if ($enabled.Count -eq 0) {
        $statusLabel.Text = 'No sections selected.'
        $script:Running = $false
        $btnRunAll.Enabled = $true
        return
    }
    $statusLabel.Text = 'Running...'
    Start-Tests -Sections $enabled
})

$btnSave.Add_Click({ Save-Report })
$btnSaveJson.Add_Click({ Save-Json })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 100
$timer.Add_Tick({
    $line = $null
    while ($script:Q.TryDequeue([ref]$line)) {
        $textBox.AppendText("$line`r`n")
    }
    if ($script:Handle -and $script:Handle.IsCompleted) {
        $script:Handle = $null
        try { $script:PS.EndInvoke($null) | Out-Null } catch { }
        $script:PS.Dispose(); $script:PS = $null
        $script:RS.Close(); $script:RS.Dispose(); $script:RS = $null
        $script:Running = $false
        $btnRunAll.Enabled = $true
        $statusLabel.Text = 'Done'
    }
})

$form.Add_FormClosing({
    param($s, $e)
    $timer.Stop()
    if ($script:PS) {
        try { $script:PS.Stop() } catch { }
        $script:PS.Dispose()
    }
    if ($script:RS) { try { $script:RS.Close() } catch { }; $script:RS.Dispose() }
    if ($script:ScriptDir -and (Split-Path $script:ScriptDir -Leaf) -like 'SystemTester_*') {
        try { Remove-Item -Recurse -Force $script:ScriptDir -ErrorAction Stop } catch {
            Start-Process cmd.exe -ArgumentList '/c', 'timeout /t 2 /nobreak > nul & rd /s /q', "`"$script:ScriptDir`"" -WindowStyle Hidden | Out-Null
        }
    }
})

$timer.Start()
$form.Add_Shown({
    $textBox.AppendText("SystemTester - click 'Run All Tests' to start.`r`n")
    $textBox.AppendText("Nothing is written to disk unless you click Save.`r`n")
})

[void]$form.ShowDialog()
