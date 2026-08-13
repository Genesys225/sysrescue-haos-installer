#!/usr/bin/env bash
# Task 6 acceptance: the operator picks the target, and nothing is written
# until they type its path back.
#
# The write is still a stub here. Every test asserting "the write was not
# reached" is checking for the stub's marker — once Task 7 replaces it, those
# same assertions guard the real thing.

. "$(dirname "$0")/lib.sh"

AUTORUN="${REPO_ROOT}/src/autorun"
FIX="${REPO_ROOT}/tests/fixtures"

echo "target selection"

# Drives the selection flow with stubbed hardware. Input arrives on stdin;
# everything the operator would see comes back on stdout.
#
#   drive <fixture> <candidates...> <<< "keystrokes"
drive() {
  local fixture="$1"; shift
  local candidates="$*"
  # The fixture and candidate list must be captured into variables BEFORE the
  # stub functions are defined: inside a function body, $2 is that function's
  # own second argument, not the script's.
  bash -c '
    . "$1" --source-only
    FIXTURE="$2"; CANDS="$3"
    block_devices()   { cat "${FIXTURE}"; }
    list_candidates() { [ -n "${CANDS}" ] && printf "%s\n" ${CANDS}; return 0; }
    partition_table() { printf "      %s: 2 partitions, one labelled DATA\n" "$1"; }

    # MANDATORY. This suite runs on the workstation, not in a VM, and it types
    # confirmations at candidate paths like /dev/nvme0n1 — the disk holding /.
    # Without this stub the write below would be real and would run here.
    # The genuine write is exercised in QEMU, where the target is a qcow2 file.
    write_image() { printf "  WOULD WRITE image %s to %s\n  (stubbed by the test harness)\n" "${IMAGE##*/}" "$1"; }
    require_block_device() { :; }
    verify_image() { :; }

    run_selection
  ' _ "${AUTORUN}" "${FIX}/${fixture}" "${candidates}" 2>&1
}

# --- the menu -------------------------------------------------------------
out="$(printf '1\n/dev/nvme1n1\n' | drive lsblk-workstation.txt /dev/nvme1n1 /dev/sda)"

check "numbers the candidates from 1" grep -q '1)' <<< "${out}"
check "numbers a second candidate" grep -q '2)' <<< "${out}"
check "shows size and model" bash -c 'grep -q "931.5G" <<< "$1" && grep -q "Example NVMe" <<< "$1"' _ "${out}"
check "shows the transport" grep -q 'nvme' <<< "${out}"
check "shows what is already on the disk" grep -q '2 partitions' <<< "${out}"

# --- never auto-select ----------------------------------------------------
# Even with exactly one candidate the operator must choose it. A tool that
# picks for you is one misplaced stick away from erasing the wrong machine.
out="$(printf '1\n/dev/nvme0n1\n' | drive lsblk-single-disk.txt /dev/nvme0n1)"
check "single candidate is still presented as a menu" grep -q '1)' <<< "${out}"
check "single candidate still requires a choice" grep -qi 'select\|choose\|which' <<< "${out}"

# --- no candidates --------------------------------------------------------
out="$(printf '' | drive lsblk-no-candidates.txt)"
rc=$?
check "refuses when there are no candidates" bash -c 'grep -qi "no installable\|nothing to install\|no disks" <<< "$1"' _ "${out}"
check "no-candidate refusal explains why" bash -c 'grep -qi "removable\|usb\|internal" <<< "$1"' _ "${out}"

# --- invalid menu input ---------------------------------------------------
for bad in "0" "99" "abc" ""; do
  out="$(printf '%s\n' "${bad}" | drive lsblk-single-disk.txt /dev/nvme0n1)"
  check "rejects menu input '${bad}'" bash -c '! grep -q "WOULD WRITE" <<< "$1"' _ "${out}"
done

# --- confirmation ---------------------------------------------------------
# Enter selects the disk, Enter again confirms. Nothing is typed. On piped
# input an empty line is that second Enter; any other key cancels.
out="$(printf '1\n\n' | drive lsblk-single-disk.txt /dev/nvme0n1)"
check "a second Enter confirms" grep -q 'WOULD WRITE' <<< "${out}"
check "warns that the contents are destroyed" grep -qi 'destroy\|erase\|overwrit' <<< "${out}"

out="$(printf '1\ny\n' | drive lsblk-single-disk.txt /dev/nvme0n1)"
check "a non-Enter answer aborts" bash -c '! grep -q "WOULD WRITE" <<< "$1"' _ "${out}"
check "says it was aborted" grep -qi "aborted" <<< "${out}"

out="$(printf '1\nno\n' | drive lsblk-single-disk.txt /dev/nvme0n1)"
check "a word aborts too" bash -c '! grep -q "WOULD WRITE" <<< "$1"' _ "${out}"

check "nothing has to be typed to confirm" bash -c '! grep -q "Type the device path\|Type .yes." "$1"' _ "${AUTORUN}"
check "the prompt names both keys" bash -c 'grep -q "Enter to confirm, Esc to abort" "$1"' _ "${AUTORUN}"

out="$(printf '1\n\n' | drive lsblk-single-disk.txt /dev/nvme0n1)"

# --- the stub is still a stub ---------------------------------------------
check "names the image it would write" grep -qi 'img.xz\|image' <<< "${out}"
check "states plainly that nothing was written" grep -qi 'nothing was written\|not yet implemented\|stub' <<< "${out}"

if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck: autorun" shellcheck -x --source-path="${REPO_ROOT}" -S style "${AUTORUN}"
fi

finish
