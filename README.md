# CRASH LOG

A background logger for a Windows PC that hard-freezes during Rust. A hard freeze writes
no crash dump, and Windows only records when the power button was pressed. This logger
writes a sensor row every 2 seconds, forced straight to disk, so the last row written is
the moment of the freeze and shows the conditions just before it.

## What it does

Started hidden at every logon by the Task Scheduler task `CrashLog`:

1. Copies Rust's `output_log.txt` into `rust-logs\` (Rust overwrites it on every launch).
2. Checks the System event log for unclean reboots (Kernel-Power 41) since the last run,
   and adds one row per reboot to `crashes.csv`, taken from the last sensor row before it.
3. Loops forever: one row every 2 seconds into `sensors\yyyy-MM-dd.csv`.

## Files

| Path                     | What                                                      |
|--------------------------|-----------------------------------------------------------|
| crashes.csv              | one row per crash; the file to open                       |
| sensors\yyyy-MM-dd.csv   | one row every 2 seconds, all day                          |
| rust-logs\               | saved copies of Rust's log, named by last-write time      |
| _engine\crashlog.ps1     | the logger                                                |
| _engine\install-task.ps1 | registers the logon task                                  |
| _engine\state.json       | bookmark: last unclean reboot already recorded            |
| _engine\engine.log       | the logger's own diary: starts, errors, cost per pass     |

Data files are not in this repository (see `.gitignore`): Rust's logs contain account
and server details.

## Sensor columns

| Column        | Meaning                                                    | Source                         |
|---------------|------------------------------------------------------------|--------------------------------|
| ts            | local time, yyyy-MM-dd HH:mm:ss                            | clock                          |
| rust_running  | Y if RustClient.exe is running                             | process list                   |
| gpu_load_pct  | GPU core load                                              | AMD driver, Load / GPU Core    |
| gpu_edge_c    | GPU edge temperature                                       | Temperature / GPU Core         |
| gpu_hotspot_c | hottest point on the GPU chip (junction)                   | Temperature / GPU Hot Spot     |
| gpu_power_w   | GPU power, firmware-averaged                               | Power / GPU Package            |
| gpu_core_mhz  | GPU core clock                                             | Clock / GPU Core               |
| vram_used_mb  | video memory in use on the card                            | SmallData / GPU Memory Used    |
| ram_used_gb   | system RAM in use                                          | Memory / Memory Used           |
| rust_mem_gb   | memory Rust has claimed (private bytes, RAM plus pagefile) | process list                   |

`crashes.csv` adds `froze_at` (last sensor row), `power_button_at`, `boot_at`,
`sensor_file`, `rust_log_file` and `note`.

## Install

Requires PowerShell 7 (`pwsh`) and an AMD GPU (other GPUs need different sensor names).

1. Download these NuGet packages and copy the listed DLL into `_engine\`:

   | Package                        | DLL inside the package                                   |
   |--------------------------------|----------------------------------------------------------|
   | LibreHardwareMonitorLib 0.9.6  | runtimes/win-x64/lib/net10.0/LibreHardwareMonitorLib.dll |
   | HidSharp 2.6.4                 | lib/netstandard2.0/HidSharp.dll                          |
   | RAMSPDToolkit-NDD 1.4.2        | lib/net10.0/RAMSPDToolkit-NDD.dll                        |
   | DiskInfoToolkit 1.1.2          | lib/net10.0/DiskInfoToolkit.dll                          |

2. Run `pwsh -File _engine\install-task.ps1`, then log off and on (or
   `Start-ScheduledTask CrashLog`).

Turn off: Task Scheduler -> Task Scheduler Library -> right-click CrashLog -> Disable.

## Limits

- The last 0 to 2 seconds before a freeze are not captured.
- Millisecond GPU power spikes are invisible at a 2-second interval.
- It records conditions at the moment of a freeze, not the cause.
