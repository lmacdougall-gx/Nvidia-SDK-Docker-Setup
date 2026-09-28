#!/usr/bin/env bash
# Run NVIDIA SDK Manager inside the Ubuntu docker image that matches the target
# device, with the GUI forwarded to the host display and USB passed through.
#
# Works on a native Linux host (Docker Engine) and inside WSL2 on Windows
# (Docker Desktop with WSL integration, or Docker Engine installed in the distro).
# Run `./sdkm.sh help` for usage.
set -euo pipefail

SDKM_VERSION="${SDKM_VERSION:-2.4.1.13536}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_DIR="${SDKM_IMAGES_DIR:-$SCRIPT_DIR/images}"
UBUNTU_VERSIONS=(18.04 20.04 22.04 24.04)

usage() {
	cat <<EOF
Usage: ./sdkm.sh <command> [target] [-- sdkmanager-args...]

Commands:
  list                      Show available/loaded images and the device table
  load  <target|all>        Load image tarball(s) from ./images into docker
  gui   <target>            Launch the SDK Manager GUI (default command)
  cli   <target> -- ARGS    Run SDK Manager in CLI mode, e.g. -- --cli --help
  shell <target>            Open a bash shell in the container (debugging)
  reset <target>            Delete the persistent home volume (logins, downloads)

<target> is an Ubuntu version (18.04 20.04 22.04 24.04) or a device/JetPack alias:
  thor, jp7                 -> 24.04
  orin, jp6                 -> 22.04
  xavier, jp5               -> 20.04
  nano, tx1, tx2, jp4       -> 18.04

Environment:
  SDKM_VERSION     SDK Manager version tag to use   (default: $SDKM_VERSION)
  SDKM_IMAGES_DIR  Where the image tarballs live    (default: ./images)
EOF
}

die() { echo "error: $*" >&2; exit 1; }

resolve_target() {
	case "${1:-}" in
		18.04|20.04|22.04|24.04) echo "$1" ;;
		thor|jp7)                echo 24.04 ;;
		orin|jp6)                echo 22.04 ;;
		xavier|jp5)              echo 20.04 ;;
		nano|tx1|tx2|jp4)        echo 18.04 ;;
		"") die "missing target (Ubuntu version or device alias). See ./sdkm.sh help" ;;
		*)  die "unknown target '$1'. See ./sdkm.sh help" ;;
	esac
}

image_tag()   { echo "sdkmanager:${SDKM_VERSION}-Ubuntu_$1"; }
volume_name() { echo "sdkm-home-$1"; }
is_loaded()   { docker image inspect "$(image_tag "$1")" >/dev/null 2>&1; }

find_tarball() {
	local f
	for f in "$IMAGES_DIR"/sdkmanager-"${SDKM_VERSION}"-Ubuntu_"$1"_docker.tar*; do
		[ -f "$f" ] && { echo "$f"; return 0; }
	done
	return 1
}

load_image() {
	local ver="$1" tarball
	if is_loaded "$ver"; then
		echo "$(image_tag "$ver") already loaded"
		return 0
	fi
	tarball="$(find_tarball "$ver")" ||
		die "no tarball for Ubuntu $ver in $IMAGES_DIR (expected sdkmanager-${SDKM_VERSION}-Ubuntu_${ver}_docker.tar*)"
	# A clone made without git-lfs contains small pointer files instead of the
	# images, which docker rejects with an unhelpful "unexpected EOF".
	if head -c 40 "$tarball" | grep -q '^version https://git-lfs'; then
		die "$(basename "$tarball") is a Git LFS pointer, not the image. Install git-lfs, then run: git lfs install && git lfs pull"
	fi
	echo "Loading $(basename "$tarball") (this takes a minute)..."
	docker load -i "$tarball"
}

cmd_list() {
	local ver status file
	printf '%-8s %-40s %-8s %s\n' UBUNTU IMAGE LOADED TARBALL
	for ver in "${UBUNTU_VERSIONS[@]}"; do
		is_loaded "$ver" && status=yes || status=no
		file="$(find_tarball "$ver" 2>/dev/null)" && file="$(basename "$file")" || file="(missing)"
		printf '%-8s %-40s %-8s %s\n' "$ver" "$(image_tag "$ver")" "$status" "$file"
	done
	cat <<EOF

Recommended host Ubuntu per device (see README for details):
  Jetson Thor                 JetPack 7.x   -> 24.04
  Jetson Orin family          JetPack 6.x   -> 22.04
  Jetson Orin / Xavier        JetPack 5.x   -> 20.04
  Jetson Nano / TX1 / TX2     JetPack 4.x   -> 18.04
EOF
}

is_wsl() { [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; }
is_docker_desktop() { [ "$(docker info --format '{{.OperatingSystem}}' 2>/dev/null)" = "Docker Desktop" ]; }

# Populates DISPLAY_ARGS with the docker flags needed to reach the host X server.
DISPLAY_ARGS=()
XHOST_GRANTED=0
setup_display() {
	if is_wsl && is_docker_desktop; then
		# The daemon runs in the docker-desktop VM; WSLg's X socket is exposed there.
		DISPLAY_ARGS=(-e DISPLAY=:0 -v /run/desktop/mnt/host/wslg/.X11-unix:/tmp/.X11-unix)
		return
	fi
	if is_docker_desktop; then
		echo "warning: Docker Desktop on Linux runs containers in a VM; the display and USB" >&2
		echo "         passthrough will likely not work. Use Docker Engine instead." >&2
	fi
	if [ -z "${DISPLAY:-}" ]; then
		# Only the GUI needs a display; cli/shell can run headless.
		[ "$1" = gui ] && die "DISPLAY is not set; run this from a graphical session"
		return 0
	fi
	DISPLAY_ARGS=(-e "DISPLAY=$DISPLAY" -v /tmp/.X11-unix:/tmp/.X11-unix)
	if [ -n "${XAUTHORITY:-}" ] && [ -f "$XAUTHORITY" ]; then
		DISPLAY_ARGS+=(-e XAUTHORITY=/tmp/.Xauthority -v "$XAUTHORITY:/tmp/.Xauthority:ro")
	fi
	# Allow local (non-network) clients such as the container to connect.
	if ! is_wsl && command -v xhost >/dev/null 2>&1; then
		xhost +local: >/dev/null && XHOST_GRANTED=1
	fi
}

# SDK Manager chroots into the Jetson's arm64 root filesystem to install
# packages. That needs the host kernel to run aarch64 binaries through QEMU,
# registered with the F (fix-binary) flag so it works inside the container.
# Without it the install fails with "chroot: failed to run command 'dpkg':
# Exec format error". Docker Desktop registers this itself.
check_arm64_emulation() {
	is_docker_desktop && return 0
	local entry=/proc/sys/fs/binfmt_misc/qemu-aarch64
	if [ -r "$entry" ] && grep -q '^enabled' "$entry" && grep -q '^flags:.*F' "$entry"; then
		return 0
	fi
	echo "warning: arm64 emulation (qemu-aarch64 binfmt with the F flag) is not set up on" >&2
	echo "         this host. Flashing/building the Jetson root filesystem will fail with" >&2
	echo "         'Exec format error'. Fix on the host:" >&2
	echo "           sudo apt install qemu-user-static binfmt-support" >&2
	echo "           sudo systemctl restart systemd-binfmt" >&2
}

# JetPack 6+ flashes by booting the Jetson from an initrd that mounts its files
# over NFS from a server SDK Manager starts inside the container. Containers use
# the host kernel, so the host must have the nfsd module loaded, otherwise the
# flash fails with "no support in current kernel".
check_nfs_server() {
	is_docker_desktop && return 0
	if ! grep -qw nfsd /proc/filesystems 2>/dev/null; then
		echo "warning: the host kernel's NFS server (nfsd) is not loaded. Flashing JetPack 6/7" >&2
		echo "         will fail with 'no support in current kernel'. Fix on the host:" >&2
		echo "           sudo modprobe nfsd   # if not found: sudo apt install linux-modules-extra-\$(uname -r)" >&2
		echo "           echo nfsd | sudo tee /etc/modules-load.d/nfsd.conf   # load at every boot" >&2
		echo "         Then restart this container." >&2
	fi
	if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nfs-kernel-server 2>/dev/null; then
		echo "warning: nfs-kernel-server is running on the host and will conflict with the" >&2
		echo "         container's NFS server while flashing. Stop it first:" >&2
		echo "           sudo systemctl stop nfs-kernel-server" >&2
	fi
}

revoke_display() {
	if [ "$XHOST_GRANTED" = 1 ]; then xhost -local: >/dev/null 2>&1 || true; fi
}

# `sdkmanager` (GUI mode) launches the Electron window as a detached child and
# exits immediately, which would stop the container. Piping through `cat` keeps
# the container alive until the GUI closes its stdout, i.e. the window closes.
GUI_WRAPPER='sdkmanager "$@" | cat'

run_container() {
	local mode="$1" ver="$2" entrypoint="$3"; shift 3
	local tty_args=(-i)
	[ -t 0 ] && [ -t 1 ] && tty_args=(-it)

	load_image "$ver"
	setup_display "$mode"
	check_arm64_emulation
	check_nfs_server
	trap revoke_display EXIT

	# --privileged + /dev: flashing uses loop devices and the Jetson re-enumerates
	#   on USB (recovery mode -> booted), so individual --device flags are not enough.
	# --network host: reach the Jetson's USB network (192.168.55.1) after flashing.
	# The named volume keeps logins, downloads and installed SDKs between runs.
	# NVIDIA's docker-entrypoint.sh is bypassed on purpose: it never starts the GUI
	# and appends a stray '%' to the last CLI argument.
	docker run --rm "${tty_args[@]}" --init \
		--name "sdkm-$ver" \
		--privileged \
		--network host \
		--shm-size 2g \
		-v /dev/bus/usb:/dev/bus/usb \
		-v /dev:/dev \
		-v "$(volume_name "$ver"):/home/nvidia" \
		"${DISPLAY_ARGS[@]}" \
		--entrypoint "$entrypoint" \
		"$(image_tag "$ver")" "$@"
}

main() {
	local cmd="${1:-help}"
	[ $# -gt 0 ] && shift
	command -v docker >/dev/null 2>&1 || die "docker not found in PATH"

	case "$cmd" in
		help|-h|--help) usage ;;
		list)  cmd_list ;;
		load)
			if [ "${1:-}" = all ]; then
				local v; for v in "${UBUNTU_VERSIONS[@]}"; do load_image "$v"; done
			else
				load_image "$(resolve_target "${1:-}")"
			fi ;;
		gui|cli|shell)
			local ver; ver="$(resolve_target "${1:-}")"; shift
			[ "${1:-}" = "--" ] && shift
			case "$cmd" in
				gui)   run_container gui "$ver" bash -c "$GUI_WRAPPER" gui "$@" ;;
				cli)   [ $# -gt 0 ] || set -- --cli --help
				       run_container cli "$ver" sdkmanager "$@" ;;
				shell) run_container shell "$ver" bash "$@" ;;
			esac ;;
		reset)
			local ver; ver="$(resolve_target "${1:-}")"
			docker volume rm "$(volume_name "$ver")" ;;
		*)
			# Allow `./sdkm.sh orin` as shorthand for `./sdkm.sh gui orin`.
			main gui "$cmd" "$@" ;;
	esac
}

main "$@"
