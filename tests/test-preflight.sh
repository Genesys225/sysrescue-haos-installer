#!/usr/bin/env bash
# Task 4 acceptance: the four preflight guards fire correctly, and every
# refusal tells the operator what to do next.
#
# Guards run in dependency order: without a boot medium nothing else can be
# checked, and there is no point hashing 552 MB on a machine that cannot boot
# the result anyway.

. "$(dirname "$0")/lib.sh"
. "${REPO_ROOT}/build/artifacts.conf"

AUTORUN="${REPO_ROOT}/src/autorun"
WORK="${ARTIFACT_DIR}/.test-preflight"

echo "preflight guards"

# Builds a fake boot medium. Uses a tiny image rather than the real 552 MB
# payload so the checksum guard can be exercised in milliseconds.
make_bootmnt() {
  local dir="$1"
  rm -rf "${dir}"
  mkdir -p "${dir}/haos" "${dir}/logs" "${dir}/efi"
  printf 'pretend disk image\n' | xz > "${dir}/haos/${HAOS_IMG}"
  ( cd "${dir}/haos" && sha256sum "${HAOS_IMG}" > "${HAOS_SHA_SIDECAR}" )
}

# run_guarded <bootmnt> [--legacy] — returns the script's exit code, output in $OUT
OUT="${ARTIFACT_DIR}/.test-preflight-out.txt"
run_guarded() {
  local mnt="$1"; shift
  local efi="${mnt}/efi"
  [ "${1:-}" = "--legacy" ] && efi="${mnt}/no-such-efi"
  bash "${AUTORUN}" --bootmnt "${mnt}" --efi-path "${efi}" > "${OUT}" 2>&1
}

# --- happy path -----------------------------------------------------------
# Preflight passing no longer means the run exits 0 — it now hands off to
# target selection, which needs an operator. Passing means reaching that
# handoff. Stdin stays closed here deliberately: this suite must never drive
# a confirmation, because the write behind it stops being a stub in Task 7.
make_bootmnt "${WORK}"
run_guarded "${WORK}"
check "reaches target selection when everything is in order" grep -qi 'select the disk' "${OUT}"
check "still reports the facts it gathered" grep -qi 'firmware' "${OUT}"

# --- require_bootmnt ------------------------------------------------------
# Must be provably absent. An earlier version of the script created this path
# as a side effect, so a stale directory from a previous run made this guard
# appear to pass. Never assume a path is missing — make it missing.
ABSENT="${ARTIFACT_DIR}/.no-such-bootmnt"
rm -rf "${ABSENT}"
run_guarded "${ABSENT}"
check "refuses when the boot medium is absent" test $? -ne 0
check "bootmnt refusal names the cause" grep -qi 'boot medium\|bootmnt' "${OUT}"
check "bootmnt refusal tells the operator what to do" grep -qiE 'run this from|boot .*from the|stick' "${OUT}"

# Running on a workstation must stop here, before touching anything else.
bash "${AUTORUN}" --bootmnt /run/archiso/bootmnt > "${OUT}" 2>&1
check "exits on a workstation without proceeding" test $? -ne 0
check "does not print the payload listing after refusing" bash -c '! grep -q "Payload:" "$1"' _ "${OUT}"

# --- require_uefi ---------------------------------------------------------
make_bootmnt "${WORK}"
run_guarded "${WORK}" --legacy
check "refuses a legacy BIOS boot" test $? -ne 0
check "uefi refusal explains the consequence" grep -qi 'unbootable\|cannot boot\|requires uefi' "${OUT}"
check "uefi refusal names the firmware settings to change" grep -qi 'secure boot' "${OUT}"

# --- require_single_image -------------------------------------------------
make_bootmnt "${WORK}"
rm -f "${WORK}/haos/${HAOS_IMG}" "${WORK}/haos/${HAOS_SHA_SIDECAR}"
run_guarded "${WORK}"
check "refuses when no image is present" test $? -ne 0
check "missing-image refusal names the fix" grep -qi 'make-stick\|fetch-artifacts' "${OUT}"

make_bootmnt "${WORK}"
printf 'second image\n' | xz > "${WORK}/haos/haos_generic-x86-64-99.9.img.xz"
run_guarded "${WORK}"
check "refuses when two images are present" test $? -ne 0
check "ambiguous-image refusal says to remove one" grep -qiE 'remove|exactly one|only one' "${OUT}"

# --- require_checksum -----------------------------------------------------
make_bootmnt "${WORK}"
printf 'tampered\n' | xz > "${WORK}/haos/${HAOS_IMG}"     # sidecar now stale
run_guarded "${WORK}"
check "refuses when the checksum does not match" test $? -ne 0
check "checksum refusal names the likely cause" grep -qiE 'corrupt|rot|damaged|re-?copy' "${OUT}"

make_bootmnt "${WORK}"
rm -f "${WORK}/haos/${HAOS_SHA_SIDECAR}"
run_guarded "${WORK}"
check "refuses when the sidecar is missing" test $? -ne 0

# --- the guards exist by the names the plan gives them --------------------
# "No guard message describes only the failure without a remedy" is asserted
# behaviourally above, once per guard. This only pins the structure.
for guard in require_bootmnt require_uefi require_single_image require_checksum; do
  check "defines ${guard}" grep -q "^${guard}()" "${AUTORUN}"
done

if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck: autorun" shellcheck -x --source-path="${REPO_ROOT}" -S style "${AUTORUN}"
fi

rm -rf "${WORK}" "${OUT}"
finish
