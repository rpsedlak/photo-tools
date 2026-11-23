#!/usr/bin/env bash
#
# uninstall.sh — remove photo-tools scripts from /usr/local/bin or a custom location.
#
# Removes all photo-tools scripts with both old names (import_photos.sh, etc.) and
# new names (phototools_import_photos.sh, etc.) from the specified destination.
# Also removes the Stream Deck launchers.
# sudo is used only when the destination isn't writable by you.
#
# Usage:
#   install/uninstall.sh [-n] [-v] [-d DEST]
#     -n       dry run: show what would be uninstalled, change nothing
#     -v       verbose: show the commands run and why sudo is (or is not) used
#              (default: off)
#     -d DEST  uninstall from somewhere else (default: /usr/local/bin)
#
# Works with the stock macOS bash 3.2.

set -u

DEST="/usr/local/bin"
DRY_RUN=0
VERBOSE=0

usage() { sed -n '/^# Usage:/,/^# Works/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d' >&2; exit 1; }
die()   { echo "Error: $*" >&2; exit 1; }
vlog()  { [ "$VERBOSE" -eq 1 ] && echo "verbose: $*" >&2; return 0; }
run()   { if [ "$DRY_RUN" -eq 1 ]; then echo "WOULD $*"; else "$@"; fi; }

while getopts ":nvd:h" opt; do
    case "$opt" in
        n) DRY_RUN=1 ;;
        v) VERBOSE=1 ;;
        d) DEST="${OPTARG%/}" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || usage
[ -n "$DEST" ] || die "destination is empty."

vlog "destination: $DEST; dry run: $DRY_RUN"

# List of scripts to uninstall (both old and new names)
SCRIPTS_TO_REMOVE=(
    # New names (phototools_ prefix)
    "phototools_import_photos.sh"
    "phototools_rename_nef.sh"
    "phototools_rename_dng.sh"
    "phototools_upload_azure.sh"
    "phototools_report_azure.sh"
    "phototools_prune_nef.sh"
    "phototools_archive_container.sh"
    "phototools_unarchive_container.sh"
    "phototools_prereqs.sh"
    "phototools_update.sh"
    # Old names (without prefix) for backward compatibility
    "import_photos.sh"
    "rename_nef.sh"
    "rename_dng.sh"
    "upload_azure.sh"
    "report_azure.sh"
    "prune_nef.sh"
    "archive_container.sh"
    "unarchive_container.sh"
    "prereqs.sh"
    "update.sh"
    # Known Stream Deck launchers, even if they no longer exist in the source.
    "streamdeck_import_clarkston.command"
    "streamdeck_import_general.command"
    "streamdeck_import_luring.command"
)

REPO=$(cd "$(dirname "$0")/.." && pwd)
if [ -d "$REPO/stream-deck" ]; then
    while IFS= read -r f; do
        SCRIPTS_TO_REMOVE+=("$(basename "$f")")
    done < <(find "$REPO/stream-deck" -mindepth 1 -maxdepth 1 -type f -name '*.command' | sort)
fi

# Need sudo if the destination isn't writable.
SUDO=""
[ -w "$DEST" ] || SUDO="sudo -A"
if [ -n "$SUDO" ]; then vlog "$DEST is not writable by you; using sudo"; else vlog "$DEST is writable; not using sudo"; fi

if [ -n "$SUDO" ] && [ "$DRY_RUN" -eq 0 ]; then
    echo "$DEST needs administrator access; you may be asked for your password."
fi

removed=0
for script in "${SCRIPTS_TO_REMOVE[@]}"; do
    if [ -f "$DEST/$script" ]; then
        vlog "removing $DEST/$script"
        if run $SUDO rm -f "$DEST/$script"; then
            [ "$DRY_RUN" -eq 1 ] || echo "Removed  $script from $DEST"
            removed=$((removed + 1))
        else
            die "could not remove $script"
        fi
    else
        vlog "$DEST/$script not found (skipped)"
    fi
done

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry run complete — nothing was changed."
else
    if [ "$removed" -eq 0 ]; then
        echo "No photo-tools scripts found to remove from $DEST."
    else
        echo "Removed $removed script(s) from $DEST."
    fi
fi
