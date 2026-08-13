#!/usr/bin/env bash
# Task 7 acceptance: the image is streamed to the target and then verified
# byte-for-byte against the source.
#
# SAFETY: every case here writes to a regular file in tmp/. Nothing in this
# suite may name a block device. The write path is exercised for real in QEMU,
# where the target is a qcow2 file and the guest cannot reach this machine's
# disks.

. "$(dirname "$0")/lib.sh"

AUTORUN="${REPO_ROOT}/src/autorun"
WORK="${ARTIFACT_DIR}/.test-write"

echo "streamed write and verification"

rm -rf "${WORK}"; mkdir -p "${WORK}"

# A small but non-trivial payload: big enough to cross dd's block boundaries,
# small enough to run in milliseconds.
SRC="${WORK}/payload.bin"
head -c 5000000 /dev/urandom > "${SRC}" 2>/dev/null || dd if=/dev/urandom of="${SRC}" bs=1M count=5 status=none
IMG="${WORK}/test.img.xz"
xz -c "${SRC}" > "${IMG}"

# in_script <code> — run code with the installer's functions available
in_script() {
  bash -c '. "$1" --source-only; IMAGE="$2"; shift 2; eval "$@"' _ "${AUTORUN}" "${IMG}" "$1" 2>&1
}

# --- uncompressed size ----------------------------------------------------
# Task 8's verification bounds itself with this number, so a wrong answer
# means comparing past the end of the image into whatever the disk held.
bytes="$(in_script 'image_uncompressed_bytes "${IMAGE}"')"
check "reports the uncompressed size" bash -c '[ "$1" = "$2" ]' _ "${bytes}" "$(stat -c %s "${SRC}")"

# --- the write ------------------------------------------------------------
TARGET="${WORK}/target.bin"
: > "${TARGET}"
out="$(in_script 'write_image "'"${TARGET}"'"')"
check "write reports the target" grep -q "${TARGET}" <<< "${out}"
check "target is the decompressed image, byte for byte" bash -c 'cmp -s "$1" "$2"' _ "${SRC}" "${TARGET}"

# --- verification on a good write -----------------------------------------
in_script 'verify_image "'"${TARGET}"'"' > "${WORK}/verify-good.txt" 2>&1
check "verification passes on a correct write" bash -c '! grep -qi "mismatch\|FATAL" "$1"' _ "${WORK}/verify-good.txt"

# --- verification catches corruption --------------------------------------
# One flipped byte in the middle. If verification cannot see this, it is
# decoration rather than a check.
printf 'X' | dd of="${TARGET}" bs=1 seek=2500000 conv=notrunc status=none
out="$(in_script 'verify_image "'"${TARGET}"'"')"
check "verification fails on a single corrupted byte" grep -qi 'mismatch\|differ\|FATAL' <<< "${out}"

# --- verification catches a short write -----------------------------------
# A target smaller than the image: the comparison must not report success
# just because it ran out of data.
truncate -s 1000000 "${TARGET}"
out="$(in_script 'verify_image "'"${TARGET}"'"')"
check "verification fails on a truncated target" grep -qi 'mismatch\|differ\|short\|FATAL' <<< "${out}"

# --- verification is bounded by the image, not the target -----------------
# Real targets are far larger than the image. Comparison must stop at the
# image's end rather than treating the remaining disk as a difference.
: > "${TARGET}"
in_script 'write_image "'"${TARGET}"'"' >/dev/null 2>&1
printf 'trailing junk beyond the image\n' >> "${TARGET}"
out="$(in_script 'verify_image "'"${TARGET}"'"')"
check "ignores data past the end of the image" bash -c '! grep -qi "mismatch\|differ\|FATAL" <<< "$1"' _ "${out}"

# --- the production guard -------------------------------------------------
# run_selection must refuse a target that is not a block device, so a bug in
# enumeration cannot turn into a write against a file or a directory.
check "defines a block-device guard" grep -q '^require_block_device()' "${AUTORUN}"
out="$(in_script 'require_block_device "'"${WORK}"'/not-a-device"')"
check "guard refuses a non-block-device target" grep -qi 'not a block device\|FATAL' <<< "${out}"

if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck: autorun" shellcheck -x --source-path="${REPO_ROOT}" -S style "${AUTORUN}"
fi

rm -rf "${WORK}"
finish
