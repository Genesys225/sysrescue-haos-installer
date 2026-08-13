#!/usr/bin/env bash
# Arrow-key selection.
#
# Key reading is isolated in read_key() so the list logic can be driven
# without a pseudo-terminal: the suite replaces it with a scripted sequence.
# On a real console read_key parses the escape sequences; here it just reads
# tokens, which keeps these tests fast and free of pty plumbing.

. "$(dirname "$0")/lib.sh"

AUTORUN="${REPO_ROOT}/src/autorun"
FIX="${REPO_ROOT}/tests/fixtures"

echo "arrow-key menu"

# pick <keys...> — drives select_from_list over three devices.
#
# The stub reads one token per line from stdin rather than keeping an index in
# a variable. select_from_list calls read_key through command substitution,
# which runs in a subshell — any variable it updated there would be discarded,
# and the same key would be returned forever. Consuming a shared stdin file
# descriptor is both immune to that and closer to how the real one behaves.
pick() {
  printf '%s\n' "$@" | bash -c '
    . "$1" --source-only
    read_key() {
      local k
      IFS= read -r k || { printf "eof\n"; return 0; }
      printf "%s\n" "${k}"
    }
    FIXTURE="'"${FIX}"'/lsblk-workstation.txt"
    block_devices() { cat "${FIXTURE}"; }
    select_from_list /dev/sda /dev/nvme1n1 /dev/nvme2n1
    printf "CHOSE=%s\n" "${SELECTED:-none}"
  ' _ "${AUTORUN}" 2>&1
}

# --- moving and selecting -------------------------------------------------
out="$(pick enter)"
check "enter picks the first device" grep -q 'CHOSE=/dev/sda' <<< "${out}"

out="$(pick down enter)"
check "down then enter picks the second" grep -q 'CHOSE=/dev/nvme1n1' <<< "${out}"

out="$(pick down down enter)"
check "two downs picks the third" grep -q 'CHOSE=/dev/nvme2n1' <<< "${out}"

out="$(pick down down up enter)"
check "up moves back" grep -q 'CHOSE=/dev/nvme1n1' <<< "${out}"

# --- edges ----------------------------------------------------------------
out="$(pick up enter)"
check "up at the top stays at the top" grep -q 'CHOSE=/dev/sda' <<< "${out}"

out="$(pick down down down down enter)"
check "down past the end stays at the end" grep -q 'CHOSE=/dev/nvme2n1' <<< "${out}"

# --- number keys still work -----------------------------------------------
# Typing a number should still land on that entry — muscle memory from the
# previous version, and faster than arrowing through a long list.
out="$(pick digit:2 enter)"
check "a number key jumps to that entry" grep -q 'CHOSE=/dev/nvme1n1' <<< "${out}"

out="$(pick digit:3 enter)"
check "number keys reach the last entry" grep -q 'CHOSE=/dev/nvme2n1' <<< "${out}"

out="$(pick digit:9 enter)"
check "an out-of-range number is ignored" grep -q 'CHOSE=/dev/sda' <<< "${out}"

# --- abandonment ----------------------------------------------------------
# A closed input must not be read as agreement to erase whatever is highlighted.
out="$(pick)"
check "end of input selects nothing" grep -q 'CHOSE=none' <<< "${out}"

# --- the list is drawn ----------------------------------------------------
out="$(pick enter)"
check "shows every candidate" bash -c 'grep -q "/dev/sda" <<< "$1" && grep -q "/dev/nvme2n1" <<< "$1"' _ "${out}"
check "marks the highlighted row" grep -qE '[>*▸]|\[x\]' <<< "${out}"
check "explains how to move" grep -qi 'arrow\|↑\|move' <<< "${out}"

# --- aborting from the list -----------------------------------------------
# Esc must work at this step too, not only at the confirmation. It was shown
# at the second prompt and silently ignored here.
out="$(pick escape)"
check "escape abandons the list" grep -q 'CHOSE=none' <<< "${out}"

out="$(pick down escape)"
check "escape abandons after moving" grep -q 'CHOSE=none' <<< "${out}"

check "the hint names the abort key" grep -qi 'esc to abort' <<< "$(pick enter)"

# --- read_key exists and is replaceable -----------------------------------
check "key reading is isolated in read_key" grep -q '^read_key()' "${AUTORUN}"
check "selection is isolated in select_from_list" grep -q '^select_from_list()' "${AUTORUN}"

if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck: autorun" shellcheck -x --source-path="${REPO_ROOT}" -S style "${AUTORUN}"
fi

finish
