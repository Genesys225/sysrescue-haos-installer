#!/usr/bin/env bash
# The run must leave evidence on the stick — especially when it refuses.
#
# The boot medium mounts read-only, so this needs a remount. That was proven
# to work on hardware; what is tested here is that the script actually does
# it, that a refusal is recorded rather than lost, and that the exit status
# survives the extra plumbing.

. "$(dirname "$0")/lib.sh"
. "${REPO_ROOT}/build/artifacts.conf"

AUTORUN="${REPO_ROOT}/src/autorun"
WORK="${ARTIFACT_DIR}/.test-logging"

echo "run logging"

make_bootmnt() {
  local dir="$1"
  rm -rf "${dir}"
  mkdir -p "${dir}/haos" "${dir}/efi"
  printf 'pretend disk image\n' | xz > "${dir}/haos/${HAOS_IMG}"
  ( cd "${dir}/haos" && sha256sum "${HAOS_IMG}" > "${HAOS_SHA_SIDECAR}" )
}

logs_in() { find "$1/logs" -maxdepth 1 -type f -name '*.log' 2>/dev/null; }

# --- a run that gets as far as target selection ---------------------------
# Stdin is closed on purpose. This suite must never answer a confirmation
# prompt: the write behind it becomes real in Task 7, and a test that types
# the magic words at it would erase one of this machine's disks.
make_bootmnt "${WORK}"
bash "${AUTORUN}" --bootmnt "${WORK}" --efi-path "${WORK}/efi" >/dev/null 2>&1 < /dev/null
check "an aborted run is still logged" bash -c '[ -n "$(find "$1/logs" -maxdepth 1 -type f -name "*.log" 2>/dev/null)" ]' _ "${WORK}"
check "writes a log to the boot medium" bash -c '[ -n "$(find "$1/logs" -maxdepth 1 -type f -name "*.log" 2>/dev/null)" ]' _ "${WORK}"
check "log names the host" bash -c 'grep -qi "$(uname -n)" $(find "$1/logs" -type f -name "*.log")' _ "${WORK}"
check "log contains the report" bash -c 'grep -qi "firmware" $(find "$1/logs" -type f -name "*.log")' _ "${WORK}"

# --- refused run — the case that matters ----------------------------------
# A refusal that leaves no trace is the worst outcome: the operator powers off
# and the reason goes with it.
make_bootmnt "${WORK}"
bash "${AUTORUN}" --bootmnt "${WORK}" --efi-path "${WORK}/no-such-efi" >/dev/null 2>&1
rc=$?
check "refused run exits non-zero" test "${rc}" -ne 0
check "writes a log even when refusing" bash -c '[ -n "$(find "$1/logs" -maxdepth 1 -type f -name "*.log" 2>/dev/null)" ]' _ "${WORK}"
check "the log records the refusal itself" bash -c 'grep -qi "legacy BIOS" $(find "$1/logs" -type f -name "*.log")' _ "${WORK}"
check "the log records the remediation" bash -c 'grep -qi "secure boot" $(find "$1/logs" -type f -name "*.log")' _ "${WORK}"

# --- successive runs do not overwrite each other --------------------------
make_bootmnt "${WORK}"
bash "${AUTORUN}" --bootmnt "${WORK}" --efi-path "${WORK}/efi" >/dev/null 2>&1
bash "${AUTORUN}" --bootmnt "${WORK}" --efi-path "${WORK}/efi" >/dev/null 2>&1
check "two runs leave two logs" bash -c '[ "$(find "$1/logs" -maxdepth 1 -type f -name "*.log" | wc -l)" -eq 2 ]' _ "${WORK}"

# --- must not fabricate a boot medium -------------------------------------
# An earlier version created directories under the boot medium path as a side
# effect, which made an absent-medium test pass for the wrong reason.
ABSENT="${ARTIFACT_DIR}/.test-logging-absent"
rm -rf "${ABSENT}"
bash "${AUTORUN}" --bootmnt "${ABSENT}" >/dev/null 2>&1
check "does not create anything when the medium is absent" bash -c '[ ! -e "$1" ]' _ "${ABSENT}"

# --- the script says where the evidence went ------------------------------
make_bootmnt "${WORK}"
OUT="${ARTIFACT_DIR}/.test-logging-out.txt"
bash "${AUTORUN}" --bootmnt "${WORK}" --efi-path "${WORK}/efi" > "${OUT}" 2>&1
check "tells the operator where the log was written" grep -qi 'log written\|saved to' "${OUT}"

if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck: autorun" shellcheck -x --source-path="${REPO_ROOT}" -S style "${AUTORUN}"
fi

rm -rf "${WORK}" "${ABSENT}" "${OUT}"
finish
