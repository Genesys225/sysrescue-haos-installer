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

# --- the autorun script ---------------------------------------------------
# Task 3's assertions about the script's own output have moved to
# test-preflight.sh, which builds a boot medium complete enough to get past
# the guards. Two Task 3 behaviours were deliberately dropped in Task 4:
#
#   * writing a report file to the boot medium — the medium is mounted
#     read-only, so it never worked on hardware. Logging is Task 8's, and
#     needs a remount first.
#   * mkdir -p on the boot medium path — a side effect that created the very
#     directory a later test needed to be absent.
#
# What remains here is Task 3's actual deliverable: the drop-in files and the
# builder that installs them.

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
# SystemRescue ships an autorun/ FOLDER at the root and searches it for
# scripts. The script belongs inside it, not at the root as a file.
check "autorun/ is a directory" test -d "${STICK}/autorun"
check "installs the script as autorun/autorun" test -f "${STICK}/autorun/autorun"
check "does not leave a stray file at the root" bash -c '[ ! -f "$1/autorun" ]' _ "${STICK}"
# Needs a stick where the destination has never been a file, so this gets its
# own directory rather than reusing the populated one above.
TRAP_STICK="${ARTIFACT_DIR}/.test-stick-dirtrap"
rm -rf "${TRAP_STICK}"
mkdir -p "${TRAP_STICK}/sysresccd" "${TRAP_STICK}/sysrescue.d/500-haos.yaml"
check "refuses to copy over a directory" bash -c '! bash "$1" "$2" >/dev/null 2>&1' _ "${MAKESTICK}" "${TRAP_STICK}"
rm -rf "${TRAP_STICK}"
check "installs the yaml into sysrescue.d/" test -f "${STICK}/sysrescue.d/500-haos.yaml"
check "installs the HAOS image under haos/" test -f "${STICK}/haos/${HAOS_IMG}"
check "installs the checksum sidecar" test -f "${STICK}/haos/${HAOS_SHA_SIDECAR}"
check "creates the logs directory" test -d "${STICK}/logs"
check "is idempotent" bash "${MAKESTICK}" "${STICK}"

# NOTE: writing SystemRescue to the stick is deliberately NOT scripted here.
# The plan makes it operator-run, and sysrescueusbwriter already does the job —
# wrapping it would be reimplementing a solved thing, and a wrapper that picks
# its own target is the exact footgun this project is built to avoid.

# --- lint -----------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  # -x so shellcheck follows the sourced manifest rather than reporting SC1091.
  # --source-path is required because run.sh executes from tests/, so a relative
  # source path in the script under test would resolve against the wrong dir.
  check "shellcheck: autorun" shellcheck -x --source-path="${REPO_ROOT}" -S style "${AUTORUN}"
  check "shellcheck: make-stick.sh" shellcheck -x --source-path="${REPO_ROOT}" -S style "${MAKESTICK}"
else
  fail_with "shellcheck clean" "shellcheck is not installed"
fi

rm -rf "${FAKE}" "${STICK}" "${OUT}" "${ARTIFACT_DIR}/.test-makestick.log"
finish
