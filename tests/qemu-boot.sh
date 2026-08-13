#!/usr/bin/env bash
# Boot a stick, a stick image, or the bare SystemRescue ISO in QEMU against a
# throwaway target disk. This is the loop that lets every later task be
# exercised without risking real hardware.
#
#   ./tests/qemu-boot.sh --iso tmp/systemrescue-13.02-amd64.iso
#   ./tests/qemu-boot.sh --stick /dev/sdb
#   ./tests/qemu-boot.sh --legacy --iso ...        # negative test: no UEFI
#   ./tests/qemu-boot.sh --iso ... --screenshot tmp/boot.ppm
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${REPO_ROOT}/tmp"

die()  { printf '\n[FATAL] %s\n' "$*" >&2; exit 1; }
note() { printf '[*] %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: qemu-boot.sh (--iso FILE | --stick DEV | --stick-image FILE) [options]

Boot source (exactly one required):
  --iso FILE            boot an ISO as a CD-ROM
  --stick DEV           boot a physical USB stick (removable devices only)
  --stick-image FILE    boot a raw image of a stick

Options:
  --target FILE         throwaway target disk   (default tmp/target.qcow2)
  --target-size SIZE    size if it is created   (default 64G)
  --memory MB           guest RAM               (default 4096)
  --legacy              boot without UEFI firmware, for the negative test
  --screenshot FILE     headless: boot, wait, capture the screen, quit
  --wait SECONDS        delay before the screenshot   (default 45)
  --dry-run             print the command line and exit; no side effects
  --help                this text
EOF
}

# --- firmware discovery ---------------------------------------------------
# Package layouts differ across distributions. Secure Boot variants are
# deliberately excluded: HAOS requires Secure Boot disabled, so testing
# against secboot firmware would test a configuration we do not support.
find_firmware() {
  local code vars
  for code in \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2/x64/OVMF_CODE.4m.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd
  do
    [ -r "${code}" ] || continue
    vars="${code/CODE/VARS}"
    [ -r "${vars}" ] || continue
    printf '%s\n%s\n' "${code}" "${vars}"
    return 0
  done
  return 1
}

# --- argument parsing -----------------------------------------------------
iso=""; stick=""; stick_image=""
target="${ARTIFACT_DIR}/target.qcow2"
target_size="64G"
memory="4096"
legacy=0; dry_run=0; screenshot=""; wait_secs="45"

while [ $# -gt 0 ]; do
  case "$1" in
    --iso)          iso="${2:-}";         shift 2 ;;
    --stick)        stick="${2:-}";       shift 2 ;;
    --stick-image)  stick_image="${2:-}"; shift 2 ;;
    --target)       target="${2:-}";      shift 2 ;;
    --target-size)  target_size="${2:-}"; shift 2 ;;
    --memory)       memory="${2:-}";      shift 2 ;;
    --screenshot)   screenshot="${2:-}";  shift 2 ;;
    --wait)         wait_secs="${2:-}";   shift 2 ;;
    --legacy)       legacy=1;             shift ;;
    --dry-run)      dry_run=1;            shift ;;
    --help|-h)      usage; exit 0 ;;
    *)              usage >&2; die "unknown option: $1" ;;
  esac
done

sources=0
[ -n "${iso}" ]         && sources=$((sources + 1))
[ -n "${stick}" ]       && sources=$((sources + 1))
[ -n "${stick_image}" ] && sources=$((sources + 1))
[ "${sources}" -eq 1 ] || die "give exactly one of --iso, --stick, --stick-image (got ${sources})"

# --- boot source validation ----------------------------------------------
if [ -n "${iso}" ]; then
  [ -s "${iso}" ] || die "ISO not found or empty: ${iso}"
elif [ -n "${stick_image}" ]; then
  [ -s "${stick_image}" ] || die "stick image not found or empty: ${stick_image}"
else
  # This project's whole purpose is writing raw images to block devices, so a
  # harness that would hand the workstation's system NVMe to a VM is a loaded
  # gun. Removable media only, no exceptions, no override flag.
  [ -b "${stick}" ] || die "not a block device: ${stick}"
  removable="$(lsblk -dno RM "${stick}" 2>/dev/null | tr -d '[:space:]')"
  [ "${removable}" = "1" ] ||
    die "refusing ${stick}: not a removable device (RM=${removable:-unknown}).
     --stick accepts removable media only. Fixed disks on this machine hold
     your running system; pass --stick-image with a copy instead."
fi

# --- firmware -------------------------------------------------------------
ovmf_code=""; ovmf_vars=""
if [ "${legacy}" -eq 0 ]; then
  if fw="$(find_firmware)"; then
    ovmf_code="$(printf '%s' "${fw}" | sed -n '1p')"
    ovmf_vars="$(printf '%s' "${fw}" | sed -n '2p')"
  else
    die "no OVMF firmware found. HAOS requires UEFI, so the harness cannot
     test the real path without it. Install it with:  sudo apt install ovmf"
  fi
fi

vars_copy="${ARTIFACT_DIR}/OVMF_VARS_4M.fd"

# --- command assembly -----------------------------------------------------
cmd=(qemu-system-x86_64 -machine q35 -m "${memory}")

# KVM is a large speed difference but not a requirement; TCG works, slowly.
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  cmd+=(-enable-kvm -cpu host)
fi

if [ "${legacy}" -eq 0 ]; then
  cmd+=(-drive "if=pflash,format=raw,readonly=on,file=${ovmf_code}")
  cmd+=(-drive "if=pflash,format=raw,file=${vars_copy}")
fi

if [ -n "${iso}" ]; then
  cmd+=(-cdrom "${iso}")
else
  src="${stick:-${stick_image}}"
  cmd+=(-device qemu-xhci)
  cmd+=(-drive "file=${src},format=raw,if=none,id=stick")
  cmd+=(-device "usb-storage,drive=stick,bootindex=0")
fi

cmd+=(-drive "file=${target},format=qcow2,if=virtio")

if [ -n "${screenshot}" ]; then
  cmd+=(-display none -monitor stdio)
fi

if [ "${dry_run}" -eq 1 ]; then
  printf '%s\n' "${cmd[*]}"
  exit 0
fi

# --- side effects, only past the dry-run gate -----------------------------
mkdir -p "${ARTIFACT_DIR}"

if [ "${legacy}" -eq 0 ] && [ ! -f "${vars_copy}" ]; then
  note "creating a private UEFI variable store (system copy stays untouched)"
  cp "${ovmf_vars}" "${vars_copy}"
fi

if [ ! -f "${target}" ]; then
  note "creating throwaway target disk ${target} (${target_size})"
  qemu-img create -f qcow2 "${target}" "${target_size}" >&2
fi

if [ -n "${screenshot}" ]; then
  note "booting headless; capturing the screen after ${wait_secs}s"
  { sleep "${wait_secs}"; printf 'screendump %s\nquit\n' "${screenshot}"; } | "${cmd[@]}" >&2
  [ -s "${screenshot}" ] || die "no screenshot produced — the guest may not have started"
  note "screenshot written to ${screenshot}"
else
  note "booting: ${cmd[*]}"
  exec "${cmd[@]}"
fi
