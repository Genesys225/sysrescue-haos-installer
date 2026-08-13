#!/usr/bin/env bash
# Runs every tests/test-*.sh and aggregates. No framework, no dependencies.
set -uo pipefail

cd "$(dirname "$0")" || exit 1

failed=0
for t in test-*.sh; do
  [ -e "$t" ] || continue
  printf '\n=== %s ===\n' "$t"
  bash "$t" || failed=$((failed + 1))
done

printf '\n'
if [ "$failed" -eq 0 ]; then
  printf 'ALL SUITES PASSED\n'
else
  printf '%d SUITE(S) FAILED\n' "$failed"
fi
exit "$failed"
