#!/usr/bin/env bash
# The whole run, end to end, with only the destructive parts replaced.
#
# This suite exists because of what the others could not see. Every bug that
# reached hardware lived in the wiring between functions, not inside them:
#
#   * the reboot offer ran before the log was written, so accepting it
#     destroyed the record of a successful install
#   * the chosen disk was assigned inside a pipeline's subshell, so logs were
#     misnamed and the reboot offer became unreachable
#
# Both were invisible to tests that call one function at a time, and both were
# found by reading an artefact from a real run. Driving run_main closes that
# gap: the pipeline, the subshell boundary and the ordering are all executed.

. "$(dirname "$0")/lib.sh"
. "${REPO_ROOT}/build/artifacts.conf"

AUTORUN="${REPO_ROOT}/src/autorun"
WORK="${ARTIFACT_DIR}/.test-orch"

echo "whole-run orchestration"

make_bootmnt() {
  rm -rf "$1"; mkdir -p "$1/haos" "$1/efi"
  printf 'pretend image\n' | xz > "$1/haos/${HAOS_IMG}"
  ( cd "$1/haos" && sha256sum "${HAOS_IMG}" > "${HAOS_SHA_SIDECAR}" )
}

# run_whole <input> — executes run_main with hardware and destructive steps
# stubbed. Everything else, including the pipeline, is the real thing.
run_whole() {
  printf '%s' "$1" | bash -c '
    . "$1" --source-only
    BOOTMNT="$2"; EFI_SYSFS="$2/efi"

    block_devices()   { printf "NAME=\"/dev/vda\" SIZE=\"64G\" TYPE=\"disk\" TRAN=\"\" RM=\"0\" MODEL=\"\"\n"; }
    partition_table() { printf "      %s  64G\n" "$1"; }
    partprobe()       { :; }
    require_block_device() { :; }
    write_image()     { printf "  STUB_WRITE %s\n" "$1"; }
    verify_image()    { printf "  STUB_VERIFY %s\n" "$1"; }
    do_reboot()       { printf "STUB_REBOOT\n"; }
    do_poweroff()     { printf "STUB_POWEROFF\n"; }

    run_main
    printf "EXIT=%s\n" "$?"
  ' _ "${AUTORUN}" "${WORK}" 2>&1
}

logs_in() { find "${WORK}/logs" -maxdepth 1 -type f -name '*.log' -printf '%f\n' 2>/dev/null; }

# --- a complete successful run --------------------------------------------
# Piped input, so selection takes the numeric path; then the device path, then
# a decline of the reboot offer.
make_bootmnt "${WORK}"
out="$(run_whole '1
/dev/vda
n
')"

check "the run completes successfully" grep -q 'EXIT=0' <<< "${out}"
check "it reaches the write" grep -q 'STUB_WRITE /dev/vda' <<< "${out}"
check "it verifies afterwards" grep -q 'STUB_VERIFY /dev/vda' <<< "${out}"
check "it hands over to the operator" grep -q 'homeassistant.local' <<< "${out}"
check "it offers a reboot" grep -qi 'reboot now' <<< "${out}"
check "declining leaves the machine running" bash -c '! grep -q "STUB_REBOOT" <<< "$1"' _ "${out}"

# The bug that shipped: this name was falling back to the generic prefix
# because the target never crossed the pipeline boundary.
check "the log is named after the disk that was written" bash -c 'case "$(cd "$1" 2>/dev/null && find logs -name "*.log" -printf "%f\n")" in install-vda-*) exit 0;; *) exit 1;; esac' _ "${WORK}"
check "exactly one log per run" bash -c '[ "$(find "$1/logs" -name "*.log" | wc -l)" -eq 1 ]' _ "${WORK}"
check "the log records the write" bash -c 'grep -q "STUB_WRITE" "$1"/logs/*.log' _ "${WORK}"

# --- accepting the reboot -------------------------------------------------
# The ordering that cost a real run's log: the record must already exist on
# the medium by the time anything can power the machine down.
make_bootmnt "${WORK}"
out="$(run_whole '1
/dev/vda
r
')"
check "accepting the offer reboots" grep -q 'STUB_REBOOT' <<< "${out}"
check "the log survives a reboot being accepted" bash -c '[ -n "$(find "$1/logs" -name "*.log" 2>/dev/null)" ]' _ "${WORK}"
check "the log was written before the reboot" bash -c 'grep -q "STUB_WRITE" "$1"/logs/*.log' _ "${WORK}"

# --- a refused run --------------------------------------------------------
make_bootmnt "${WORK}"
out="$(run_whole '')"
check "an aborted selection exits non-zero" bash -c '! grep -q "EXIT=0" <<< "$1"' _ "${out}"
check "no reboot is offered after a failure" bash -c '! grep -qi "reboot now" <<< "$1"' _ "${out}"
check "a failed run is still logged" bash -c '[ -n "$(find "$1/logs" -name "*.log" 2>/dev/null)" ]' _ "${WORK}"
check "a failed run's log is not named after a disk" bash -c 'case "$(cd "$1" && find logs -name "*.log" -printf "%f\n")" in preflight-*) exit 0;; *) exit 1;; esac' _ "${WORK}"

# --- a guard refusing ------------------------------------------------------
make_bootmnt "${WORK}"
rm -f "${WORK}/haos/${HAOS_IMG}"
out="$(run_whole '')"
check "a preflight refusal never reaches the write" bash -c '! grep -q "STUB_WRITE" <<< "$1"' _ "${out}"
check "a preflight refusal is recorded on the medium" bash -c 'grep -qi "no Home Assistant OS image" "$1"/logs/*.log' _ "${WORK}"

rm -rf "${WORK}"
finish
