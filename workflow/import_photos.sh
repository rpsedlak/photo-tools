#!/usr/bin/env bash
#
# import_photos.sh — import photos from one SD card onto a destination disk.
#
#   1. COPY    Every file in the card's DCIM folder is copied (never moved —
#              the card is left untouched) into a folder for its capture date,
#              then a subfolder for its extension, and each copy is verified:
#                  <destination>/20261017/NEF/
#                                             /JPG/
#                                             /MOV/
#                  <destination>/20261018/NEF/ ...
#              The date comes from the photo's EXIF capture time
#              (DateTimeOriginal), or the file's timestamp when there is none.
#              Each of those date folders also gets an empty prod/ folder
#              (left as-is if it already exists).
#              RAW+JPEG shots (DSC_0001.NEF + DSC_0001.JPG) are both copied,
#              each to its own extension folder.
#   2. RENAME  The newly imported NEFs and JPGs are renamed to their capture
#              time by rename_nef.sh (same folder as this script), so they sort
#              by time and RAW+JPEG pairs share a name. With -m, the camera's
#              Make and Model are added to both filenames:
#                  20261017/NEF/2026101720184537_Nikon-Z-8.NEF
#                  20261017/JPG/2026101720184537_Nikon-Z-8.JPG
#              Timestamp names always include at least two subsecond digits;
#              missing values use 00.
#              Other types (MOV, ...) keep their camera names.
#   3. DNG     Those NEFs are converted with Adobe DNG Converter into the
#              date folder's DNG/. By default, DNGs are named
#              <YYYYMMDD>-<event>-<nnnnn>.dng; with -m they use the NEF's
#              timestamp and camera name. Only NEFs are converted: for a
#              RAW+JPEG shot the DNG always comes from the NEF.
#   4. COPYRIGHT
#              With an owner set (-c, or PHOTO_COPYRIGHT_OWNER), each new DNG
#              gets "© <year> <owner>" as its copyright and <owner> as its
#              creator (EXIF, XMP, and IPTC if present), with <year> taken
#              from that photo's capture date. NEFs are never modified.
#   5. COMPRESS
#              Once a date's NEFs are all converted and filed, its NEF/ folder
#              is zipped into <destination>/20261017/NEF.zip, the zip is tested,
#              and the NEF/ folder is removed. Turn this off with -z or
#              PHOTO_COMPRESS_NEF=0. Not done with -k (no DNGs were made), or
#              while any NEF of that date still waits for a retry. If a later
#              card adds NEFs to a date that already has NEF.zip, the zip is
#              unpacked first (so duplicates are still caught), then re-zipped.
#
# Several cards for the same date and event
#   Import them one after another. <nnnnn> continues from the highest number
#   already in that date's DNG/ for that event, so the second card's DNGs
#   carry on (…-00143, …-00144, …) and a DNG name is never reused or
#   overwritten. Two events on the same day each have their own sequence.
#
# No duplicates
#   * A manifest (.photo-import-manifest.tsv on the destination) remembers every file
#     imported (name + size + EXIF capture time), so re-inserting a card — or
#     importing the backup card from the camera's second slot — copies nothing.
#   * Before converting, each new NEF is compared byte-for-byte with the NEFs
#     already in that date folder; an identical photo is dropped, so it can
#     never get a second DNG. New JPGs are checked the same way.
#
# Usage:
#   ./import_photos.sh -e EVENT [options]
#
#   -e EVENT     event name (required). "Detroit Riverwalk" -> detroit-riverwalk
#   -c OWNER     copyright owner written into each new DNG, e.g. "Richard Sedlak"
#                (default: $PHOTO_COPYRIGHT_OWNER; no copyright if neither is set)
#   -s SOURCE    card mount point (default: the volume in /Volumes that has a
#                DCIM folder)
#   -d DEST      destination root (required unless PHOTO_IMPORT_DEST is set)
#   -m           include the camera Make and Model in NEF, JPG and DNG filenames
#   -D YYYYMMDD  put everything in this one date folder instead of sorting
#                by each file's capture date
#   -V           verify copies byte-for-byte (default: size check)
#   -k           copy and rename only; skip DNG conversion (and NEF compression)
#   -z           do not zip the NEF/ folders afterwards
#                (default: zip them; PHOTO_COMPRESS_NEF=0 turns it off too)
#   -F           force: ignore the manifest and copy everything again
#                (identical photos are still never converted twice)
#   -x           eject the card when finished
#   -n           dry run: show what would happen, change nothing
#
# Environment overrides:
#   PHOTO_IMPORT_DEST  destination root (same as -d; -d overrides it)
#   PHOTO_COPYRIGHT_OWNER  default for -c; set it once in ~/.zshrc, e.g.
#                  export PHOTO_COPYRIGHT_OWNER="Richard Sedlak"
#   PHOTO_COMPRESS_NEF  set to 0 (or no/false/off) to stop compressing NEF/
#                  folders after import (same as -z); default is to compress
#   DNG_CONVERTER  path to the converter binary
#                  (default: /Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter)
#   DNG_OPTS       converter options (default: "-c -p1" = lossless compressed,
#                  medium preview). See Adobe's DNG Converter command-line notes.
#
# Requires: exiftool (brew install exiftool), Adobe DNG Converter (free,
# from Adobe), rename_nef.sh next to this script, and zip + unzip (stock on
# macOS) unless NEF compression is off.
# Works with the stock macOS bash 3.2.

set -u

# ---------- settings ----------------------------------------------------------
DEST_ROOT="${PHOTO_IMPORT_DEST:-}"
VOLUMES_DIR="${VOLUMES_DIR:-/Volumes}"
DNG_CONVERTER="${DNG_CONVERTER:-/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter}"
DNG_OPTS="${DNG_OPTS:--c -p1}"
DNG_BATCH=100                   # NEFs per converter launch
COPYRIGHT_OWNER="${PHOTO_COPYRIGHT_OWNER:-}"
COMPRESS_NEF=1
case "$(printf '%s' "${PHOTO_COMPRESS_NEF:-1}" | tr '[:upper:]' '[:lower:]')" in
    0|no|false|off|n) COMPRESS_NEF=0 ;;
esac

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
RENAME_NEF="$SCRIPT_DIR/rename_nef.sh"

EVENT_RAW=""; SOURCE=""; FORCE_DATE=""; VERIFY_BYTES=0; SKIP_DNG=0; CAMERA_NAME=0
FORCE=0; EJECT=0; DRY_RUN=0

usage() { sed -n '/^# Usage:/,/^# Environment/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d' >&2; exit 1; }
die()   { echo "Error: $*" >&2; exit 1; }
log()   { echo "$*"; }

while getopts ":e:c:s:d:D:VkzFmxnh" opt; do
    case "$opt" in
        e) EVENT_RAW="$OPTARG" ;;
        c) COPYRIGHT_OWNER="$OPTARG" ;;
        s) SOURCE="${OPTARG%/}" ;;
        d) DEST_ROOT="${OPTARG%/}" ;;
        D) FORCE_DATE="$OPTARG" ;;
        m) CAMERA_NAME=1 ;;
        V) VERIFY_BYTES=1 ;;
        k) SKIP_DNG=1 ;;
        z) COMPRESS_NEF=0 ;;
        F) FORCE=1 ;;
        x) EJECT=1 ;;
        n) DRY_RUN=1 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || usage

# ---------- portable helpers (macOS/BSD and GNU) ------------------------------
if stat --version >/dev/null 2>&1; then
    file_size()  { stat -c %s "$1"; }
    file_epoch() { stat -c %Y "$1"; }
else
    file_size()  { stat -f %z "$1"; }
    file_epoch() { stat -f %m "$1"; }
fi
epoch_ymd() { date -r "$1" +%Y%m%d 2>/dev/null || date -d "@$1" +%Y%m%d; }
upper()     { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
is_ymd()    { case "$1" in [12][0-9][0-9][0-9][01][0-9][0-3][0-9]) return 0 ;; esac; return 1; }
ext_of()    { local n; n=$(basename "$1"); if [ "$n" = "${n##*.}" ]; then echo OTHER; else upper "${n##*.}"; fi; }
add_date()  { case "$dates_seen" in *"|$1|"*) ;; *) dates_seen="$dates_seen$1|" ;; esac; }

# ---------- progress display --------------------------------------------------
# On a terminal one status line is rewritten in place; when the output goes to
# a file or pipe, a line is printed at every 10% instead.
PROG_TTY=0; [ -t 1 ] && PROG_TTY=1
PROG_STEP=-1
progress() {      # $1 = percent done, $2 = status text
    if [ "$PROG_TTY" -eq 1 ]; then
        printf '\r\033[K%s' "$2"
    elif [ $(( $1 / 10 )) -ne "$PROG_STEP" ]; then
        PROG_STEP=$(( $1 / 10 )); printf '%s\n' "$2"
    fi
}
progress_end() {  # clear the status line before normal output resumes
    if [ "$PROG_TTY" -eq 1 ]; then printf '\r\033[K'; fi
    PROG_STEP=-1
}
hms()    { if [ "$1" -ge 3600 ]; then printf '%dh%02dm' $(($1 / 3600)) $(($1 % 3600 / 60)); else printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); fi; }
size_h() { if [ "$1" -ge 1073741824 ]; then printf '%d.%d GB' $(($1 / 1073741824)) $(($1 % 1073741824 * 10 / 1073741824)); else printf '%d MB' $(($1 / 1048576)); fi; }
timing() {        # $1 = start ($SECONDS), $2 = amount done, $3 = total -> "1m02s, ~3m10s left"
    local el=$((SECONDS - $1))
    printf '%s' "$(hms "$el")"
    if [ "$2" -gt 0 ] && [ "$2" -lt "$3" ] && [ "$el" -ge 2 ]; then
        printf ', ~%s left' "$(hms $(( el * ($3 - $2) / $2 )))"
    fi
}

# ---------- validate ----------------------------------------------------------
[ -n "$EVENT_RAW" ] || { echo "Error: an event name is required (-e)." >&2; usage; }
EVENT=$(printf '%s' "$EVENT_RAW" | tr '[:upper:]' '[:lower:]' \
        | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//')
[ -n "$EVENT" ] || die "event name '$EVENT_RAW' has no usable letters or digits."
[ -z "$FORCE_DATE" ] || is_ymd "$FORCE_DATE" || die "-D must be YYYYMMDD, got '$FORCE_DATE'."

[ -n "$DEST_ROOT" ] || die "a destination root is required (-d DEST or PHOTO_IMPORT_DEST)."
[ -d "$DEST_ROOT" ] || die "destination '$DEST_ROOT' not found."
DEST_ROOT=$(cd "$DEST_ROOT" && pwd)     # the DNG converter needs absolute paths
[ -w "$DEST_ROOT" ] || [ "$DRY_RUN" -eq 1 ] || die "destination '$DEST_ROOT' is not writable."

command -v exiftool >/dev/null 2>&1 || die "exiftool not found. Install it with: brew install exiftool"
if [ "$COMPRESS_NEF" -eq 1 ] && [ "$SKIP_DNG" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    command -v zip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1 || \
        die "zip/unzip not found. Install them, or use -z (or PHOTO_COMPRESS_NEF=0) to skip NEF compression."
fi
[ -f "$RENAME_NEF" ] || die "rename_nef.sh not found next to this script ($SCRIPT_DIR)."
if [ "$SKIP_DNG" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ ! -x "$DNG_CONVERTER" ]; then
    die "Adobe DNG Converter not found at:
  $DNG_CONVERTER
Install it from Adobe, set DNG_CONVERTER to its path, or use -k to skip DNG conversion."
fi

# The card: the mounted volume with a DCIM folder (other than the destination).
if [ -z "$SOURCE" ]; then
    found=0
    for v in "$VOLUMES_DIR"/*; do
        [ -d "$v/DCIM" ] || continue
        [ "$(cd "$v" && pwd)" = "$DEST_ROOT" ] && continue
        SOURCE="$v"; found=$((found + 1))
    done
    [ $found -gt 0 ] || die "no SD card found (no volume in $VOLUMES_DIR has a DCIM folder). Use -s to name one."
    [ $found -eq 1 ] || die "more than one volume has a DCIM folder — name the card with -s."
fi
[ -d "$SOURCE" ] || die "source '$SOURCE' not found."
SOURCE=$(cd "$SOURCE" && pwd)

MANIFEST="$DEST_ROOT/.photo-import-manifest.tsv"
[ -e "$MANIFEST" ] || [ "$DRY_RUN" -eq 1 ] || : > "$MANIFEST"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/photo-import.XXXXXX") || die "cannot create a temp folder"
trap 'rm -rf "$WORK"' EXIT
CONV_PID=""       # DNG converter running in the background (it ignores Ctrl-C itself)
trap 'echo ""; [ -n "$CONV_PID" ] && kill "$CONV_PID" 2>/dev/null
      echo "Interrupted — re-run the same command to finish." >&2; exit 130' INT TERM

log "Event:   $EVENT"
log "Card:    $SOURCE"
log "Dest:    $DEST_ROOT"
if [ "$SKIP_DNG" -eq 0 ]; then
    if [ -n "$COPYRIGHT_OWNER" ]; then
        log "Rights:  © <capture year> $COPYRIGHT_OWNER"
    else
        log "Rights:  none (set -c OWNER or PHOTO_COPYRIGHT_OWNER to add a copyright)"
    fi
fi
log ""

# ---------- 1. plan: what is new on the card, and which date is it? -----------
scan="$SOURCE"; [ -d "$SOURCE/DCIM" ] && scan="$SOURCE/DCIM"
find "$scan" -type f ! -name '.*' ! -path '*/.*' > "$WORK/files"

# Capture time for every file in one exiftool pass: path, YYYYMMDDHHMMSS, subsec.
# -progress reports "[n/total]" on stderr, which drives the status line.
: > "$WORK/exif"
if [ -s "$WORK/files" ]; then
    log "Reading capture dates from $(wc -l < "$WORK/files" | tr -d ' ') file(s)..."
    exiftool -q -q -m -f -fast2 -progress -d '%Y%m%d%H%M%S' \
             -p '$Directory/$FileName	$DateTimeOriginal	$SubSecTimeOriginal' \
             -@ "$WORK/files" 2>&1 > "$WORK/exif" |
    while IFS= read -r line; do
        case "$line" in
            "======== "*"/"*"]")
                c="${line##* \[}"; c="${c%]}"
                progress $(( ${c%/*} * 100 / ${c#*/} )) "Reading capture dates... $c" ;;
        esac
    done
    progress_end
fi
awk -F'\t' 'NR == FNR { t[$1] = $2 "\t" $3; next }
            { print $0 "\t" (($0 in t) ? t[$0] : "-\t-") }' \
    "$WORK/exif" "$WORK/files" > "$WORK/plan"

TODO=(); TODO_KEY=(); TODO_DATE=(); TODO_SIZE=()
total_bytes=0; nef_bytes=0; already=0
dates_seen="|"
plan_n=$(wc -l < "$WORK/plan" | tr -d ' '); k=0

while IFS=$'\t' read -r f dto sub; do
    [ -n "$f" ] || continue
    k=$((k + 1))
    progress $(( k * 100 / plan_n )) "Checking against the manifest... $k/$plan_n"
    name=$(basename "$f")
    size=$(file_size "$f"); mtime=$(file_epoch "$f")
    sub=$(printf '%s' "$sub" | tr -cd '0-9')
    # Identity of a file: name + size + EXIF capture time. (Card timestamps
    # can shift an hour with daylight saving, so they're only a fallback.)
    case "$dto" in
        [12][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
            key="$name	$size	$dto$sub" ;;
        *)  key="$name	$size	$mtime" ;;
    esac
    if [ "$FORCE" -eq 0 ] && grep -qxF "$key" "$MANIFEST" 2>/dev/null; then
        already=$((already + 1)); continue
    fi

    if [ -n "$FORCE_DATE" ]; then d="$FORCE_DATE"
    else d="${dto:0:8}"; is_ymd "$d" || d=$(epoch_ymd "$mtime")
    fi
    TODO+=("$f"); TODO_KEY+=("$key"); TODO_DATE+=("$d"); TODO_SIZE+=("$size")
    total_bytes=$((total_bytes + size))
    case "$name" in *.[Nn][Ee][Ff]) nef_bytes=$((nef_bytes + size)) ;; esac
done < "$WORK/plan"
progress_end

# NEFs and JPGs left in .incoming by an interrupted run are finished too.
leftover=0
for inc in "$DEST_ROOT"/[12][0-9][0-9][0-9][01][0-9][0-3][0-9]/NEF/.incoming \
           "$DEST_ROOT"/[12][0-9][0-9][0-9][01][0-9][0-3][0-9]/JPG/.incoming; do
    [ -d "$inc" ] || continue
    t=$(basename "$(dirname "$inc")")
    n=$(find "$inc" -maxdepth 1 -type f -iname "*.$t" | wc -l | tr -d ' ')
    [ "$n" -gt 0 ] || continue
    d=$(basename "$(dirname "$(dirname "$inc")")")
    leftover=$((leftover + n))
    log "Resume:  $n $t(s) in $d/$t/.incoming from an earlier run"
    add_date "$d"
done

log "New:     ${#TODO[@]} file(s), $((total_bytes / 1048576)) MB   (already imported: $already)"
i=0; while [ $i -lt ${#TODO[@]} ]; do add_date "${TODO_DATE[$i]}"; i=$((i + 1)); done
DATES=$(printf '%s' "$dates_seen" | tr '|' '\n' | sed '/^$/d' | sort)
[ -n "$DATES" ] && log "Dates:   $(echo $DATES)"
log ""

if [ ${#TODO[@]} -eq 0 ] && [ "$leftover" -eq 0 ]; then
    log "Nothing new to import."
    [ "$EJECT" -eq 1 ] && [ "$DRY_RUN" -eq 0 ] && diskutil eject "$SOURCE" >/dev/null 2>&1 && log "Ejected $SOURCE"
    exit 0
fi

# Free-space check: the copies, plus about as much again for the DNGs, plus 1%.
avail_kb=$(df -Pk "$DEST_ROOT" | awk 'NR==2 {print $4}')
need_bytes=$(( total_bytes + (SKIP_DNG ? 0 : nef_bytes) + (SKIP_DNG || ! COMPRESS_NEF ? 0 : nef_bytes) ))
need_kb=$(( need_bytes / 1024 + need_bytes / 102400 ))
[ "$need_kb" -le "$avail_kb" ] || \
    die "not enough space on $DEST_ROOT: need $((need_kb / 1024)) MB, have $((avail_kb / 1024)) MB."

if [ "$DRY_RUN" -eq 1 ]; then
    i=0
    while [ $i -lt ${#TODO[@]} ]; do
        log "WOULD COPY  ${TODO[$i]} -> ${TODO_DATE[$i]}/$(ext_of "${TODO[$i]}")/"
        i=$((i + 1))
    done
    for day in $DATES; do
        [ -d "$DEST_ROOT/$day/prod" ] || log "WOULD CREATE  $day/prod/"
    done
    log ""
    log "Dry run complete — nothing was changed. NEFs and JPGs would then be renamed to capture time"
    [ "$SKIP_DNG" -eq 0 ] && log "and the NEFs converted to <date>/DNG/<YYYYMMDD>-$EVENT-<nnnnn>.dng"
    [ "$SKIP_DNG" -eq 0 ] && [ "$COMPRESS_NEF" -eq 1 ] && log "and each date's NEF/ folder zipped to <date>/NEF.zip"
    exit 0
fi

# ---------- 2. copy + verify --------------------------------------------------
copied=0; failed=0; nef_new=0
done_bytes=0; t0=$SECONDS
i=0
while [ $i -lt ${#TODO[@]} ]; do
    f="${TODO[$i]}"; key="${TODO_KEY[$i]}"; d="${TODO_DATE[$i]}"; i=$((i + 1))
    name=$(basename "$f"); ext=$(ext_of "$f")
    p=100; [ "$total_bytes" -gt 0 ] && p=$(( done_bytes * 100 / total_bytes ))
    progress "$p" "Copying $i/${#TODO[@]} ($p%)  $(size_h $done_bytes) of $(size_h $total_bytes)  $(timing $t0 $done_bytes $total_bytes)  $name"
    done_bytes=$((done_bytes + ${TODO_SIZE[$((i - 1))]}))
    case "$ext" in
        NEF|JPG) dir="$DEST_ROOT/$d/$ext/.incoming" ;;  # new NEFs/JPGs wait here until renamed (+ converted)
        *)       dir="$DEST_ROOT/$d/$ext" ;;
    esac
    mkdir -p "$dir" || die "cannot create $dir"
    # Remember the event for these NEFs, in case the run is interrupted and resumed.
    [ "$ext" = "NEF" ] && [ ! -e "$dir/.event" ] && printf '%s\n' "$EVENT" > "$dir/.event"

    # Free target name (camera counters roll over: DSC_0001 can repeat).
    # An identical file already there means it's a duplicate — don't copy it.
    stem="${name%.*}"; sfx=""; [ "$name" != "${name##*.}" ] && sfx=".${name##*.}"
    target="$dir/$name"; n=0; ok=0
    while [ -e "$target" ]; do
        if cmp -s "$f" "$target"; then ok=2; break; fi
        n=$((n + 1)); target="$dir/${stem}_$n$sfx"
    done
    if [ $ok -eq 2 ]; then
        printf '%s\n' "$key" >> "$MANIFEST"; already=$((already + 1)); continue
    fi

    if cp -p "$f" "$target" 2>/dev/null; then
        if [ "$VERIFY_BYTES" -eq 1 ]; then
            cmp -s "$f" "$target" && ok=1
        else
            [ "$(file_size "$target")" = "$(file_size "$f")" ] && ok=1
        fi
    fi
    if [ $ok -eq 1 ]; then
        printf '%s\n' "$key" >> "$MANIFEST"
        copied=$((copied + 1))
        [ "$ext" = "NEF" ] && nef_new=$((nef_new + 1))
    else
        rm -f "$target"
        progress_end; echo "FAIL  copy $f" >&2
        failed=$((failed + 1))
    fi
done
progress_end
log "Copied $copied file(s) ($nef_new NEF) in $(hms $((SECONDS - t0))), $failed failed."

# Every date folder gets an empty prod/ next to NEF/ and DNG/; an existing one is left alone.
for day in $DATES; do
    [ -d "$DEST_ROOT/$day" ] || continue
    [ -d "$DEST_ROOT/$day/prod" ] && continue
    if mkdir -p "$DEST_ROOT/$day/prod"; then
        log "Created  $day/prod/"
    else
        echo "FAIL  could not create $DEST_ROOT/$day/prod" >&2
        failed=$((failed + 1))
    fi
done

# ---------- 3 + 4. per date folder: rename, drop duplicates, convert, file ---
shopt -s nullglob
converted=0; conv_failed=0; dupes=0; jpg_dupes=0; nef_zipped=0

next_serial() {   # $1 = DNG dir, $2 = prefix; highest existing NNNNN, plus one
    local max=0 f n
    for f in "$1/$2"-[0-9][0-9][0-9][0-9][0-9].[Dd][Nn][Gg]; do
        n="${f##*-}"; n="${n%.*}"; n=$((10#$n))
        [ "$n" -gt "$max" ] && max=$n
    done
    echo $((max + 1))
}

file_photo() {    # $1 = NEF/JPG in .incoming, $2 = its final dir; move it (and any sidecar) out
    local src="$1" nd="$2" base t n=0 side dest_stem="${3:-}"
    base=$(basename "$src"); t="$nd/$base"
    if [ -n "$dest_stem" ]; then
        t="$nd/$dest_stem.${base##*.}"
    else
        while [ -e "$t" ]; do n=$((n + 1)); t="$nd/${base%.*}_$n.${base##*.}"; done
    fi
    mv -n "$src" "$t"
    for side in "$src.xmp" "$src.XMP" "${src%.*}.xmp" "${src%.*}.XMP"; do
        [ -e "$side" ] && mv -n "$side" "$nd/"
    done
}

is_duplicate() {  # $1 = renamed NEF/JPG in .incoming, $2 = its final dir
    # Also check timestamp-only names from archives created before camera naming.
    local f="$1" nd="$2" stem root camera_time c
    stem=$(basename "$f"); stem="${stem%.*}"
    root=$(printf '%s' "$stem" | sed 's/_[1-9][0-9]\{0,2\}$//')
    for c in "$nd/$root".* "$nd/${root}"_[1-9]*.*; do
        cmp -s "$f" "$c" && return 0
    done
    if [ "$CAMERA_NAME" -eq 1 ]; then
        camera_time="${root:0:14}"
        for c in "$nd/$camera_time"*; do
            cmp -s "$f" "$c" && return 0
        done
    fi
    return 1
}

run_rename() {    # $1 = .incoming dir, $2 = file count, then any rename_nef.sh options
    local inc="$1" total="$2" n=0 line
    shift 2
    bash "$RENAME_NEF" "$@" "$inc" 2>&1 | while IFS= read -r line; do
        case "$line" in
            "OK "*)       n=$((n + 1)); progress $(( n * 100 / total )) "          renaming... $n/$total" ;;
            FAIL*|SKIP*)  progress_end; echo "          $line" >&2 ;;
            Renamed:*)    progress_end; echo "          $line" ;;
        esac
    done
}

restore_nef_zip() { # $1 = YYYYMMDD; unpack an earlier NEF.zip so new NEFs are checked against it
    local day="$1" dir="$DEST_ROOT/$day"
    [ "$COMPRESS_NEF" -eq 1 ] && [ -f "$dir/NEF.zip" ] || return 0
    log "$day: unpacking NEF.zip..."
    unzip -q -n "$dir/NEF.zip" -d "$dir" && return 0
    echo "FAIL  could not unpack $day/NEF.zip" >&2
    return 1
}

compress_nef() {  # $1 = YYYYMMDD; zip NEF/ into NEF.zip, test it, then remove NEF/
    local day="$1" dir="$DEST_ROOT/$day" tmp=".NEF.tmp.zip"
    [ -d "$dir/NEF" ] && [ ! -d "$dir/NEF/.incoming" ] || return 0   # nothing, or NEFs still waiting
    [ -n "$(find "$dir/NEF" -type f | head -n 1)" ] || return 0
    log "$day: compressing NEF/ to NEF.zip..."
    rm -f "$dir/$tmp"
    if (cd "$dir" && zip -r -q "$tmp" NEF) && unzip -tq "$dir/$tmp" >/dev/null 2>&1 \
       && mv -f "$dir/$tmp" "$dir/NEF.zip"; then
        rm -rf "$dir/NEF"
        nef_zipped=$((nef_zipped + 1))
    else
        rm -f "$dir/$tmp"
        echo "WARN  could not compress $day/NEF (left as is)" >&2
    fi
    return 0
}

process_jpgs() {  # $1 = YYYYMMDD; rename new JPGs to capture time and file them in JPG/
    local day="$1" jd inc jpgs f
    jd="$DEST_ROOT/$day/JPG"; inc="$jd/.incoming"
    jpgs=( "$inc"/*.[Jj][Pp][Gg] )
    [ ${#jpgs[@]} -gt 0 ] || { rmdir "$inc" 2>/dev/null; return 0; }

    log ""
    log "$day: renaming ${#jpgs[@]} JPG(s) to capture time..."
    if [ "$CAMERA_NAME" -eq 1 ]; then
        run_rename "$inc" "${#jpgs[@]}" -m -e jpg
    else
        run_rename "$inc" "${#jpgs[@]}" -e jpg
    fi

    jpgs=( "$inc"/*.[Jj][Pp][Gg] )
    for f in "${jpgs[@]}"; do
        if is_duplicate "$f" "$jd"; then
            log "          duplicate of an existing photo, skipped: $(basename "$f")"
            rm -f "$f"; jpg_dupes=$((jpg_dupes + 1))
        else
            file_photo "$f" "$jd"
        fi
    done
    rmdir "$inc" 2>/dev/null
    return 0
}

process_date() {  # $1 = YYYYMMDD
    local day="$1" nd dd inc din ev nefs f j base stem dng c dt prefix cur_prefix serial camera_stem out rights_ok t0 made total
    nd="$DEST_ROOT/$day/NEF"; inc="$nd/.incoming"
    dd="$DEST_ROOT/$day/DNG"; din="$dd/.incoming"
    nefs=( "$inc"/*.[Nn][Ee][Ff] )
    [ ${#nefs[@]} -gt 0 ] || { rm -f "$inc/.event"; rmdir "$inc" 2>/dev/null; return 0; }

    restore_nef_zip "$day" || { failed=$((failed + 1)); return 0; }

    ev="$EVENT"
    [ -s "$inc/.event" ] && ev=$(head -n 1 "$inc/.event")

    log ""
    log "$day: renaming ${#nefs[@]} NEF(s) to capture time..."
    if [ "$CAMERA_NAME" -eq 1 ]; then
        run_rename "$inc" "${#nefs[@]}" -m
    else
        run_rename "$inc" "${#nefs[@]}"
    fi

    # Drop any NEF that is byte-identical to one already imported.
    nefs=( "$inc"/*.[Nn][Ee][Ff] )
    for f in "${nefs[@]}"; do
        if is_duplicate "$f" "$nd"; then
            log "          duplicate of an existing photo, skipped: $(basename "$f")"
            rm -f "$f"; dupes=$((dupes + 1))
        fi
    done
    nefs=( "$inc"/*.[Nn][Ee][Ff] )        # sorted = capture order after renaming
    [ ${#nefs[@]} -gt 0 ] || { rm -f "$inc/.event"; rmdir "$inc" 2>/dev/null; return 0; }

    if [ "$SKIP_DNG" -eq 1 ]; then
        for f in "${nefs[@]}"; do file_photo "$f" "$nd"; done
    else
        log "$day: converting ${#nefs[@]} NEF(s) to DNG ($ev)..."
        rm -rf "$din"; mkdir -p "$din" || die "cannot create $din"
        t0=$SECONDS; j=0
        while [ $j -lt ${#nefs[@]} ]; do         # one converter launch per batch
            # Run in the background and count the DNGs as they appear.
            # shellcheck disable=SC2086
            "$DNG_CONVERTER" $DNG_OPTS -d "$din" "${nefs[@]:$j:$DNG_BATCH}" >/dev/null 2>&1 &
            CONV_PID=$!
            while kill -0 "$CONV_PID" 2>/dev/null; do
                made=( "$din"/*.[Dd][Nn][Gg] )
                progress $(( ${#made[@]} * 100 / ${#nefs[@]} )) \
                    "          converting... ${#made[@]}/${#nefs[@]}  $(timing $t0 ${#made[@]} ${#nefs[@]})"
                sleep 1
            done
            wait "$CONV_PID"; CONV_PID=""
            j=$((j + DNG_BATCH))
        done
        progress_end
        log "          converted in $(hms $((SECONDS - t0)))"

        exiftool -q -q -m -f -ext nef -d '%Y%m%d' -p '$FileName	$DateTimeOriginal' "$inc" \
            > "$WORK/dates" 2>/dev/null

        # Copyright goes in before filing, so a failure leaves the NEFs to retry.
        rights_ok=1
        if [ -n "$COPYRIGHT_OWNER" ]; then
            : > "$WORK/rights.args"
            for f in "${nefs[@]}"; do
                base=$(basename "$f"); stem="${base%.*}"
                for c in "$din/$stem.dng" "$din/$stem.DNG"; do
                    [ -e "$c" ] || continue
                    dt=$(awk -F'\t' -v n="$base" '$1 == n {print $2; exit}' "$WORK/dates")
                    is_ymd "$dt" || dt="$day"
                    [ -s "$WORK/rights.args" ] && echo "-execute" >> "$WORK/rights.args"
                    printf '%s\n' "-MWG:Copyright=© ${dt:0:4} $COPYRIGHT_OWNER" "$c" \
                        >> "$WORK/rights.args"
                    break   # on a case-insensitive disk .dng and .DNG are the same file
                done
            done
            if [ -s "$WORK/rights.args" ]; then
                log "$day: writing copyright ($COPYRIGHT_OWNER)..."
                # -echo3 prints one line as each file is finished, for the status line.
                total=$(grep -c '^-MWG:Copyright=' "$WORK/rights.args")
                exiftool -@ "$WORK/rights.args" -common_args -q -q -m -overwrite_original \
                         -MWG:Creator="$COPYRIGHT_OWNER" -XMP-xmpRights:Marked=True -echo3 . \
                         2>/dev/null | {
                    n=0
                    while IFS= read -r _; do
                        n=$((n + 1)); progress $(( n * 100 / total )) "          writing copyright... $n/$total"
                    done
                }
                [ "${PIPESTATUS[0]}" -eq 0 ] || rights_ok=0
                progress_end
            fi
            [ "$rights_ok" -eq 1 ] || echo "FAIL  could not write copyright to $day's DNGs (re-run to retry)" >&2
        fi

        cur_prefix=""; serial=0
        for f in "${nefs[@]}"; do
            [ "$rights_ok" -eq 1 ] || { conv_failed=$((conv_failed + 1)); continue; }
            base=$(basename "$f"); stem="${base%.*}"; dng=""
            for c in "$din/$stem.dng" "$din/$stem.DNG"; do [ -e "$c" ] && dng="$c"; done
            if [ -z "$dng" ]; then
                echo "FAIL  DNG conversion: $day/NEF/.incoming/$base (re-run to retry)" >&2
                conv_failed=$((conv_failed + 1)); continue
            fi
            dt=$(awk -F'\t' -v n="$base" '$1 == n {print $2; exit}' "$WORK/dates")
            is_ymd "$dt" || dt="$day"
            if [ "$CAMERA_NAME" -eq 1 ]; then
                camera_stem="$stem"
                serial=1
                while [ -e "$dd/$camera_stem.dng" ] || [ -e "$nd/$camera_stem.${f##*.}" ]; do
                    camera_stem="${stem}_$serial"
                    serial=$((serial + 1))
                done
                out="$dd/$camera_stem.dng"
            else
                prefix="$dt-$ev"
                # Continue from the highest number already there (e.g. an earlier card).
                if [ "$prefix" != "$cur_prefix" ]; then cur_prefix="$prefix"; serial=$(next_serial "$dd" "$prefix"); fi
                out=$(printf '%s/%s-%05d.dng' "$dd" "$prefix" "$serial")
                while [ -e "$out" ]; do serial=$((serial + 1)); out=$(printf '%s/%s-%05d.dng' "$dd" "$prefix" "$serial"); done
            fi
            if mv -n "$dng" "$out" && [ -e "$out" ] && [ ! -e "$dng" ]; then
                serial=$((serial + 1)); converted=$((converted + 1))
                if [ "$CAMERA_NAME" -eq 1 ]; then
                    file_photo "$f" "$nd" "$camera_stem"
                else
                    file_photo "$f" "$nd"
                fi
            else
                echo "FAIL  could not file $dng" >&2
                conv_failed=$((conv_failed + 1))
            fi
        done
        rm -rf "$din"
    fi
    nefs=( "$inc"/*.[Nn][Ee][Ff] )
    if [ ${#nefs[@]} -eq 0 ]; then rm -f "$inc/.event"; rmdir "$inc" 2>/dev/null; fi
    return 0
}

for day in $DATES; do
    process_jpgs "$day"; process_date "$day"
    [ "$COMPRESS_NEF" -eq 1 ] && [ "$SKIP_DNG" -eq 0 ] && compress_nef "$day"
done
log ""
[ "$SKIP_DNG" -eq 0 ] && log "Converted $converted NEF(s) to DNG, $conv_failed failed."
[ "$nef_zipped" -gt 0 ] && log "Compressed $nef_zipped NEF folder(s) to NEF.zip."
[ "$dupes" -gt 0 ] && log "Dropped $dupes duplicate NEF(s)."
[ "$jpg_dupes" -gt 0 ] && log "Dropped $jpg_dupes duplicate JPG(s)."

# ---------- 5. wrap up --------------------------------------------------------
log ""
log "Done in $(hms $SECONDS)."
for day in $DATES; do
    [ -d "$DEST_ROOT/$day" ] || continue
    line=""
    for sub in "$DEST_ROOT/$day"/*/; do
        c=$(find "$sub" -maxdepth 1 -type f ! -name '.*' | wc -l | tr -d ' ')
        line="$line  $(basename "$sub")/ $c"
    done
    log "  $day:$line"
done

if [ "$failed" -gt 0 ] || [ "$conv_failed" -gt 0 ]; then
    log ""
    log "Some files had problems (see FAIL lines above). The card was NOT ejected."
    exit 2
fi

if [ "$EJECT" -eq 1 ]; then
    diskutil eject "$SOURCE" >/dev/null 2>&1 && log "Ejected $SOURCE" || log "Could not eject $SOURCE — eject it in Finder."
fi
exit 0
