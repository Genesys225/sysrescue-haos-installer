#!/usr/bin/env bash
# Task 5 acceptance: candidate filtering keeps exactly the disks it should.
#
# Pure unit tests against captured lsblk output — no hardware, no privileges.
# The filter is the last thing standing between the operator and a menu that
# offers to erase the wrong disk, so every exclusion rule gets its own case.
#
# Fixtures use lsblk's --pairs format deliberately: MODEL contains spaces
# ("EXAMPLE SATA SSD 960G"), and TRAN is empty for loop and virtio devices, so
# column-positional parsing misreads real machines.

. "$(dirname "$0")/lib.sh"

AUTORUN="${REPO_ROOT}/src/autorun"
FIX="${REPO_ROOT}/tests/fixtures"

echo "candidate enumeration"

# filter <fixture> <boot-disk> — candidate device paths, one per line
filter() {
  bash -c '. "$1" --source-only; filter_candidates "$3" < "$2"' _ "${AUTORUN}" "${FIX}/$2" "${3:-}"
}

# --- the real workstation -------------------------------------------------
# 45 loop devices for snaps, one USB stick, one SATA and four NVMe disks.
out="$(filter _ lsblk-workstation.txt /dev/nvme0n1)"

check "excludes every loop device" bash -c '! grep -q "loop" <<< "$1"' _ "${out}"
check "excludes the USB stick" bash -c '! grep -q "/dev/sdb" <<< "$1"' _ "${out}"
check "excludes the boot disk" bash -c '! grep -q "/dev/nvme0n1" <<< "$1"' _ "${out}"
check "keeps the SATA disk" bash -c 'grep -q "^/dev/sda$" <<< "$1"' _ "${out}"
check "keeps the other three NVMe disks" bash -c '[ "$(grep -c nvme <<< "$1")" -eq 3 ]' _ "${out}"
check "returns exactly four candidates" bash -c '[ "$(grep -c . <<< "$1")" -eq 4 ]' _ "${out}"

# --- a QEMU guest ---------------------------------------------------------
out="$(filter _ lsblk-qemu.txt /dev/sda)"
check "qemu: keeps only the virtio target" bash -c '[ "$1" = "/dev/vda" ]' _ "${out}"
check "qemu: excludes the optical drive" bash -c '! grep -q "sr0" <<< "$1"' _ "${out}"
check "qemu: excludes zram" bash -c '! grep -q "zram" <<< "$1"' _ "${out}"

# --- a typical target machine ---------------------------------------------
out="$(filter _ lsblk-single-disk.txt /dev/sda)"
check "single-disk: finds the internal NVMe" bash -c '[ "$1" = "/dev/nvme0n1" ]' _ "${out}"

# --- nothing installable --------------------------------------------------
out="$(filter _ lsblk-no-candidates.txt /dev/sda)"
check "no-candidates: returns nothing" bash -c '[ -z "$1" ]' _ "${out}"

# --- boot disk not excluded when unknown ----------------------------------
# If the boot device cannot be resolved, the filter must not silently treat
# everything as fair game — but neither should it drop real disks. It returns
# them all; refusing is the caller's job, with a human in the loop.
out="$(filter _ lsblk-single-disk.txt '')"
check "unknown boot disk still excludes removable media" bash -c '! grep -q "/dev/sda" <<< "$1"' _ "${out}"

# --- undersized disks are kept, not dropped -------------------------------
# A 16 GB eMMC is a bad idea for HAOS but it is the operator's call, not ours.
# Silently hiding the only disk in the machine would be worse than a warning.
out="$(filter _ lsblk-tiny-disk.txt /dev/sda)"
check "keeps an undersized disk as a candidate" bash -c '[ "$1" = "/dev/mmcblk0" ]' _ "${out}"

# --- description lookup ---------------------------------------------------
desc="$(bash -c '. "$1" --source-only; describe_device "/dev/nvme1n1" < "$2"' _ "${AUTORUN}" "${FIX}/lsblk-workstation.txt")"
check "describes a device with size and model" bash -c 'grep -q "931.5G" <<< "$1" && grep -q "Example NVMe Plus 1TB" <<< "$1"' _ "${desc}"
check "description survives spaces in the model" bash -c 'grep -q "EVO Plus 1TB" <<< "$1"' _ "${desc}"

if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck: autorun" shellcheck -x --source-path="${REPO_ROOT}" -S style "${AUTORUN}"
fi

finish
