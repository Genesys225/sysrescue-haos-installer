#!/usr/bin/env bash
# Build a SystemRescue stick as an IMAGE FILE instead of on physical media.
#
#   sudo ./build/make-stick-image.sh
#
# Why this exists: the writer needs a raw block device, and a loop device is an
# acceptable one. That buys two things — the checkpoint no longer waits on
# working hardware, and once the image exists it can be populated with mtools
# and booted in QEMU entirely without root.
#
# INTERACTIVE. The writer does check whether the target is removable/hotplug;
# for a loop device it warns and asks for confirmation:
#
#   WARNING: /dev/loopN is not a removable or hotplug device
#   Are you sure you want to overwrite it? (y/n)?
#
# Answer y. It is a hard stop for automation — this script cannot run
# unattended, and should not be wrapped in one that assumes it can.
#
# This is the ONLY step in the project that needs privileges.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${REPO_ROOT}/build/artifacts.conf"
ARTIFACT_DIR="${REPO_ROOT}/tmp"

image="${1:-${ARTIFACT_DIR}/stick.img}"
size="${2:-8G}"

note() { printf '[*] %s\n' "$*"; }
die()  { printf '\n[FATAL] %s\n' "$*" >&2; exit 1; }

# Argument sanity first, before the privilege check: a wrong target should be
# rejected whether or not the caller remembered sudo.
[ ! -b "${image}" ] || die "refusing ${image}: that is a block device, not an image file"
[ ! -c "${image}" ] || die "refusing ${image}: that is a character device, not an image file"
if [ -e "${image}" ] && [ ! -f "${image}" ]; then
  die "refusing ${image}: exists but is not a regular file"
fi

[ "$(id -u)" -eq 0 ] || die "needs root for losetup. Run:
     sudo ./build/make-stick-image.sh"

iso="${ARTIFACT_DIR}/${SYSRESCUE_ISO}"
writer="${ARTIFACT_DIR}/${USBWRITER_FILE}"
[ -s "${iso}" ]    || die "missing ISO: ${iso} — run ./build/fetch-artifacts.sh"
[ -x "${writer}" ] || die "missing writer: ${writer}"

if [ ! -f "${image}" ]; then
  note "creating sparse image ${image} (${size})"
  truncate -s "${size}" "${image}"
fi

image_real="$(readlink -f "${image}")"

# Returns the backing file of a loop device, empty if it has none.
loop_backing() { losetup -n -O BACK-FILE "$1" 2>/dev/null | sed 's/[[:space:]]*$//'; }

# Only ever detach a device we can still prove is ours. This machine runs
# dozens of loop devices for snap mounts; detaching the wrong one would
# unmount live software.
loop=""
cleanup() {
  [ -n "${loop}" ] || return 0
  if [ "$(loop_backing "${loop}")" = "${image_real}" ]; then
    note "detaching ${loop}"
    losetup -d "${loop}" || true
  else
    note "NOT detaching ${loop}: it no longer backs ${image_real}"
  fi
}
trap cleanup EXIT

loop="$(losetup -fP --show "${image}")"

# losetup -f hands back a free device, so it cannot steal one that is in use.
# But nothing above proves what actually came back, and every line below feeds
# a destructive writer — so prove it before going near that.
[ -n "${loop}" ] || die "losetup returned no device"
case "${loop}" in
  /dev/loop[0-9]*) : ;;
  *) die "losetup returned something that is not a loop device: ${loop}" ;;
esac
[ -b "${loop}" ] || die "${loop} is not a block device"

backing="$(loop_backing "${loop}")"
[ "${backing}" = "${image_real}" ] ||
  die "refusing to write: ${loop} backs '${backing}', not '${image_real}'"

note "attached ${image_real} as ${loop} (backing file verified)"

note "writing SystemRescue (this unpacks the whole ISO; it takes a minute)"
TMPDIR="${ARTIFACT_DIR}" "${writer}" -c -e "${ARTIFACT_DIR}" -t "${loop}" "${iso}"

cleanup
trap - EXIT
loop=""

# Hand the artifact back to the invoking user so every later step is unprivileged.
owner="${SUDO_USER:-}"
if [ -n "${owner}" ]; then
  chown "${owner}:$(id -gn "${owner}")" "${image}"
  note "ownership handed to ${owner}"
fi

note "done"
printf '\nNext (no root needed):\n  ./build/make-stick.sh %s\n  ./tests/qemu-boot.sh --stick-image %s\n' \
  "${image}" "${image}"
