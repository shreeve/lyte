#!/bin/sh
# Build-graph identity for the gates' SwiftPM caches. SwiftPM can keep stale
# absolute dependency paths after a file moves between targets or packages,
# so a gate cleans a package's scratch directory whenever this identity
# changes: the package's manifest, pins and Sources/Tests file list, plus the
# manifest, pins and Sources file list of every package it reaches through
# `.package(path:)`. A file added to one package cleans only that package and
# the packages that depend on it.
#
# Every helper returns 1 when a package it needs has no manifest. Callers
# run them inside command substitution, where no bash applies `set -e`, so
# each failure is an explicit return.

# lyte_sha256: the hex SHA-256 of stdin.
lyte_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        shasum -a 256 | awk '{print $1}'
    fi
}

# lyte_manifest_path_dependencies MANIFEST: the X of every
# `.package(… path: "../X" …)` in MANIFEST, whatever its other arguments and
# however it is split across lines. Whole-line `//` comments are ignored.
lyte_manifest_path_dependencies() {
    [ -f "$1" ] || return 1
    awk '
        { sub(/^[[:space:]]*\/\/.*/, ""); text = text " " $0 }
        END {
            while (match(text, /\.package[[:space:]]*\([^)]*\)/)) {
                call = substr(text, RSTART, RLENGTH)
                text = substr(text, RSTART + RLENGTH)
                if (match(call, /path:[[:space:]]*"\.\.\/[^"\/]*"/)) {
                    dependency = substr(call, RSTART, RLENGTH)
                    sub(/^path:[[:space:]]*"\.\.\//, "", dependency)
                    sub(/"$/, "", dependency)
                    print dependency
                }
            }
        }
    ' "$1"
}

# lyte_path_dependencies ROOT PACKAGE: every package PACKAGE reaches through
# `.package(path: "../X")`, one per line, sorted.
lyte_path_dependencies() {
    local root="$1" next="$2" found="" queue package dependency dependencies
    while [ -n "$next" ]; do
        queue="$next"
        next=""
        for package in $queue; do
            dependencies="$(lyte_manifest_path_dependencies \
                "$root/$package/Package.swift")" || return 1
            for dependency in $dependencies; do
                case " $found " in
                    *" $dependency "*) ;;
                    *)
                        found="$found $dependency"
                        next="$next $dependency"
                        ;;
                esac
            done
        done
    done
    for package in $found; do
        printf '%s\n' "$package"
    done | LC_ALL=C sort
}

# lyte_package_identity ROOT PACKAGE TREE...: PACKAGE's manifest and pin
# digests and the paths of every file under its TREEs.
lyte_package_identity() {
    local root="$1" package="$2" file tree digest files
    shift 2
    [ -f "$root/$package/Package.swift" ] || return 1
    for file in Package.swift Package.resolved; do
        if [ -f "$root/$package/$file" ]; then
            digest="$(lyte_sha256 < "$root/$package/$file")" || return 1
            printf '%s %s\n' "$package/$file" "$digest"
        fi
    done
    files="$(for tree in "$@"; do
        if [ -d "$root/$package/$tree" ]; then
            (cd "$root" && find "$package/$tree" -type f -print) || exit 1
        fi
    done)" || return 1
    if [ -n "$files" ]; then
        printf '%s\n' "$files" | LC_ALL=C sort
    fi
}

# lyte_build_graph_hash ROOT PACKAGE
lyte_build_graph_hash() {
    local root="$1" package="$2" dependencies dependency identity more
    dependencies="$(lyte_path_dependencies "$root" "$package")" || return 1
    identity="$(lyte_package_identity "$root" "$package" Sources Tests)" \
        || return 1
    for dependency in $dependencies; do
        more="$(lyte_package_identity "$root" "$dependency" Sources)" \
            || return 1
        identity="$identity
$more"
    done
    printf '%s\n' "$identity" | lyte_sha256
}
