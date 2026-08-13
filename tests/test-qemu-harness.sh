#!/usr/bin/env bash
# Task 2 acceptance: the QEMU harness assembles a correct, safe command line.
#
# Everything here is asserted against --dry-run. Booting a VM is verified
# separately (see tasks/todo.md Task 2); these tests must stay fast and must
# never launch qemu, attach a real disk, or need a display.

. "$(dirname "$0")/lib.sh"
. "${REPO_ROOT}/build/artifacts.conf"

HARNESS="${REPO_ROOT}/tests/qemu-boot.sh"
ISO="${ARTIFACT_DIR}/${SYSRESCUE_ISO}"
OUT="${ARTIFACT_DIR}/.test-qemu-dry.txt"

echo "qemu harness"

check "harness exists" test -f "${HARNESS}"
check "harness is executable" test -x "${HARNESS}"

if [ ! -x "${HARNESS}" ]; then
  fail_with "harness is runnable" "cannot continue without ${HARNESS}"
  finish
  exit $?
fi

check "--help exits cleanly" bash "${HARNESS}" --help

# --- UEFI command line ----------------------------------------------------
bash "${HARNESS}" --dry-run --iso "${ISO}" > "${OUT}" 2>&1

check "UEFI: loads OVMF code firmware" grep -q 'OVMF_CODE_4M\.fd' "${OUT}"
check "UEFI: code firmware is read-only" grep -q 'readonly=on' "${OUT}"

# HAOS requires Secure Boot disabled, so the harness must never pick the
# secboot/ms firmware variants that also live in /usr/share/OVMF.
check "UEFI: does not use a Secure Boot firmware" bash -c '! grep -qE "secboot|\.ms\.|snakeoil" "$1"' _ "${OUT}"

# The VARS file is per-run state. Using the system copy would mutate a
# root-owned file shared with every other VM on this machine.
check "UEFI: uses a private VARS copy under tmp/" grep -q "tmp/.*OVMF_VARS" "${OUT}"
check "UEFI: does not write the system VARS file" bash -c '! grep -q "file=/usr/share/OVMF/OVMF_VARS" "$1"' _ "${OUT}"

check "UEFI: attaches the ISO" grep -q "${SYSRESCUE_ISO}" "${OUT}"
check "UEFI: attaches a target disk" grep -q 'target\.qcow2' "${OUT}"
check "UEFI: enables KVM when available" bash -c '
  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then grep -q -- "-enable-kvm" "$1"; else ! grep -q -- "-enable-kvm" "$1"; fi' _ "${OUT}"

# --- legacy (negative-test) command line ----------------------------------
bash "${HARNESS}" --dry-run --legacy --iso "${ISO}" > "${OUT}" 2>&1

check "legacy: omits UEFI firmware entirely" bash -c '! grep -q "pflash" "$1"' _ "${OUT}"
check "legacy: still attaches the ISO" grep -q "${SYSRESCUE_ISO}" "${OUT}"

# --- argument handling ----------------------------------------------------
check "rejects unknown options" bash -c '! bash "$1" --dry-run --nonsense --iso "$2" >/dev/null 2>&1' _ "${HARNESS}" "${ISO}"
check "requires a boot source" bash -c '! bash "$1" --dry-run >/dev/null 2>&1' _ "${HARNESS}"
check "rejects two boot sources at once" bash -c '! bash "$1" --dry-run --iso "$2" --stick-image /nonexistent >/dev/null 2>&1' _ "${HARNESS}" "${ISO}"
check "rejects a boot source that does not exist" bash -c '! bash "$1" --dry-run --iso /nonexistent.iso >/dev/null 2>&1' _ "${HARNESS}"

# --- the safety guard that matters ----------------------------------------
# This project exists to write disk images. A harness that will hand the
# workstation's system NVMe to a VM is a loaded gun; --stick must accept
# removable media only.
check "refuses a non-removable device as --stick" bash -c '! bash "$1" --dry-run --stick /dev/nvme0n1 >/dev/null 2>&1' _ "${HARNESS}"
check "refuses a --stick device that does not exist" bash -c '! bash "$1" --dry-run --stick /dev/nope0 >/dev/null 2>&1' _ "${HARNESS}"

# --- lint -----------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck clean" shellcheck -S style "${HARNESS}"
else
  fail_with "shellcheck clean" "shellcheck is not installed"
fi

rm -f "${OUT}"
finish
