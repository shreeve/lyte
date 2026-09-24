#!/bin/bash
# The macOS gate's frozen-vector contract (Scripts/lib/frozen-vectors.sh), in
# a scratch repository: modified, deleted and renamed vectors are reported,
# README prose and new vectors are not, and a base that is not a commit is an
# error rather than an empty diff.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/Scripts/lib/assert.sh"
source "$repo_root/Scripts/lib/frozen-vectors.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
git_() {
    git -c user.name=gate -c user.email=gate@example.invalid \
        -c commit.gpgsign=false "$@"
}
cd "$fixture"
git_ init -q
mkdir -p Wire/Vectors/nested
printf 'one\n' > Wire/Vectors/a.vec
printf 'two\n' > Wire/Vectors/nested/b.vec
printf 'prose\n' > Wire/Vectors/nested/README.md
git_ add Wire
git_ commit -q -m base
base="$(git rev-parse HEAD)"

# expect_changed WHAT WANT: the working tree's changed vectors are WANT.
expect_changed() {
    local what="$1" want="$2" changed
    changed="$(lyte_changed_vectors "$base")" \
        || fail "$what: the diff against a valid base failed"
    [[ "$changed" == "$want" ]] \
        || fail "$what: reported '$changed'; want '$want'"
}

expect_changed "a clean tree" ""

for bad in no-such-ref 0123456789abcdef0123456789abcdef01234567 \
    "$(git rev-parse HEAD^{tree})" ""
do
    if lyte_changed_vectors "$bad" > "$fixture/out"; then
        fail "base '$bad' was accepted"
    fi
    [[ ! -s "$fixture/out" ]] || fail "base '$bad' printed $(cat "$fixture/out")"
done

printf 'more prose\n' >> Wire/Vectors/nested/README.md
printf 'three\n' > Wire/Vectors/c.vec
git_ add Wire/Vectors/c.vec
expect_changed "README prose and a new vector" ""

printf 'edited\n' > Wire/Vectors/a.vec
expect_changed "a modified vector" "Wire/Vectors/a.vec"
git checkout -q -- Wire/Vectors/a.vec

rm Wire/Vectors/nested/b.vec
expect_changed "a deleted vector" "Wire/Vectors/nested/b.vec"
git checkout -q -- Wire/Vectors/nested/b.vec

git_ mv -f Wire/Vectors/a.vec Wire/Vectors/nested/README.md
expect_changed "a vector renamed onto a README" "Wire/Vectors/a.vec"

echo "frozen-vector tests PASSED"
