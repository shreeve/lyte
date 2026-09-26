#!/usr/bin/env bash
#
# install.sh — install Lyte.app with one command (macOS 15 or later, Apple Silicon):
#
#   curl -fsSL https://raw.githubusercontent.com/shreeve/lyte/main/Scripts/install.sh | bash
#
# Installs the newest GitHub release, signed with a Developer ID and notarized, so it opens on
# first launch; Sparkle updates it in place from then on. Nothing is installed unless the app is
# signed by Lyte's Developer ID (team SD6N7Z8P9P) and Gatekeeper accepts it as notarized.
#
# The app lands in /Applications, or ~/Applications where that is not writable; LYTE_DEST names
# another directory (... | LYTE_DEST=dir bash). An installed copy is replaced by rename, so a
# failed install leaves it be, and never while Lyte or its helper runs. LYTE_ZIP_URL installs
# another archive, for tests, and must pass the same checks; LYTE_LSREGISTER names another
# Launch Services registrar, for tests.

set -euo pipefail

# Color only when stdout is a terminal, and never against NO_COLOR.
Color_Off='' Red='' Green='' Dim='' Bold_Green=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    Color_Off='\033[0m'
    Red='\033[0;31m' Green='\033[0;32m' Dim='\033[0;2m'
    Bold_Green='\033[1;32m'
fi

info() { printf "${Dim}%s${Color_Off}\n" "$*"; }
fail() { printf "${Red}error${Color_Off}: %s\n" "$*" >&2; exit 1; }
tildify() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

# A bundle is replaced only while none of its code runs: not the app, and not
# the root helper it registered, which exits a few seconds after a stream ends.
# A process table that cannot be read counts as running.
refuse_while_running() {
    local process status
    for process in Lyte lyte-helperd; do
        status=0
        pgrep -x "$process" >/dev/null 2>&1 || status=$?
        [ "$status" -eq 1 ] && continue
        [ "$status" -eq 0 ] || fail "cannot tell whether Lyte is running; nothing was changed"
        case "$process" in
            Lyte) fail "Lyte is running; quit it (Lyte → Quit Lyte, or: osascript -e 'quit app \"Lyte\"') and run this again; nothing was changed" ;;
            *) fail "Lyte's helper is still running; it exits a few seconds after Lyte quits, so run this again then; nothing was changed" ;;
        esac
    done
}

main() {
    [ "$(uname -s)" = "Darwin" ] || fail "Lyte is a macOS app."
    [ "$(uname -m)" = "arm64" ] || fail "Lyte is Apple Silicon only (this Mac is $(uname -m))."
    major=$(sw_vers -productVersion | cut -d. -f1)
    [ "$major" -ge 15 ] || fail "Lyte needs macOS 15 or later (this Mac runs $(sw_vers -productVersion))."
    refuse_while_running

    # A Developer ID Application certificate (the two Apple extensions that mark one) of team SD6N7Z8P9P.
    requirement='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "SD6N7Z8P9P"'
    # The repo's latest release is Lyte's newest; its archive keeps one name.
    url="${LYTE_ZIP_URL:-https://github.com/shreeve/lyte/releases/latest/download/Lyte.zip}"
    # LYTE_DEST, when given, is honored or refused, never quietly swapped for
    # another; only the default falls back, for Macs where /Applications
    # belongs to someone else.
    if [ -n "${LYTE_DEST:-}" ]; then
        dest="$LYTE_DEST"
    else
        dest="/Applications"
        [ -w "$dest" ] || dest="$HOME/Applications"
    fi
    mkdir -p "$dest"
    [ -w "$dest" ] || fail "$(tildify "$dest") is not writable"
    installed="$dest/Lyte.app"
    staged="$dest/.Lyte.app.incoming"
    aside="$dest/.Lyte.app.outgoing"

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp" "$staged"' EXIT
    info "Lyte (latest release, Apple Silicon)"
    # A redirect may not leave HTTPS.
    curl -fSL --proto-redir =https --retry 3 --retry-delay 1 --progress-bar "$url" -o "$tmp/Lyte.zip"
    # ditto, not unzip: it preserves the bundle exactly as it was archived.
    ditto -x -k "$tmp/Lyte.zip" "$tmp/unpacked"
    [ -d "$tmp/unpacked/Lyte.app" ] || fail "the download holds no Lyte.app; nothing was changed"

    # Stage beside the destination, so the swap below is two renames within
    # one directory. Everything that touches the bundle happens to the staged
    # copy: nothing is written into an app once it is in place.
    rm -rf "$staged"
    mv "$tmp/unpacked/Lyte.app" "$staged"
    # A damaged or substituted download stops here, with the installed app
    # still standing. A valid signature is not enough, since anyone can sign
    # a bundle: it must come from a Developer ID Application certificate of
    # Lyte's team, and Gatekeeper must accept the app as notarized.
    codesign --verify --deep --strict -R="$requirement" "$staged" 2>/dev/null \
        || fail "the downloaded Lyte.app is not signed with Lyte's Developer ID; nothing was changed"
    assessment=$(spctl --assess --type execute -vv "$staged" 2>&1) \
        && grep -qx 'source=Notarized Developer ID' <<<"$assessment" \
        || fail "Gatekeeper does not accept the downloaded Lyte.app as notarized; nothing was changed"

    # The download took a while; Lyte may have been opened meanwhile.
    refuse_while_running

    # A swap that died between its two renames left the only copy set
    # aside; it goes back before anything else.
    if [ -e "$aside" ]; then
        [ -e "$installed" ] || mv "$aside" "$installed"
        rm -rf "$aside"
    fi

    # Replace, never merge, and never by deleting first: the installed app
    # steps aside, the staged one takes its name, and only then is the old
    # one removed. A rename that fails puts back the app that was there.
    if [ -e "$installed" ]; then
        mv "$installed" "$aside" || fail "cannot replace $(tildify "$installed")"
        if ! mv "$staged" "$installed"; then
            mv "$aside" "$installed"
            fail "cannot move Lyte into $(tildify "$dest"); the installed copy is untouched"
        fi
        rm -rf "$aside"
    else
        mv "$staged" "$installed"
    fi

    # Launch Services learns of the bundle at this path at once, so Finder,
    # Spotlight and `open -a Lyte` find it without waiting for a rescan. Best
    # effort: the app runs the same without it.
    lsregister="${LYTE_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
    if [ -x "$lsregister" ]; then
        "$lsregister" -f "$installed" >/dev/null 2>&1 || true
    fi

    printf "${Green}Lyte was installed to ${Bold_Green}%s${Color_Off}\n" "$(tildify "$installed")"
    info "Run 'open -a Lyte' to get started"
}

main "$@"
