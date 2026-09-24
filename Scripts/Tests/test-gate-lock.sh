#!/bin/bash
# The pup gate's mirror lock (Scripts/lib/gate-lock.sh): it takes an absent
# or regular lock file and records its owner there, refuses a symlink or any
# other file type without writing through it, and leaves a held lock's
# contents alone. flock is faked, so this runs on macOS too.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/Scripts/lib/assert.sh"
source "$repo_root/Scripts/lib/gate-lock.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

mkdir "$fixture/bin" "$fixture/ns"
cat > "$fixture/bin/flock" <<'EOF'
#!/bin/sh
exit "${FAKE_FLOCK_STATUS:-0}"
EOF
chmod +x "$fixture/bin/flock"
PATH="$fixture/bin:$PATH"
lock="$fixture/ns/.deterministic.flock"
victim="$fixture/paired_clients"
printf 'client-a\nclient-b\n' > "$victim"
victim_before="$(cat "$victim")"

fd9_open() { { : >&9; } 2>/dev/null; }

# expect_refused WHAT PATTERN: acquiring $lock fails with an error matching
# PATTERN, fd 9 stays closed and the victim is unchanged.
expect_refused() {
    local what="$1" pattern="$2"
    (
        if lyte_acquire_gate_lock "$lock" "gate B"; then
            fail "$what: the lock was taken"
        fi
        [[ "$lyte_gate_lock_error" == $pattern ]] \
            || fail "$what: error was '$lyte_gate_lock_error'"
        refute fd9_open
    ) || exit 1
    [[ "$(cat "$victim")" == "$victim_before" ]] \
        || fail "$what: the lock wrote through to $victim"
}

# An absent lock is created and names its owner; fd 9 holds it.
(
    lyte_acquire_gate_lock "$lock" "gate A, since now" \
        || fail "absent lock: $lyte_gate_lock_error"
    fd9_open || fail "absent lock: fd 9 is not open"
    [[ "$(cat "$lock")" == "gate A, since now" ]] \
        || fail "absent lock does not name its owner"
) || exit 1
[[ -f "$lock" && ! -L "$lock" ]] || fail "the lock is not a regular file"

# A regular lock left by an earlier gate is reused and its owner replaced.
printf 'an old gate with a much longer owner line\n' > "$lock"
(
    lyte_acquire_gate_lock "$lock" "gate C" \
        || fail "regular lock: $lyte_gate_lock_error"
    [[ "$(cat "$lock")" == "gate C" ]] \
        || fail "regular lock owner is '$(cat "$lock")'"
) || exit 1

# A held lock is refused and still names its holder.
printf 'gate A, since then\n' > "$lock"
FAKE_FLOCK_STATUS=1 expect_refused "held lock" \
    "another deterministic gate holds the pup mirror: gate A, since then"
[[ "$(cat "$lock")" == "gate A, since then" ]] \
    || fail "a refused gate rewrote the holder"

# A planted symlink to protected state is refused, not truncated.
rm -f "$lock"
ln -s "$victim" "$lock"
expect_refused "symlink to a file" "the gate lock is not a regular file: *"

# A dangling symlink is refused and its target never created.
rm -f "$lock"
ln -s "$fixture/created-through-link" "$lock"
expect_refused "dangling symlink" "the gate lock is not a regular file: *"
[[ ! -e "$fixture/created-through-link" ]] \
    || fail "a dangling lock link created its target"

# A symlink to a directory, a directory and a FIFO are refused too.
rm -f "$lock"
ln -s "$fixture/ns" "$lock"
expect_refused "symlink to a directory" "the gate lock is not a regular file: *"
rm -f "$lock"
mkdir "$lock"
expect_refused "directory" "the gate lock is not a regular file: *"
rmdir "$lock"
mkfifo "$lock"
expect_refused "FIFO" "the gate lock is not a regular file: *"

echo "gate lock tests PASSED"
