#!/usr/bin/env bash
#
# prereqs.sh — make sure the tools photo-tools needs are installed (macOS).
#
#   exiftool             Homebrew formula  (import_photos.sh, rename_nef.sh)
#   Adobe DNG Converter  Homebrew cask     (import_photos.sh)
#
# Optional, only for upload_azure.sh (reported, never installed automatically,
# and never a reason to fail):
#   Azure CLI, azcopy, jq   brew install azure-cli azcopy jq
#
# Anything missing is installed with Homebrew. Homebrew itself is not
# installed automatically; if it's missing you're told how to get it.
# The DNG Converter cask runs Adobe's installer, which asks for your password.
#
# Usage:
#   install/prereqs.sh [-n]
#     -n   check only: report what's missing, install nothing
#
# Exit status: 0 when everything is ready, 1 otherwise.
# Works with the stock macOS bash 3.2.

set -u

CHECK_ONLY=0
DNG_CONVERTER="${DNG_CONVERTER:-/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter}"

usage() { sed -n '/^# Usage:/,/^# Exit status/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d' >&2; exit 1; }

while getopts ":nh" opt; do
    case "$opt" in
        n) CHECK_ONLY=1 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || usage

[ "$(uname -s)" = "Darwin" ] || { echo "Error: photo-tools requires macOS." >&2; exit 1; }

# Homebrew may be installed but not on PATH (e.g. a shell without brew shellenv).
BREW=$(command -v brew 2>/dev/null || true)
if [ -z "$BREW" ]; then
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [ -x "$b" ] && { BREW="$b"; break; }
    done
fi

problems=0
need_brew=""

ok()      { printf 'OK       %s\n' "$*"; }
missing() { printf 'MISSING  %s\n' "$*"; }

# $1 = label, $2 = brew install arguments
brew_install() {
    if [ "$CHECK_ONLY" -eq 1 ]; then
        echo "         install with: brew install $2"
        return 1
    fi
    if [ -z "$BREW" ]; then
        need_brew="$need_brew $1,"
        return 1
    fi
    echo "Installing $1 with Homebrew..."
    # shellcheck disable=SC2086
    "$BREW" install $2
}

# ---------- Homebrew ---------------------------------------------------------
if [ -n "$BREW" ]; then
    ok "Homebrew $("$BREW" --version 2>/dev/null | head -n 1 | sed 's/^Homebrew //')  ($BREW)"
else
    missing "Homebrew (needed only to install anything missing below)"
fi

# ---------- exiftool ---------------------------------------------------------
check_exiftool() {
    local p
    p=$(command -v exiftool 2>/dev/null) || return 1
    ok "exiftool $(exiftool -ver 2>/dev/null)  ($p)"
}

if ! check_exiftool; then
    if [ -n "$BREW" ] && [ -x "$("$BREW" --prefix)/bin/exiftool" ]; then
        # Installed, but the scripts won't find it.
        missing "exiftool is installed at $("$BREW" --prefix)/bin/exiftool but is not on your PATH."
        echo "         Add Homebrew to your PATH, e.g. in ~/.zprofile:"
        echo "             eval \"\$($BREW shellenv)\""
        problems=$((problems + 1))
    else
        missing "exiftool"
        if brew_install "exiftool" "exiftool" && check_exiftool; then :; else
            problems=$((problems + 1))
        fi
    fi
fi

# ---------- Adobe DNG Converter ----------------------------------------------
check_dng() {
    [ -x "$DNG_CONVERTER" ] || return 1
    ok "Adobe DNG Converter  ($DNG_CONVERTER)"
}

if ! check_dng; then
    missing "Adobe DNG Converter (not found at $DNG_CONVERTER)"
    [ "$CHECK_ONLY" -eq 1 ] || [ -z "$BREW" ] || \
        echo "Adobe's installer will ask for your password."
    if brew_install "Adobe DNG Converter" "--cask adobe-dng-converter" && check_dng; then :; else
        [ "$CHECK_ONLY" -eq 1 ] || [ -z "$BREW" ] || \
            echo "         Still not found at $DNG_CONVERTER. If you installed it elsewhere, set DNG_CONVERTER to its path."
        problems=$((problems + 1))
    fi
fi

# ---------- optional: Azure upload tools (upload_azure.sh) --------------------
opt_missing=""
for t in "az:azure-cli:Azure CLI" "azcopy:azcopy:azcopy" "jq:jq:jq"; do
    cmd="${t%%:*}"; rest="${t#*:}"; formula="${rest%%:*}"; label="${rest#*:}"
    if p=$(command -v "$cmd" 2>/dev/null); then
        ok "$label  ($p)  [optional]"
    else
        printf 'OPTIONAL %s not installed (only upload_azure.sh needs it)\n' "$label"
        opt_missing="$opt_missing $formula"
    fi
done

# ---------- summary ----------------------------------------------------------
echo ""
if [ -n "$opt_missing" ]; then
    echo "To upload to Azure with upload_azure.sh, also run: brew install$opt_missing"
    echo ""
fi
if [ -n "$need_brew" ]; then
    echo "Homebrew is needed to install:${need_brew%,}"
    echo "Install Homebrew from https://brew.sh, then re-run this script."
    echo ""
fi
if [ "$problems" -eq 0 ]; then
    echo "All prerequisites are installed."
    exit 0
fi
echo "$problems prerequisite(s) not ready."
exit 1
