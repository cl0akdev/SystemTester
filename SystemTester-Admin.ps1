# SystemTester - Admin launcher
# Runs the SystemTester GUI elevated (UAC prompt) for full data (temps, SMART).
# Self-cleaning: nothing is left on disk after the GUI closes.
# One-liner:  irm https://raw.githubusercontent.com/cl0akdev/SystemTester/main/SystemTester-Admin.ps1 | iex

$ErrorActionPreference = 'Stop'
$guiUrl = 'https://raw.githubusercontent.com/cl0akdev/SystemTester/main/SystemTester-GUI.ps1'

$dir = Join-Path $env:TEMP ('SystemTester_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$file = Join-Path $dir 'SystemTester-GUI.ps1'
Invoke-WebRequest -Uri $guiUrl -OutFile $file

$isAdmin = [bool]([Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

if ($isAdmin) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $file
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
} else {
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $file + '"'
    try {
        Start-Process powershell -Verb RunAs -ArgumentList $argLine -ErrorAction Stop
        Write-Host 'UAC accepted? The SystemTester GUI will open elevated.'
        Write-Host "It deletes itself from $dir when closed."
    } catch {
        Write-Host 'Elevation was cancelled.'
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    }
}
