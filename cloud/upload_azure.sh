#!/usr/bin/env bash
#
# upload_azure.sh — upload photo folders to Azure Blob Storage, one container
#                   per category, with azcopy.
#
#   SIGN IN  As you (your existing `az login`), or as a service principal
#            (-I sp) with a certificate or a client secret.
#   ACCESS   By default the script creates its own short-lived user delegation
#            SAS for each container (signed with Entra ID, never with account
#            keys) and hands it to azcopy. With -A oauth, azcopy signs in
#            itself instead and renews its own tokens (best for very long runs).
#   UPLOAD   Files under each folder are uploaded to its container, keeping the
#            folder structure. NEF and ZIP files are skipped by default:
#                DIR/20261017/DNG/a.dng -> <container>/<prefix>/20261017/DNG/a.dng
#            Hidden files and folders are skipped. Blobs that are already in
#            the container are skipped, so a re-run only sends what is new.
#            Each blob gets an MD5 hash.
#   RETRY    Files that could not be uploaded are listed at the end and linked
#            from a retry folder (default DIR/.upload-retry/<container>/),
#            keeping their folder structure; retry-manifest.tsv there records
#            where each one came from and why it failed. Re-run the same
#            command with -R to upload only those files: each successful retry
#            removes its link; the original stays where it was.
#
# Usage:
#   upload_azure.sh -a ACCOUNT -u CONTAINER=DIR [-u CONTAINER=DIR ...] [options]
#
#   -a ACCOUNT    name of the Azure storage account that holds the containers:
#                 the first part of https://ACCOUNT.blob.core.windows.net,
#                 3-24 lowercase letters/digits, e.g. rpsphotography001; not
#                 a URL, resource group or container (default: $PHOTO_AZ_ACCOUNT).
#                 List yours with: az storage account list --query '[].name' -o tsv
#   -u C=DIR      upload folder DIR into container C (repeat for each category)
#   -m MAPFILE    read CONTAINER=DIR (or CONTAINER<TAB>DIR) lines from a file;
#                 blank lines and # comments are ignored
#   -p PREFIX     optional extra folder in front of everything uploaded,
#                 e.g. 2026 puts DIR/20261017/a.dng at 2026/20261017/a.dng
#   -r RETRY      retry folder root (default: $PHOTO_UPLOAD_RETRY, else
#                 DIR/.upload-retry for each DIR)
#   -R            retry mode: upload only what is in the retry folders
#   -e EXTENSIONS comma-separated filename extensions to ignore (default:
#                 $PHOTO_UPLOAD_IGNORE_EXTENSIONS, else nef,zip); -e '' ignores none
#   -I user|sp    which Azure identity signs in and uploads (default: $PHOTO_AZ_AUTH,
#                 else user):
#                   user  you: reuses your existing 'az login' sign-in. Simplest;
#                         use it when you run uploads yourself.
#                   sp    a service principal (an app identity with its own
#                         certificate or secret): signs in separately, leaving
#                         your 'az login' alone. Use it for scheduled/unattended
#                         runs or to limit access to just the photo storage.
#                         Needs -i, -z and -K or a client secret.
#                 Either one needs the 'Storage Blob Data Contributor' role.
#   -i APP_ID     service principal application (client) ID
#                 (default: $PHOTO_AZ_CLIENT_ID, else $AZURE_CLIENT_ID)
#   -z TENANT     Entra tenant ID (default: $PHOTO_AZ_TENANT_ID, else $AZURE_TENANT_ID)
#   -K PEM        service principal certificate: an unencrypted PEM file holding
#                 the private key and the certificate (default:
#                 $PHOTO_AZ_CERT_PATH, else $AZURE_CLIENT_CERTIFICATE_PATH)
#   -A sas|oauth  how azcopy is authorized: a SAS created by this script, or
#                 azcopy signing in itself (default: $PHOTO_AZ_TRANSFER, else sas)
#   -c ask|yes|no what to do when a container does not exist in the account
#                 (default: $PHOTO_AZ_CREATE_CONTAINERS, else ask):
#                   ask   ask before creating each missing container (needs a
#                         terminal; without one the script stops instead)
#                   yes   create missing containers without asking
#                   no    never create containers; stop if one is missing
#                 New containers are private (no public access). With -n
#                 nothing is created or asked; the output says which
#                 containers would be created. Creating a container needs the
#                 same 'Storage Blob Data Contributor' role. Not used with -R.
#   -t HOURS      SAS lifetime in hours, 1-167 (default 24)
#   -T TIER       blob tier: Hot, Cool, Cold or Archive (default: the account's)
#   -O            replace a blob when the local file is newer
#                 (default: never replace a blob that is already there)
#   -n            dry run: sign in and check access, show what would be
#                 uploaded, change nothing
#   -v            verbose, for debugging: show each setting and where it came
#                 from, every az/azcopy command (secrets hidden) with its exit
#                 code and time, and full error messages; azcopy logs at INFO
#                 level. Also saved to debug.log in the run folder (except -n).
#
# Environment:
#   PHOTO_AZ_ACCOUNT        storage account name, e.g. rpsphotography001 (same as -a)
#   PHOTO_AZ_AUTH           user (your az login) or sp (service principal) (same as -I)
#   PHOTO_AZ_CLIENT_ID      service principal app ID (same as -i; falls back to AZURE_CLIENT_ID)
#   PHOTO_AZ_TENANT_ID      tenant ID (same as -z; falls back to AZURE_TENANT_ID)
#   PHOTO_AZ_CERT_PATH      certificate PEM (same as -K; falls back to AZURE_CLIENT_CERTIFICATE_PATH)
#   PHOTO_AZ_CLIENT_SECRET  client secret (falls back to AZURE_CLIENT_SECRET, then
#                           the macOS Keychain). There is deliberately no option
#                           for it: command lines show up in `ps` and shell history.
#   PHOTO_AZ_KEYCHAIN_SERVICE  Keychain item holding the secret, stored with the
#                           app ID as its account (default: photo-tools-azure)
#   PHOTO_AZ_TRANSFER       sas or oauth (same as -A)
#   PHOTO_AZ_CREATE_CONTAINERS  ask, yes or no (same as -c)
#   PHOTO_UPLOAD_RETRY      retry folder root (same as -r)
#   PHOTO_UPLOAD_IGNORE_EXTENSIONS  comma-separated extensions to ignore
#                           (default: nef,zip; empty disables ignoring)
#   PHOTO_UPLOAD_LOGS       where run reports and azcopy logs go
#                           (default: ~/.photo-tools/upload-runs)
#   PHOTO_UPLOAD_VERBOSE    1 = verbose (same as -v)
#   Options given on the command line win over these.
#
# Exit status: 0 all files uploaded (or already there), 2 some files failed
# and were moved to the retry folder, 1 nothing was uploaded (error, or a
# missing container was not created).
#
# Requires: Azure CLI (brew install azure-cli), azcopy (brew install azcopy),
# jq (included with macOS 15 and later; otherwise brew install jq).
# Works with the stock macOS bash 3.2.

set -u

# ---------- settings ----------------------------------------------------------
ACCOUNT="${PHOTO_AZ_ACCOUNT:-}"
AUTH="${PHOTO_AZ_AUTH:-user}"
CLIENT_ID="${PHOTO_AZ_CLIENT_ID:-${AZURE_CLIENT_ID:-}}"
TENANT_ID="${PHOTO_AZ_TENANT_ID:-${AZURE_TENANT_ID:-}}"
CERT_PATH="${PHOTO_AZ_CERT_PATH:-${AZURE_CLIENT_CERTIFICATE_PATH:-}}"
KEYCHAIN_SERVICE="${PHOTO_AZ_KEYCHAIN_SERVICE:-photo-tools-azure}"
TRANSFER="${PHOTO_AZ_TRANSFER:-sas}"
CREATE="${PHOTO_AZ_CREATE_CONTAINERS:-ask}"
RETRY_ROOT="${PHOTO_UPLOAD_RETRY:-}"
IGNORE_EXTENSIONS="${PHOTO_UPLOAD_IGNORE_EXTENSIONS-nef,zip}"
RUNS_ROOT="${PHOTO_UPLOAD_LOGS:-$HOME/.photo-tools/upload-runs}"
case "${PHOTO_UPLOAD_VERBOSE:-0}" in 1|[Yy]*|[Tt]rue) VERBOSE=1 ;; *) VERBOSE=0 ;; esac

src_of() {        # where a setting came from: $1 = option letter, then env names
    local opt="$1" v; shift
    case "$OPTS_GIVEN" in *"$opt"*) echo "option -$opt"; return ;; esac
    for v in "$@"; do
        if printenv "$v" >/dev/null 2>&1; then echo "\$$v"; return; fi
    done
    echo "default"
}
BLOB_SUFFIX="blob.core.windows.net"
HIDDEN_RE='(^|/)\.'             # skip hidden files and anything in hidden folders
GENERAL_DIR="general"           # container folder for files directly inside DIR
SHOW_FAILS=20                   # FAIL lines printed per container; all go in the report

PREFIX=""; SAS_HOURS=24; TIER=""; OVERWRITE=0; RETRY_MODE=0; DRY_RUN=0
SPEC_LINES=""                   # CONTAINER=DIR lines from -u and -m
OPTS_GIVEN=""                   # option letters used, for the -v settings list
ERR_LINES=3                     # lines of az error output shown (all of them with -v)
DEBUG_LOG=""
exec 3>&2                       # -v output; stays on the screen even when stderr is captured

usage() { sed -n '/^# Usage:/,/^# Exit status/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d' >&2; exit 1; }
die()   { echo "Error: $*" >&2; exit 1; }
log()   { echo "$*"; }
warn()  { echo "Warning: $*" >&2; }
redact() { sed -E 's/(sig=)[^&"[:space:]]*/\1REDACTED/g'; }
vlog() {          # -v only: to the screen (fd 3) and debug.log, SAS signatures hidden
    [ "$VERBOSE" -eq 1 ] || return 0
    local line
    line=$(printf '[%s] %s' "$(date +%H:%M:%S)" "$*" | redact)
    if [ "${PROG_TTY:-0}" -eq 1 ]; then printf '\r\033[K' >&3; fi
    printf 'debug %s\n' "$line" >&3
    [ -z "$DEBUG_LOG" ] || printf '%s\n' "$line" >> "$DEBUG_LOG"
}
trace() {         # run a command; with -v log it (secrets hidden), its exit code and time
    [ "$VERBOSE" -eq 1 ] || { "$@"; return; }
    local a shown="" hide=0 t0=$SECONDS rc
    for a in "$@"; do
        if [ "$hide" -eq 1 ]; then a="<hidden>"; hide=0; fi
        case "$a" in -p|--password|--client-secret) hide=1 ;; esac
        case "$a" in *[[:space:]]*|"") a="'$a'" ;; esac
        shown="$shown $a"
    done
    vlog "run:$shown"
    "$@"; rc=$?
    vlog "    exit $rc after $((SECONDS - t0))s"
    return $rc
}
NL='
'

while getopts ":a:u:m:p:r:e:RI:i:z:K:A:c:t:T:Onvh" opt; do
    OPTS_GIVEN="$OPTS_GIVEN$opt"
    case "$opt" in
        a) ACCOUNT="$OPTARG" ;;
        u) SPEC_LINES="$SPEC_LINES$OPTARG$NL" ;;
        m) [ -r "$OPTARG" ] || die "map file '$OPTARG' not found or not readable."
           SPEC_LINES="$SPEC_LINES$(cat "$OPTARG")$NL" ;;
        p) PREFIX="$OPTARG" ;;
        r) RETRY_ROOT="$OPTARG" ;;
        e) IGNORE_EXTENSIONS="$OPTARG" ;;
        R) RETRY_MODE=1 ;;
        I) AUTH="$OPTARG" ;;
        i) CLIENT_ID="$OPTARG" ;;
        z) TENANT_ID="$OPTARG" ;;
        K) CERT_PATH="$OPTARG" ;;
        A) TRANSFER="$OPTARG" ;;
        c) CREATE="$OPTARG" ;;
        t) SAS_HOURS="$OPTARG" ;;
        T) TIER="$OPTARG" ;;
        O) OVERWRITE=1 ;;
        n) DRY_RUN=1 ;;
        v) VERBOSE=1 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || usage

# ---------- progress display (same as import_photos.sh) -----------------------
PROG_TTY=0; [ -t 1 ] && PROG_TTY=1
PROG_STEP=-1
progress() {      # $1 = percent done, $2 = status text
    if [ "$PROG_TTY" -eq 1 ]; then
        printf '\r\033[K%s' "$2"
    elif [ $(( $1 / 10 )) -ne "$PROG_STEP" ]; then
        PROG_STEP=$(( $1 / 10 )); printf '%s\n' "$2"
    fi
}
progress_end() {
    if [ "$PROG_TTY" -eq 1 ]; then printf '\r\033[K'; fi
    PROG_STEP=-1
}
hms()    { if [ "$1" -ge 3600 ]; then printf '%dh%02dm' $(($1 / 3600)) $(($1 % 3600 / 60)); else printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); fi; }
size_h() { if [ "$1" -ge 1073741824 ]; then printf '%d.%d GB' $(($1 / 1073741824)) $(($1 % 1073741824 * 10 / 1073741824)); else printf '%d MB' $(($1 / 1048576)); fi; }
timing() {
    local el=$((SECONDS - $1))
    printf '%s' "$(hms "$el")"
    if [ "$2" -gt 0 ] && [ "$2" -lt "$3" ] && [ "$el" -ge 2 ]; then
        printf ', ~%s left' "$(hms $(( el * ($3 - $2) / $2 )))"
    fi
}
utc_in() {        # $1 = minutes from now (may be negative) -> 2026-10-21T19:00Z
    local m="$1" v="+$1"
    [ "$m" -lt 0 ] && v="$m"
    date -u -v"${v}"M +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "$v min" +%Y-%m-%dT%H:%MZ
}
abs_path() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }

# ---------- validate options --------------------------------------------------
valid_container() {   # Azure rules: 3-63 chars, a-z 0-9 and single hyphens inside
    [ ${#1} -ge 3 ] && [ ${#1} -le 63 ] || return 1
    case "$1" in *[!a-z0-9-]*|-*|*-|*--*) return 1 ;; esac
    return 0
}

[ -n "$ACCOUNT" ] || { echo "Error: a storage account is required (-a or PHOTO_AZ_ACCOUNT)." >&2; usage; }
case "$ACCOUNT" in *[!a-z0-9]*) die "storage account '$ACCOUNT' may only contain lowercase letters and digits." ;; esac
[ ${#ACCOUNT} -ge 3 ] && [ ${#ACCOUNT} -le 24 ] || die "storage account '$ACCOUNT' must be 3-24 characters."

case "$AUTH" in user|sp) ;; *) die "-I must be 'user' or 'sp', got '$AUTH'." ;; esac
case "$TRANSFER" in sas|oauth) ;; *) die "-A must be 'sas' or 'oauth', got '$TRANSFER'." ;; esac
CREATE=$(printf '%s' "$CREATE" | tr '[:upper:]' '[:lower:]')
case "$CREATE" in ask|yes|no) ;; *) die "-c must be 'ask', 'yes' or 'no', got '$CREATE'." ;; esac
case "$SAS_HOURS" in ''|*[!0-9]*) die "-t must be a whole number of hours, got '$SAS_HOURS'." ;; esac
[ "$SAS_HOURS" -ge 1 ] && [ "$SAS_HOURS" -le 167 ] || die "-t must be 1-167 hours (a user delegation SAS lasts at most 7 days)."
case "$(printf '%s' "$TIER" | tr '[:upper:]' '[:lower:]')" in
    "")      ;;
    hot)     TIER=Hot ;;
    cool)    TIER=Cool ;;
    cold)    TIER=Cold ;;
    archive) TIER=Archive ;;
    *)       die "-T must be Hot, Cool, Cold or Archive, got '$TIER'." ;;
esac
while :; do case "$PREFIX" in /*) PREFIX="${PREFIX#/}" ;; */) PREFIX="${PREFIX%/}" ;; *) break ;; esac; done
case "$PREFIX" in *[!A-Za-z0-9._/-]*) die "-p may only use letters, digits, '.', '_', '-' and '/', got '$PREFIX'." ;; esac
if [ -n "$PREFIX" ]; then
    case "/$PREFIX/" in *//*|*/./*|*/../*) die "-p has an empty, '.' or '..' folder: '$PREFIX'." ;; esac
fi
IGNORE_EXTENSIONS=$(printf '%s' "$IGNORE_EXTENSIONS" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
case "$IGNORE_EXTENSIONS" in
    "" ) ;;
    ,*|*,|*,,*|*[!a-z0-9,]*) die "-e must be a comma-separated list of filename extensions (letters and digits only)." ;;
esac

if [ "$AUTH" = "sp" ]; then
    missing=""
    [ -n "$CLIENT_ID" ] || missing="$missing${NL}  app (client) ID: -i, PHOTO_AZ_CLIENT_ID or AZURE_CLIENT_ID"
    [ -n "$TENANT_ID" ] || missing="$missing${NL}  tenant ID:       -z, PHOTO_AZ_TENANT_ID or AZURE_TENANT_ID"
    [ -z "$missing" ] || die "service principal sign-in (-I sp) needs:$missing"
fi

# ---------- container -> folder list ------------------------------------------
E_C=(); E_D=(); E_R=()          # container, absolute folder, retry root
[ -z "$RETRY_ROOT" ] || RETRY_ROOT=$(abs_path "${RETRY_ROOT%/}")
while IFS= read -r line; do
    line=$(printf '%s' "$line" | tr -d '\r')
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
        *"	"*) c="${line%%	*}"; d="${line#*	}" ;;
        *=*)    c="${line%%=*}"; d="${line#*=}" ;;
        *)      die "'$line' is not CONTAINER=DIR." ;;
    esac
    c=$(printf '%s' "$c" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    d=$(printf '%s' "$d" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    # shellcheck disable=SC2088  # a literal ~ from a map file
    case "$d" in "~") d="$HOME" ;; "~/"*) d="$HOME/${d#\~/}" ;; esac
    valid_container "$c" || die "'$c' is not a valid container name (3-63 characters: lowercase letters, digits and single hyphens, starting and ending with a letter or digit)."
    [ -n "$d" ] && [ -d "$d" ] || die "folder '$d' for container '$c' not found."
    d=$(cd "$d" && pwd)
    if [ -n "$RETRY_ROOT" ]; then r="$RETRY_ROOT"; else r="$d/.upload-retry"; fi
    # A retry folder inside a source folder must be hidden, or it would be uploaded.
    case "$r/" in "$d/"*)
        case "${r#"$d"}/" in */.*) ;; *) die "retry folder '$r' is inside '$d' but not hidden; its files would be uploaded again. Use a name starting with '.' or a folder elsewhere." ;; esac ;;
    esac
    E_C+=("$c"); E_D+=("$d"); E_R+=("$r")
done <<EOF
$SPEC_LINES
EOF
[ ${#E_C[@]} -gt 0 ] || { echo "Error: name at least one CONTAINER=DIR with -u or -m." >&2; usage; }

# ---------- tools -------------------------------------------------------------
command -v az     >/dev/null 2>&1 || die "Azure CLI (az) not found. Install it with: brew install azure-cli"
command -v azcopy >/dev/null 2>&1 || die "azcopy not found. Install it with: brew install azcopy"
command -v jq     >/dev/null 2>&1 || die "jq not found. Install it with: brew install jq"
case "$(azcopy --version 2>/dev/null)" in
    *" 10."*) ;;
    *) die "azcopy version 10 is required (found: $(azcopy --version 2>&1 | head -n 1))." ;;
esac
# Warnings from az are hidden normally; with -v they are kept, with full errors.
if [ "$VERBOSE" -eq 1 ]; then ERR_LINES=1000; else export AZURE_CORE_ONLY_SHOW_ERRORS=true; fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/photo-upload.XXXXXX") || die "cannot create a temp folder"
AZ_DIR=""; SECRET=""
# shellcheck disable=SC2329  # called from the EXIT trap
cleanup() {
    local rc=$?
    vlog "exit status $rc"
    rm -rf "$WORK"; [ -z "$AZ_DIR" ] || rm -rf "$AZ_DIR"
}
trap cleanup EXIT

if [ "$VERBOSE" -eq 1 ]; then
    DEBUG_LOG="$WORK/debug.log"
    vlog "upload_azure.sh $(date '+%Y-%m-%d %H:%M:%S'), pid $$"
    vlog "tools: $(azcopy --version 2>&1 | head -n 1); az $(az version --query '"azure-cli"' -o tsv 2>/dev/null); $(jq --version 2>&1); bash $BASH_VERSION; macOS $(sw_vers -productVersion 2>/dev/null || uname -r)"
    vlog "paths: az=$(command -v az) azcopy=$(command -v azcopy) jq=$(command -v jq)"
    vlog "setting account   = $ACCOUNT  [$(src_of a PHOTO_AZ_ACCOUNT)]"
    vlog "setting auth      = $AUTH  [$(src_of I PHOTO_AZ_AUTH)]"
    if [ "$AUTH" = "sp" ]; then
        vlog "setting client id = ${CLIENT_ID:-<none>}  [$(src_of i PHOTO_AZ_CLIENT_ID AZURE_CLIENT_ID)]"
        vlog "setting tenant id = ${TENANT_ID:-<none>}  [$(src_of z PHOTO_AZ_TENANT_ID AZURE_TENANT_ID)]"
        vlog "setting cert      = ${CERT_PATH:-<none>}  [$(src_of K PHOTO_AZ_CERT_PATH AZURE_CLIENT_CERTIFICATE_PATH)]"
        vlog "setting secret    = $(if [ -n "${PHOTO_AZ_CLIENT_SECRET:-}" ]; then echo "set in \$PHOTO_AZ_CLIENT_SECRET"; elif [ -n "${AZURE_CLIENT_SECRET:-}" ]; then echo "set in \$AZURE_CLIENT_SECRET"; else echo "not in the environment (Keychain item '$KEYCHAIN_SERVICE' is tried)"; fi)"
    fi
    vlog "setting transfer  = $TRANSFER  [$(src_of A PHOTO_AZ_TRANSFER)]"
    vlog "setting create    = $CREATE  [$(src_of c PHOTO_AZ_CREATE_CONTAINERS)]"
    vlog "setting prefix    = ${PREFIX:-<none>}; SAS hours = $SAS_HOURS; tier = ${TIER:-<account default>}; overwrite = $([ "$OVERWRITE" -eq 1 ] && echo ifSourceNewer || echo false); retry mode = $RETRY_MODE; dry run = $DRY_RUN"
    vlog "setting retry     = ${RETRY_ROOT:-DIR/.upload-retry}  [$(src_of r PHOTO_UPLOAD_RETRY)]"
    vlog "setting ignored extensions = ${IGNORE_EXTENSIONS:-<none>}  [$(src_of e PHOTO_UPLOAD_IGNORE_EXTENSIONS)]"
    vlog "setting logs      = $RUNS_ROOT  [$(src_of x PHOTO_UPLOAD_LOGS)]"
    i=0
    while [ $i -lt ${#E_C[@]} ]; do
        vlog "folder  ${E_C[$i]} <- ${E_D[$i]}  (retry root ${E_R[$i]})"; i=$((i + 1))
    done
    vlog "AZURE_CONFIG_DIR=${AZURE_CONFIG_DIR:-<default ~/.azure>}"
fi
trap 'progress_end; echo ""
      echo "Interrupted. Nothing was moved to the retry folder; re-run the same command (files already uploaded are skipped)." >&2
      exit 130' INT TERM

# ---------- 1. sign in --------------------------------------------------------
login_hint() {    # $1 = file with az's error output
    case "$(cat "$1")" in
        *AADSTS7000222*|*AADSTS7000215*)
            echo "  The client secret is wrong or has expired. Create a new one with:"
            echo "    az ad sp credential reset --id $CLIENT_ID" ;;
        *AADSTS700027*|*AADSTS700024*|*[Cc]ertificate*)
            echo "  The certificate is not registered for this app, has expired, or is not a PEM with the private key."
            echo "  Register a new one with: az ad sp credential reset --id $CLIENT_ID --create-cert" ;;
        *AADSTS700016*)
            echo "  No app with ID $CLIENT_ID in tenant $TENANT_ID. Check -i and -z." ;;
        *AADSTS90002*)
            echo "  Tenant '$TENANT_ID' not found. Check -z." ;;
    esac
}

CRED_DESC=""
if [ "$AUTH" = "user" ]; then
    who=$(trace az account show --query user.name -o tsv 2>/dev/null) || \
        die "you are not signed in to the Azure CLI. Run: az login   (or use -I sp for a service principal)"
    IDENTITY="user:$who"
    CRED_DESC="your Azure CLI sign-in"
    vlog "az account: $(az account show --query '[name, id, tenantId]' -o tsv 2>/dev/null | tr '\t\n' '  ')"
else
    if [ -n "$CERT_PATH" ]; then
        CERT_PATH=$(abs_path "$CERT_PATH")
        [ -f "$CERT_PATH" ] && [ -r "$CERT_PATH" ] || die "certificate '$CERT_PATH' not found or not readable."
        perm=$(stat -f %Lp "$CERT_PATH" 2>/dev/null || stat -c %a "$CERT_PATH" 2>/dev/null)
        case "$perm" in *00) ;; *) warn "$CERT_PATH can be read by other users (mode $perm). Run: chmod 600 \"$CERT_PATH\"" ;; esac
        CRED_DESC="certificate $CERT_PATH"
    elif [ -n "${PHOTO_AZ_CLIENT_SECRET:-}" ]; then
        SECRET="$PHOTO_AZ_CLIENT_SECRET"; CRED_DESC="client secret from PHOTO_AZ_CLIENT_SECRET"
    elif [ -n "${AZURE_CLIENT_SECRET:-}" ]; then
        SECRET="$AZURE_CLIENT_SECRET"; CRED_DESC="client secret from AZURE_CLIENT_SECRET"
    else
        SECRET=$(trace security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$CLIENT_ID" -w 2>/dev/null || true)
        [ -n "$SECRET" ] || die "no credential for service principal $CLIENT_ID. Provide one of:
  a certificate:   -K PEM, PHOTO_AZ_CERT_PATH or AZURE_CLIENT_CERTIFICATE_PATH
  a client secret: PHOTO_AZ_CLIENT_SECRET or AZURE_CLIENT_SECRET
  a Keychain item: security add-generic-password -s $KEYCHAIN_SERVICE -a $CLIENT_ID -w"
        CRED_DESC="client secret from Keychain item '$KEYCHAIN_SERVICE'"
    fi

    # A private Azure CLI profile, so your own `az login` is left untouched.
    AZ_DIR=$(mktemp -d "${TMPDIR:-/tmp}/photo-upload-az.XXXXXX") || die "cannot create a temp folder"
    chmod 700 "$AZ_DIR"
    export AZURE_CONFIG_DIR="$AZ_DIR"
    log "Signing in as service principal $CLIENT_ID ($CRED_DESC)..."
    if [ -n "$CERT_PATH" ]; then
        trace az login --service-principal -u "$CLIENT_ID" --tenant "$TENANT_ID" \
                 --certificate "$CERT_PATH" --allow-no-subscriptions -o none 2> "$WORK/login.err"
    else
        trace az login --service-principal -u "$CLIENT_ID" --tenant "$TENANT_ID" \
                 -p "$SECRET" --allow-no-subscriptions -o none 2> "$WORK/login.err"
    fi || {
        echo "Error: service principal sign-in failed:" >&2
        sed -e '/^[[:space:]]*$/d' "$WORK/login.err" | head -n "$((ERR_LINES + 2))" | sed 's/^/  /' >&2
        login_hint "$WORK/login.err" >&2
        exit 1
    }
    IDENTITY="sp:$CLIENT_ID"
fi

# ---------- 2. check every container before anything is uploaded --------------
log "Account: $ACCOUNT  ($BLOB_SUFFIX)"
log "Sign-in: $IDENTITY  ($CRED_DESC)"
if [ "$TRANSFER" = "sas" ]; then
    log "Access:  user delegation SAS per container, valid $SAS_HOURS h"
else
    log "Access:  azcopy signs in itself (OAuth)"
fi
[ "$RETRY_MODE" -eq 0 ] || log "Mode:    retry (only files in the retry folders)"
log ""

# Ask whether to create a missing container ($1); 0 = go ahead.
confirm_create() {
    case "$CREATE" in
        yes) return 0 ;;
        no)  return 1 ;;
    esac
    if [ ! -t 0 ]; then
        echo "Container '$1' does not exist, and there is no terminal to ask on. Use -c yes to create it." >&2
        return 1
    fi
    local ans
    printf "Container '%s' does not exist in storage account '%s'. Create it (private)? [y/N] " "$1" "$ACCOUNT" >&2
    read -r ans || ans=""
    case "$ans" in [Yy]|[Yy][Ee][Ss]) return 0 ;; esac
    return 1
}

checked="|"
MISSING="|"                     # containers that do not exist yet (dry run only)
CREATED="|"                     # containers created by this run
i=0
while [ $i -lt ${#E_C[@]} ]; do
    c="${E_C[$i]}"; i=$((i + 1))
    case "$checked" in *"|$c|"*) continue ;; esac
    checked="$checked$c|"
    if ! out=$(trace az storage container exists --account-name "$ACCOUNT" -n "$c" --auth-mode login \
                   --query exists -o tsv 2> "$WORK/exists.err"); then
        echo "Error: cannot reach container '$c' in '$ACCOUNT' as $IDENTITY:" >&2
        sed -e '/^[[:space:]]*$/d' "$WORK/exists.err" | head -n "$ERR_LINES" | redact | sed 's/^/  /' >&2
        case "$(cat "$WORK/exists.err")" in
            *AuthorizationPermissionMismatch*|*AuthorizationFailure*|*"not authorized"*|*403*)
                echo "  $IDENTITY needs the 'Storage Blob Data Contributor' role on storage account $ACCOUNT" >&2
                echo "  (or on container $c). New role assignments can take up to 10 minutes to apply." >&2
                echo "  If the account has a firewall, your public IP must also be allowed." >&2 ;;
        esac
        exit 1
    fi
    vlog "container $c exists: $out"
    if [ "$out" != "true" ]; then
        [ "$RETRY_MODE" -eq 0 ] || die "container '$c' does not exist in storage account '$ACCOUNT', so there is nothing to retry."
        if [ "$DRY_RUN" -eq 1 ]; then
            [ "$CREATE" != "no" ] || die "container '$c' does not exist in storage account '$ACCOUNT' (-c no: not creating containers)."
            MISSING="$MISSING$c|"
            continue
        fi
        confirm_create "$c" || die "container '$c' does not exist in storage account '$ACCOUNT' and was not created. Use -c yes to create missing containers, or create it yourself first."
        if ! trace az storage container create --account-name "$ACCOUNT" -n "$c" --auth-mode login \
                 --query created -o tsv > /dev/null 2> "$WORK/exists.err"; then
            echo "Error: cannot create container '$c' in '$ACCOUNT' as $IDENTITY:" >&2
            sed -e '/^[[:space:]]*$/d' "$WORK/exists.err" | head -n "$ERR_LINES" | redact | sed 's/^/  /' >&2
            echo "  $IDENTITY needs the 'Storage Blob Data Contributor' role on storage account $ACCOUNT." >&2
            exit 1
        fi
        log "Created container '$c' in '$ACCOUNT'."
        CREATED="$CREATED$c|"
    fi
    # "exists" only needs a management role such as Owner; reading blobs needs
    # a data role, which uploads need too, so check that before uploading.
    if ! trace az storage blob list --account-name "$ACCOUNT" -c "$c" --auth-mode login \
             --num-results 1 --query '[].name' -o tsv > /dev/null 2> "$WORK/exists.err"; then
        echo "Error: $IDENTITY can see container '$c' in '$ACCOUNT' but cannot read or upload blobs:" >&2
        sed -e '/^[[:space:]]*$/d' "$WORK/exists.err" | head -n "$ERR_LINES" | redact | sed 's/^/  /' >&2
        echo "  Owner and Contributor don't include blob data access. $IDENTITY needs the" >&2
        echo "  'Storage Blob Data Contributor' role on storage account $ACCOUNT (or on container $c)." >&2
        echo "  New role assignments can take up to 10 minutes to apply." >&2
        exit 1
    fi
done

# ---------- 3. what to upload -------------------------------------------------
# One "job" per container + source folder. In retry mode the source is the
# retry folder for that container, uploaded with no prefix, because the
# retry folder already holds the full blob path.
J_C=(); J_SRC=(); J_PREFIX=(); J_R=()
i=0
while [ $i -lt ${#E_C[@]} ]; do
    c="${E_C[$i]}"; d="${E_D[$i]}"; r="${E_R[$i]}"; i=$((i + 1))
    if [ "$RETRY_MODE" -eq 1 ]; then
        src="$r/$c"
        dup=0; k=0
        while [ $k -lt ${#J_SRC[@]} ]; do [ "${J_SRC[$k]}" = "$src" ] && dup=1; k=$((k + 1)); done
        [ "$dup" -eq 0 ] || continue
        if [ ! -d "$src" ]; then log "$c: nothing to retry ($src not found)"; continue; fi
        J_C+=("$c"); J_SRC+=("$src"); J_PREFIX+=(""); J_R+=("$r")
    else
        J_C+=("$c"); J_SRC+=("$d"); J_PREFIX+=("$PREFIX"); J_R+=("$r")
    fi
done
if [ ${#J_C[@]} -eq 0 ]; then log "Nothing to do."; exit 0; fi

# $1 = folder, $2 = prefix -> "relative path<TAB>size<TAB>blob name" lines,
# hidden and ignored-extension files skipped. Each first-level subfolder keeps
# its name in the container; files directly inside go into GENERAL_DIR.
list_files() {
    if [ "$RETRY_MODE" -eq 1 ]; then
        (cd "$1" && find . \( -type f -o \( -type l -exec test -f {} \; \) \) ! -path '*/.*' -exec stat -L -f '%N%t%z' {} + 2>/dev/null)
    else
        (cd "$1" && find . -type f ! -path '*/.*' -exec stat -f '%N%t%z' {} + 2>/dev/null)
    fi |
        sed 's|^\./||' | LC_ALL=C sort |
        awk -F'\t' -v OFS='\t' -v bp="${2:+$2/}" -v g="$GENERAL_DIR" -v ignored="$IGNORE_EXTENSIONS" '
            BEGIN {
                n = split(ignored, parts, ",")
                for (i = 1; i <= n; i++) if (parts[i] != "") skip[parts[i]] = 1
            }
            NF == 2 {
                name = $1
                sub(/^.*\//, "", name)
                ext = name
                if (ext ~ /\./) sub(/^.*\./, "", ext)
                if (!(tolower(ext) in skip))
                    print $1, $2, bp (index($1, "/") ? $1 : g "/" $1)
            }'
}

# A loose file and a file of the same name in DIR/general/ would both become
# general/NAME; stop before uploading rather than let one replace the other.
check_general_clash() {   # $1 = folder, $2 = list file
    local clash
    clash=$(awk -F'\t' -v g="$GENERAL_DIR/" '
        { seen[$1] = 1 }
        END { for (f in seen) if (index(f, "/") == 0 && ((g f) in seen)) print f }' "$2" | LC_ALL=C sort)
    [ -z "$clash" ] || die "these files in $1 would land on the same blob as files in its '$GENERAL_DIR' subfolder (files directly in the folder go to $GENERAL_DIR/):
$(printf '%s\n' "$clash" | head -n 10 | sed 's/^/  /')
Rename or move one of each pair, then run again."
}

if [ "$DRY_RUN" -eq 1 ]; then
    j=0
    while [ $j -lt ${#J_C[@]} ]; do
        c="${J_C[$j]}"; src="${J_SRC[$j]}"; bp="${J_PREFIX[$j]}"; r="${J_R[$j]}"; j=$((j + 1))
        list_files "$src" "$bp" > "$WORK/list"
        check_general_clash "$src" "$WORK/list"
        n=$(wc -l < "$WORK/list" | tr -d ' ')
        loose=$(awk -F'\t' 'index($1, "/") == 0' "$WORK/list" | wc -l | tr -d ' ')
        bytes=$(awk -F'\t' '{ s += $2 } END { printf "%d", s }' "$WORK/list")
        case "$MISSING" in *"|$c|"*) log "$c: container does not exist; WOULD be created (private)" ;; esac
        log "$c: WOULD upload $n file(s), $(size_h "$bytes")"
        log "    from  $src"
        log "    to    https://$ACCOUNT.$BLOB_SUFFIX/$c/${bp:+$bp/}"
        [ "$loose" -eq 0 ] || log "          ($loose file(s) directly in the folder go to ${bp:+$bp/}$GENERAL_DIR/)"
        [ "$RETRY_MODE" -eq 1 ] || log "    retry $r/$c/"
        head -n 5 "$WORK/list" | awk -F'\t' '{ print "      " $1 "  ->  " $3 }'
        [ "$n" -le 5 ] || log "      ... and $((n - 5)) more"
    done
    log ""
    log "Dry run complete — signed in and checked access; nothing was uploaded or moved."
    exit 0
fi

RUN_DIR="$RUNS_ROOT/$(date +%Y%m%d-%H%M%S)-$$"
{ mkdir -p "$RUN_DIR" && chmod 700 "$RUN_DIR"; } || die "cannot create $RUN_DIR"
export AZCOPY_LOG_LOCATION="$RUN_DIR/logs" AZCOPY_JOB_PLAN_LOCATION="$RUN_DIR/plans"
REPORT="$RUN_DIR/report.txt"
if [ "$VERBOSE" -eq 1 ]; then
    cat "$DEBUG_LOG" > "$RUN_DIR/debug.log" 2>/dev/null; DEBUG_LOG="$RUN_DIR/debug.log"
    vlog "run folder $RUN_DIR (debug.log, report.txt, azcopy logs in logs/)"
fi
{
    echo "upload_azure.sh  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "account   $ACCOUNT"
    echo "identity  $IDENTITY ($CRED_DESC)"
    echo "access    $TRANSFER"
    [ "$RETRY_MODE" -eq 0 ] || echo "mode      retry"
    [ "$CREATED" = "|" ] || echo "created   containers: $(printf '%s' "${CREATED#|}" | sed -e 's/|$//' -e 's/|/, /g')"
    echo ""
} > "$REPORT"

# ---------- 4. upload ---------------------------------------------------------
make_sas() {      # $1 = container -> SAS on stdout (never logged)
    trace az storage container generate-sas --account-name "$ACCOUNT" -n "$1" \
        --as-user --auth-mode login --permissions rcwl --https-only \
        --start "$(utc_in -5)" --expiry "$(utc_in $((SAS_HOURS * 60)))" \
        -o tsv 2> "$WORK/sas.err"
}

azcopy_auth_env() {   # used only in the subshell that runs azcopy copy
    [ "$TRANSFER" = "oauth" ] || return 0
    if [ "$AUTH" = "sp" ]; then
        export AZCOPY_AUTO_LOGIN_TYPE=SPN AZCOPY_SPA_APPLICATION_ID="$CLIENT_ID" AZCOPY_TENANT_ID="$TENANT_ID"
        if [ -n "$CERT_PATH" ]; then export AZCOPY_SPA_CERT_PATH="$CERT_PATH"
        else export AZCOPY_SPA_CLIENT_SECRET="$SECRET"; fi
    else
        export AZCOPY_AUTO_LOGIN_TYPE=AZCLI
    fi
    vlog "azcopy sign-in: $(env | sed -n 's/^\(AZCOPY_[A-Z_]*\)=.*/\1/p' | grep -v 'LOCATION$' | sort | tr '\n' ' ')(values not shown)"
}

# Turns azcopy's JSON output into tab-separated lines for the progress loop.
# shellcheck disable=SC2016  # $raw, $j, $m are jq variables
JQ_PROGRESS='. as $raw | (try fromjson catch null) as $j |
  if $j == null then ($raw | select(length > 0) | "TEXT\t" + .)
  elif $j.MessageType == "Init" then "INIT\t" + ($j.MessageContent | fromjson | .JobID)
  elif $j.MessageType == "Progress" then
      ($j.MessageContent | fromjson) as $m |
      ["Progress", $m.TransfersCompleted, $m.TransfersFailed, $m.TransfersSkipped,
       $m.TotalTransfers, $m.TotalBytesTransferred]
      | map(tostring) | join("\t")
  elif $j.MessageType == "Error" then "ERROR\t" + ($j.MessageContent | tostring | gsub("[\t\n]"; " "))
  else empty end'

reason_for() {    # $1 = azcopy status, $2 = HTTP error code
    case "$1:$2" in
        Failed:403) echo "HTTP 403: access denied (SAS expired, role missing, or blocked by the account firewall)" ;;
        Failed:404) echo "HTTP 404: container not found" ;;
        Failed:0|Failed:) echo "transfer failed (network error or unreadable file; see the azcopy log)" ;;
        Failed:*)   echo "HTTP $2" ;;
        *)          echo "not uploaded: azcopy stopped before reaching this file" ;;
    esac
}

GRAND_OK=0; GRAND_SKIP=0; GRAND_FAIL=0; SUMMARY=""; RUN_START=$SECONDS
NOW=$(date '+%Y-%m-%dT%H:%M:%S')
MANIFEST_HEADER="# container	blob	original path	time	identity	error"

j=0
while [ $j -lt ${#J_C[@]} ]; do
    c="${J_C[$j]}"; src="${J_SRC[$j]}"; bp="${J_PREFIX[$j]}"; r="${J_R[$j]}"; j=$((j + 1))
    manifest="$r/retry-manifest.tsv"
    list_files "$src" "$bp" > "$WORK/list"
    check_general_clash "$src" "$WORK/list"
    n=$(wc -l < "$WORK/list" | tr -d ' ')
    loose=$(awk -F'\t' 'index($1, "/") == 0' "$WORK/list" | wc -l | tr -d ' ')
    [ "$j" -eq 1 ] || log ""
    if [ "$n" -eq 0 ]; then log "$c: nothing to upload in $src"; continue; fi
    bytes=$(awk -F'\t' '{ s += $2 } END { printf "%d", s }' "$WORK/list")
    log "$c: uploading $n file(s), $(size_h "$bytes") from $src"

    dest="https://$ACCOUNT.$BLOB_SUFFIX/$c${bp:+/$bp}"
    url="$dest"
    if [ "$TRANSFER" = "sas" ]; then
        sas=$(make_sas "$c") || sas=""
        case "$sas" in *sig=*) ;; *)
            echo "Error: could not create a SAS for container '$c':" >&2
            sed -e '/^[[:space:]]*$/d' "$WORK/sas.err" | head -n "$ERR_LINES" | redact | sed 's/^/  /' >&2
            echo "  $IDENTITY needs 'Storage Blob Data Contributor' (or 'Storage Blob Delegator') on $ACCOUNT." >&2
            exit 1 ;;
        esac
        url="$dest?$sas"
        vlog "SAS for $c: $sas"
    fi

    # Two azcopy passes: subfolders keep their names (top-level files left
    # out), then the files directly in the folder go into GENERAL_DIR.
    rm -f "$WORK/jobids" "$WORK/errors"
    t0=$SECONDS
    base=0
    for pass in sub loose; do
        if [ "$pass" = "sub" ]; then
            pass_n=$((n - loose)); pass_url="$url"
            copy_args=(copy "$src/*" "$pass_url" --recursive --exclude-regex "$HIDDEN_RE|^[^/]+\$")
        else
            pass_n=$loose; pass_url="$dest/$GENERAL_DIR${sas:+?$sas}"
            copy_args=(copy "$src/*" "$pass_url" --exclude-regex "$HIDDEN_RE")
        fi
        [ "$pass_n" -gt 0 ] || continue
        copy_args+=(--put-md5 --block-size-mb=40 --cap-mbps=0
                    --log-level="$([ "$VERBOSE" -eq 1 ] && echo INFO || echo WARNING)" --output-type=json)
                [ "$RETRY_MODE" -eq 0 ] || copy_args+=(--follow-symlinks)
        if [ "$OVERWRITE" -eq 1 ]; then copy_args+=(--overwrite=ifSourceNewer); else copy_args+=(--overwrite=false); fi
        [ -z "$TIER" ] || copy_args+=(--block-blob-tier="$TIER")

        vlog "pass $pass: $pass_n file(s); run: azcopy ${copy_args[*]}"
        ( azcopy_auth_env; exec azcopy "${copy_args[@]}" ) 2>&1 |
            jq -R --unbuffered -r "$JQ_PROGRESS" 2>/dev/null |
            while IFS=$'\t' read -r kind a b e _f g; do
                case "$kind" in
                    INIT)     printf '%s\n' "$a" >> "$WORK/jobids"
                              vlog "azcopy job $a; log: $AZCOPY_LOG_LOCATION/$a.log" ;;
                    Progress) done_n=$((base + a + b + e))
                              progress $(( done_n * 100 / n )) \
                                  "    $done_n/$n file(s), $(size_h "${g:-0}") sent, $(timing "$t0" "$done_n" "$n")" ;;
                    ERROR)    printf '%s\n' "$a" | redact >> "$WORK/errors"; vlog "azcopy error: $a" ;;
                    TEXT)     vlog "azcopy: $a"
                              case "$a" in INFO:*) ;; *) printf '%s\n' "$a" | redact >> "$WORK/errors" ;; esac ;;
                esac
            done
        base=$((base + pass_n))
    done
    progress_end
    sas=""; url=""; pass_url=""; copy_args=()

    # Per-file outcome from azcopy's job record: source path, status, HTTP code.
    : > "$WORK/status"
    job=$(tr '\n' ' ' < "$WORK/jobids" 2>/dev/null | sed 's/ $//' || true)
    for jid in $job; do
        trace azcopy jobs show "$jid" --with-status=All --output-type=json 2>/dev/null |
            jq -R -r 'fromjson? | select(.MessageType == "ListJobTransfers") | .MessageContent | fromjson
                      | .Details[]? | select(.IsFolderProperties | not)
                      | [.Src, .TransferStatus, (.ErrorCode | tostring)] | join("\t")' >> "$WORK/status"
    done

    vlog "job(s) ${job:-<none>} transfer status: $(cut -f2 "$WORK/status" | sort | uniq -c | awk '{ printf "%s%s=%s", (NR > 1 ? ", " : ""), $2, $1 }')"

    # A skipped file only counts if the blob already there is the same size;
    # otherwise a different photo with that name is in the way.
    : > "$WORK/blobs"
    if grep -q '	Skipped' "$WORK/status"; then
        trace az storage blob list --account-name "$ACCOUNT" -c "$c" --auth-mode login \
            ${bp:+--prefix "$bp/"} --num-results '*' \
            --query '[].[name, properties.contentLength]' -o tsv > "$WORK/blobs" 2>/dev/null || \
            warn "could not list $c to check skipped files; they are treated as failed."
    fi

    # rel <TAB> size <TAB> ok|skip|fail <TAB> status <TAB> code <TAB> blob
    awk -F'\t' -v OFS='\t' -v src="$src/" '
        FILENAME == ARGV[1] { st[substr($1, length(src) + 1)] = $2 "\t" $3; next }
        FILENAME == ARGV[2] { bl[$1] = $2; next }
        {
            s = ($1 in st) ? st[$1] : "Missing\t0"
            split(s, p, "\t")
            if (p[1] == "Success") o = "ok"
            else if (p[1] ~ /^Skipped/ && ($3 in bl) && bl[$3] == $2) o = "skip"
            else o = "fail"
            print $1, $2, o, p[1], p[2], $3
        }' "$WORK/status" "$WORK/blobs" "$WORK/list" > "$WORK/outcome"
    if [ "$VERBOSE" -eq 1 ]; then
        { printf '# file\tsize\toutcome\tazcopy status\tHTTP code\tblob\n'; cat "$WORK/outcome"; } > "$RUN_DIR/outcome-$j-$c.tsv"
        vlog "per-file outcome: $RUN_DIR/outcome-$j-$c.tsv"
    fi

    first_error=$(head -n 1 "$WORK/errors" 2>/dev/null | cut -c 1-200)
    ok=0; skip=0; fail=0; shown=0; kept_back=0
    : > "$WORK/manifest.drop"; : > "$WORK/manifest.add"; : > "$WORK/orig"
    if [ "$RETRY_MODE" -eq 1 ] && [ -f "$manifest" ]; then
        awk -F'\t' -v c="$c" '$1 == c { print $2 "\t" $3 }' "$manifest" > "$WORK/orig"
    fi

    while IFS=$'\t' read -r rel _size o st code blob; do
        if [ "$o" = "fail" ]; then
            case "$st" in
                Skipped*) if [ "$OVERWRITE" -eq 1 ]; then reason="the container already has a newer '$blob' (not replaced)"
                          else reason="the container already has a different '$blob' (not replaced; -O replaces it if this file is newer)"; fi ;;
                Missing)  if [ -z "$job" ] && [ -n "$first_error" ]; then reason="not uploaded: $first_error"
                          else reason=$(reason_for "$st" "$code"); fi ;;
                *)        reason=$(reason_for "$st" "$code") ;;
            esac
            reason=$(printf '%s' "$reason" | tr '\t\n' '  ')
            fail=$((fail + 1))
            if [ "$RETRY_MODE" -eq 1 ]; then
                orig=$(awk -F'\t' -v b="$rel" '$1 == b { print $2; exit }' "$WORK/orig")
                where="$src/$rel"
            else
                orig="$src/$rel"; where="$r/$c/$blob"
                if [ -e "$where" ] || [ -L "$where" ]; then
                    reason="$reason; NOT linked: $where already exists"; where="$orig"
                elif ! { [ -f "$orig" ] && mkdir -p "$(dirname "$where")" && ln -s "$orig" "$where"; }; then
                    reason="$reason; NOT linked: could not create link at $where"; where="$orig"
                fi
            fi
            printf '%s\t%s\n' "$c" "$blob" >> "$WORK/manifest.drop"
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$c" "$blob" "${orig:-?}" "$NOW" "$IDENTITY" "$reason" >> "$WORK/manifest.add"
            printf 'FAIL  %s  %s: %s\n      now at %s\n' "$c" "$blob" "$reason" "$where" >> "$REPORT"
            if [ "$shown" -lt "$SHOW_FAILS" ]; then echo "FAIL  $c/$blob: $reason" >&2; shown=$((shown + 1)); fi
        else
            if [ "$o" = "ok" ]; then ok=$((ok + 1)); else skip=$((skip + 1)); fi
            [ "$RETRY_MODE" -eq 1 ] || continue
            # A retried link points to the original, which never left its path.
            orig=$(awk -F'\t' -v b="$rel" '$1 == b { print $2; exit }' "$WORK/orig")
            if [ -L "$src/$rel" ]; then
                link_target=$(readlink "$src/$rel")
                if [ "$link_target" = "$orig" ] && rm -f "$src/$rel"; then
                    printf '%s\t%s\n' "$c" "$blob" >> "$WORK/manifest.drop"
                    continue
                fi
                note="uploaded, but retry link was not removed; left at $src/$rel"
                kept_back=$((kept_back + 1))
                echo "NOTE  $c/$blob: $note" >&2
                printf 'NOTE  %s  %s: %s\n' "$c" "$blob" "$note" >> "$REPORT"
                continue
            fi
            # Legacy retry files were moved, so restore them to their source path.
            printf '%s\t%s\n' "$c" "$blob" >> "$WORK/manifest.drop"
            if [ -z "$orig" ]; then
                note="uploaded, but no original path is recorded; left at $src/$rel"
            elif [ -e "$orig" ]; then
                note="uploaded, but $orig already exists; left at $src/$rel"
            elif mkdir -p "$(dirname "$orig")" && mv -n "$src/$rel" "$orig" && [ ! -e "$src/$rel" ]; then
                continue
            else
                note="uploaded, but could not move it back to $orig; left at $src/$rel"
            fi
            kept_back=$((kept_back + 1))
            echo "NOTE  $c/$blob: $note" >&2
            printf 'NOTE  %s  %s: %s\n' "$c" "$blob" "$note" >> "$REPORT"
        fi
    done < "$WORK/outcome"
    [ "$fail" -le "$shown" ] || echo "      ... and $((fail - shown)) more (see the report)" >&2

    # Rewrite the manifest once: drop entries settled in this job, add new failures.
    if [ -s "$WORK/manifest.drop" ]; then
        mkdir -p "$r" || die "cannot create $r"
        [ -f "$manifest" ] || printf '%s\n' "$MANIFEST_HEADER" > "$manifest"
        awk -F'\t' 'FILENAME == ARGV[1] { drop[$1 "\t" $2] = 1; next }
                    !(($1 "\t" $2) in drop)' "$WORK/manifest.drop" "$manifest" > "$WORK/manifest.new"
        cat "$WORK/manifest.add" >> "$WORK/manifest.new"
        if grep -qv '^#' "$WORK/manifest.new"; then cp "$WORK/manifest.new" "$manifest"
        else rm -f "$manifest"; fi
    fi
    # Tidy up emptied retry folders (never the source folders themselves).
    if [ -d "$r/$c" ]; then find "$r/$c" -type d -empty -delete 2>/dev/null; fi
    rmdir "$r" 2>/dev/null

    if [ "$fail" -gt 1 ] && [ "$fail" -eq "$n" ]; then
        echo "      Every file failed. Check your network, the account firewall, the role assignment" >&2
        echo "      and the SAS lifetime (-t); details are in $AZCOPY_LOG_LOCATION" >&2
        [ -z "$first_error" ] || echo "      azcopy said: $first_error" >&2
    fi
    line="$c: $ok uploaded, $skip already there, $fail failed  ($(hms $((SECONDS - t0))))"
    [ "$kept_back" -eq 0 ] || line="$line, $kept_back left in the retry folder (see NOTE lines)"
    log "    $line"
    SUMMARY="$SUMMARY  $line$NL"
    GRAND_OK=$((GRAND_OK + ok)); GRAND_SKIP=$((GRAND_SKIP + skip)); GRAND_FAIL=$((GRAND_FAIL + fail))
done

# ---------- 5. report ---------------------------------------------------------
# The retry folder replaces azcopy's own resume; -v keeps the plans for 'azcopy jobs show'.
if [ "$VERBOSE" -eq 1 ]; then vlog "kept azcopy job plans in $AZCOPY_JOB_PLAN_LOCATION"
else rm -rf "$AZCOPY_JOB_PLAN_LOCATION"; fi
{ echo ""; echo "summary"; printf '%s' "$SUMMARY"; } >> "$REPORT"

log ""
log "Done in $(hms $((SECONDS - RUN_START))): $GRAND_OK uploaded, $GRAND_SKIP already there, $GRAND_FAIL failed."
printf '%s' "$SUMMARY"
log "Report:  $REPORT"
if [ "$GRAND_FAIL" -gt 0 ]; then
    log ""
    if [ "$RETRY_MODE" -eq 1 ]; then
        log "$GRAND_FAIL file(s) are still in the retry folder. Fix the cause and run the same command again."
    else
        log "$GRAND_FAIL file(s) were moved to the retry folder (see FAIL lines above)."
        log "Fix the cause, then run the same command with -R to upload only those."
    fi
    exit 2
fi
exit 0
