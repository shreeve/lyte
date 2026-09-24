#!/bin/bash
# The pup gate's mirror lock. Scripts/CI/test-all-pup.sh sends this file to
# pup ahead of its remote script, before the mirror (and Scripts/) is synced.
#
# The lock file names its holder, so acquiring it truncates the file. A path
# that is a symlink (dangling or not) or anything but a regular file is
# refused before any open, and an absent one is created O_EXCL, so a planted
# link can never aim that truncation at another file.

# lyte_acquire_gate_lock LOCK OWNER: opens LOCK on fd 9, takes a
# non-blocking flock on it and writes OWNER into it. On failure it returns 1
# with fd 9 closed, LOCK's contents untouched and the reason in
# lyte_gate_lock_error.
lyte_acquire_gate_lock() {
    local lock="$1" owner="$2"
    lyte_gate_lock_error=""
    if [[ ! -e "$lock" && ! -L "$lock" ]]; then
        # noclobber opens an absent file O_CREAT|O_EXCL. Losing that race to
        # another gate leaves a regular file, which the check below accepts.
        (set -C; : > "$lock") 2>/dev/null || true
    fi
    if [[ -L "$lock" || ! -f "$lock" ]]; then
        lyte_gate_lock_error="the gate lock is not a regular file: $lock"
        return 1
    fi
    if ! exec 9>>"$lock"; then
        lyte_gate_lock_error="cannot open the gate lock: $lock"
        return 1
    fi
    if ! flock -n 9; then
        exec 9>&-
        lyte_gate_lock_error="another deterministic gate holds the pup mirror: $(head -n 1 -- "$lock")"
        return 1
    fi
    # The path must still name the file fd 9 holds when the owner is written.
    # Inodes only: macOS reports its fd filesystem's device for /dev/fd/9.
    local held named
    held="$(ls -Ldi /dev/fd/9 | awk '{print $1}')" || held=""
    named="$(ls -di -- "$lock" | awk '{print $1}')" || named=""
    if [[ -L "$lock" || -z "$held" || "$held" != "$named" ]]; then
        exec 9>&-
        lyte_gate_lock_error="the gate lock was replaced while it was taken: $lock"
        return 1
    fi
    printf '%s\n' "$owner" > "$lock"
}
