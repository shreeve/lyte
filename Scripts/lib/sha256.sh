#!/bin/sh
# lyte_sha256 [FILE]: the hex SHA-256 of FILE, or of stdin.
lyte_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@" | awk '{print $1}'
    else
        shasum -a 256 "$@" | awk '{print $1}'
    fi
}
