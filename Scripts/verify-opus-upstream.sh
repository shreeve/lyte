#!/bin/bash
# Independently prove that every committed Opus byte came from the pinned
# official archive. Builds stay offline; maintainers run this only when
# importing or auditing the vendored leaf.
set -euo pipefail

if (( $# != 1 )); then
    echo "usage: Scripts/verify-opus-upstream.sh /path/to/opus-1.6.1.tar.gz" >&2
    exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive="$1"
expected_archive_sha=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
committed_root="$repo_root/Common/Sources/COpus"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

if command -v shasum >/dev/null 2>&1; then
    actual_archive_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
else
    actual_archive_sha="$(sha256sum "$archive" | awk '{print $1}')"
fi
[[ "$actual_archive_sha" == "$expected_archive_sha" ]] || {
    echo "Opus verification FAILED: archive SHA-256 mismatch" >&2
    exit 1
}

tar -xzf "$archive" -C "$work"
upstream_root="$work/opus-1.6.1"
[[ -d "$upstream_root" ]] || {
    echo "Opus verification FAILED: archive root is not opus-1.6.1" >&2
    exit 1
}

upstream_count=0
while IFS= read -r committed; do
    relative="${committed#"$committed_root/Upstream/opus-1.6.1/"}"
    cmp -- "$committed" "$upstream_root/$relative" || {
        echo "Opus verification FAILED: changed upstream file: $relative" >&2
        exit 1
    }
    upstream_count=$((upstream_count + 1))
done < <(find "$committed_root/Upstream/opus-1.6.1" -type f -print | LC_ALL=C sort)
[[ "$upstream_count" -eq 234 ]] || {
    echo "Opus verification FAILED: expected 234 upstream files, found $upstream_count" >&2
    exit 1
}

header_count=0
while IFS= read -r committed; do
    header="${committed##*/}"
    cmp -- "$committed" "$upstream_root/include/$header" || {
        echo "Opus verification FAILED: changed public header: $header" >&2
        exit 1
    }
    header_count=$((header_count + 1))
done < <(find "$committed_root/include/opus" -type f -print | LC_ALL=C sort)
[[ "$header_count" -eq 6 ]] || {
    echo "Opus verification FAILED: expected 6 public headers, found $header_count" >&2
    exit 1
}

echo "Opus upstream verification PASSED: 240 files match the pinned archive"
