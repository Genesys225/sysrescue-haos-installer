#!/usr/bin/env bash
# Fetch and measure the artifacts named in build/artifacts.conf.
#
# Idempotent and resumable: existing complete files are left alone, partial
# downloads are continued. Safe to re-run.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${REPO_ROOT}/build/artifacts.conf"

ARTIFACT_DIR="${REPO_ROOT}/tmp"
mkdir -p "${ARTIFACT_DIR}"

note() { printf '[*] %s\n' "$*"; }
die()  { printf '\n[FATAL] %s\n' "$*" >&2; exit 1; }

# fetch <url> <destination> — resumable, fails loudly on HTTP errors
fetch() {
  local url="$1" dest="$2"
  if [ -s "${dest}" ]; then
    note "already present: $(basename "${dest}")"
    return 0
  fi
  note "fetching $(basename "${dest}")"
  curl -fL --retry 3 --retry-delay 2 -C - -o "${dest}" "${url}" ||
    die "download failed: ${url}"
}

# --- SystemRescue ---------------------------------------------------------
fetch "${SYSRESCUE_SHA_URL}" "${ARTIFACT_DIR}/${SYSRESCUE_ISO}.sha256"
fetch "${SYSRESCUE_URL}"     "${ARTIFACT_DIR}/${SYSRESCUE_ISO}"

# --- Home Assistant OS ----------------------------------------------------
fetch "${HAOS_URL}" "${ARTIFACT_DIR}/${HAOS_IMG}"

# Upstream ships no digest for the HAOS images, so generate our own. This
# catches corruption and stick rot on every later run; it does not authenticate
# the download, and nothing here should pretend otherwise.
if [ ! -s "${ARTIFACT_DIR}/${HAOS_SHA_SIDECAR}" ]; then
  note "generating sidecar checksum (upstream publishes none)"
  ( cd "${ARTIFACT_DIR}" && sha256sum "${HAOS_IMG}" > "${HAOS_SHA_SIDECAR}" )
fi

# Record the uncompressed length. Task 7 bounds its byte-comparison with this
# so verification stops at the image boundary instead of running on into the
# larger target disk.
if [ ! -s "${ARTIFACT_DIR}/${HAOS_SIZE_FILE}" ]; then
  note "measuring uncompressed length"
  bytes="$(xz --robot --list "${ARTIFACT_DIR}/${HAOS_IMG}" | awk '$1 == "file" { print $5 }')"
  [ -n "${bytes}" ] && [ "${bytes}" -gt 0 ] 2>/dev/null ||
    die "could not read uncompressed size from xz --robot --list"
  printf '%s' "${bytes}" > "${ARTIFACT_DIR}/${HAOS_SIZE_FILE}"
fi

note "done"
printf '\n'
ls -lh "${ARTIFACT_DIR}/${SYSRESCUE_ISO}" "${ARTIFACT_DIR}/${HAOS_IMG}"
printf '\nuncompressed HAOS image: %s bytes (%s GiB)\n' \
  "$(cat "${ARTIFACT_DIR}/${HAOS_SIZE_FILE}")" \
  "$(awk -v b="$(cat "${ARTIFACT_DIR}/${HAOS_SIZE_FILE}")" 'BEGIN { printf "%.2f", b/1073741824 }')"
