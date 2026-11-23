#!/usr/bin/env bash
#
# phototools_archive_container.sh — move every blob in a named Azure Blob container to the
#                        Archive access tier, to save storage costs.
#
#   SAFETY   Nothing is changed by default. The tool shows what it found, then
#            asks once before acting (it needs a terminal to ask on). Use -y to
#            skip the question, or -n to only report.
#   ARCHIVE  Blobs are moved to the Archive access tier (cheapest storage;
#            reading a blob again takes hours and has a 180 day minimum
#            charge). Blobs already archived are skipped, as are blob types
#            that cannot be archived (only block blobs can).
#
# Usage:
#   phototools_archive_container.sh [-a ACCOUNT] -c CONTAINER [-n | -y] [-l]
#                        [-I user|sp] [-i APP_ID] [-z TENANT] [-K PEM] [-v]
#
#   -a ACCOUNT    storage account name (default: $PHOTO_AZ_ACCOUNT)
#   -c CONTAINER  the container to archive (required)
#   -n            dry run: report folders and counts, change nothing
#   -y            do not ask; archive right away
#   -l            list every blob (not just the counts per folder)
#   -I user|sp    Azure identity (default: $PHOTO_AZ_AUTH, else user)
#   -i APP_ID     service principal app ID (default: $PHOTO_AZ_CLIENT_ID, else $AZURE_CLIENT_ID)
#   -z TENANT     tenant ID (default: $PHOTO_AZ_TENANT_ID, else $AZURE_TENANT_ID)
#   -K PEM        service principal certificate (default: $PHOTO_AZ_CERT_PATH,
#                 else $AZURE_CLIENT_CERTIFICATE_PATH)
#   -v            show the Azure CLI commands being run (default: off)
#
#   Sign-in is the same as upload_azure.sh: your 'az login', or a service
#   principal (-I sp). Client secrets come from PHOTO_AZ_CLIENT_SECRET,
#   AZURE_CLIENT_SECRET, or the macOS Keychain (service PHOTO_AZ_KEYCHAIN_SERVICE,
#   default photo-tools-azure); they cannot be passed on the command line.
#   The identity needs the 'Storage Blob Data Contributor' role.
#
# Environment:
#   PHOTO_AZ_ACCOUNT, PHOTO_AZ_AUTH, PHOTO_AZ_CLIENT_ID, PHOTO_AZ_TENANT_ID,
#   PHOTO_AZ_CERT_PATH, PHOTO_AZ_CLIENT_SECRET, PHOTO_AZ_KEYCHAIN_SERVICE
#   (client ID, tenant, certificate and secret also fall back to their AZURE_* names)
#
# Exit status: 0 done (or nothing to do, or not confirmed), 2 some blobs could
# not be archived, 1 error.
#
# Requires: Azure CLI, Python 3.
# Works with the stock macOS bash 3.2.

set -u

ACCOUNT="${PHOTO_AZ_ACCOUNT:-}"
AUTH="${PHOTO_AZ_AUTH:-user}"
CLIENT_ID="${PHOTO_AZ_CLIENT_ID:-${AZURE_CLIENT_ID:-}}"
TENANT_ID="${PHOTO_AZ_TENANT_ID:-${AZURE_TENANT_ID:-}}"
CERT_PATH="${PHOTO_AZ_CERT_PATH:-${AZURE_CLIENT_CERTIFICATE_PATH:-}}"
KEYCHAIN_SERVICE="${PHOTO_AZ_KEYCHAIN_SERVICE:-photo-tools-azure}"
CONTAINER=""
DRY_RUN=0
FORCE=0
LIST=0
VERBOSE=0

usage() { sed -n '/^# Usage:/,/^# Environment/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d' >&2; exit 1; }
die() { echo "Error: $*" >&2; exit 1; }

while getopts ":a:c:nylvhI:i:z:K:" opt; do
    case "$opt" in
        a) ACCOUNT="$OPTARG" ;;
        c) CONTAINER="$OPTARG" ;;
        n) DRY_RUN=1 ;;
        y) FORCE=1 ;;
        l) LIST=1 ;;
        v) VERBOSE=1 ;;
        I) AUTH="$OPTARG" ;;
        i) CLIENT_ID="$OPTARG" ;;
        z) TENANT_ID="$OPTARG" ;;
        K) CERT_PATH="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || usage

[ -n "$ACCOUNT" ] || die "storage account is required; pass -a or set PHOTO_AZ_ACCOUNT."
case "$ACCOUNT" in *[!a-z0-9]*) die "invalid storage account name '$ACCOUNT'." ;; esac
if [ "${#ACCOUNT}" -lt 3 ] || [ "${#ACCOUNT}" -gt 24 ]; then
    die "storage account names must be 3–24 lowercase letters or digits."
fi
[ -n "$CONTAINER" ] || die "container is required; pass -c."
case "$CONTAINER" in
    *[!a-z0-9-]*|-*|*-|*--*) die "'$CONTAINER' is not a valid container name." ;;
esac
[ "${#CONTAINER}" -ge 3 ] && [ "${#CONTAINER}" -le 63 ] || die "'$CONTAINER' is not a valid container name (3-63 characters)."
case "$AUTH" in user|sp) ;; *) die "-I must be 'user' or 'sp', got '$AUTH'." ;; esac
if [ "$AUTH" = "sp" ]; then
    missing=""
    [ -n "$CLIENT_ID" ] || missing="$missing
  app (client) ID: -i, PHOTO_AZ_CLIENT_ID or AZURE_CLIENT_ID"
    [ -n "$TENANT_ID" ] || missing="$missing
  tenant ID:       -z, PHOTO_AZ_TENANT_ID or AZURE_TENANT_ID"
    [ -z "$missing" ] || die "service principal sign-in (-I sp) needs:$missing"
fi

command -v az >/dev/null 2>&1 || die "Azure CLI (az) is required."
command -v python3 >/dev/null 2>&1 || die "Python 3 is required."

AZ_DIR=""
cleanup() { [ -z "$AZ_DIR" ] || rm -rf "$AZ_DIR"; }
trap cleanup EXIT

if [ "$AUTH" = "sp" ]; then
    SECRET=""
    if [ -n "$CERT_PATH" ]; then
        case "$CERT_PATH" in /*) ;; *) CERT_PATH="$PWD/$CERT_PATH" ;; esac
        if [ ! -f "$CERT_PATH" ] || [ ! -r "$CERT_PATH" ]; then
            die "certificate '$CERT_PATH' not found or not readable."
        fi
    elif [ -n "${PHOTO_AZ_CLIENT_SECRET:-}" ]; then
        SECRET="$PHOTO_AZ_CLIENT_SECRET"
    elif [ -n "${AZURE_CLIENT_SECRET:-}" ]; then
        SECRET="$AZURE_CLIENT_SECRET"
    else
        SECRET=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$CLIENT_ID" -w 2>/dev/null || true)
        [ -n "$SECRET" ] || die "no credential for service principal $CLIENT_ID. Provide a certificate with -K, PHOTO_AZ_CERT_PATH or AZURE_CLIENT_CERTIFICATE_PATH; a client secret with PHOTO_AZ_CLIENT_SECRET or AZURE_CLIENT_SECRET; or a Keychain item (service '$KEYCHAIN_SERVICE')."
    fi

    AZ_DIR=$(mktemp -d "${TMPDIR:-/tmp}/photo-archive-az.XXXXXX") || die "cannot create a temporary Azure CLI profile."
    chmod 700 "$AZ_DIR"
    export AZURE_CONFIG_DIR="$AZ_DIR"
    if [ -n "$CERT_PATH" ]; then
        az login --service-principal -u "$CLIENT_ID" --tenant "$TENANT_ID" \
            --certificate "$CERT_PATH" --allow-no-subscriptions -o none 2>"$AZ_DIR/login.err"
    else
        az login --service-principal -u "$CLIENT_ID" --tenant "$TENANT_ID" \
            -p "$SECRET" --allow-no-subscriptions -o none 2>"$AZ_DIR/login.err"
    fi || {
        echo "Error: service principal sign-in failed:" >&2
        sed -e '/^[[:space:]]*$/d' "$AZ_DIR/login.err" | head -n 5 | sed 's/^/  /' >&2
        exit 1
    }
fi

HAVE_TTY=0; [ -t 0 ] && HAVE_TTY=1

# The Python code is passed with -c so that stdin stays free for the question.
PY=""
read -r -d '' PY <<'PY' || true
import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

ACCOUNT, CONTAINER, DRY_RUN, FORCE, LIST, VERBOSE, HAVE_TTY = sys.argv[1:]
DRY_RUN, FORCE, LIST, VERBOSE, HAVE_TTY = (
    value == "1" for value in (DRY_RUN, FORCE, LIST, VERBOSE, HAVE_TTY)
)
WORKERS = 8


def run_az(*args):
    command = ["az", *args]
    if VERBOSE:
        print("verbose: " + " ".join(command), file=sys.stderr)
    return subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def az_json(*args):
    result = run_az(*args, "--output", "json")
    if result.returncode:
        if result.stderr:
            sys.stderr.write(result.stderr)
        raise RuntimeError("Azure CLI command failed.")
    try:
        return json.loads(result.stdout)
    except ValueError as error:
        raise RuntimeError("Azure CLI returned invalid JSON.") from error


def properties_of(blob):
    properties = blob.get("properties") or {}
    size = properties.get("contentLength", properties.get("content_length", blob.get("contentLength", 0)))
    tier = properties.get("blobTier", properties.get("blob_tier", properties.get("accessTier", properties.get("access_tier", ""))))
    kind = properties.get("blobType", properties.get("blob_type", blob.get("blobType", "BlockBlob")))
    return int(size or 0), tier or "", kind or "BlockBlob"


def split_name(name):
    folder, _, base = name.rpartition("/")
    return folder, base


def classify(blobs):
    """Return blobs to archive, already archived names, and non-block blob names."""
    planned, archived, unsupported = [], [], []
    for blob in blobs:
        name = blob.get("name", "")
        size, tier, kind = properties_of(blob)
        if kind.lower() != "blockblob":
            unsupported.append(name)
        elif tier.lower() == "archive":
            archived.append(name)
        else:
            planned.append((name, size))
    return planned, archived, unsupported


def gigabytes(size_bytes):
    return size_bytes / 1_000_000_000


def archive_one(name):
    result = run_az(
        "storage", "blob", "set-tier", "--account-name", ACCOUNT, "--container-name", CONTAINER,
        "--name=" + name, "--tier", "Archive", "--auth-mode", "login", "--only-show-errors",
    )
    return result.returncode == 0, result.stderr.strip()


def main():
    print("Archive container: {}/{}{}".format(ACCOUNT, CONTAINER, " (dry run)" if DRY_RUN else ""))
    plan, archived, unsupported = classify(az_json(
        "storage", "blob", "list", "--account-name", ACCOUNT, "--container-name", CONTAINER,
        "--auth-mode", "login", "--num-results", "*"))
    print("")
    if plan:
        folders = {}
        for name, size in plan:
            row = folders.setdefault(split_name(name)[0], [0, 0])
            row[0] += 1
            row[1] += size
        print("  {:<52} {:>8} {:>10}".format("Folder", "Blobs", "Size (GB)"))
        for folder in sorted(folders):
            row = folders[folder]
            print("  {:<52} {:>8} {:>10.3f}".format(folder or "(container root)", row[0], gigabytes(row[1])))
        if LIST:
            for name, size in sorted(plan):
                print("    {} ({:.3f} GB)".format(name, gigabytes(size)))
    else:
        print("  nothing to archive")
    if LIST:
        for name in sorted(archived):
            print("    {} (already in Archive tier, skipped)".format(name))
        for name in sorted(unsupported):
            print("    {} (skipped, not a block blob)".format(name))

    total_bytes = sum(size for _, size in plan)
    print("")
    print("Total: {} blob(s), {:.3f} GB to archive".format(len(plan), gigabytes(total_bytes)))
    print("Already in the Archive tier (skipped): {}".format(len(archived)))
    print("Blobs that cannot be archived (skipped): {}".format(len(unsupported)))
    if not plan:
        return 0
    if DRY_RUN:
        print("Dry run: nothing was changed.")
        return 0

    if not FORCE:
        if not HAVE_TTY:
            print("Error: nothing was changed. There is no terminal to ask on; run again with -y to archive.",
                  file=sys.stderr)
            return 1
        question = "Move {} blob(s) ({:.3f} GB) in '{}' to the Archive tier? They take hours to read again. [y/N] "
        try:
            answer = input(question.format(len(plan), gigabytes(total_bytes), CONTAINER))
        except EOFError:
            answer = ""
        if answer.strip().lower() not in ("y", "yes"):
            print("Cancelled; nothing was changed.")
            return 0

    failures = []
    done = 0
    step = -1
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        results = pool.map(lambda item: archive_one(item[0]), plan)
        for (name, _), (ok, error) in zip(plan, results):
            done += 1
            if not ok:
                failures.append((name, error))
            if done * 10 // len(plan) != step:
                step = done * 10 // len(plan)
                print("  {}/{} processed".format(done, len(plan)), flush=True)
    print("Archived {} blob(s).".format(len(plan) - len(failures)))
    if failures:
        print("Failed: {} blob(s):".format(len(failures)), file=sys.stderr)
        for name, error in failures:
            print("  {}/{}: {}".format(CONTAINER, name, error.splitlines()[-1] if error else "unknown error"), file=sys.stderr)
        return 2
    return 0


try:
    sys.exit(main())
except (OSError, RuntimeError, ValueError, KeyError) as error:
    print("Error: {}".format(error), file=sys.stderr)
    sys.exit(1)
PY

python3 -c "$PY" "$ACCOUNT" "$CONTAINER" "$DRY_RUN" "$FORCE" "$LIST" "$VERBOSE" "$HAVE_TTY"
