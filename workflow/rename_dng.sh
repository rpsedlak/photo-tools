#!/usr/bin/env bash
#
# rename_dng.sh — rename DNG files to YYYYMMDD-event-NNNNN.dng.
#
# The event is normalized like import_photos.sh. The date comes from
# DateTimeOriginal, or the file modification date when that EXIF tag is absent.
# Serials continue after the highest existing number for that date and event.
#
# Usage:
#   ./rename_dng.sh [-n] [-r] -e EVENT DIRECTORY
#     -n       dry run: show what would be renamed, change nothing
#     -r       recurse into subdirectories
#     -e EVENT event name, e.g. "Detroit Riverwalk" -> detroit-riverwalk
#
# Requires exiftool:  brew install exiftool   (macOS)
#                     sudo apt install libimage-exiftool-perl   (Debian/Ubuntu)
# Works with the stock macOS bash 3.2.

set -u

DRY_RUN=0
RECURSE=""
EVENT_RAW=""

usage() {
    echo "Usage: $(basename "$0") [-n] [-r] -e EVENT DIRECTORY" >&2
    echo "  -n       dry run (show changes only)" >&2
    echo "  -r       recurse into subdirectories" >&2
    echo "  -e EVENT event name, e.g. \"Detroit Riverwalk\"" >&2
    exit 1
}

die() { echo "Error: $*" >&2; exit 1; }

while getopts ":ne:rh" opt; do
    case "$opt" in
        n) DRY_RUN=1 ;;
        e) EVENT_RAW="$OPTARG" ;;
        r) RECURSE="-r" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[ $# -eq 1 ] || usage
[ -n "$EVENT_RAW" ] || die "an event name is required (-e EVENT)."
EVENT=$(printf '%s' "$EVENT_RAW" | tr '[:upper:]' '[:lower:]' \
        | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//')
[ -n "$EVENT" ] || die "event name '$EVENT_RAW' has no usable letters or digits."

DIR="$1"
[ -d "$DIR" ] || die "'$DIR' is not a directory."
command -v exiftool >/dev/null 2>&1 || die "exiftool not found. Install it with 'brew install exiftool'."

if stat --version >/dev/null 2>&1; then
    file_epoch() { stat -c %Y "$1"; }
else
    file_epoch() { stat -f %m "$1"; }
fi
epoch_ymd() { date -r "$1" +%Y%m%d 2>/dev/null || date -d "@$1" +%Y%m%d; }
is_ymd() { case "$1" in [12][0-9][0-9][0-9][01][0-9][0-3][0-9]) return 0 ;; esac; return 1; }

next_serial() {
    local dir="$1" prefix="$2" max=0 f number
    for f in "$dir/$prefix"-[0-9][0-9][0-9][0-9][0-9].[dD][nN][gG]; do
        [ -e "$f" ] || continue
        number="${f##*-}"
        number="${number%.*}"
        case "$number" in ""|*[!0-9]*) continue ;; esac
        number=$((10#$number))
        [ "$number" -gt "$max" ] && max="$number"
    done
    echo $((max + 1))
}

renamed=0; skipped=0; failed=0
planned="|"

# ExifTool reports '-' for missing DateTimeOriginal; use the legacy file-date fallback.
# shellcheck disable=SC2016  # ExifTool expands the metadata placeholders.
while IFS=$'\t' read -r src date; do
    [ -n "$src" ] || continue
    if ! is_ymd "$date"; then
        mtime=$(file_epoch "$src") || { echo "SKIP  $src (cannot read modification date)" >&2; skipped=$((skipped + 1)); continue; }
        date=$(epoch_ymd "$mtime") || { echo "SKIP  $src (cannot determine date)" >&2; skipped=$((skipped + 1)); continue; }
    fi
    is_ymd "$date" || { echo "SKIP  $src (invalid capture date '$date')" >&2; skipped=$((skipped + 1)); continue; }

    dir=$(dirname "$src")
    prefix="$date-$EVENT"
    name=$(basename "$src")
    stem="${name%.*}"
    case "$stem" in
        "$prefix"-[0-9][0-9][0-9][0-9][0-9])
            skipped=$((skipped + 1))
            continue ;;
    esac

    serial=$(next_serial "$dir" "$prefix")
    while :; do
        new=$(printf '%s-%05d' "$prefix" "$serial")
        target="$dir/$new.dng"
        case "$planned" in *"|$target|"*) serial=$((serial + 1)); continue ;; esac
        [ -e "$target" ] || break
        serial=$((serial + 1))
    done
    planned="${planned}${target}|"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "WOULD $src -> $new.dng"
    elif mv -n "$src" "$target" && [ ! -e "$src" ]; then
        echo "OK    $src -> $new.dng"
        renamed=$((renamed + 1))
    else
        echo "FAIL  $src" >&2
        failed=$((failed + 1))
    fi
done < <(exiftool -q -q -m -f $RECURSE -ext dng -d '%Y%m%d' \
            -p '$Directory/$FileName	$DateTimeOriginal' "$DIR" 2>/dev/null | sort)

echo
if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry run complete — nothing was changed."
else
    echo "Renamed: $renamed   Skipped: $skipped   Failed: $failed"
fi