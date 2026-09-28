<#
.SYNOPSIS
  Forward an NVIDIA device (USB vendor 0955) from Windows into WSL2 so the
  SDK Manager container can see it. Requires usbipd-win:
      winget install --interactive --exact dorssel.usbipd-win

.DESCRIPTION
  Binding a device needs an elevated (Administrator) PowerShell the first time.
  Attaching uses --auto-attach so the device is re-attached whenever it
  re-enumerates (recovery mode -> flashing -> booted Jetson). Keep the window
  that this script opens running for the whole flash.

.EXAMPLE
  .\usb-attach.ps1              # find the NVIDIA device and attach it
  .\usb-attach.ps1 -BusId 2-3   # attach a specific device
  .\usb-attach.ps1 -List        # just show usbipd's device list
#>
param(
    [string] $BusId,
    [switch] $List
)
$ErrorActionPreference = 'Stop'

if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
    # A terminal opened before usbipd was installed won't have it on PATH yet.
    $installed = Join-Path $env:ProgramFiles 'usbipd-win'
    if (-not (Test-Path (Join-Path $installed 'usbipd.exe'))) {
        throw 'usbipd not found. Install it with: winget install --interactive --exact dorssel.usbipd-win'
    }
    $env:Path = "$installed;$env:Path"
}

if ($List) { usbipd list; exit $LASTEXITCODE }

if (-not $BusId) {
    # usbipd list rows look like: "2-3    0955:7023  APX    Not shared"
    $rows = usbipd list | Where-Object { $_ -match '^\s*(\d+-\d+)\s+0955:[0-9a-fA-F]{4}\s' }
    if (-not $rows) {
        usbipd list
        throw 'No NVIDIA USB device (VID 0955) found. Put the device in recovery mode, connect it, and retry (or pass -BusId).'
    }
    if (@($rows).Count -gt 1) {
        $rows
        throw 'More than one NVIDIA device found; pass -BusId to pick one.'
    }
    $BusId = ([regex]::Match(@($rows)[0], '^\s*(\d+-\d+)')).Groups[1].Value
    Write-Host "Found NVIDIA device on bus $BusId"
}

$state = usbipd list | Where-Object { $_ -match "^\s*$([regex]::Escape($BusId))\s" }
if ($state -match 'Not shared') {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "Bus $BusId is not shared yet. Run once from an Administrator PowerShell:  usbipd bind --busid $BusId"
    }
    usbipd bind --busid $BusId
}

Write-Host "Attaching $BusId to WSL with auto-attach in a new window. Leave it open while flashing."
Start-Process powershell -ArgumentList '-NoExit', '-Command', "usbipd attach --wsl --busid $BusId --auto-attach"
