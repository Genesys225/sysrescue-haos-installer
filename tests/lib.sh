# Minimal assertion helpers. No framework — this project is bash, and a bash
# test runner keeps the toolchain at zero.
#
# Usage in a test file:
#   . "$(dirname "$0")/lib.sh"
#   check "description" test -f /some/path
#   finish

TESTS_RUN=0
TESTS_FAILED=0

_green() { printf '\033[32m%s\033[0m' "$1"; }
_red()   { printf '\033[31m%s\033[0m' "$1"; }

# check <description> <command...> — passes if the command exits 0
check() {
  local desc="$1"; shift
  TESTS_RUN=$((TESTS_RUN + 1))
  if "$@" >/dev/null 2>&1; then
    printf '  %s %s\n' "$(_green PASS)" "$desc"
  else
    printf '  %s %s\n' "$(_red FAIL)" "$desc"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# fail_with <description> <reason> — record a failure that has an explanation
fail_with() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  %s %s\n       %s\n' "$(_red FAIL)" "$1" "$2"
}

finish() {
  printf '\n  %d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}

# Repo root, regardless of where the test was invoked from
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${REPO_ROOT}/tmp"
