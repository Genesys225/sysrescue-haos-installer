#!/usr/bin/env bash
# Build a SystemRescue stick as an IMAGE FILE instead of on physical media.
#
#   sudo ./build/make-stick-image.sh
#
# Why this exists: the writer needs a raw block device, but it has no
# removable-media filter (it only rejects partitions, via PKNAME), so a loop
# device is an acceptable target. That buys two things — the checkpoint no
# longer waits on working hardware, and once the image exists it can be
# populated with mtools and booted in QEMU entirely without root.
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

loop=""
cleanup() {
  if [ -n "${loop}" ] && losetup "${loop}" >/dev/null 2>&1; then
    note "detaching ${loop}"
    losetup -d "${loop}" || true
  fi
}
trap cleanup EXIT

loop="$(losetup -fP --show "${image}")"
note "attached ${image} as ${loop}"

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
