# SystemTester

Laptop diagnostics for checking machines. A zero-dependency PowerShell GUI that runs from a one-liner and leaves nothing behind.

## Quick start

### Normal (no UAC prompt)

```powershell
irm https://raw.githubusercontent.com/cl0akdev/SystemTester/main/SystemTester-GUI.ps1 | iex
```

### Admin (full data: CPU temps, SMART disk health)

```powershell
irm https://raw.githubusercontent.com/cl0akdev/SystemTester/main/SystemTester-Admin.ps1 | iex
```

The admin version triggers a UAC prompt, opens the GUI elevated, and deletes itself when closed.

## What it checks

- **Snapshot** - OS, BIOS, serial, CPU, RAM slots/speeds, drives
- **CPU** - load, temps (admin), prime-calc stress test
- **Memory** - 64 MB RAM speed test, event-log memory errors
- **Disk** - model/type (SSD vs HDD), SMART health (admin), 20 MB read/write benchmark
- **Battery** - health %, cycle count, charge status
- **Keyboard** - interactive key test
- **Battery life** - 60 s drain estimate (can be skipped in the GUI)
- **Events** - critical events, unexpected shutdowns (Kernel-Power 41)
- **Summary** - detected issues

## Notes

- Runs entirely in memory. Reports are only written when you click **Save Report** / **Save JSON**.
- F-keys: if F1-F12 fail the keyboard test, the F-row might be set to media keys (FnLock on). Hold `Fn` or toggle `FnLock` (usually `Fn+Esc`). This is normal, not a fault.
- Needs internet to download. Windows PowerShell 5.1+ (built into Windows 10/11).

## Files

| File | Description |
| --- | --- |
| `SystemTester-GUI.ps1` | WinForms GUI (the one-liner target) |
| `SystemTester-Admin.ps1` | Elevates then runs the GUI |
| `SystemTester.ps1` | CLI version, all sections + JSON output |
