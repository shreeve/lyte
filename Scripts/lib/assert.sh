#!/bin/sh
# Assertions for the script tests. macOS /bin/bash 3.2 does not exit under
# `set -e` when a bare `[[ … ]]` or `(( … ))` statement fails, and no bash
# exits on a failing `! cmd`, so every check is spelled `[[ … ]] || fail "…"`
# or `refute cmd …`. Scripts/Tests/test-shell-assertions.sh rejects the bare
# forms.

fail() {
    printf '%s FAILED: %s\n' "${0##*/}" "$*" >&2
    exit 1
}

# refute CMD [ARG...]: fails when CMD succeeds.
refute() {
    if "$@"; then
        fail "unexpectedly succeeded: $*"
    fi
}
