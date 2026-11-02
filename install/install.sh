#!/usr/bin/env bash
#
# install.sh — install the prerequisites, then copy the photo-tools scripts
#              into /usr/local/bin.
#
# First runs tools/prereqs.sh, which installs anything missing (exiftool,
# Adobe DNG Converter, Azure CLI, azcopy and jq) with Homebrew; stops if that
# fails.
#
# Then installs every *.sh in the repository's tool directories (workflow/,
# cloud/, tools/, ...) with mode 755: everyone can read and run them, only the owner can modify
# them. sudo is used only when the destination isn't writable by you.
#
# Usage:
#   install/install.sh [-n] [-v] [-d DEST]
#     -n       dry run: report missing prerequisites and show what would be
#              installed, change nothing
#     -v       verbose: show the scripts found, the commands run and why sudo
#              is (or is not) used (default: off)
#     -d DEST  install somewhere else (default: /usr/local/bin)
#
# Re-run after pulling updates; installed copies are replaced.
# Works with the stock macOS bash 3.2.

set -u

DEST="/usr/local/bin"
DRY_RUN=0
VERBOSE=0

usage() { sed -n '/^# Usage:/,/^# Re-run/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d' >&2; exit 1; }
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

REPO=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$REPO/cloud/upload_azure.sh" ] || die "required script cloud/upload_azure.sh not found."

# Tool scripts live one level down: <repo>/<tool-dir>/<script>.sh
SCRIPTS=()
while IFS= read -r f; do
    SCRIPTS+=("$f")
done < <(find "$REPO" -mindepth 2 -maxdepth 2 -type f -name '*.sh' \
              ! -path "$REPO/install/*" ! -path "$REPO/.*" | sort)
[ ${#SCRIPTS[@]} -gt 0 ] || die "no scripts found in $REPO."
vlog "repository: $REPO; destination: $DEST; dry run: $DRY_RUN"
for f in "${SCRIPTS[@]}"; do vlog "found ${f#"$REPO"/}"; done

# Everything lands in one directory, so names must be unique.
dupes=$(for f in "${SCRIPTS[@]}"; do basename "$f"; done | sort | uniq -d)
[ -z "$dupes" ] || die "these names exist in more than one tool directory and would overwrite each other:
$dupes"

echo "Checking prerequisites..."
PREREQ_OPTS=""; [ "$DRY_RUN" -eq 0 ] || PREREQ_OPTS="-n"; [ "$VERBOSE" -eq 0 ] || PREREQ_OPTS="$PREREQ_OPTS -v"
vlog "running: bash $REPO/tools/prereqs.sh$([ -z "$PREREQ_OPTS" ] || echo " $PREREQ_OPTS")"
if [ "$DRY_RUN" -eq 1 ]; then
    # shellcheck disable=SC2086
    bash "$REPO/tools/prereqs.sh" $PREREQ_OPTS
else
    # shellcheck disable=SC2086
    bash "$REPO/tools/prereqs.sh" $PREREQ_OPTS || die "prerequisites are not ready (see above). Fix them and re-run."
fi
echo ""

# Need sudo if the destination (or, if missing, its nearest existing parent) isn't writable.
SUDO=""
p="$DEST"; while [ ! -d "$p" ]; do p=$(dirname "$p"); done
[ -w "$p" ] || SUDO="sudo"
if [ -n "$SUDO" ]; then vlog "$p is not writable by you; using sudo"; else vlog "$p is writable; not using sudo"; fi

if [ -n "$SUDO" ] && [ "$DRY_RUN" -eq 0 ]; then
    echo "$DEST needs administrator access; you may be asked for your password."
fi

run $SUDO mkdir -p "$DEST" || die "cannot create $DEST"

installed=0
for f in "${SCRIPTS[@]}"; do
    name=$(basename "$f")
    vlog "installing $f -> $DEST/$name (mode 0755)"
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
