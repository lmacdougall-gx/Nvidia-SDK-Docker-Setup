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
$DockerDir      = Join-Path $PSScriptRoot 'docker'
$UbuntuVersions = '18.04', '20.04', '22.04', '24.04'

function Show-Usage {
    @"
Usage: .\sdkm.ps1 <command> [target] [-- sdkmanager-args...]

Commands:
  list                      Show available/loaded images and the device table
  load  <target|all>        Load NVIDIA's image tarball(s) from .\images into docker
  build <target|all>        Build the local image (NVIDIA's + flash prerequisites)
  gui   <target>            Launch the SDK Manager GUI
  cli   <target> -- ARGS    Run SDK Manager in CLI mode, e.g. -- --cli --help
  shell <target>            Open a bash shell in the container (debugging)
  logs  <target> [lines]    Show the end of SDK Manager's log (default 100 lines)
  doctor <target>           Check Docker, USB and the container for known flash problems
  reset <target>            Delete the persistent home volume (logins, downloads)

<target> is an Ubuntu version (18.04 20.04 22.04 24.04) or a device/JetPack alias:
  thor, jp7                 -> 24.04
  orin, jp6                 -> 22.04   (also offers JetPack 7.2+ for Orin)
  xavier, jp5               -> 20.04
  nano, tx1, tx2, jp4       -> 18.04

Environment: SDKM_NO_BUILD=1 runs NVIDIA's image as-is instead of the local build.
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
function Get-LocalTag([string] $v) { "sdkm-local:$SdkmVersion-Ubuntu_$v" }
function Get-VolumeName([string] $v) { "sdkm-home-$v" }

# Runs a native command without Windows PowerShell turning its stderr into a
# terminating error; returns stdout.
function Invoke-Quiet([scriptblock] $block) {
    $ErrorActionPreference = 'Continue'
    & $block 2>$null
}

function Get-ImageId([string] $tag) { Invoke-Quiet { docker image inspect -f '{{.Id}}' $tag } }
function Get-ImageLabels([string] $tag) {
    # {{index ... "key"}} can't be used: Windows PowerShell mangles the inner quotes.
    $json = Invoke-Quiet { docker image inspect -f '{{json .Config.Labels}}' $tag }
    if ($json -and $json -ne 'null') { return ($json | ConvertFrom-Json) }
    return $null
}
function Get-RecipeVersion {
    $m = Select-String -Path (Join-Path $DockerDir 'install.sh') -Pattern '^# sdkm\.recipe: *(\S+)'
    return $m.Matches[0].Groups[1].Value
}

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

# The local image is NVIDIA's image plus the flash prerequisites (see
# docker\install.sh). It is rebuilt when NVIDIA's image or the recipe changes.
function Test-LocalImageCurrent([string] $v) {
    $labels = Get-ImageLabels (Get-LocalTag $v)
    if (-not $labels) { return $false }
    return ($labels.'sdkm.base' -eq (Get-ImageId (Get-ImageTag $v))) -and
           ($labels.'sdkm.recipe' -eq (Get-RecipeVersion))
}

# Runs docker\install.sh as root in a container of NVIDIA's image and commits
# the result. (Not `docker build`: BuildKit's docker-container driver, the
# default on some Docker Desktop setups, can't use locally loaded images.)
function Build-SdkmImage([string] $v) {
    Import-SdkmImage $v | Out-Host
    $baseId = Get-ImageId (Get-ImageTag $v)
    $name = "sdkm-build-$v"
    Write-Host "Building $(Get-LocalTag $v) (needs internet, a few minutes the first time)..."
    $ErrorActionPreference = 'Continue'
    docker rm -f $name 2>$null | Out-Null
    docker create --name $name --user root --entrypoint bash (Get-ImageTag $v) /tmp/sdkm-build/install.sh | Out-Null
    $ok = $LASTEXITCODE -eq 0
    if ($ok) { docker cp "$DockerDir\." "${name}:/tmp/sdkm-build"; $ok = $LASTEXITCODE -eq 0 }
    if ($ok) { docker start -a $name | Out-Host; $ok = $LASTEXITCODE -eq 0 }
    if ($ok) {
        # Windows PowerShell (and PowerShell before 7.3) drops embedded double
        # quotes when calling native programs unless they are escaped as \".
        $legacyQuoting = $PSVersionTable.PSVersion -lt [version]'7.3' -or $PSNativeCommandArgumentPassing -eq 'Legacy'
        $q = if ($legacyQuoting) { '\"' } else { '"' }
        # Restore NVIDIA's runtime settings, which the build container overrode.
        docker commit `
            --change 'USER nvidia' `
            --change 'WORKDIR /home/nvidia' `
            --change "ENTRYPOINT [${q}docker-entrypoint.sh${q}]" `
            --change "CMD [${q}sdkmanager${q}]" `
            --change "LABEL sdkm.base=$baseId sdkm.recipe=$(Get-RecipeVersion)" `
            $name (Get-LocalTag $v) | Out-Null
        $ok = $LASTEXITCODE -eq 0
    }
    docker rm -f $name 2>$null | Out-Null
    if ($ok) { Write-Host "Built $(Get-LocalTag $v)" }
    return $ok
}

# Returns the image a container should use.
function Get-RunImage([string] $v) {
    Import-SdkmImage $v | Out-Host
    if ($env:SDKM_NO_BUILD -eq '1') {
        Write-Warning "SDKM_NO_BUILD=1: using NVIDIA's image; flashing may fail after the first launch"
        return (Get-ImageTag $v)
    }
    if (-not (Test-LocalImageCurrent $v)) {
        if (-not (Build-SdkmImage $v)) {
            if (Get-ImageId (Get-LocalTag $v)) {
                Write-Warning "rebuild failed; using the existing (older) $(Get-LocalTag $v)"
            } else {
                throw "could not build $(Get-LocalTag $v). Check your internet connection, or set `$env:SDKM_NO_BUILD='1' to run NVIDIA's image as-is"
            }
        }
    }
    return (Get-LocalTag $v)
}

function Show-List {
    '{0,-8} {1,-40} {2,-7} {3,-6} {4}' -f 'UBUNTU', 'IMAGE', 'LOADED', 'BUILT', 'TARBALL'
    foreach ($v in $UbuntuVersions) {
        $isLoaded = Test-Loaded $v
        $loaded = if ($isLoaded) { 'yes' } else { 'no' }
        $built = if ($isLoaded -and (Test-LocalImageCurrent $v)) { 'yes' } else { 'no' }
        $file = Find-Tarball $v
        $name = if ($file) { $file.Name } else { '(missing)' }
        '{0,-8} {1,-40} {2,-7} {3,-6} {4}' -f $v, (Get-ImageTag $v), $loaded, $built, $name
    }
    @"

Recommended host Ubuntu per device (see README for details):
  Jetson Thor                 JetPack 7.x   -> 24.04
  Jetson Orin family          JetPack 6.x / 7.2+ -> 22.04
  Jetson Orin / Xavier        JetPack 5.x   -> 20.04
  Jetson Nano / TX1 / TX2     JetPack 4.x   -> 18.04
"@
}

function Get-JetsonModel([string] $usbPid) {
    switch ($usbPid) {
        '7f21' { 'Jetson Nano (recovery mode)' }
        '7c18' { 'Jetson TX2 (recovery mode)' }
        '7019' { 'Jetson AGX Xavier (recovery mode)' }
        '7e19' { 'Jetson Xavier NX (recovery mode)' }
        '7023' { 'Jetson AGX Orin (recovery mode)' }
        { $_ -in '7323', '7423' } { 'Jetson Orin NX (recovery mode)' }
        { $_ -in '7523', '7623' } { 'Jetson Orin Nano (recovery mode)' }
        '7035' { 'Jetson in flash mode (initrd running)' }
        '7020' { 'Jetson booted into Linux' }
        default { 'unknown NVIDIA device' }
    }
}

function Invoke-Doctor([string] $v) {
    $script:fails = 0
    function Pass([string] $m) { "  [PASS] $m" }
    function Fail([string] $m) { "  [FAIL] $m"; $script:fails++ }

    'Host'
    Pass 'Docker Desktop is running'
    $usbipd = (Get-Command usbipd -ErrorAction SilentlyContinue) -or (Test-Path "$env:ProgramFiles\usbipd-win\usbipd.exe")
    if ($usbipd) { Pass 'usbipd-win is installed' } else { Fail 'usbipd-win is not installed (winget install --exact dorssel.usbipd-win)' }

    'Image'
    if (-not (Test-Loaded $v)) { Fail "$(Get-ImageTag $v) is not loaded (.\sdkm.ps1 load $v)" }
    elseif (Test-LocalImageCurrent $v) { Pass "$(Get-LocalTag $v) is built and current" }
    else { Fail "$(Get-LocalTag $v) is missing or outdated (.\sdkm.ps1 build $v)" }

    'Container'
    $img = if (Get-ImageId (Get-LocalTag $v)) { Get-LocalTag $v } else { Get-ImageTag $v }
    if (Get-ImageId $img) {
        $probe = 'for t in cpp dtc python3 lsusb sshpass exportfs rpcbind; do command -v $t >/dev/null && echo ok:$t || echo miss:$t; done; ids=$(lsusb 2>/dev/null | grep -o "0955:[0-9a-f]\{4\}"); [ -n "$ids" ] && for i in $ids; do echo usb:$i; done || echo nousb'
        $lines = Invoke-Quiet { docker run --rm --privileged -v /dev/bus/usb:/dev/bus/usb --entrypoint bash $img -c $probe }
        foreach ($line in $lines) {
            if ($line -like 'ok:*') { Pass "$($line.Substring(3)) found" }
            elseif ($line -like 'miss:*') { Fail "$($line.Substring(5)) missing (flash prerequisites not installed)" }
            elseif ($line -like 'usb:*') { $id = $line.Substring(4); Pass "USB ${id}: $(Get-JetsonModel $id.Substring(5))" }
            elseif ($line -eq 'nousb') { Fail 'no NVIDIA USB device visible (put the Jetson in recovery mode, then run .\usb-attach.ps1)' }
        }
    }
    ''
    if ($script:fails -eq 0) { 'All checks passed.' } else { "$($script:fails) check(s) failed." }
}

function Show-Logs([string] $v, [string] $lines) {
    if (-not $lines) { $lines = '100' }
    $show = 'f=$(ls -t ~/.nvsdkm/sdkm*.log 2>/dev/null | head -1); [ -n "$f" ] || { echo "no SDK Manager log yet"; exit 0; }; echo "== $f"; tail -n ' + $lines + ' "$f"'
    $ErrorActionPreference = 'Continue'
    $running = (docker inspect -f '{{.State.Running}}' "sdkm-$v" 2>$null) -eq 'true'
    if ($running) { docker exec "sdkm-$v" bash -c $show }
    else {
        Import-SdkmImage $v | Out-Null
        docker run --rm -v "$(Get-VolumeName $v):/home/nvidia" --entrypoint bash (Get-ImageTag $v) -c $show
    }
}

# Before SDK Manager starts, sdkm-prereqs (baked into the local image) installs
# any flash prerequisite the installed JetPack asks for that the image lacks.
$Prereqs = 'command -v sdkm-prereqs >/dev/null && sdkm-prereqs'
# `sdkmanager` (GUI mode) launches the Electron window as a detached child and
# exits immediately, which would stop the container. Piping through `cat` keeps
# the container alive until the GUI closes its stdout, i.e. the window closes.
$GuiWrapper = @('-c', ($Prereqs + '; sdkmanager "$@" | cat'), 'gui')
$CliWrapper = @('-c', ($Prereqs + '; exec sdkmanager "$@"'), 'cli')

function Invoke-Container([string] $v, [string] $entrypoint, [string[]] $extra) {
    $image = Get-RunImage $v
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
        $image
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
    { $_ -in 'load', 'build' } {
        $vers = if ($Target -eq 'all') { $UbuntuVersions } else { @(Resolve-Target $Target) }
        foreach ($v in $vers) {
            if ($Command -eq 'load') { Import-SdkmImage $v }
            elseif (-not (Build-SdkmImage $v)) { throw "build failed for Ubuntu $v" }
        }
    }
    'gui'   { Invoke-Container (Resolve-Target $Target) 'bash' ($GuiWrapper + $rest) }
    'cli'   {
        if ($rest.Count -eq 0) { $rest = @('--cli', '--help') }
        Invoke-Container (Resolve-Target $Target) 'bash' ($CliWrapper + $rest)
    }
    'logs'   { Show-Logs (Resolve-Target $Target) ($rest | Select-Object -First 1) }
    'doctor' { Invoke-Doctor (Resolve-Target $Target) }
    'shell' { Invoke-Container (Resolve-Target $Target) 'bash' $rest }
    'reset' { docker volume rm (Get-VolumeName (Resolve-Target $Target)) }
    default {
        # Allow `.\sdkm.ps1 orin` as shorthand for `.\sdkm.ps1 gui orin`.
        $extra = @(@($Target) + $rest | Where-Object { $_ -and $_ -ne '--' })
        Invoke-Container (Resolve-Target $Command) 'bash' ($GuiWrapper + $extra)
    }
}
