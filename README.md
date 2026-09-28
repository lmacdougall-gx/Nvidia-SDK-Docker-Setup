# SDK Mananger

The SDK manager must be run within specific version of Ubuntu. The version required changes depending on which Nvidia device you are flashing. This repo will include instructions on how to run the SDK Manager for any Nvidia device while not needing to run any specific operating system. We can do this by running different docker images of ubuntu designed for the SDK Manager. We will also pass through the display of the docker image to maintain the SDK Manager's GUI, instead of doing things purely through terminal.

## Images

There are 4 images as of writing this documentation provided by Nvidia, Ubuntu 24.04, Ubuntu 22.04, Ubuntu 20.04, Ubuntu 18.04. All these images are for version 2.4.1.13536 of the SDK Manager. In the future, this list may need to be updated with newer, and possibly more ubuntu images.

| Tarball in `images/`                                   | Docker tag after loading                |
| ------------------------------------------------------ | --------------------------------------- |
| `sdkmanager-2.4.1.13536-Ubuntu_18.04_docker.tar.tar`   | `sdkmanager:2.4.1.13536-Ubuntu_18.04`   |
| `sdkmanager-2.4.1.13536-Ubuntu_20.04_docker.tar.tar`   | `sdkmanager:2.4.1.13536-Ubuntu_20.04`   |
| `sdkmanager-2.4.1.13536-Ubuntu_22.04_docker.tar.tar`   | `sdkmanager:2.4.1.13536-Ubuntu_22.04`   |
| `sdkmanager-2.4.1.13536-Ubuntu_24.04_docker.tar.tar`   | `sdkmanager:2.4.1.13536-Ubuntu_24.04`   |

The images can be downloaded from the [SDK Manager download page](https://developer.nvidia.com/sdk-manager) (Docker Image section, requires an NVIDIA Developer login). NVIDIA ships them as `.tar.gz`; either the compressed or uncompressed tarball works with the scripts here.

## Which image do I need?

Pick the image by the JetPack version you want to flash. Each JetPack release only supports certain host Ubuntu versions:

| Device                                 | JetPack       | Host Ubuntu supported | Alias to use          |
| -------------------------------------- | ------------- | --------------------- | --------------------- |
| Jetson AGX Thor                        | 7.x (L4T 38)  | 24.04                 | `thor`, `jp7`         |
| Jetson AGX Orin, Orin NX, Orin Nano    | 6.x (L4T 36)  | 22.04, 20.04          | `orin`, `jp6`         |
| Jetson AGX Orin, Orin NX, Orin Nano, AGX Xavier, Xavier NX | 5.x (L4T 35) | 20.04, 18.04 | `xavier`, `jp5` |
| Jetson Nano, TX1, TX2, TX2 NX, AGX Xavier, Xavier NX | 4.x (L4T 32) | 18.04, 16.04 | `nano`, `tx1`, `tx2`, `jp4` |

The alias always picks the newest Ubuntu in that row. For other products (DRIVE, Holoscan/IGX, etc.) check the host OS column in NVIDIA's [SDK Manager system requirements](https://docs.nvidia.com/sdk-manager/system-requirements/index.html) and pass the Ubuntu version directly (e.g. `22.04`). You can always pass a version number instead of an alias.

## Repository layout

```
images/           SDK Manager docker image tarballs from NVIDIA
sdkm.sh           Launcher for Linux hosts and WSL2 (bash)
sdkm.ps1          Launcher for Windows with Docker Desktop (PowerShell)
usb-attach.ps1    Windows only: forwards the Jetson's USB connection into WSL2
.gitattributes    Keeps sdkm.sh LF-only and stores images/ with Git LFS
```

Both launchers take the same commands:

| Command                     | What it does                                                          |
| --------------------------- | --------------------------------------------------------------------- |
| `list`                      | Show which images exist in `images/` and which are loaded into docker |
| `load <target\|all>`        | `docker load` the matching tarball(s). Done automatically on first run |
| `gui <target>`              | Launch the SDK Manager GUI. `sdkm orin` is shorthand for `sdkm gui orin` |
| `cli <target> -- <args>`    | Run SDK Manager's CLI, e.g. `-- --cli` or `-- --query non-interactive` |
| `shell <target>`            | Open bash inside the container (user `nvidia`, password `nvidia`, passwordless sudo) |
| `reset <target>`            | Delete that image's saved home volume (login, downloads, installed SDKs) |

`<target>` is an Ubuntu version (`18.04`, `20.04`, `22.04`, `24.04`) or an alias from the table above.

## Running on Linux

Requirements: an x86_64 Linux machine with a desktop session (X11 or Wayland with XWayland) and **Docker Engine** (not Docker Desktop for Linux, which runs containers inside a VM that can't see your display or USB devices).

```bash
sudo apt install docker.io x11-xserver-utils   # or install Docker Engine from docs.docker.com
sudo usermod -aG docker $USER                   # then log out and back in
sudo apt install qemu-user-static binfmt-support  # arm64 emulation, see below
```

**arm64 emulation:** while building the Jetson's root filesystem, SDK Manager `chroot`s into it and runs arm64 programs such as `dpkg`. The host kernel must be able to run them through QEMU, and the registration needs the `F` flag so it works inside the container. `cat /proc/sys/fs/binfmt_misc/qemu-aarch64` should show `enabled` and `F` in its `flags:` line. If it doesn't, run `sudo systemctl restart systemd-binfmt`. Without this, the "File System and OS" step fails with `chroot: failed to run command 'dpkg': Exec format error`. `sdkm.sh` warns at startup if it's missing.

**NFS server module (JetPack 6 and 7):** these releases flash by booting the Jetson from a temporary image that loads its files over NFS. The NFS server runs inside the container, but it uses the host kernel's `nfsd` module, so load it on the host:

```bash
sudo modprobe nfsd                                   # if "not found": sudo apt install linux-modules-extra-$(uname -r)
echo nfsd | sudo tee /etc/modules-load.d/nfsd.conf   # load it at every boot
grep nfsd /proc/filesystems                          # should print "nodev nfsd"
```

You don't need to run an NFS server on the host. If `nfs-kernel-server` is running on the host for something else, stop it while flashing (`sudo systemctl stop nfs-kernel-server`), since it conflicts with the container's server. Without `nfsd`, the flash fails with `no support in current kernel`. `sdkm.sh` warns about both at startup. If you load the module while SDK Manager is open, close it and start it again.

Then from the repo:

```bash
chmod +x sdkm.sh
./sdkm.sh load all      # optional, images load on first use anyway
./sdkm.sh gui orin
```

The script temporarily runs `xhost +local:` so the container can draw on your display and revokes it when SDK Manager exits.

## Running on Windows

Requirements:

1. **Docker Desktop** using the WSL2 backend (the default).
2. **WSL2 with WSLg**. Windows 11 has it built in. Check with `wsl --version` (WSLg version should be listed) and run `wsl --update` if needed.
3. **usbipd-win**, to get the Jetson's USB connection into WSL2 (only needed to flash, not to download):

   ```powershell
   winget install --interactive --exact dorssel.usbipd-win
   ```

Launch the GUI from PowerShell in the repo folder:

```powershell
.\sdkm.ps1 load all
.\sdkm.ps1 gui orin
```

If PowerShell refuses to run the script, allow local scripts for your user once with `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`, or run it with `powershell -ExecutionPolicy Bypass -File .\sdkm.ps1 gui orin`.

The SDK Manager window opens as a normal Windows window (titled "SDK Manager (docker-desktop)") through WSLg.

### Getting the Jetson into the container (Windows)

Windows owns USB devices by default. Before flashing, forward the Jetson to WSL2:

1. Put the Jetson in **Force Recovery mode** and connect it to the PC with USB.
2. The first time only, share the device from an **Administrator** PowerShell:
   ```powershell
   usbipd list                      # find the row with VID 0955 (NVIDIA), note its BUSID
   usbipd bind --busid <BUSID>
   ```
   In recovery mode the Jetson shows up as **`APX`**. That's expected: it's the boot ROM's recovery interface, which is what SDK Manager flashes through. The PID tells you which module it is, e.g. `0955:7f21` = Jetson Nano, `7c18` = TX2, `7019` = AGX Xavier, `7e19` = Xavier NX, `7023` = AGX Orin, `7323`/`7423` = Orin NX, `7523`/`7623` = Orin Nano. After flashing it reboots and comes back under a different PID (e.g. `7020`), and auto-attach picks that up too.
3. From a normal PowerShell in the repo, run:
   ```powershell
   .\usb-attach.ps1
   ```
   This finds the NVIDIA device and opens a window running `usbipd attach --wsl --auto-attach`. **Leave that window open for the whole flash.** The Jetson disconnects and reconnects several times (recovery mode, flashing, first boot), and auto-attach puts it back into WSL each time.
4. Start (or restart) `.\sdkm.ps1 gui <target>`. SDK Manager should detect the board.

You can also use `sdkm.sh` from a WSL2 Ubuntu shell instead of `sdkm.ps1`. For that, turn on Docker Desktop > Settings > Resources > WSL integration for your distro. The script detects WSL and uses the WSLg display automatically.

## Using SDK Manager in the container

- **Logging in:** the container has no web browser, so the **LOGIN** button can't open the NVIDIA login page. Click the **QR code** in the top-right corner of the login box and scan it with your phone to log in instead.
- **Persistence:** each Ubuntu version gets a docker volume (`sdkm-home-22.04`, etc.) mounted at `/home/nvidia`. Your login, `~/Downloads/nvidia/sdkm_downloads` and `~/nvidia/nvidia_sdk` survive between runs. Use `reset <target>` to wipe it.
- **Getting files out:** while the container is running, copy files with `docker cp sdkm-22.04:/home/nvidia/nvidia/nvidia_sdk ./nvidia_sdk`. Or use `shell <target>` and work in the container directly.
- **Closing:** closing the SDK Manager window stops and removes the container. `docker stop sdkm-22.04` also works.
- **Console noise:** `Failed to connect to the bus` (dbus) errors in the terminal are harmless and can be ignored.
- **Headless / scripted installs:** use the CLI, e.g.
  ```bash
  ./sdkm.sh cli orin -- --cli --query interactive
  ```
  which walks you through the options and prints the full unattended install command at the end.

## How it works

The scripts wrap `docker run` with the following:

| Flag                                          | Why                                                                         |
| --------------------------------------------- | --------------------------------------------------------------------------- |
| `--privileged`, `-v /dev:/dev`, `-v /dev/bus/usb:/dev/bus/usb` | Flashing needs loop devices, and the Jetson re-enumerates on USB during flashing, so passing single `--device` nodes isn't enough |
| `--network host`                              | Reach the Jetson's USB network (`192.168.55.1`) to install SDK components after flashing |
| `-e DISPLAY` + `/tmp/.X11-unix` mount         | Draw the GUI on the host display. On Windows the X socket comes from WSLg at `/run/desktop/mnt/host/wslg/.X11-unix` inside the Docker Desktop VM |
| `--shm-size 2g`                               | Electron/Chromium crashes with Docker's default 64 MB `/dev/shm`            |
| `--init`                                      | Proper signal handling so Ctrl+C and `docker stop` work                    |
| `--entrypoint`                                | Skips NVIDIA's `docker-entrypoint.sh`, which never launches the GUI and appends a stray `%` to the last CLI argument (a bug in the 2.4.1.13536 images) |

Also, in GUI mode `sdkmanager` starts the Electron window as a detached child and exits immediately, which would stop the container. The scripts run `sdkmanager | cat`, which keeps the container alive until the window closes.

## Known limitations

- **Flashing from Windows is not officially supported by NVIDIA.** It goes through usbipd + WSL2 and generally works, but it's less reliable than a native Linux host. If a flash keeps failing at "waiting for target to boot up" or the post-flash SDK component install can't reach `192.168.55.1`, the WSL2 kernel may be missing the USB networking drivers (`rndis_host` / `cdc_ncm`). In that case, flash from a Linux machine with `sdkm.sh`, or finish the component install over Ethernet by entering the Jetson's LAN IP in SDK Manager.
- **Jetson Nano / TX1 / TX2 (JetPack 4) usually fail to flash through usbipd** with `Error: Return value 8` / `Reading board information failed` right after `tegrarcm --oem platformdetails eeprom`. The board re-enumerates on USB after the recovery applet loads, and usbipd takes a few seconds to re-attach it (visible in `dmesg` as `USB disconnect` followed by `Device attached` ~4 s later). `tegrarcm` times out first. Workarounds: for a Nano Developer Kit with a microSD slot, write NVIDIA's SD card image with Balena Etcher instead of flashing, and use SDK Manager only for SDK components (uncheck Jetson Linux). For eMMC modules, flash from a native Linux host with `sdkm.sh`.
- Only x86_64 hosts are supported (the images are amd64).
- The GUI uses software rendering, so it can be slow to redraw. This doesn't affect downloads or flashing.

## Adding newer images

1. Download the new Docker images from the SDK Manager download page into `images/`, keeping NVIDIA's file name (`sdkmanager-<version>-Ubuntu_<xx.04>_docker.tar.gz`).
2. Either set the version for one run (`SDKM_VERSION=2.5.0.12345 ./sdkm.sh gui orin`, or `$env:SDKM_VERSION='2.5.0.12345'` in PowerShell), or change the default `SDKM_VERSION` at the top of `sdkm.sh` and `sdkm.ps1`.
3. For a new Ubuntu release, add it to `UBUNTU_VERSIONS` and the alias table in both scripts, and update the tables in this README.

## Committing to git

The image tarballs are ~500 MB each, so `.gitattributes` stores `images/*.tar*` with Git LFS. Run `git lfs install` once before the first `git add`.

**Cloning:** install Git LFS *before* cloning (`sudo apt install git-lfs` on Ubuntu, included with Git for Windows) and run `git lfs install` once. Otherwise `images/` contains ~130-byte pointer files instead of the images, and `docker load` fails with `unexpected EOF`. The scripts detect this and tell you. To fix an existing clone, run `git lfs install && git lfs pull`, then check with `git lfs fsck`.
