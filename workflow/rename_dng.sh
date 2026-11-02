#!/usr/bin/env bash
#
# rename_dng.sh — rename DNG files to YYYYMMDD-event-NNNNN.dng.
#
# The event is normalized like import_photos.sh. The date comes from
# DateTimeOriginal, or the file modification date when that EXIF tag is absent.
# Serials continue after the highest existing number for that date and event.
#
# Usage:
#   ./rename_dng.sh [-n] [-r] [-v] -e EVENT DIRECTORY
#     -n       dry run: show what would be renamed, change nothing
#              (over 500 files: warns it can take several minutes and asks to continue)
#     -r       recurse into subdirectories
#     -v       verbose: show the settings and, for each file, where its date
#              came from and why it was skipped (default: off)
#     -e EVENT event name, e.g. "Detroit Riverwalk" -> detroit-riverwalk
#
# Requires exiftool:  brew install exiftool   (macOS)
#                     sudo apt install libimage-exiftool-perl   (Debian/Ubuntu)
# Works with the stock macOS bash 3.2.

set -u

DRY_RUN=0
RECURSE=""
EVENT_RAW=""
VERBOSE=0

vlog() { [ "$VERBOSE" -eq 1 ] && echo "verbose: $*" >&2; return 0; }

# A dry run still reads every file's metadata, so warn before a big one.
# Asks first when run from a terminal; otherwise warns and carries on.
DRY_RUN_WARN_FILES=500
confirm_large_dry_run() {   # $1 = number of files
    [ "$DRY_RUN" -eq 1 ] && [ "$1" -gt "$DRY_RUN_WARN_FILES" ] || return 0
    echo "Warning: $1 files found. A dry run can take several minutes to complete." >&2
    if [ -t 0 ]; then
        printf 'Continue? [y/N] ' >&2
        read -r reply
        case "$reply" in
            [yY]|[yY][eE][sS]) ;;
            *) echo "Cancelled — nothing was changed." >&2; exit 0 ;;
        esac
    fi
}

usage() {
    echo "Usage: $(basename "$0") [-n] [-r] [-v] -e EVENT DIRECTORY" >&2
    echo "  -n       dry run (show changes only)" >&2
    echo "  -r       recurse into subdirectories" >&2
    echo "  -v       verbose: show what is happening (default: off)" >&2
    echo "  -e EVENT event name, e.g. \"Detroit Riverwalk\"" >&2
    exit 1
}

die() { echo "Error: $*" >&2; exit 1; }

while getopts ":ne:rvh" opt; do
    case "$opt" in
        n) DRY_RUN=1 ;;
        e) EVENT_RAW="$OPTARG" ;;
        r) RECURSE="-r" ;;
        v) VERBOSE=1 ;;
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

vlog "directory: $DIR; event: $EVENT_RAW -> $EVENT; recurse: $([ -n "$RECURSE" ] && echo yes || echo no); dry run: $([ "$DRY_RUN" -eq 1 ] && echo yes || echo no)"
if [ "$DRY_RUN" -eq 1 ]; then
    if [ -n "$RECURSE" ]; then depth=""; else depth="-maxdepth 1"; fi
    # shellcheck disable=SC2086  # $depth is intentionally word-split.
    confirm_large_dry_run "$(find "$DIR" $depth -type f -iname '*.dng' | wc -l | tr -d ' ')"
fi
vlog "reading capture dates with exiftool..."

renamed=0; skipped=0; failed=0; found=0
planned="|"

# ExifTool reports '-' for missing DateTimeOriginal; use the legacy file-date fallback.
# shellcheck disable=SC2016  # ExifTool expands the metadata placeholders.
while IFS=$'\t' read -r src date; do
    [ -n "$src" ] || continue
    found=$((found + 1))
    vlog "found $src (DateTimeOriginal=$date)"
    if ! is_ymd "$date"; then
        vlog "$src has no DateTimeOriginal; using its modification date"
        mtime=$(file_epoch "$src") || { echo "SKIP  $src (cannot read modification date)" >&2; skipped=$((skipped + 1)); continue; }
        date=$(epoch_ymd "$mtime") || { echo "SKIP  $src (cannot determine date)" >&2; skipped=$((skipped + 1)); continue; }
    fi
    is_ymd "$date" || { echo "SKIP  $src (invalid capture date '$date')" >&2; skipped=$((skipped + 1)); continue; }

    dir=$(dirname "$src")
    prefix="$date-$EVENT"
    name=$(basename "$src")
    stem="${name%.*}"
    side_sources=()
    side_targets=()
    for side in "$dir/$stem.xmp" "$dir/$stem.XMP" "$src.xmp" "$src.XMP"; do
        [ -e "$side" ] || continue
        duplicate=0
        for ((i = 0; i < ${#side_sources[@]}; i++)); do
            existing_side="${side_sources[$i]}"
            [ "$side" = "$existing_side" ] && duplicate=1
        done
        [ "$duplicate" -eq 1 ] || side_sources[${#side_sources[@]}]="$side"
    done
    case "$stem" in
        "$prefix"-[0-9][0-9][0-9][0-9][0-9])
            vlog "$src is already named for $date and $EVENT; skipping"
            skipped=$((skipped + 1))
            continue ;;
    esac

    serial=$(next_serial "$dir" "$prefix")
    while :; do
        new=$(printf '%s-%05d' "$prefix" "$serial")
        target="$dir/$new.dng"
        collision=0
        case "$planned" in *"|$target|"*) collision=1 ;; esac
        [ -e "$target" ] && collision=1
        side_targets=()
        for ((i = 0; i < ${#side_sources[@]}; i++)); do
            side="${side_sources[$i]}"
            side_ext="${side##*.}"
            case "$side" in
                "$src".*) side_target="$target.$side_ext" ;;
                *)        side_target="$dir/$new.$side_ext" ;;
            esac
            side_targets[i]="$side_target"
            case "$planned" in *"|$side_target|"*) collision=1 ;; esac
            if [ -e "$side_target" ] && [ "$side_target" != "$side" ]; then
                collision=1
            fi
        done
        [ "$collision" -eq 0 ] && break
        vlog "$new.dng (or one of its sidecars) is already taken; trying the next serial"
        serial=$((serial + 1))
    done
    planned="${planned}${target}|"
    for ((i = 0; i < ${#side_targets[@]}; i++)); do
        side_target="${side_targets[$i]}"
        planned="${planned}${side_target}|"
    done

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "WOULD $src -> $new.dng"
    elif mv -n "$src" "$target" && [ ! -e "$src" ]; then
        echo "OK    $src -> $new.dng"
        renamed=$((renamed + 1))
    else
        echo "FAIL  $src" >&2
        failed=$((failed + 1))
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        for ((i = 0; i < ${#side_sources[@]}; i++)); do
            echo "      + $(basename "${side_sources[$i]}") -> $(basename "${side_targets[$i]}")"
        done
    elif [ -e "$target" ] && [ ! -e "$src" ]; then
        for ((i = 0; i < ${#side_sources[@]}; i++)); do
            side="${side_sources[$i]}"
            side_target="${side_targets[$i]}"
            if mv -n "$side" "$side_target" && [ ! -e "$side" ]; then
                echo "      + $(basename "$side") -> $(basename "$side_target")"
            else
                echo "FAIL  $side" >&2
                failed=$((failed + 1))
            fi
        done
    fi
done < <(exiftool -q -q -m -f $RECURSE -ext dng -d '%Y%m%d' \
            -p '$Directory/$FileName	$DateTimeOriginal' "$DIR" 2>/dev/null | sort)

vlog "examined $found file(s)"
echo
if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry run complete — nothing was changed."
else
    echo "Renamed: $renamed   Skipped: $skipped   Failed: $failed"
fi