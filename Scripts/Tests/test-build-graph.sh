#!/bin/bash
# The gates' per-package build-graph identity: a package's hash moves when
# its own manifest or file list moves, or when a package it depends on (by
# path, transitively) changes its manifest or Sources, and for nothing else.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/Scripts/lib/assert.sh"
source "$repo_root/Scripts/lib/build-graph.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

# Leaf <- Middle <- Top, and Other beside them.
package() {
    local name="$1" dependency
    shift
    mkdir -p "$fixture/$name/Sources/$name" "$fixture/$name/Tests/${name}Tests"
    {
        echo '// swift-tools-version:6.0'
        echo 'let package = Package(dependencies: ['
        for dependency in "$@"; do
            echo "    .package(path: \"../$dependency\"),"
        done
        echo '])'
    } > "$fixture/$name/Package.swift"
    : > "$fixture/$name/Sources/$name/$name.swift"
}
package Leaf
package Middle Leaf
package Top Middle
package Other

dependencies="$(lyte_path_dependencies "$fixture" Top | tr '\n' ' ')"
[[ "$dependencies" == "Leaf Middle " ]] \
    || fail "Top reaches '$dependencies'; want Leaf and Middle"
[[ -z "$(lyte_path_dependencies "$fixture" Leaf)" ]] \
    || fail "Leaf has no dependencies"

snapshot() {
    local name
    for name in Leaf Middle Top Other; do
        printf '%s=%s ' "$name" "$(lyte_build_graph_hash "$fixture" "$name")"
    done
}
# expect_moved WHAT PACKAGE...: after WHAT, exactly PACKAGE... changed hash.
expect_moved() {
    local what="$1" name after moved="" want=""
    shift
    for name in "$@"; do
        want="$want $name"
    done
    after="$(snapshot)"
    for name in Leaf Middle Top Other; do
        if [[ " $before " != *" $(grep -o "$name=[0-9a-f]*" <<< "$after") "* ]]
        then
            moved="$moved $name"
        fi
    done
    [[ "$moved" == "$want" ]] \
        || fail "$what moved:${moved:- nothing}; want${want:- nothing}"
    before="$after"
}

before="$(snapshot)"
[[ "$(snapshot)" == "$before" ]] || fail "the hash is not deterministic"
touch "$fixture/Top/Tests/TopTests/New.swift"
expect_moved "a Top test file" Top
touch "$fixture/Leaf/Tests/LeafTests/New.swift"
expect_moved "a Leaf test file" Leaf
touch "$fixture/Leaf/Sources/Leaf/New.swift"
expect_moved "a Leaf source file" Leaf Middle Top
printf '{}\n' > "$fixture/Middle/Package.resolved"
expect_moved "Middle's pins" Middle Top
echo '// edit' >> "$fixture/Other/Package.swift"
expect_moved "Other's manifest" Other
echo 'let x = 1' >> "$fixture/Leaf/Sources/Leaf/Leaf.swift"
expect_moved "a Leaf source edit"

echo "build graph tests PASSED"
