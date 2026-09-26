# Shared by the host scripts, which always run from a checkout. A sourcing
# script defines fail() before it calls system_side.

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
todo() { printf '  \033[33m→\033[0m %s\n' "$1"; }

# sha256_file PATH: the file's hex SHA-256 with GNU or BSD tools.
sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# xdg_home VALUE FALLBACK: VALUE without a trailing slash when absolute,
# else FALLBACK.
xdg_home() {
    local value="$1" fallback="$2"
    if [[ "$value" == /* ]]; then printf '%s\n' "${value%/}"; else printf '%s\n' "$fallback"; fi
}

# mv_no_target_dir [-f] SOURCE DEST: a rename that never moves SOURCE into
# DEST. GNU mv has -T for that; BSD mv does not, so a caller whose DEST
# could be a directory checks it first.
mv_no_target_dir() {
    if mv --version >/dev/null 2>&1; then mv -T "$@"; else mv "$@"; fi
}

# Sets install_root, systemctl_command and as_root. LYTE_INSTALL_ROOT is a
# test/package-construction seam for the system side only: the unit lands
# under that prefix, nothing escalates, and only the injected
# LYTE_SYSTEMCTL is contacted.
system_side() {
    install_root="${LYTE_INSTALL_ROOT:-}"
    if [[ -n "$install_root" ]]; then
        [[ "$install_root" == /* && -d "$install_root" && ! -L "$install_root" ]] \
            || fail "LYTE_INSTALL_ROOT must be a real absolute directory"
        install_root="$(cd "$install_root" && pwd -P)"
        [[ "$install_root" != / ]] \
            || fail "use an empty LYTE_INSTALL_ROOT for the real root"
        as_root() { "$@"; }
    else
        as_root() { sudo "$@"; }
    fi
    systemctl_command="${LYTE_SYSTEMCTL:-systemctl}"
}
