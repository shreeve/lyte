#!/bin/sh
# The frozen-vector contract the macOS gate enforces. Vectors are
# append-only: a committed file under Wire/Vectors/ may never be modified,
# deleted, renamed, or retyped. New vector files and README.md prose at any
# depth are fine. Without rename detection a rename is a deletion, so a
# vector moved onto a README path still fails.

# lyte_changed_vectors BASE: prints each committed vector the working tree
# changed relative to BASE, one per line. Returns 1, printing nothing, when
# BASE is not a commit or git cannot diff against it, so a bad base never
# reads as "nothing changed".
lyte_changed_vectors() {
    local base_commit diff
    base_commit="$(git rev-parse --verify --quiet "$1^{commit}" 2>/dev/null)" \
        || return 1
    [ -n "$base_commit" ] || return 1
    diff="$(git diff --no-renames --name-only --diff-filter=MDT \
        "$base_commit" -- Wire/Vectors/)" || return 1
    printf '%s\n' "$diff" | grep -Ev '^(Wire/Vectors/(.*/)?README\.md)?$'
    return 0
}
