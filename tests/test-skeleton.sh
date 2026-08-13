#!/usr/bin/env bash
# Task 3 acceptance: the drop-in files exist, say the right things, and
# make-stick.sh assembles them onto a stick correctly and safely.
#
# The actual proof — that SystemRescue executes a dropped-in autorun — can
# only come from a boot. These tests cover everything up to that point so the
# boot is testing one unknown instead of five.

. "$(dirname "$0")/lib.sh"
. "${REPO_ROOT}/build/artifacts.conf"

AUTORUN="${REPO_ROOT}/src/autorun"
YAML="${REPO_ROOT}/src/500-haos.yaml"
MAKESTICK="${REPO_ROOT}/build/make-stick.sh"

echo "walking skeleton"

check "autorun exists" test -f "${AUTORUN}"
check "yaml drop-in exists" test -f "${YAML}"
check "make-stick.sh exists" test -f "${MAKESTICK}"
check "make-stick.sh is executable" test -x "${MAKESTICK}"

if [ ! -f "${AUTORUN}" ] || [ ! -f "${YAML}" ] || [ ! -x "${MAKESTICK}" ]; then
  fail_with "skeleton is present" "cannot continue"
  finish
  exit $?
fi

# --- the YAML drop-in -----------------------------------------------------
# SystemRescue only reads *.yaml (not *.yml) and merges lexicographically.
check "yaml declares the autorun scope" grep -q '^autorun:' "${YAML}"
check "yaml runs without waiting" grep -qE 'ar_nowait|wait:' "${YAML}"
check "yaml does not enable copytoram" bash -c '! grep -qE "^\s*copytoram:\s*true" "$1"' _ "${YAML}"

# --- the autorun script, run against a fake boot medium -------------------
FAKE="${ARTIFACT_DIR}/.test-bootmnt"
rm -rf "${FAKE}"; mkdir -p "${FAKE}/haos" "${FAKE}/logs"
: > "${FAKE}/haos/${HAOS_IMG}"

OUT="${ARTIFACT_DIR}/.test-autorun-out.txt"
bash "${AUTORUN}" --bootmnt "${FAKE}" > "${OUT}" 2>&1 || true

check "autorun prints a banner" grep -qi 'haos installer' "${OUT}"
check "autorun reports firmware mode" grep -qi 'firmware' "${OUT}"
check "autorun reports its own permission bits" grep -qi 'permission\|exec bit\|mode:' "${OUT}"
check "autorun reports the boot medium contents" grep -q "${HAOS_IMG}" "${OUT}"

# The whole point of the skeleton: leave evidence behind that survives a
# reboot, so the checkpoint can be judged from the stick rather than from
# someone's memory of a screen.
check "autorun writes a report onto the boot medium" bash -c 'ls "$1"/logs/skeleton-*.txt >/dev/null 2>&1' _ "${FAKE}"
check "the report names the firmware mode" bash -c 'grep -qi firmware "$1"/logs/skeleton-*.txt' _ "${FAKE}"

# It must never exit non-zero on a healthy run — SystemRescue's on_error:
# break would halt the sequence and hide the very output we need.
bash "${AUTORUN}" --bootmnt "${FAKE}" >/dev/null 2>&1
check "autorun exits 0 on a healthy run" test $? -eq 0

# --- make-stick.sh --------------------------------------------------------
STICK="${ARTIFACT_DIR}/.test-stick"
rm -rf "${STICK}"; mkdir -p "${STICK}"

# Refuse to scatter files across an arbitrary directory. A real stick written
# by sysrescueusbwriter carries a sysresccd/ tree; without it, we are almost
# certainly pointed at the wrong place.
check "refuses a directory that is not a SystemRescue stick" bash -c '! bash "$1" "$2" >/dev/null 2>&1' _ "${MAKESTICK}" "${STICK}"
check "refuses a path that does not exist" bash -c '! bash "$1" /nonexistent-stick >/dev/null 2>&1' _ "${MAKESTICK}"

mkdir -p "${STICK}/sysresccd"          # now it looks like a real stick
bash "${MAKESTICK}" "${STICK}" > "${ARTIFACT_DIR}/.test-makestick.log" 2>&1
rc=$?
check "populates a stick successfully" test "${rc}" -eq 0
check "installs autorun at the stick root" test -f "${STICK}/autorun"
check "installs the yaml into sysrescue.d/" test -f "${STICK}/sysrescue.d/500-haos.yaml"
check "installs the HAOS image under haos/" test -f "${STICK}/haos/${HAOS_IMG}"
check "installs the checksum sidecar" test -f "${STICK}/haos/${HAOS_SHA_SIDECAR}"
check "creates the logs directory" test -d "${STICK}/logs"
check "is idempotent" bash "${MAKESTICK}" "${STICK}"

# --- the image builder ----------------------------------------------------
# It is the one privileged step in the project, so it must refuse clearly
# rather than fail halfway through with a confusing losetup error.
IMAGEBUILD="${REPO_ROOT}/build/make-stick-image.sh"
check "image builder exists and is executable" test -x "${IMAGEBUILD}"
if [ "$(id -u)" -ne 0 ]; then
  check "image builder refuses to run without root" bash -c '! bash "$1" >/dev/null 2>&1' _ "${IMAGEBUILD}"
  check "image builder names the command to re-run" bash -c 'bash "$1" 2>&1 | grep -q "sudo"' _ "${IMAGEBUILD}"
fi

# It attaches a loop device and then hands it to a raw-image writer. On this
# machine dozens of loop devices back live snap mounts, so the identity of the
# device it got must be proven, not assumed. The runtime checks need root; what
# is assertable here is that the guards exist and name the right conditions.
check "verifies the loop device backs our image" grep -q 'refusing to write:.*backs' "${IMAGEBUILD}"
check "refuses a non-loop device path" grep -q 'not a loop device' "${IMAGEBUILD}"
check "refuses a block device as the image" bash -c '! bash "$1" /dev/sdb 2>&1 | grep -q "needs root"' _ "${IMAGEBUILD}"
check "block-device refusal names the reason" bash -c 'bash "$1" /dev/sdb 2>&1 | grep -q "that is a block device"' _ "${IMAGEBUILD}"
check "detaches only a device it can still prove is ours" grep -q 'NOT detaching' "${IMAGEBUILD}"

# --- lint -----------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  # -x so shellcheck follows the sourced manifest rather than reporting SC1091.
  # --source-path is required because run.sh executes from tests/, so a relative
  # source path in the script under test would resolve against the wrong dir.
  check "shellcheck: autorun" shellcheck -x --source-path="${REPO_ROOT}" -S style "${AUTORUN}"
  check "shellcheck: make-stick.sh" shellcheck -x --source-path="${REPO_ROOT}" -S style "${MAKESTICK}"
  check "shellcheck: make-stick-image.sh" shellcheck -x --source-path="${REPO_ROOT}" -S style "${REPO_ROOT}/build/make-stick-image.sh"
else
  fail_with "shellcheck clean" "shellcheck is not installed"
fi

rm -rf "${FAKE}" "${STICK}" "${OUT}" "${ARTIFACT_DIR}/.test-makestick.log"
finish
