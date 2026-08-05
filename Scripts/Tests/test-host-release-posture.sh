#!/bin/bash
# Owner-facing host recipes must never drift back to SwiftPM's unoptimized
# debug artifact. Debug remains correct for tests and development harnesses.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

files=(
    AGENTS.md
    Host/INSTALL.md
    Host/README.md
    Host/Scripts/install-host.sh
    Host/Scripts/setup-host.sh
    Host/Systemd/lyte-host.conf
    Scripts/benchmark-app.sh
)

if rg -n '\.build/debug/lyte-host' "${files[@]}"; then
    echo "host release posture FAILED: owner-facing debug host path returned" >&2
    exit 1
fi

for file in "${files[@]}"; do
    [[ -f "$file" ]] || {
        echo "host release posture FAILED: missing operational file: $file" >&2
        exit 1
    }
done

grep -Fq '.build/release/lyte-host' Host/Systemd/lyte-host.conf
grep -Fq 'swift build -c release' Host/INSTALL.md
grep -Fq 'swift build -c release' AGENTS.md

echo "host release posture tests PASSED"
