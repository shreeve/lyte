#!/bin/bash
# Owner-facing host recipes must never drift back to SwiftPM's unoptimized
# debug artifact. Debug remains correct for tests and development harnesses.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

files=(
    AGENTS.md
    docs/OPERATIONS.md
    docs/TESTING.md
    Host/INSTALL.md
    Host/README.md
    Host/Scripts/deploy-host.sh
    Host/Scripts/install-host.sh
    Host/Scripts/setup-host.sh
    Host/Scripts/verify-host-image.sh
    Host/Systemd/host.conf
    Host/Systemd/lyte-host.service
    Scripts/benchmark-app.sh
)

if grep -nE '\.build/debug/lyte-host' "${files[@]}"; then
    echo "host release posture FAILED: owner-facing debug host path returned" >&2
    exit 1
fi

for file in "${files[@]}"; do
    [[ -f "$file" ]] || {
        echo "host release posture FAILED: missing operational file: $file" >&2
        exit 1
    }
done

# The unit runs the deployed version link from the seat user's home and logs
# into its XDG state directory; no checkout, /etc/lyte or /tmp path survives.
grep -Fq 'exec @HOME@/.local/bin/lyte-host $$LYTE_HOST_ARGS' Host/Systemd/lyte-host.service
grep -Fq 'EnvironmentFile=@CONFIG_HOME@/lyte/host.conf' Host/Systemd/lyte-host.service
grep -Fq 'log=@STATE_HOME@/lyte/host.log' Host/Systemd/lyte-host.service
if grep -rnE 'LYTE_HOST_BIN|\.build/(debug|release)/lyte-host|/home/CHANGE_ME' \
    Host/Systemd Host/Scripts/install-host.sh
then
    echo "host release posture FAILED: installed service regained a checkout path" >&2
    exit 1
fi
if grep -vhE '^#' Host/Systemd/* | grep -nE '/etc/lyte|/tmp/|/usr/local/bin'; then
    echo "host release posture FAILED: the service regained a pre-XDG path" >&2
    exit 1
fi
if grep -rn 'portal_token' Host/Sources Host/Scripts Host/Systemd \
    Scripts/CI/test-all-pup.sh Scripts/benchmark-app.sh
then
    echo "host release posture FAILED: the retired portal token returned" >&2
    exit 1
fi
grep -Fq 'swift build --package-path Host -c release' Host/INSTALL.md
# The pup build recipe lives in the operations runbook (AGENTS.md links it).
grep -Fq 'swift build -c release' docs/OPERATIONS.md

echo "host release posture tests PASSED"
