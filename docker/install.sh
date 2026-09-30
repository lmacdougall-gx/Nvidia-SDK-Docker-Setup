#!/bin/bash
# Turns NVIDIA's SDK Manager image into the local image by installing the
# Jetson flash prerequisites. Run as root inside a container of NVIDIA's image
# by `sdkm.sh build` / `sdkm.ps1 build`, which then `docker commit` the result.
#
# Why: SDK Manager installs these with Linux_for_Tegra/tools/l4t_flash_prerequisites.sh
# during its first install, but the launchers run containers with --rm, so apt
# packages vanish on exit. On the next launch SDK Manager skips that step and the
# flash fails (e.g. "No such file or directory: 'cpp'" -> "Bootrom status check
# failed"). Baking them into the image fixes that for every launch.
#
# `docker build` isn't used because BuildKit's docker-container driver (the
# default on some Docker Desktop setups) can't see locally loaded images.
#
# Bump this whenever this file or sdkm-prereqs changes so local images rebuild:
# sdkm.recipe: 2
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

. /etc/os-release
case "$VERSION_ID" in
	18.04) extra="liblz4-tool python vim-common" ;;
	24.04) extra="lz4 python-is-python3 xxd libasound2t64" ;;
	*)     extra="lz4 python-is-python3 xxd" ;;
esac
# 24.04: NVIDIA's image satisfies sdkmanager's libasound2 dependency with
# liboss4-salsa-asound2, an OSS4 stand-in for ALSA that lacks symbols Electron
# needs, so the GUI dies before opening a window ("undefined symbol:
# snd_device_name_get_hint"). Installing the real ALSA library (libasound2t64,
# renamed in 24.04 by the 64-bit time_t transition) replaces it.

apt-get update
# shellcheck disable=SC2086
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
	abootimg binfmt-support binutils cpio cpp device-tree-compiler dosfstools \
	e2fsprogs file gdisk iproute2 iputils-ping lbzip2 libxml2-utils \
	netcat-openbsd nfs-kernel-server openssl parted python3 python3-usb \
	python3-yaml qemu-user-static rsync sshpass udev usbutils uuid-runtime \
	whois xmlstarlet zlib1g zstd $extra
rm -rf /var/lib/apt/lists/*

install -m 0755 "$here/sdkm-prereqs" /usr/local/bin/sdkm-prereqs
rm -rf "$here"
echo "sdkm: flash prerequisites installed"
