#!/usr/bin/env bash
# Populate a prepared SystemRescue stick with the installer drop-ins.
#
#   ./build/make-stick.sh /media/$USER/RESCUE1302
#
# The stick must already have been written by sysrescueusbwriter (or Rufus in
# ISO mode). This script only copies files onto it — it never partitions,
# formats, or writes a bootloader, and it never touches a raw device.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${REPO_ROOT}/build/artifacts.conf"
ARTIFACT_DIR="${REPO_ROOT}/tmp"

note() { printf '[*] %s\n' "$*"; }
die()  { printf '\n[FATAL] %s\n' "$*" >&2; exit 1; }

stick="${1:-}"
[ -n "${stick}" ] || die "usage: make-stick.sh <path to mounted SystemRescue stick>"
[ -d "${stick}" ] || die "not a directory: ${stick}"

# Guard against splattering 552 MB across the wrong directory. A stick written
# by sysrescueusbwriter carries a sysresccd/ tree; if that is missing we are
# almost certainly pointed somewhere we should not be writing.
[ -d "${stick}/sysresccd" ] ||
  die "${stick} does not look like a SystemRescue stick (no sysresccd/ directory).
     Write it first:  ./tmp/${USBWRITER_FILE} tmp/${SYSRESCUE_ISO}"

img="${ARTIFACT_DIR}/${HAOS_IMG}"
sidecar="${ARTIFACT_DIR}/${HAOS_SHA_SIDECAR}"
[ -s "${img}" ]     || die "missing payload: ${img} — run ./build/fetch-artifacts.sh"
[ -s "${sidecar}" ] || die "missing checksum: ${sidecar} — run ./build/fetch-artifacts.sh"

# Warn rather than fail on a label mismatch: the label is a boot requirement,
# but the operator may have mounted the stick somewhere unrelated to its name.
case "${stick}" in
  *"${SYSRESCUE_LABEL}"*) : ;;
  *) note "note: mount path does not contain ${SYSRESCUE_LABEL}; the volume label must still match or the stick will not boot" ;;
esac

note "populating ${stick}"
# autorun/ is SystemRescue's own drop-in folder — it ships on the ISO with a
# .gitkeep, and the docs list it as an autorun search location. The script goes
# INSIDE it as autorun/autorun. Writing to "${stick}/autorun" instead would
# depend on cp's behaviour when the destination happens to be a directory,
# which is luck, not intent.
mkdir -p "${stick}/autorun" "${stick}/haos" "${stick}/sysrescue.d" "${stick}/logs"

install_file() {
  local src="$1" dest="$2"
  # A directory here means the caller passed a path that already exists as one,
  # and cp would silently copy *into* it. Refuse rather than guess.
  [ ! -d "${dest}" ] || die "refusing to copy over a directory: ${dest}"
  if [ -f "${dest}" ] && [ "$(stat -c %s "${src}")" = "$(stat -c %s "${dest}")" ]; then
    note "unchanged: $(basename "${dest}")"
    return 0
  fi
  note "copying: $(basename "${dest}")"
  cp -f "${src}" "${dest}"
}

install_file "${REPO_ROOT}/src/autorun"        "${stick}/autorun/autorun"
install_file "${REPO_ROOT}/src/500-haos.yaml"  "${stick}/sysrescue.d/500-haos.yaml"
install_file "${img}"                          "${stick}/haos/${HAOS_IMG}"
install_file "${sidecar}"                      "${stick}/haos/${HAOS_SHA_SIDECAR}"

# Harmless on FAT32, which cannot store the bit — but the stick may one day be
# ext4, and setting it costs nothing.
chmod +x "${stick}/autorun/autorun" 2>/dev/null || true

sync
note "done"
printf '\n'
find "${stick}/autorun" "${stick}/sysrescue.d" "${stick}/haos" "${stick}/logs" -maxdepth 1 -printf '%M %10s  %p\n' 2>/dev/null
