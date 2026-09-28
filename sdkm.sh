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
DOCKER_DIR="$SCRIPT_DIR/docker"
HOST_DIR="$SCRIPT_DIR/host"
UBUNTU_VERSIONS=(18.04 20.04 22.04 24.04)

usage() {
	cat <<EOF
Usage: ./sdkm.sh <command> [target] [-- sdkmanager-args...]

Commands:
  list                      Show available/loaded images and the device table
  load  <target|all>        Load NVIDIA's image tarball(s) from ./images into docker
  build <target|all>        Build the local image (NVIDIA's + flash prerequisites)
  gui   <target>            Launch the SDK Manager GUI (default command)
  cli   <target> -- ARGS    Run SDK Manager in CLI mode, e.g. -- --cli --help
  shell <target>            Open a bash shell in the container (debugging)
  logs  <target> [lines]    Show the end of SDK Manager's log (default 100 lines)
  doctor <target>           Check the host and container for known flash problems
  host-setup                One-time host setup for flashing (uses sudo)
  reset <target>            Delete the persistent home volume (logins, downloads)

<target> is an Ubuntu version (18.04 20.04 22.04 24.04) or a device/JetPack alias:
  thor, jp7                 -> 24.04
  orin, jp6                 -> 22.04   (also offers JetPack 7.2+ for Orin)
  xavier, jp5               -> 20.04
  nano, tx1, tx2, jp4       -> 18.04

Environment:
  SDKM_VERSION     SDK Manager version tag to use   (default: $SDKM_VERSION)
  SDKM_IMAGES_DIR  Where the image tarballs live    (default: ./images)
  SDKM_NO_BUILD=1  Run NVIDIA's image as-is instead of the local build
EOF
}

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }

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

image_tag()     { echo "sdkmanager:${SDKM_VERSION}-Ubuntu_$1"; }
local_tag()     { echo "sdkm-local:${SDKM_VERSION}-Ubuntu_$1"; }
volume_name()   { echo "sdkm-home-$1"; }
is_loaded()     { docker image inspect "$(image_tag "$1")" >/dev/null 2>&1; }
image_label()   { docker image inspect -f "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || true; }
recipe_version() { sed -n 's/^# sdkm\.recipe: *//p' "$DOCKER_DIR/install.sh"; }
is_running()    { [ "$(docker inspect -f '{{.State.Running}}' "sdkm-$1" 2>/dev/null)" = true ]; }

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

# The local image is NVIDIA's image plus the flash prerequisites (see
# docker/install.sh). It is rebuilt when NVIDIA's image or the recipe changes.
local_image_current() {
	local ver="$1" base_id
	base_id="$(docker image inspect -f '{{.Id}}' "$(image_tag "$ver")")"
	[ "$(image_label "$(local_tag "$ver")" sdkm.base)" = "$base_id" ] &&
		[ "$(image_label "$(local_tag "$ver")" sdkm.recipe)" = "$(recipe_version)" ]
}

# Runs docker/install.sh as root in a container of NVIDIA's image and commits
# the result. (Not `docker build`: BuildKit's docker-container driver can't use
# locally loaded images, and plain Docker Engine installs may lack buildx.)
build_image() {
	local ver="$1" base_id name="sdkm-build-$1" rc=0
	load_image "$ver"
	base_id="$(docker image inspect -f '{{.Id}}' "$(image_tag "$ver")")"
	echo "Building $(local_tag "$ver") (needs internet, a few minutes the first time)..."
	docker rm -f "$name" >/dev/null 2>&1 || true
	docker create --name "$name" --user root --entrypoint bash \
		"$(image_tag "$ver")" /tmp/sdkm-build/install.sh >/dev/null
	docker cp "$DOCKER_DIR/." "$name:/tmp/sdkm-build"
	docker start -a "$name" || rc=$?
	if [ "$rc" -eq 0 ]; then
		# Restore NVIDIA's runtime settings, which the build container overrode.
		docker commit \
			--change 'USER nvidia' \
			--change 'WORKDIR /home/nvidia' \
			--change 'ENTRYPOINT ["docker-entrypoint.sh"]' \
			--change 'CMD ["sdkmanager"]' \
			--change "LABEL sdkm.base=$base_id sdkm.recipe=$(recipe_version)" \
			"$name" "$(local_tag "$ver")" >/dev/null || rc=$?
	fi
	docker rm -f "$name" >/dev/null 2>&1 || true
	[ "$rc" -eq 0 ] && echo "Built $(local_tag "$ver")"
	return "$rc"
}

# Sets RUN_IMAGE to the image a container should use.
RUN_IMAGE=""
ensure_image() {
	local ver="$1"
	load_image "$ver"
	if [ "${SDKM_NO_BUILD:-}" = 1 ]; then
		warn "SDKM_NO_BUILD=1: using NVIDIA's image; flashing may fail after the first launch"
		RUN_IMAGE="$(image_tag "$ver")"
		return
	fi
	if ! local_image_current "$ver"; then
		if ! build_image "$ver"; then
			if docker image inspect "$(local_tag "$ver")" >/dev/null 2>&1; then
				warn "rebuild failed; using the existing (older) $(local_tag "$ver")"
			else
				die "could not build $(local_tag "$ver"). Check your internet connection, or set SDKM_NO_BUILD=1 to run NVIDIA's image as-is"
			fi
		fi
	fi
	RUN_IMAGE="$(local_tag "$ver")"
}

cmd_list() {
	local ver status built file
	printf '%-8s %-40s %-7s %-6s %s\n' UBUNTU IMAGE LOADED BUILT TARBALL
	for ver in "${UBUNTU_VERSIONS[@]}"; do
		is_loaded "$ver" && status=yes || status=no
		built=no
		if [ "$status" = yes ] && local_image_current "$ver" 2>/dev/null; then built=yes; fi
		file="$(find_tarball "$ver" 2>/dev/null)" && file="$(basename "$file")" || file="(missing)"
		printf '%-8s %-40s %-7s %-6s %s\n' "$ver" "$(image_tag "$ver")" "$status" "$built" "$file"
	done
	cat <<EOF

Recommended host Ubuntu per device (see README for details):
  Jetson Thor                 JetPack 7.x   -> 24.04
  Jetson Orin family          JetPack 6.x / 7.2+ -> 22.04
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
		warn "Docker Desktop on Linux runs containers in a VM; the display and USB"
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

revoke_display() {
	if [ "$XHOST_GRANTED" = 1 ]; then xhost -local: >/dev/null 2>&1 || true; fi
}

# --- Host checks -------------------------------------------------------------
# Each prints nothing and returns 0 when fine, or prints a problem + fix and
# returns 1. They skip on Docker Desktop, which runs containers in its own VM.

# SDK Manager chroots into the Jetson's arm64 root filesystem to install
# packages. That needs the host kernel to run aarch64 binaries through QEMU,
# registered with the F (fix-binary) flag so it works inside the container.
# Without it the install fails with "chroot: failed to run command 'dpkg':
# Exec format error".
check_arm64_emulation() {
	local entry=/proc/sys/fs/binfmt_misc/qemu-aarch64
	if [ -r "$entry" ] && grep -q '^enabled' "$entry" && grep -q '^flags:.*F' "$entry"; then
		return 0
	fi
	echo "arm64 emulation (qemu-aarch64 binfmt with the F flag) is not set up. Building the"
	echo "  Jetson root filesystem will fail with 'Exec format error'. Fix: ./sdkm.sh host-setup"
	return 1
}

# JetPack 6+ flashes by booting the Jetson from an initrd that mounts its files
# over NFS from a server started inside the container. Containers use the host
# kernel, so the host must have the nfsd module loaded ("no support in current
# kernel" otherwise), and no host NFS server may hold port 2049.
check_nfs_server() {
	local rc=0
	if ! grep -qw nfsd /proc/filesystems 2>/dev/null; then
		echo "the host kernel's NFS server module (nfsd) is not loaded. Flashing JetPack 6/7"
		echo "  fails with 'no support in current kernel'. Fix: ./sdkm.sh host-setup"
		rc=1
	fi
	if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nfs-kernel-server 2>/dev/null; then
		echo "nfs-kernel-server is running on the host and conflicts with the container's NFS"
		echo "  server while flashing. Fix: sudo systemctl stop nfs-kernel-server"
		rc=1
	fi
	return $rc
}

# During an initrd flash the Jetson shows up as a USB network device (0955:7035).
# NVIDIA's flash script installs a udev rule telling NetworkManager to leave it
# alone, but inside the container that rule never reaches the host's udev, so
# NetworkManager grabs the interface and the flash can't reach the board.
check_udev_rules() {
	local rc=0
	if command -v nmcli >/dev/null 2>&1 && [ ! -e /etc/udev/rules.d/99-l4t-host.rules ]; then
		echo "NetworkManager may take over the Jetson's USB network during flashing (the flash"
		echo "  'detects the board but can't connect'). Fix: ./sdkm.sh host-setup"
		rc=1
	fi
	return $rc
}

host_checks() {
	is_docker_desktop && return 0
	local out
	for c in check_arm64_emulation check_nfs_server check_udev_rules; do
		if ! out="$($c)"; then
			echo "$out" | sed '1s/^/warning: /; 2,$s/^/         /' >&2
		fi
	done
}

cmd_host_setup() {
	is_docker_desktop && die "host-setup is for Linux hosts running Docker Engine"
	echo "== arm64 emulation (qemu-user-static, binfmt with F flag)"
	if ! check_arm64_emulation >/dev/null; then
		sudo apt-get install -y qemu-user-static binfmt-support
		sudo systemctl restart systemd-binfmt 2>/dev/null || true
	fi
	check_arm64_emulation >/dev/null && echo "   OK" || echo "   still missing; see README 'arm64 emulation'"

	echo "== NFS server kernel module (nfsd)"
	if ! grep -qw nfsd /proc/filesystems; then
		sudo modprobe nfsd || { sudo apt-get install -y "linux-modules-extra-$(uname -r)" && sudo modprobe nfsd; }
	fi
	echo nfsd | sudo tee /etc/modules-load.d/nfsd.conf >/dev/null
	grep -qw nfsd /proc/filesystems && echo "   OK (loads at every boot)" || echo "   still missing"

	echo "== udev rules for the Jetson's flash-mode USB devices"
	sudo install -m 0644 "$HOST_DIR/99-l4t-host.rules" "$HOST_DIR/10-l4t-usb-msd.rules" /etc/udev/rules.d/
	sudo udevadm control --reload-rules
	echo "   OK (NetworkManager and the desktop's automounter will ignore the Jetson while flashing)"

	if systemctl is-active --quiet nfs-kernel-server 2>/dev/null; then
		echo "note: nfs-kernel-server is running on this host. Stop it before flashing:"
		echo "      sudo systemctl stop nfs-kernel-server"
	fi
}

# --- doctor ------------------------------------------------------------------

jetson_model() {
	case "$1" in
		7f21) echo "Jetson Nano (recovery mode)" ;;
		7c18) echo "Jetson TX2 (recovery mode)" ;;
		7019) echo "Jetson AGX Xavier (recovery mode)" ;;
		7e19) echo "Jetson Xavier NX (recovery mode)" ;;
		7023) echo "Jetson AGX Orin (recovery mode)" ;;
		7323|7423) echo "Jetson Orin NX (recovery mode)" ;;
		7523|7623) echo "Jetson Orin Nano (recovery mode)" ;;
		7035) echo "Jetson in flash mode (initrd running)" ;;
		7020) echo "Jetson booted into Linux" ;;
		*) echo "unknown NVIDIA device" ;;
	esac
}

cmd_doctor() {
	local ver="$1" fails=0 out line
	pass() { printf '  [PASS] %s\n' "$1"; }
	fail() { printf '  [FAIL] %s\n' "$1"; fails=$((fails + 1)); }

	echo "Host"
	if docker info >/dev/null 2>&1; then pass "docker is running"; else fail "docker is not running"; fi
	if is_docker_desktop; then
		is_wsl && pass "Docker Desktop via WSL2" || fail "Docker Desktop on Linux (use Docker Engine)"
	else
		pass "Docker Engine"
		for c in check_arm64_emulation check_nfs_server check_udev_rules; do
			if out="$($c)"; then pass "${c#check_}"; else fail "$(echo "$out" | tr -s ' \n' ' ')"; fi
		done
		[ -e /dev/loop-control ] && pass "/dev/loop-control exists" || fail "/dev/loop-control missing (sudo modprobe loop)"
		if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ':2049 '; then
			if is_running "$ver"; then pass "port 2049 in use (the container's NFS server)"
			else fail "something on the host is listening on NFS port 2049"; fi
		else
			pass "NFS port 2049 is free"
		fi
	fi

	echo "Image"
	if ! is_loaded "$ver"; then
		fail "$(image_tag "$ver") is not loaded (./sdkm.sh load $ver)"
	elif local_image_current "$ver"; then
		pass "$(local_tag "$ver") is built and current"
	else
		fail "$(local_tag "$ver") is missing or outdated (./sdkm.sh build $ver)"
	fi

	echo "Container"
	local img; img="$(local_tag "$ver")"
	docker image inspect "$img" >/dev/null 2>&1 || img="$(image_tag "$ver")"
	if docker image inspect "$img" >/dev/null 2>&1; then
		while IFS= read -r line; do
			case "$line" in
				ok:*)   pass "${line#ok:} found" ;;
				miss:*) fail "${line#miss:} missing (flash prerequisites not installed)" ;;
				usb:*)  pass "USB ${line#usb:}: $(jetson_model "${line##*:}")" ;;
				nousb)  fail "no NVIDIA USB device visible (put the Jetson in recovery mode; on Windows run usb-attach.ps1)" ;;
			esac
		done < <(docker run --rm --privileged -v /dev/bus/usb:/dev/bus/usb --entrypoint bash "$img" -c '
			for t in cpp dtc python3 lsusb sshpass exportfs rpcbind; do
				command -v $t >/dev/null && echo "ok:$t" || echo "miss:$t"
			done
			ids=$(lsusb 2>/dev/null | grep -o "0955:[0-9a-f]\{4\}")
			[ -n "$ids" ] && for i in $ids; do echo "usb:$i"; done || echo nousb')
	fi

	echo
	[ "$fails" -eq 0 ] && echo "All checks passed." || echo "$fails check(s) failed."
}

cmd_logs() {
	local ver="$1" lines="${2:-100}"
	local show='f=$(ls -t ~/.nvsdkm/sdkm*.log 2>/dev/null | head -1); [ -n "$f" ] || { echo "no SDK Manager log yet"; exit 0; }; echo "== $f"; tail -n '"$lines"' "$f"'
	if is_running "$ver"; then
		docker exec "sdkm-$ver" bash -c "$show"
	else
		load_image "$ver" >/dev/null
		docker run --rm -v "$(volume_name "$ver"):/home/nvidia" --entrypoint bash "$(image_tag "$ver")" -c "$show"
	fi
}

# --- run ---------------------------------------------------------------------

# Before SDK Manager starts, sdkm-prereqs (baked into the local image) installs
# any flash prerequisite the installed JetPack asks for that the image lacks.
PREREQS='command -v sdkm-prereqs >/dev/null && sdkm-prereqs'
# `sdkmanager` (GUI mode) launches the Electron window as a detached child and
# exits immediately, which would stop the container. Piping through `cat` keeps
# the container alive until the GUI closes its stdout, i.e. the window closes.
GUI_WRAPPER="$PREREQS; sdkmanager \"\$@\" | cat"
CLI_WRAPPER="$PREREQS; exec sdkmanager \"\$@\""

run_container() {
	local mode="$1" ver="$2" entrypoint="$3"; shift 3
	local tty_args=(-i)
	[ -t 0 ] && [ -t 1 ] && tty_args=(-it)

	ensure_image "$ver"
	setup_display "$mode"
	host_checks
	trap revoke_display EXIT

	# --privileged + /dev: flashing uses loop devices and the Jetson re-enumerates
	#   on USB (recovery mode -> booted), so individual --device flags are not enough.
	# --network host: reach the Jetson's USB network (192.168.55.1) during/after flashing.
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
		"$RUN_IMAGE" "$@"
}

main() {
	local cmd="${1:-help}"
	[ $# -gt 0 ] && shift
	command -v docker >/dev/null 2>&1 || die "docker not found in PATH"

	case "$cmd" in
		help|-h|--help) usage ;;
		list)  cmd_list ;;
		load|build)
			local v vers=()
			if [ "${1:-}" = all ]; then vers=("${UBUNTU_VERSIONS[@]}"); else vers=("$(resolve_target "${1:-}")"); fi
			for v in "${vers[@]}"; do
				if [ "$cmd" = load ]; then load_image "$v"; else build_image "$v"; fi
			done ;;
		gui|cli|shell)
			local ver; ver="$(resolve_target "${1:-}")"; shift
			[ "${1:-}" = "--" ] && shift
			case "$cmd" in
				gui)   run_container gui "$ver" bash -c "$GUI_WRAPPER" gui "$@" ;;
				cli)   [ $# -gt 0 ] || set -- --cli --help
				       run_container cli "$ver" bash -c "$CLI_WRAPPER" cli "$@" ;;
				shell) run_container shell "$ver" bash "$@" ;;
			esac ;;
		logs)   cmd_logs "$(resolve_target "${1:-}")" "${2:-100}" ;;
		doctor) cmd_doctor "$(resolve_target "${1:-}")" ;;
		host-setup) cmd_host_setup ;;
		reset)
			local ver; ver="$(resolve_target "${1:-}")"
			docker volume rm "$(volume_name "$ver")" ;;
		*)
			# Allow `./sdkm.sh orin` as shorthand for `./sdkm.sh gui orin`.
			main gui "$cmd" "$@" ;;
	esac
}

main "$@"
