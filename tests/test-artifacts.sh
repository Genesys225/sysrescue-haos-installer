#!/usr/bin/env bash
# Task 1 acceptance: the artifacts are present, intact, and measured.
#
# This is also the standing pre-flight for any later task that builds a stick —
# re-run it whenever the manifest changes or the artifacts have been sitting.

. "$(dirname "$0")/lib.sh"
. "${REPO_ROOT}/build/artifacts.conf"

echo "artifacts (${ARTIFACT_DIR})"

iso="${ARTIFACT_DIR}/${SYSRESCUE_ISO}"
img="${ARTIFACT_DIR}/${HAOS_IMG}"
sidecar="${ARTIFACT_DIR}/${HAOS_SHA_SIDECAR}"
sizefile="${ARTIFACT_DIR}/${HAOS_SIZE_FILE}"

check "manifest defines a SystemRescue label" test -n "${SYSRESCUE_LABEL}"
check "label matches the version (${SYSRESCUE_LABEL})" test "${SYSRESCUE_LABEL}" = "RESCUE1302"

check "SystemRescue ISO present" test -s "${iso}"
check "HAOS image present" test -s "${img}"
check "HAOS checksum sidecar present" test -s "${sidecar}"
check "HAOS uncompressed size recorded" test -s "${sizefile}"

# ISO integrity against the checksum upstream publishes alongside it.
iso_sha="${ARTIFACT_DIR}/${SYSRESCUE_ISO}.sha256"
if [ -s "${iso}" ] && [ -s "${iso_sha}" ]; then
  expected="$(awk '{print $1}' "${iso_sha}")"
  actual="$(sha256sum "${iso}" | awk '{print $1}')"
  check "SystemRescue ISO matches upstream sha256" test "${expected}" = "${actual}"
else
  fail_with "SystemRescue ISO matches upstream sha256" "ISO or its upstream .sha256 is missing"
fi

# HAOS integrity against our own sidecar. Upstream publishes no digest, so this
# proves the file has not rotted since we fetched it — not that it is authentic.
if [ -s "${img}" ] && [ -s "${sidecar}" ]; then
  expected="$(awk '{print $1}' "${sidecar}")"
  actual="$(sha256sum "${img}" | awk '{print $1}')"
  check "HAOS image matches its sidecar" test "${expected}" = "${actual}"
else
  fail_with "HAOS image matches its sidecar" "image or sidecar is missing"
fi

# The recorded length must be a plausible uncompressed disk image: larger than
# the 552 MB compressed form. Measured at 1.83 GiB for 18.2 — under FAT32's
# 4 GiB per-file ceiling, contrary to the original assumption. Task 7 needs
# this number to bound its comparison, which is the real reason we record it.
if [ -s "${sizefile}" ]; then
  bytes="$(cat "${sizefile}")"
  check "recorded size is a number" test "${bytes}" -gt 0 2>/dev/null
  check "recorded size exceeds the compressed image" test "${bytes}" -gt 600000000
else
  fail_with "recorded size is usable" "size file is missing"
fi

finish
