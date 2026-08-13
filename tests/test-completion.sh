#!/usr/bin/env bash
# Task 8 acceptance: after a successful write the installer settles the disk,
# tells the operator what to do next, and offers — never performs — a reboot.
#
# SAFETY: the actual reboot and poweroff calls sit behind do_reboot/do_poweroff
# so this suite can stub them. Nothing here may feed an input that would
# restart the workstation, and every case asserts what did NOT happen.

. "$(dirname "$0")/lib.sh"

AUTORUN="${REPO_ROOT}/src/autorun"
WORK="${ARTIFACT_DIR}/.test-completion"

echo "completion and handover"

rm -rf "${WORK}"; mkdir -p "${WORK}"

# with_stubs <input> <code> — run installer functions with hardware stubbed
with_stubs() {
  printf '%s' "$1" | bash -c '
    . "$1" --source-only
    partition_table() { printf "      %s1  32M  vfat  hassos-boot\n      %s8  57G  ext4  hassos-data\n" "$1" "$1"; }
    do_reboot()   { printf "STUB_REBOOT_CALLED\n"; }
    do_poweroff() { printf "STUB_POWEROFF_CALLED\n"; }
    partprobe()   { printf "STUB_PARTPROBE %s\n" "$1"; }
    sync()        { :; }
    eval "$2"
  ' _ "${AUTORUN}" "$2" 2>&1
}

# --- settling the disk ----------------------------------------------------
out="$(with_stubs '' 'settle_target /dev/vda')"
check "re-reads the partition table" grep -q 'STUB_PARTPROBE /dev/vda' <<< "${out}"
check "shows what the disk now contains" grep -q 'hassos-boot' <<< "${out}"
check "shows the data partition" grep -q 'hassos-data' <<< "${out}"

# --- the handover ---------------------------------------------------------
out="$(with_stubs '' 'report_next_steps /dev/vda')"
check "says to remove the USB stick" grep -qi 'remove.*usb\|unplug' <<< "${out}"
check "warns that first boot needs a network" grep -qi 'ethernet\|network\|internet' <<< "${out}"
check "gives the address to reach Home Assistant" grep -q 'homeassistant.local:8123' <<< "${out}"
check "warns the first boot is slow" grep -qi 'minutes\|takes a while\|downloads' <<< "${out}"

# --- the reboot offer -----------------------------------------------------
# Neither option may be the default. An installer that reboots on a stray
# Return is one keystroke from yanking a disk out from under someone.
out="$(with_stubs '' 'offer_reboot')"
check "empty input reboots nothing" bash -c '! grep -q "STUB_REBOOT_CALLED" <<< "$1"' _ "${out}"
check "empty input powers off nothing" bash -c '! grep -q "STUB_POWEROFF_CALLED" <<< "$1"' _ "${out}"
check "says the machine was left running" grep -qi 'left running\|nothing further\|still running' <<< "${out}"

out="$(with_stubs 'n
' 'offer_reboot')"
check "declining does nothing" bash -c '! grep -qE "STUB_(REBOOT|POWEROFF)_CALLED" <<< "$1"' _ "${out}"

out="$(with_stubs 'x
' 'offer_reboot')"
check "an unrecognised answer does nothing" bash -c '! grep -qE "STUB_(REBOOT|POWEROFF)_CALLED" <<< "$1"' _ "${out}"

out="$(with_stubs 'r
' 'offer_reboot')"
check "r reboots" grep -q 'STUB_REBOOT_CALLED' <<< "${out}"

out="$(with_stubs 'p
' 'offer_reboot')"
check "p powers off" grep -q 'STUB_POWEROFF_CALLED' <<< "${out}"

# --- the reboot path is stubbable at all ----------------------------------
# If these were inline commands rather than functions, this suite would have
# restarted the workstation the first time it ran.
check "reboot goes through an overridable function" grep -q '^do_reboot()' "${AUTORUN}"
check "poweroff goes through an overridable function" grep -q '^do_poweroff()' "${AUTORUN}"

# --- the log must be written BEFORE anything can power the machine down ---
# Found on hardware: an install succeeded, the operator accepted the reboot
# offer, and no log reached the stick. The reboot happened inside the run, so
# persistence never got its turn — losing the record on the single most common
# successful path.
check "every reboot offer happens after the log is written" bash -c '
  p=$(grep -n "persist_log \"" "$1" | cut -d: -f1)
  [ -n "$p" ] || exit 1
  # every call site of offer_reboot, ignoring its definition
  for o in $(grep -nE "^[[:space:]]*offer_reboot[[:space:]]*$" "$1" | cut -d: -f1); do
    [ "$o" -gt "$p" ] || exit 1
  done
  exit 0' _ "${AUTORUN}"

check "no reboot is offered after a failed run" bash -c '
  grep -qE "rc\}\" -eq 0 \].*&&|\[ \"\$\{rc\}\" -eq 0 \]" "$1"' _ "${AUTORUN}"

# --- log naming -----------------------------------------------------------
# The test laptop's clock runs weeks slow, so a timestamp alone cannot
# distinguish runs. The target device is the part an operator can correlate.
check "log name includes the target device when known" grep -q 'TARGET' "${AUTORUN}"

if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck: autorun" shellcheck -x --source-path="${REPO_ROOT}" -S style "${AUTORUN}"
fi

rm -rf "${WORK}"
finish
