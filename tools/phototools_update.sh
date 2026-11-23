#!/usr/bin/env bash
#
# phototools_update.sh - install missing prerequisites, then update photo-tools dependencies.
#
# Updates only Homebrew-managed dependencies used by this repository. The jq
# command supplied by macOS is left alone.
#
# Usage:
#   phototools_update.sh [-v]
#     -v   verbose: show the Homebrew commands run and which dependencies are
#          (or are not) managed by Homebrew (default: off)
#
# Works with the stock macOS bash 3.2.

set -u

VERBOSE=0

usage() { sed -n '/^# Usage:/,/^# Works/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d' >&2; exit 1; }
die() { echo "Error: $*" >&2; exit 1; }
vlog() { [ "$VERBOSE" -eq 1 ] && echo "verbose: $*" >&2; return 0; }

while getopts ":vh" opt; do
    case "$opt" in
        v) VERBOSE=1 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || usage

[ "$(uname -s)" = "Darwin" ] || die "photo-tools requires macOS."

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PREREQS="$SCRIPT_DIR/phototools_prereqs.sh"
[ -f "$PREREQS" ] || die "phototools_prereqs.sh not found. Reinstall photo-tools using install/install.sh."

BREW=$(command -v brew 2>/dev/null || true)
if [ -z "$BREW" ]; then
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [ -x "$b" ] && { BREW="$b"; break; }
    done
fi
[ -n "$BREW" ] || die "Homebrew is required to update dependencies. Install it from https://brew.sh."

vlog "using Homebrew at $BREW and $PREREQS"
echo "Updating Homebrew..."
vlog "running: $BREW update"
"$BREW" update || die "Homebrew could not update its package metadata."

echo "Checking prerequisites..."
if [ "$VERBOSE" -eq 1 ]; then
    vlog "running: bash $PREREQS -v"
    bash "$PREREQS" -v || die "prerequisites are not ready (see above)."
else
    bash "$PREREQS" || die "prerequisites are not ready (see above)."
fi

formulas=()
for formula in exiftool azure-cli azcopy jq python; do
    if "$BREW" list --formula "$formula" >/dev/null 2>&1; then
        formulas+=("$formula")
    else
        vlog "$formula is not installed by Homebrew; leaving it alone"
    fi
done

if [ "${#formulas[@]}" -gt 0 ]; then
    echo "Updating Homebrew formulas: ${formulas[*]}"
    vlog "running: $BREW upgrade --formula ${formulas[*]}"
    "$BREW" upgrade --formula "${formulas[@]}" || die "Homebrew formula upgrade failed."
else
    echo "No Homebrew-managed formulas to update."
fi

if "$BREW" list --cask adobe-dng-converter >/dev/null 2>&1; then
    echo "Updating Adobe DNG Converter..."
    vlog "running: $BREW upgrade --cask adobe-dng-converter"
    "$BREW" upgrade --cask adobe-dng-converter || die "Adobe DNG Converter upgrade failed."
else
    echo "Adobe DNG Converter is not managed by Homebrew; skipping its update."
fi

echo "Dependencies are up to date."