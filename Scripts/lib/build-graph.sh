#!/bin/sh
# Build-graph identity for the gates' SwiftPM caches. SwiftPM can keep stale
# absolute dependency paths after a file moves between targets or packages,
# so a gate cleans a package's scratch directory whenever this identity
# changes: the package's manifest, pins and Sources/Tests file list, plus the
# manifest, pins and Sources file list of every package it reaches through
# `.package(path:)`. A file added to one package cleans only that package and
# the packages that depend on it.

# lyte_sha256: the hex SHA-256 of stdin.
lyte_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        shasum -a 256 | awk '{print $1}'
    fi
}

# lyte_path_dependencies ROOT PACKAGE: every package PACKAGE reaches through
# `.package(path: "../X")`, one per line, sorted.
lyte_path_dependencies() {
    local root="$1" next="$2" found="" queue package dependency
    while [ -n "$next" ]; do
        queue="$next"
        next=""
        for package in $queue; do
            for dependency in $(sed -n \
                's|.*\.package(path: *"\.\./\([^"/]*\)").*|\1|p' \
                "$root/$package/Package.swift")
            do
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
    local root="$1" package="$2" file tree
    shift 2
    for file in Package.swift Package.resolved; do
        if [ -f "$root/$package/$file" ]; then
            printf '%s %s\n' "$package/$file" \
                "$(lyte_sha256 < "$root/$package/$file")"
        fi
    done
    for tree in "$@"; do
        if [ -d "$root/$package/$tree" ]; then
            (cd "$root" && find "$package/$tree" -type f -print)
        fi
    done | LC_ALL=C sort
}

# lyte_build_graph_hash ROOT PACKAGE
lyte_build_graph_hash() {
    local root="$1" package="$2" dependency
    {
        lyte_package_identity "$root" "$package" Sources Tests
        for dependency in $(lyte_path_dependencies "$root" "$package"); do
            lyte_package_identity "$root" "$dependency" Sources
        done
    } | lyte_sha256
}
