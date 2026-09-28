<#
.SYNOPSIS
  Run NVIDIA SDK Manager in the Ubuntu docker image that matches the target
  device, on Windows with Docker Desktop (WSL2 backend). The GUI is shown
  through WSLg; USB devices must be attached to WSL with usb-attach.ps1.

.EXAMPLE
  .\sdkm.ps1 list
  .\sdkm.ps1 gui orin
  .\sdkm.ps1 cli 22.04 -- --cli --help
#>
param(
    [Parameter(Position = 0)] [string] $Command = 'help',
    [Parameter(Position = 1)] [string] $Target,
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $SdkmArgs
)
$ErrorActionPreference = 'Stop'

$SdkmVersion    = if ($env:SDKM_VERSION) { $env:SDKM_VERSION } else { '2.4.1.13536' }
$ImagesDir      = if ($env:SDKM_IMAGES_DIR) { $env:SDKM_IMAGES_DIR } else { Join-Path $PSScriptRoot 'images' }
$UbuntuVersions = '18.04', '20.04', '22.04', '24.04'

function Show-Usage {
    @"
Usage: .\sdkm.ps1 <command> [target] [-- sdkmanager-args...]

Commands:
  list                      Show available/loaded images and the device table
  load  <target|all>        Load image tarball(s) from .\images into docker
  gui   <target>            Launch the SDK Manager GUI
  cli   <target> -- ARGS    Run SDK Manager in CLI mode, e.g. -- --cli --help
  shell <target>            Open a bash shell in the container (debugging)
  reset <target>            Delete the persistent home volume (logins, downloads)

<target> is an Ubuntu version (18.04 20.04 22.04 24.04) or a device/JetPack alias:
  thor, jp7                 -> 24.04
  orin, jp6                 -> 22.04
  xavier, jp5               -> 20.04
  nano, tx1, tx2, jp4       -> 18.04
"@
}

function Resolve-Target([string] $t) {
    switch ($t) {
        { $_ -in $UbuntuVersions }            { return $t }
        { $_ -in 'thor', 'jp7' }              { return '24.04' }
        { $_ -in 'orin', 'jp6' }              { return '22.04' }
        { $_ -in 'xavier', 'jp5' }            { return '20.04' }
        { $_ -in 'nano', 'tx1', 'tx2', 'jp4' } { return '18.04' }
        ''      { throw "missing target (Ubuntu version or device alias). See .\sdkm.ps1 help" }
        default { throw "unknown target '$t'. See .\sdkm.ps1 help" }
    }
}

function Get-ImageTag([string] $v) { "sdkmanager:$SdkmVersion-Ubuntu_$v" }
function Get-VolumeName([string] $v) { "sdkm-home-$v" }

function Test-Loaded([string] $v) {
    return [bool](docker images -q (Get-ImageTag $v))
}

function Find-Tarball([string] $v) {
    Get-ChildItem -Path $ImagesDir -Filter "sdkmanager-$SdkmVersion-Ubuntu_${v}_docker.tar*" -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

function Import-SdkmImage([string] $v) {
    if (Test-Loaded $v) { Write-Host "$(Get-ImageTag $v) already loaded"; return }
    $tarball = Find-Tarball $v
    if (-not $tarball) {
        throw "no tarball for Ubuntu $v in $ImagesDir (expected sdkmanager-$SdkmVersion-Ubuntu_${v}_docker.tar*)"
    }
    # A clone made without git-lfs contains small pointer files instead of the
    # images, which docker rejects with an unhelpful "unexpected EOF".
    if ($tarball.Length -lt 1024 -and (Get-Content $tarball.FullName -TotalCount 1) -like 'version https://git-lfs*') {
        throw "$($tarball.Name) is a Git LFS pointer, not the image. Install Git LFS, then run: git lfs install; git lfs pull"
    }
    Write-Host "Loading $($tarball.Name) (this takes a minute)..."
    docker load -i $tarball.FullName
    if ($LASTEXITCODE -ne 0) { throw "docker load failed" }
}

function Show-List {
    '{0,-8} {1,-40} {2,-8} {3}' -f 'UBUNTU', 'IMAGE', 'LOADED', 'TARBALL'
    foreach ($v in $UbuntuVersions) {
        $loaded = if (Test-Loaded $v) { 'yes' } else { 'no' }
        $file = Find-Tarball $v
        $name = if ($file) { $file.Name } else { '(missing)' }
        '{0,-8} {1,-40} {2,-8} {3}' -f $v, (Get-ImageTag $v), $loaded, $name
    }
    @"

Recommended host Ubuntu per device (see README for details):
  Jetson Thor                 JetPack 7.x   -> 24.04
  Jetson Orin family          JetPack 6.x   -> 22.04
  Jetson Orin / Xavier        JetPack 5.x   -> 20.04
  Jetson Nano / TX1 / TX2     JetPack 4.x   -> 18.04
"@
}

# `sdkmanager` (GUI mode) launches the Electron window as a detached child and
# exits immediately, which would stop the container. Piping through `cat` keeps
# the container alive until the GUI closes its stdout, i.e. the window closes.
$GuiWrapper = @('-c', 'sdkmanager "$@" | cat', 'gui')

function Invoke-Container([string] $v, [string] $entrypoint, [string[]] $extra) {
    Import-SdkmImage $v
    $ttyFlag = if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { '-i' } else { '-it' }
    # Paths below are inside the Docker Desktop VM, not on Windows:
    #  /run/desktop/mnt/host/wslg/.X11-unix is WSLg's X server socket,
    #  /dev is the WSL2 kernel's devices (where usbipd-attached USB shows up).
    $runArgs = @(
        # NVIDIA's docker-entrypoint.sh is bypassed on purpose: it never starts
        # the GUI and appends a stray '%' to the last CLI argument.
        'run', '--rm', $ttyFlag, '--init',
        '--name', "sdkm-$v",
        '--privileged',
        '--network', 'host',
        '--shm-size', '2g',
        '-v', '/dev/bus/usb:/dev/bus/usb',
        '-v', '/dev:/dev',
        '-v', "$(Get-VolumeName $v):/home/nvidia",
        '-e', 'DISPLAY=:0',
        '-v', '/run/desktop/mnt/host/wslg/.X11-unix:/tmp/.X11-unix',
        '--entrypoint', $entrypoint,
        (Get-ImageTag $v)
    ) + $extra
    # Chromium logs harmless dbus errors to stderr; don't let them abort the script.
    $ErrorActionPreference = 'Continue'
    & docker @runArgs
    exit $LASTEXITCODE
}

# Windows PowerShell turns native stderr into terminating errors under 'Stop'.
$ErrorActionPreference = 'Continue'
docker version --format '{{.Server.Version}}' *> $null
$dockerOk = $LASTEXITCODE -eq 0
$ErrorActionPreference = 'Stop'
if (-not $dockerOk) { throw 'docker is not running. Start Docker Desktop and try again.' }

# PowerShell keeps a literal '--' in the remaining args; drop it.
$rest = @($SdkmArgs | Where-Object { $_ -ne $null })
if ($rest.Count -gt 0 -and $rest[0] -eq '--') { $rest = @($rest | Select-Object -Skip 1) }

switch ($Command) {
    { $_ -in 'help', '-h', '--help' } { Show-Usage }
    'list' { Show-List }
    'load' {
        if ($Target -eq 'all') { foreach ($v in $UbuntuVersions) { Import-SdkmImage $v } }
        else { Import-SdkmImage (Resolve-Target $Target) }
    }
    'gui'   { Invoke-Container (Resolve-Target $Target) 'bash' ($GuiWrapper + $rest) }
    'cli'   {
        if ($rest.Count -eq 0) { $rest = @('--cli', '--help') }
        Invoke-Container (Resolve-Target $Target) 'sdkmanager' $rest
    }
    'shell' { Invoke-Container (Resolve-Target $Target) 'bash' $rest }
    'reset' { docker volume rm (Get-VolumeName (Resolve-Target $Target)) }
    default {
        # Allow `.\sdkm.ps1 orin` as shorthand for `.\sdkm.ps1 gui orin`.
        $extra = @(@($Target) + $rest | Where-Object { $_ -and $_ -ne '--' })
        Invoke-Container (Resolve-Target $Command) 'bash' ($GuiWrapper + $extra)
    }
}
