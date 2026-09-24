#!/usr/bin/env bash
# Deploy lyte-host binaries as an immutable version and point the service's
# executable at it. Run as the seat user (never root):
#
#   deploy-host.sh [--restart] [--keep N] [RELEASE_DIR]
#       copy RELEASE_DIR/lyte-host (+ lyte-audio-check when present) into
#       versions/<sha256-prefix-12>/, then atomically flip ~/.local/bin/lyte-host
#       to it. RELEASE_DIR defaults to Host/.build/release. Redeploying the
#       active binary is a no-op flip; the newest N versions (default 5) plus
#       the active and previous ones are kept.
#   deploy-host.sh --rollback [--restart]
#       flip back to the previously active version (a second rollback undoes
#       the first).
#   deploy-host.sh --status
#       print the active and previous versions and verify the active binary.
#
# --restart runs `sudo -n systemctl restart lyte-host` after the flip; without
# it the running service keeps its open executable until the next restart.
#
# Layout (XDG_DATA_HOME is honored when it is an absolute path):
#   ${XDG_DATA_HOME:-~/.local/share}/lyte/versions/<id>/lyte-host
#   ${XDG_DATA_HOME:-~/.local/share}/lyte/previous      id of the prior version
#   ~/.local/bin/lyte-host -> .../versions/<id>/lyte-host
#
# LYTE_SYSTEMCTL is a test seam: when set, --restart runs it (without sudo)
# instead of systemctl.
set -euo pipefail

usage() {
    sed -n '4,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 64
}

fail() {
    echo "host deploy FAILED: $*" >&2
    exit 1
}

host_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
mode=deploy
restart=0
keep=5
release_dir=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --restart) restart=1 ;;
        --rollback|--status)
            [[ "$mode" == deploy ]] || usage
            mode="${1#--}"
            ;;
        --keep)
            [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || usage
            keep="$2"
            shift
            ;;
        -h|--help) usage ;;
        -*) usage ;;
        *)
            [[ -z "$release_dir" ]] || usage
            release_dir="$1"
            ;;
    esac
    shift
done
[[ "$mode" == deploy || -z "$release_dir" ]] || usage
[[ "$mode" != status || "$restart" == 0 ]] || usage

[[ "$(id -u)" != 0 ]] || fail "run as the seat user, not root"
[[ "${HOME:-}" == /* && "$HOME" != / && -d "$HOME" ]] \
    || fail "HOME must be an existing absolute directory"
data_home="$HOME/.local/share"
[[ "${XDG_DATA_HOME:-}" != /* ]] || data_home="$XDG_DATA_HOME"
data_root="$data_home/lyte"
versions="$data_root/versions"
previous_file="$data_root/previous"
bin_dir="$HOME/.local/bin"
link="$bin_dir/lyte-host"
companions=(lyte-audio-check)

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# The id of the version a symlink target names, or failure when the target
# is anything but <versions>/<12 hex>/lyte-host.
version_of_target() {
    local target="$1" id
    [[ "$target" == "$versions"/*/lyte-host ]] || return 1
    id="${target#"$versions"/}"
    id="${id%/lyte-host}"
    [[ "$id" =~ ^[0-9a-f]{12}$ ]] || return 1
    printf '%s\n' "$id"
}

# The active version id, empty when no link exists. Refuses a link that is
# not ours: a regular file, or a symlink escaping the versions directory.
active_version() {
    if [[ -L "$link" ]]; then
        version_of_target "$(readlink "$link")" \
            || fail "$link points outside $versions ($(readlink "$link")) — move it aside first"
    elif [[ -e "$link" ]]; then
        fail "$link is not a symlink — move it aside first"
    fi
}

previous_version() {
    local id=""
    [[ -f "$previous_file" ]] && id="$(head -1 "$previous_file")"
    if [[ "$id" =~ ^[0-9a-f]{12}$ && -d "$versions/$id" ]]; then
        printf '%s\n' "$id"
    fi
}

# A version directory is valid when its lyte-host hashes to its name.
check_version() {
    local id="$1" binary="$versions/$1/lyte-host"
    [[ -d "$versions/$id" && ! -L "$versions/$id" \
        && -f "$binary" && ! -L "$binary" && -x "$binary" ]] \
        || fail "version $id is missing or not a regular executable"
    [[ "$(sha256_file "$binary")" == "$id"* ]] \
        || fail "version $id does not match its binary's sha256"
}

check_layout() {
    local path
    for path in "$data_root" "$versions" "$bin_dir"; do
        [[ ! -L "$path" ]] || fail "$path is a symlink"
        [[ ! -e "$path" || -d "$path" ]] || fail "$path is not a directory"
    done
}

write_previous() {
    local temporary="$previous_file.tmp.$$"
    printf '%s\n' "$1" > "$temporary"
    mv -f "$temporary" "$previous_file"
}

# Replace the link in one rename(2): readers see the old or the new target,
# never a missing file.
flip_link() {
    local id="$1" current="$2" temporary="$bin_dir/.lyte-host.tmp.$$"
    rm -f -- "$temporary"
    ln -s "$versions/$id/lyte-host" "$temporary"
    if mv --version >/dev/null 2>&1; then
        mv -f -T "$temporary" "$link"
    else
        mv -f "$temporary" "$link" # BSD mv: the link never names a directory
    fi
    if [[ -n "$current" && "$current" != "$id" ]]; then
        write_previous "$current"
    fi
    touch "$versions/$id" # recency for pruning
}

restart_service() {
    (( restart )) || return 0
    if [[ -n "${LYTE_SYSTEMCTL:-}" ]]; then
        "$LYTE_SYSTEMCTL" restart lyte-host
    else
        sudo -n systemctl restart lyte-host
    fi
    echo "restarted lyte-host.service"
}

prune() {
    local id current previous kept=0
    current="$(active_version)"
    previous="$(previous_version)"
    # Newest first by the recency stamp flip_link leaves.
    while IFS= read -r id; do
        [[ "$id" =~ ^[0-9a-f]{12}$ && -d "$versions/$id" \
            && ! -L "$versions/$id" ]] || continue
        if [[ "$id" == "$current" || "$id" == "$previous" ]] \
            || (( kept < keep )); then
            kept=$((kept + 1))
            continue
        fi
        find "$versions/$id" -xdev -depth -delete
        echo "pruned version $id"
    done < <(ls -1t "$versions")
}

deploy() {
    local source="${release_dir:-$host_root/.build/release}" sha id current
    local staging="" name
    [[ -d "$source" ]] || fail "release directory not found: $source"
    [[ -f "$source/lyte-host" && -x "$source/lyte-host" ]] \
        || fail "no executable lyte-host in $source"
    check_layout
    current="$(active_version)"
    sha="$(sha256_file "$source/lyte-host")"
    id="${sha:0:12}"

    if [[ -e "$versions/$id" || -L "$versions/$id" ]]; then
        check_version "$id"
        [[ "$(sha256_file "$versions/$id/lyte-host")" == "$sha" ]] \
            || fail "version $id exists with a different binary"
        echo "version $id already deployed"
    else
        mkdir -p "$versions" "$bin_dir"
        staging="$(mktemp -d "$versions/.staging.XXXXXX")"
        trap 'find "$staging" -xdev -depth -delete 2>/dev/null || true' EXIT
        install -m 0755 "$source/lyte-host" "$staging/lyte-host"
        for name in "${companions[@]}"; do
            if [[ -f "$source/$name" && -x "$source/$name" ]]; then
                install -m 0755 "$source/$name" "$staging/$name"
            fi
        done
        [[ "$(sha256_file "$staging/lyte-host")" == "$sha" ]] \
            || fail "copied binary does not match $source/lyte-host"
        chmod 0755 "$staging"
        # -T: a version that appeared meanwhile (a concurrent deploy of
        # the same binary) fails the rename instead of receiving the
        # staging directory inside it.
        if mv --version >/dev/null 2>&1; then
            mv -T "$staging" "$versions/$id" \
                || fail "version $id appeared during this deploy"
        else
            [[ ! -e "$versions/$id" ]] \
                || fail "version $id appeared during this deploy"
            mv "$staging" "$versions/$id"
        fi
        trap - EXIT
        echo "deployed version $id from $source"
    fi

    mkdir -p "$bin_dir"
    flip_link "$id" "$current"
    if [[ "$current" == "$id" ]]; then
        echo "$link already active at $id"
    else
        echo "$link -> $id${current:+ (previous $current)}"
    fi
    prune
    restart_service
}

rollback() {
    local current previous
    check_layout
    current="$(active_version)"
    previous="$(previous_version)"
    [[ -n "$current" ]] || fail "no active version to roll back from"
    [[ -n "$previous" && "$previous" != "$current" ]] \
        || fail "no previous version recorded"
    check_version "$previous"
    flip_link "$previous" "$current"
    echo "$link -> $previous (rolled back from $current)"
    restart_service
}

status() {
    local current previous target
    check_layout
    current="$(active_version)"
    previous="$(previous_version)"
    if [[ -z "$current" ]]; then
        echo "no active version ($link absent)"
        return 1
    fi
    target="$(readlink "$link")"
    check_version "$current"
    echo "link:     $link -> $target"
    echo "sha256:   $(sha256_file "$target")"
    echo "active:   $current"
    echo "previous: ${previous:-none}"
    echo "versions: $(ls -1t "$versions" | grep -E '^[0-9a-f]{12}$' | tr '\n' ' ')"
}

case "$mode" in
    deploy) deploy ;;
    rollback) rollback ;;
    status) status ;;
esac
