# crashlog.ps1 -- Rust crash logger.
# Started at logon by the Task Scheduler task "CrashLog". Runs hidden until shutdown.
#   1. Copies Rust's last output_log.txt into rust-logs\ (Rust overwrites it every launch).
#   2. If Windows recorded an unclean reboot since the last run, adds a row to crashes.csv
#      built from the last sensor row written before that reboot.
#   3. Forever: one sensor row every 2 seconds into sensors\yyyy-MM-dd.csv, forced to disk.
# Test switches: -Root points at a different folder; -ChoresOnly skips the loop.

param(
    [string]$Root = (Split-Path $PSScriptRoot -Parent),
    [switch]$ChoresOnly
)

$ErrorActionPreference = 'Stop'
$Inv = [Globalization.CultureInfo]::InvariantCulture

$Engine   = $PSScriptRoot
$Sensors  = Join-Path $Root 'sensors'
$RustLogs = Join-Path $Root 'rust-logs'
$Crashes  = Join-Path $Root 'crashes.csv'
$State    = Join-Path $Root '_engine\state.json'
$EngLog   = Join-Path $Root '_engine\engine.log'
$RustOut  = 'C:\Program Files (x86)\Steam\steamapps\common\Rust\output_log.txt'
$IntervalMs = 2000
$TsFormat   = 'yyyy-MM-dd HH:mm:ss'

$SensorCols = 'ts','rust_running','gpu_load_pct','gpu_edge_c','gpu_hotspot_c','gpu_power_w',
              'gpu_core_mhz','vram_used_mb','ram_used_gb','rust_mem_gb'
$CrashCols  = @('froze_at','power_button_at','boot_at') + $SensorCols[1..9] +
              @('sensor_file','rust_log_file','note')

function Write-Engine([string]$msg) {
    Add-Content -Path $EngLog -Value ((Get-Date).ToString($TsFormat) + '  ' + $msg)
}

# Append lines and force them onto the disk itself (WriteThrough + Flush(true)), not just
# into Windows' write cache, so the rows survive a hard freeze. Throws if the file is locked.
function Add-DurableLines([string]$path, [string[]]$header, [string[]]$lines) {
    $isNew = -not (Test-Path $path)
    $fs = [IO.FileStream]::new($path, [IO.FileMode]::Append, [IO.FileAccess]::Write,
                               [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
    try {
        $all = if ($isNew) { @($header -join ',') + $lines } else { $lines }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($all -join "`r`n") + "`r`n")
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush($true)
    } finally { $fs.Dispose() }
}

function Format-Num($v, [int]$decimals) {
    if ($null -eq $v) { return '' }
    return ([double]$v).ToString('F' + $decimals, $Inv)
}

# ---------------------------------------------------------------- single instance
$created = $false
$mutex = [Threading.Mutex]::new($true, 'Local\CrashLogRust_' + ($Root -replace '[\\: ]', '_'), [ref]$created)
if (-not $created) { exit 0 }

foreach ($d in $Sensors, $RustLogs, (Join-Path $Root '_engine')) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}
Write-Engine "started (pid $PID)"

# ---------------------------------------------------------------- chore 1: save Rust's log
$rustLogName = $null; $rustLogTime = $null
try {
    if (Test-Path $RustOut) {
        $rustLogTime = (Get-Item $RustOut).LastWriteTime
        $rustLogName = 'output_log_' + $rustLogTime.ToString('yyyy-MM-dd_HHmm') + '.txt'
        $dest = Join-Path $RustLogs $rustLogName
        if (-not (Test-Path $dest)) {
            Copy-Item $RustOut $dest
            Write-Engine "saved Rust log as $rustLogName"
        }
    }
} catch { Write-Engine "ERROR saving Rust log: $($_.Exception.Message)" }

# ---------------------------------------------------------------- chore 2: crash check
function Find-LastRow([datetime]$after, [datetime]$before) {
    # Newest sensor row with after <= ts < before, searching back from the newest file.
    $files = Get-ChildItem $Sensors -Filter '*.csv' |
        Where-Object { $_.BaseName -match '^\d{4}-\d\d-\d\d$' } |
        Where-Object { $d = [datetime]::ParseExact($_.BaseName, 'yyyy-MM-dd', $Inv)
                       $d -ge $after.Date -and $d -le $before.Date } |
        Sort-Object BaseName -Descending
    foreach ($f in $files) {
        $lines = @(Get-Content $f.FullName -Tail 200)
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $cells = $lines[$i].Split(',')
            if ($cells[0] -eq 'ts' -or $cells[0] -eq '') { continue }
            $t = [datetime]::ParseExact($cells[0], $TsFormat, $Inv)
            if ($t -lt $after) { return $null }
            if ($t -lt $before) { return @{ File = $f.Name; Cells = $cells; Time = $t } }
        }
    }
    return $null
}

function Get-UncleanReboots([datetime]$since) {
    # Kernel-Power 41 = "rebooted without cleanly shutting down". Empty result is normal.
    try {
        return @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41
            ProviderName = 'Microsoft-Windows-Kernel-Power'; StartTime = $since } | Sort-Object TimeCreated)
    } catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return @() }
        throw
    }
}

try {
    $now = Get-Date
    $parse = { param($s) [datetime]::Parse($s, $Inv, [Globalization.DateTimeStyles]::RoundtripKind) }
    if (Test-Path $State) {
        $st = Get-Content $State -Raw | ConvertFrom-Json
        $bookmark     = & $parse $st.lastHandledReboot
        $sessionStart = & $parse $st.sessionStart
        $events = @(Get-UncleanReboots $bookmark.AddSeconds(1))
        if ($events.Count) { $bookmark = $events[-1].TimeCreated }
        $newest = $events | Select-Object -Last 1
        foreach ($ev in $events) {
            $x = [xml]$ev.ToXml(); $data = @{}
            foreach ($n in $x.Event.EventData.Data) { $data[$n.Name] = $n.'#text' }
            $bootAt = $ev.TimeCreated
            $pb = [int64]$data['PowerButtonTimestamp']
            $pbAt = if ($pb -gt 0) { [DateTime]::FromFileTime($pb) } else { $null }
            $cutoff = if ($pbAt) { $pbAt } else { $bootAt }

            $notes = @()
            $row = $null
            if ($ev -eq $newest) { $row = Find-LastRow $sessionStart $cutoff }
            if (-not $row) { $notes += 'no sensor data for this session' }
            if (-not $pbAt) { $notes += 'no power-button press recorded: power loss or automatic restart' }
            $logLink = ''
            if ($rustLogTime -and $rustLogTime -ge $sessionStart -and $rustLogTime -lt $bootAt -and $ev -eq $newest) {
                $logLink = $rustLogName
            }
            $vals = @(
                $(if ($row) { $row.Cells[0] } else { '' }),
                $(if ($pbAt) { $pbAt.ToString($TsFormat) } else { '' }),
                $bootAt.ToString($TsFormat)
            )
            $vals += if ($row) { $row.Cells[1..9] } else { @('') * 9 }
            $vals += @($(if ($row) { $row.File } else { '' }), $logLink, ($notes -join '; '))
            Add-DurableLines $Crashes $CrashCols @($vals -join ',')
            Write-Engine ("recorded crash: boot $($bootAt.ToString($TsFormat))" +
                          $(if ($row) { ", last sensor row $($row.Cells[0])" } else { ', no sensor data' }))
        }
    } else {
        $prior = @(Get-UncleanReboots (Get-Date).AddYears(-5))
        $bookmark = if ($prior.Count) { $prior[-1].TimeCreated } else { $now }
        Write-Engine 'first run: bookmark set to the newest existing unclean reboot; earlier crashes are not recorded'
    }
    if (-not (Test-Path $Crashes)) { Add-DurableLines $Crashes $CrashCols @() }
    @{ lastHandledReboot = $bookmark.ToString('o'); sessionStart = $now.ToString('o') } |
        ConvertTo-Json | Set-Content $State
} catch { Write-Engine "ERROR in crash check: $($_.Exception.Message)" }

if ($ChoresOnly) { Write-Engine 'chores only, exiting'; exit 0 }

# ---------------------------------------------------------------- sensor loop
$gpu = $null; $mem = $null; $Sens = @{}
try {
    foreach ($n in 'HidSharp', 'RAMSPDToolkit-NDD', 'DiskInfoToolkit', 'LibreHardwareMonitorLib') {
        Add-Type -Path (Join-Path $Engine "$n.dll")
    }
    $pc = [LibreHardwareMonitor.Hardware.Computer]::new()
    $pc.IsGpuEnabled = $true
    $pc.IsMemoryEnabled = $true
    $pc.Open()
    $gpu = $pc.Hardware | Where-Object { "$($_.HardwareType)" -eq 'GpuAmd' } | Select-Object -First 1
    $mem = $pc.Hardware | Where-Object { "$($_.HardwareType)" -eq 'Memory' -and $_.Name -eq 'Total Memory' } | Select-Object -First 1
    if ($gpu) { $gpu.Update() }
    if ($mem) { $mem.Update() }
    $want = [ordered]@{
        load = @($gpu, 'Load', 'GPU Core');        edge = @($gpu, 'Temperature', 'GPU Core')
        hot  = @($gpu, 'Temperature', 'GPU Hot Spot'); pwr = @($gpu, 'Power', 'GPU Package')
        clk  = @($gpu, 'Clock', 'GPU Core');       vram = @($gpu, 'SmallData', 'GPU Memory Used')
        ram  = @($mem, 'Data', 'Memory Used')
    }
    foreach ($k in $want.Keys) {
        $hw, $type, $name = $want[$k]
        $s = if ($hw) { $hw.Sensors | Where-Object { "$($_.SensorType)" -eq $type -and $_.Name -eq $name } | Select-Object -First 1 }
        if ($s) { $Sens[$k] = $s } else { Write-Engine "MISSING sensor: $type / $name (column left blank)" }
    }
    Write-Engine ("sensors ready: " + $(if ($gpu) { $gpu.Name } else { 'NO AMD GPU FOUND' }))
} catch { Write-Engine "ERROR opening sensors: $($_.Exception.Message) (logging Rust columns only)" }

$pending   = [Collections.Generic.List[string]]::new()
$pendFile  = $null
$sw        = [Diagnostics.Stopwatch]::new()
$passes = 0; $totalMs = 0.0; $maxMs = 0.0
$lastSummary = Get-Date
$lastError = ''

while ($true) {
    $sw.Restart()
    try {
        if ($gpu) { $gpu.Update() }
        if ($mem) { $mem.Update() }
        $rc = @(Get-Process -Name 'RustClient' -ErrorAction SilentlyContinue)
        $rustMem = if ($rc.Count) { ($rc | Measure-Object PrivateMemorySize64 -Sum).Sum / 1GB } else { $null }
        $t = Get-Date
        $line = @(
            $t.ToString($TsFormat),
            $(if ($rc.Count) { 'Y' } else { 'N' }),
            (Format-Num $Sens.load.Value 0), (Format-Num $Sens.edge.Value 0), (Format-Num $Sens.hot.Value 0),
            (Format-Num $Sens.pwr.Value 0),  (Format-Num $Sens.clk.Value 0),  (Format-Num $Sens.vram.Value 0),
            (Format-Num $Sens.ram.Value 2),  (Format-Num $rustMem 2)
        ) -join ','

        $file = Join-Path $Sensors ($t.ToString('yyyy-MM-dd') + '.csv')
        if ($pendFile -and $pendFile -ne $file -and $pending.Count) {
            Add-DurableLines $pendFile $SensorCols $pending.ToArray(); $pending.Clear()
        }
        $pendFile = $file
        $pending.Add($line)
        try {
            Add-DurableLines $file $SensorCols $pending.ToArray()
            if ($pending.Count -gt 1) { Write-Engine "wrote $($pending.Count) held rows after the file was locked" }
            $pending.Clear()
        } catch [System.IO.IOException] {
            # File open in Excel: hold rows in memory, retry next pass.
            if ($pending.Count -eq 1) { Write-Engine "sensor file locked (open in Excel?); holding rows" }
        }
        $lastError = ''
    } catch {
        $msg = $_.Exception.Message
        if ($msg -ne $lastError) { Write-Engine "ERROR in loop: $msg" ; $lastError = $msg }
    }
    $ms = $sw.Elapsed.TotalMilliseconds
    $passes++; $totalMs += $ms; if ($ms -gt $maxMs) { $maxMs = $ms }
    if (((Get-Date) - $lastSummary).TotalMinutes -ge 30) {
        Write-Engine ("cost: {0} passes, avg {1:F1} ms, max {2:F1} ms, working set {3} MB" -f
            $passes, ($totalMs / $passes), $maxMs, [math]::Round((Get-Process -Id $PID).WorkingSet64 / 1MB))
        $passes = 0; $totalMs = 0.0; $maxMs = 0.0; $lastSummary = Get-Date
    }
    $wait = $IntervalMs - [int]$sw.Elapsed.TotalMilliseconds
    if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
}
