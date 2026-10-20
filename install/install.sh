#!/usr/bin/env bash
#
# install.sh — copy the photo-tools scripts into /usr/local/bin.
#
# Installs every *.sh in the repository's tool directories (workflow/, ...)
# with mode 755: everyone can read and run them, only the owner can modify
# them. sudo is used only when the destination isn't writable by you.
#
# Usage:
#   install/install.sh [-n] [-d DEST]
#     -n       dry run: show what would be installed, change nothing
#     -d DEST  install somewhere else (default: /usr/local/bin)
#
# Re-run after pulling updates; installed copies are replaced.
# Works with the stock macOS bash 3.2.

set -u

DEST="/usr/local/bin"
DRY_RUN=0

usage() { sed -n '/^# Usage:/,/^# Re-run/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d' >&2; exit 1; }
die()   { echo "Error: $*" >&2; exit 1; }
run()   { if [ "$DRY_RUN" -eq 1 ]; then echo "WOULD $*"; else "$@"; fi; }

while getopts ":nd:h" opt; do
    case "$opt" in
        n) DRY_RUN=1 ;;
        d) DEST="${OPTARG%/}" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || usage
[ -n "$DEST" ] || die "destination is empty."

REPO=$(cd "$(dirname "$0")/.." && pwd)

# Tool scripts live one level down: <repo>/<tool-dir>/<script>.sh
SCRIPTS=()
while IFS= read -r f; do
    SCRIPTS+=("$f")
done < <(find "$REPO" -mindepth 2 -maxdepth 2 -type f -name '*.sh' \
              ! -path "$REPO/install/*" ! -path "$REPO/.*" | sort)
[ ${#SCRIPTS[@]} -gt 0 ] || die "no scripts found in $REPO."

# Everything lands in one directory, so names must be unique across tool dirs.
dupes=$(for f in "${SCRIPTS[@]}"; do basename "$f"; done | sort | uniq -d)
[ -z "$dupes" ] || die "these names exist in more than one tool directory and would overwrite each other:
$dupes"

# Need sudo if the destination (or, if missing, its nearest existing parent) isn't writable.
SUDO=""
p="$DEST"; while [ ! -d "$p" ]; do p=$(dirname "$p"); done
[ -w "$p" ] || SUDO="sudo"

if [ -n "$SUDO" ] && [ "$DRY_RUN" -eq 0 ]; then
    echo "$DEST needs administrator access; you may be asked for your password."
fi

run $SUDO mkdir -p "$DEST" || die "cannot create $DEST"

installed=0
for f in "${SCRIPTS[@]}"; do
    name=$(basename "$f")
    if run $SUDO install -m 0755 "$f" "$DEST/$name"; then
        [ "$DRY_RUN" -eq 1 ] || echo "Installed  ${f#"$REPO"/} -> $DEST/$name"
        installed=$((installed + 1))
    else
        die "could not install $name"
    fi
done

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry run complete — nothing was changed."
else
    echo "Installed $installed script(s) to $DEST."
fi

case ":$PATH:" in
    *":$DEST:"*) ;;
    *) echo "Note: $DEST is not in your PATH. Add it to run the tools by name." ;;
esac
