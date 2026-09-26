#!/bin/sh

# Source identity for build provenance. make-app.sh records the client
# fingerprint inside Lyte.app; benchmark-app.sh refuses an app whose recorded
# fingerprint differs from the checkout, so "edit B, benchmark A" cannot pass.

# Every tracked or untracked-unignored file a Lyte.app build compiles.
LYTE_CLIENT_SOURCE_PATHS="Client/Package.swift Client/Package.resolved Client/Sources Common/Package.swift Common/Sources Wire/Package.swift Wire/Package.resolved Wire/Sources"
# Every file a lyte-host build compiles.
LYTE_HOST_SOURCE_PATHS="Host/Package.swift Host/Package.resolved Host/Sources Common/Package.swift Common/Sources Wire/Package.swift Wire/Package.resolved Wire/Sources"

# The files under <paths...> that git knows of (tracked, or untracked and not
# ignored), relative to <root>, sorted.
lyte_source_files() {
    (
        cd "$1"
        shift
        git ls-files --cached --others --exclude-standard -- "$@" | LC_ALL=C sort
    )
}

# lyte_source_fingerprint <root> <paths...>: SHA-256 over the per-file hashes.
lyte_source_fingerprint() {
    root=$1
    shift
    lyte_source_files "$root" "$@" | (
        cd "$root"
        while IFS= read -r path; do
            if [ -f "$path" ]; then
                shasum -a 256 "$path"
            fi
        done
    ) | shasum -a 256 | awk '{print $1}'
}
