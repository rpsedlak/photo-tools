#!/usr/bin/env bash
#
# update.sh - install missing prerequisites, then update photo-tools dependencies.
#
# Updates only Homebrew-managed dependencies used by this repository. The jq
# command supplied by macOS is left alone.
# Works with the stock macOS bash 3.2.

set -u

die() { echo "Error: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "photo-tools requires macOS."

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PREREQS="$SCRIPT_DIR/prereqs.sh"
[ -f "$PREREQS" ] || die "prereqs.sh not found. Reinstall photo-tools using install/install.sh."

BREW=$(command -v brew 2>/dev/null || true)
if [ -z "$BREW" ]; then
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [ -x "$b" ] && { BREW="$b"; break; }
    done
fi
[ -n "$BREW" ] || die "Homebrew is required to update dependencies. Install it from https://brew.sh."

echo "Updating Homebrew..."
"$BREW" update || die "Homebrew could not update its package metadata."

echo "Checking prerequisites..."
bash "$PREREQS" || die "prerequisites are not ready (see above)."

formulas=()
for formula in exiftool xz azure-cli azcopy jq; do
    if "$BREW" list --formula "$formula" >/dev/null 2>&1; then
        formulas+=("$formula")
    fi
done

if [ "${#formulas[@]}" -gt 0 ]; then
    echo "Updating Homebrew formulas: ${formulas[*]}"
    "$BREW" upgrade --formula "${formulas[@]}" || die "Homebrew formula upgrade failed."
else
    echo "No Homebrew-managed formulas to update."
fi

if "$BREW" list --cask adobe-dng-converter >/dev/null 2>&1; then
    echo "Updating Adobe DNG Converter..."
    "$BREW" upgrade --cask adobe-dng-converter || die "Adobe DNG Converter upgrade failed."
else
    echo "Adobe DNG Converter is not managed by Homebrew; skipping its update."
fi

echo "Dependencies are up to date."