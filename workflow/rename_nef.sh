#!/usr/bin/env bash
#
# rename_nef.sh — rename Nikon NEF files using capture time stored in EXIF.
#                 Include camera Make and Model by default. With -e, other
#                 types (e.g. the JPG of a RAW+JPEG shot) can be renamed too.
#
#   2026101720184500_Nikon-Z-8.NEF <- 2026-10-17 20:18:45 (no subseconds)
#   2026101720184537_Nikon-Z-8.NEF <- 2026-10-17 20:18:45.37
#
# Uses DateTimeOriginal + SubSecTimeOriginal. Camera labels use Make and Model,
# with non-alphanumeric characters replaced by hyphens. If two shots land on
# the exact same name, a suffix _1, _2, ... is added. Matching Lightroom/
# Photoshop .xmp sidecars are renamed alongside. If camera tags are missing,
# the timestamp-only name is used with a warning.
#
# Usage:
#   ./rename_nef.sh [-n] [-r] [-m] [-e EXT] DIRECTORY
#     -n       dry run: show what would be renamed, change nothing
#     -r       recurse into subdirectories
#     -m       explicitly include the camera Make and Model (default: on)
#     -e EXT   rename files with this extension instead of NEF, e.g. -e jpg
#              (matches upper and lower case; the extension's case is kept)
#
# Requires exiftool:  brew install exiftool   (macOS)
#                     sudo apt install libimage-exiftool-perl   (Debian/Ubuntu)
#
# Works with the stock macOS bash 3.2.

set -u

DRY_RUN=0
RECURSE=""
EXT="nef"
CAMERA_NAME=1

usage() {
    echo "Usage: $(basename "$0") [-n] [-r] [-m] [-e EXT] DIRECTORY" >&2
    echo "  -n      dry run (show changes only)" >&2
    echo "  -r      recurse into subdirectories" >&2
    echo "  -m      include the camera Make and Model (default: on)" >&2
    echo "  -e EXT  rename this file type instead of NEF (e.g. jpg)" >&2
    exit 1
}

while getopts ":nmre:h" opt; do
    case "$opt" in
        n) DRY_RUN=1 ;;
        r) RECURSE="-r" ;;
        m) CAMERA_NAME=1 ;;
        e) EXT="${OPTARG#.}" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[ $# -eq 1 ] || usage
case "$EXT" in
    ""|*[!A-Za-z0-9]*) echo "Error: -e takes a file extension such as jpg, got '$EXT'" >&2; exit 1 ;;
esac
DIR="$1"
[ -d "$DIR" ] || { echo "Error: '$DIR' is not a directory" >&2; exit 1; }

command -v exiftool >/dev/null 2>&1 || {
    echo "Error: exiftool not found. Install it (e.g. 'brew install exiftool')." >&2
    exit 1
}

renamed=0; skipped=0; failed=0
planned="|"   # names already claimed in this run (catches collisions during dry runs)

# One exiftool call for the whole directory: path <TAB> datetime <TAB> subsec <TAB> make <TAB> model
# -f prints "-" for missing tags; -ext matches upper and lower case (.nef/.NEF).
# shellcheck disable=SC2016  # ExifTool expands the metadata placeholders.
while IFS=$'\t' read -r src dto subsec make model; do
    [ -n "$src" ] || continue
    dir=$(dirname "$src")
    file=$(basename "$src")
    ext="${file##*.}"
    stem="${file%.*}"

    if [ "$dto" = "-" ] || [ -z "$dto" ]; then
        echo "SKIP  $src (no DateTimeOriginal in EXIF)" >&2
        skipped=$((skipped + 1))
        continue
    fi

    subsec=$(printf '%s' "$subsec" | tr -cd '0-9')   # strip spaces / "-" placeholder
    if [ -z "$subsec" ]; then
        subsec="00"
    elif [ "${#subsec}" -eq 1 ]; then
        subsec="${subsec}0"
    fi
    base="${dto}${subsec}"
    if [ "$CAMERA_NAME" -eq 1 ]; then
        camera=$(printf '%s %s' "$make" "$model" | sed -E 's/[^[:alnum:]]+/-/g; s/^-|-$//g')
        if [ -n "$camera" ]; then
            base="${base}_${camera}"
        else
            echo "WARN  $src (camera Make/Model unavailable; using timestamp only)" >&2
        fi
    fi

    # Pick a free target name
    new="$base"
    n=0
    while :; do
        target="$dir/$new.$ext"
        if [ "$target" = "$src" ]; then
            break                                   # already correctly named
        fi
        case "$planned" in *"|$target|"*) ;; *)
            [ -e "$target" ] || break ;;
        esac
        n=$((n + 1))
        new="${base}_$n"
    done

    if [ "$target" = "$src" ]; then
        skipped=$((skipped + 1))
        continue
    fi
    planned="${planned}${target}|"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "WOULD $src -> $new.$ext"
    else
        if mv -n "$src" "$target" && [ ! -e "$src" ]; then
            echo "OK    $src -> $new.$ext"
            renamed=$((renamed + 1))
        else
            echo "FAIL  $src" >&2
            failed=$((failed + 1))
            continue
        fi
    fi

    # Carry along sidecars: IMG.xmp / IMG.XMP and IMG.NEF.xmp styles
    for side in "$dir/$stem.xmp" "$dir/$stem.XMP" "$src.xmp" "$src.XMP"; do
        [ -e "$side" ] || continue
        side_ext="${side##*.}"
        case "$side" in
            "$src".*) side_target="$target.$side_ext" ;;
            *)        side_target="$dir/$new.$side_ext" ;;
        esac
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "      + $(basename "$side") -> $(basename "$side_target")"
        else
            mv -n "$side" "$side_target" && echo "      + $(basename "$side") -> $(basename "$side_target")"
        fi
    done
done < <(exiftool -q -q -m -f $RECURSE -ext "$EXT" \
            -d '%Y%m%d%H%M%S' \
            -p '$Directory/$FileName	$DateTimeOriginal	$SubSecTimeOriginal	$Make	$Model' \
            "$DIR" 2>/dev/null | sort)

echo
if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry run complete — nothing was changed."
else
    echo "Renamed: $renamed   Skipped: $skipped   Failed: $failed"
fi
