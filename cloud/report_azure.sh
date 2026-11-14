#!/usr/bin/env bash
#
# report_azure.sh — report read-only statistics for an Azure Blob account.
#
# Usage:
#   report_azure.sh [-a ACCOUNT] [-I user|sp] [-i APP_ID] [-z TENANT] [-K PEM] [-s | -d FILE] [-v]
#
#   -a ACCOUNT  storage account name (default: $PHOTO_AZ_ACCOUNT)
#   -I user|sp  Azure identity (default: $PHOTO_AZ_AUTH, else user)
#   -i APP_ID   service principal app ID (default: $PHOTO_AZ_CLIENT_ID, else $AZURE_CLIENT_ID)
#   -z TENANT   tenant ID (default: $PHOTO_AZ_TENANT_ID, else $AZURE_TENANT_ID)
#   -K PEM      service principal certificate (default: $PHOTO_AZ_CERT_PATH,
#               else $AZURE_CLIENT_CERTIFICATE_PATH)
#   -s          print a summary to the terminal (default)
#   -d FILE     write an Excel workbook with a summary and one tab per container
#   -v          show the Azure CLI commands being run (default: off)
#
#   Service principal secrets come from PHOTO_AZ_CLIENT_SECRET, AZURE_CLIENT_SECRET,
#   or the macOS Keychain (service: PHOTO_AZ_KEYCHAIN_SERVICE, default photo-tools-azure).
#   Secrets cannot be passed on the command line.
#
# Environment:
#   PHOTO_AZ_ACCOUNT, PHOTO_AZ_AUTH, PHOTO_AZ_CLIENT_ID, PHOTO_AZ_TENANT_ID,
#   PHOTO_AZ_CERT_PATH, PHOTO_AZ_CLIENT_SECRET, PHOTO_AZ_KEYCHAIN_SERVICE
#   (client ID, tenant, certificate and secret also fall back to their AZURE_* names)
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
MODE="summary"
MODE_SET=0
OUTPUT=""
VERBOSE=0

usage() { sed -n '/^# Usage:/,/^# Requires/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d' >&2; exit 1; }
die() { echo "Error: $*" >&2; exit 1; }

while getopts ":a:sd:vI:i:z:K:h" opt; do
    case "$opt" in
        a) ACCOUNT="$OPTARG" ;;
        I) AUTH="$OPTARG" ;;
        i) CLIENT_ID="$OPTARG" ;;
        z) TENANT_ID="$OPTARG" ;;
        K) CERT_PATH="$OPTARG" ;;
        s) [ "$MODE_SET" -eq 0 ] || usage; MODE="summary"; MODE_SET=1 ;;
        d) [ "$MODE_SET" -eq 0 ] || usage; MODE="detail"; OUTPUT="$OPTARG"; MODE_SET=1 ;;
        v) VERBOSE=1 ;;
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
case "$AUTH" in user|sp) ;; *) die "-I must be 'user' or 'sp', got '$AUTH'." ;; esac
if [ "$AUTH" = "sp" ]; then
    missing=""
    [ -n "$CLIENT_ID" ] || missing="$missing
  app (client) ID: -i, PHOTO_AZ_CLIENT_ID or AZURE_CLIENT_ID"
    [ -n "$TENANT_ID" ] || missing="$missing
  tenant ID:       -z, PHOTO_AZ_TENANT_ID or AZURE_TENANT_ID"
    [ -z "$missing" ] || die "service principal sign-in (-I sp) needs:$missing"
fi
if [ "$MODE" = "detail" ] && [ -z "$OUTPUT" ]; then
    die "an output file is required with -d."
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

    AZ_DIR=$(mktemp -d "${TMPDIR:-/tmp}/photo-report-az.XXXXXX") || die "cannot create a temporary Azure CLI profile."
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

python3 - "$ACCOUNT" "$MODE" "$OUTPUT" "$VERBOSE" <<'PY'
import json
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ACCOUNT, MODE, OUTPUT, VERBOSE = sys.argv[1:]
VERBOSE = VERBOSE == "1"


def az_json(*args):
    command = ["az", *args, "--output", "json"]
    if VERBOSE:
        print("verbose: " + " ".join(command), file=sys.stderr)
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        if result.stderr:
            sys.stderr.write(result.stderr)
        raise RuntimeError("Azure CLI command failed.")
    try:
        return json.loads(result.stdout)
    except ValueError as error:
        raise RuntimeError("Azure CLI returned invalid JSON.") from error


def blob_fields(blob):
    properties = blob.get("properties") or {}
    settings = properties.get("contentSettings") or properties.get("content_settings") or {}
    size = properties.get("contentLength", properties.get("content_length", blob.get("contentLength", 0)))
    return [
        blob.get("name", ""),
        int(size or 0),
        properties.get("lastModified", properties.get("last_modified", "")) or "",
        properties.get("blobType", properties.get("blob_type", "")) or "",
        settings.get("contentType", settings.get("content_type", "")) or "",
        properties.get("accessTier", properties.get("access_tier", "")) or "",
    ]


def gigabytes(size_bytes):
    return round(size_bytes / 1_000_000_000, 3)


def column_name(number):
    name = ""
    while number:
        number, remainder = divmod(number - 1, 26)
        name = chr(65 + remainder) + name
    return name


def cell_value(parent, reference, value):
    cell = ET.SubElement(parent, "c", {"r": reference})
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        ET.SubElement(cell, "v").text = str(value)
    else:
        cell.set("t", "inlineStr")
        inline = ET.SubElement(cell, "is")
        text = ET.SubElement(inline, "t")
        text.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
        text.text = str(value)


def worksheet_xml(rows):
    worksheet = ET.Element("worksheet", {"xmlns": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"})
    data = ET.SubElement(worksheet, "sheetData")
    for row_number, values in enumerate(rows, 1):
        row = ET.SubElement(data, "row", {"r": str(row_number)})
        for column, value in enumerate(values, 1):
            if value is not None:
                cell_value(row, column_name(column) + str(row_number), value)
    return ET.tostring(worksheet, encoding="utf-8", xml_declaration=True)


def sheet_names(containers):
    used = {"summary"}
    names = []
    for container in containers:
        base = re.sub(r"[\[\]:*?/\\]", "_", container)[:31].strip("'") or "Container"
        name = base
        suffix = 2
        while name.casefold() in used:
            tail = " ({})".format(suffix)
            name = base[:31 - len(tail)] + tail
            suffix += 1
        used.add(name.casefold())
        names.append(name)
    return names


def write_workbook(path, containers, blobs_by_container):
    summary = [
        ["Storage account", ACCOUNT],
        ["Container count", len(containers)],
        ["Blob count", sum(len(blobs) for blobs in blobs_by_container)],
        ["Total size (GB)", gigabytes(sum(fields[1] for blobs in blobs_by_container for fields in blobs))],
        [],
        ["Container", "Blob count", "Size (GB)"],
    ]
    for container, blobs in zip(containers, blobs_by_container):
        summary.append([container, len(blobs), gigabytes(sum(fields[1] for fields in blobs))])
    sheets = [("Summary", summary)]
    for name, blobs in zip(sheet_names(containers), blobs_by_container):
        if len(blobs) + 1 > 1048576:
            raise RuntimeError("container has too many blobs for a single Excel worksheet.")
        blob_rows = [[fields[0], gigabytes(fields[1])] + fields[2:] for fields in blobs]
        sheets.append((name, [["Blob name", "Size (GB)", "Last modified", "Blob type", "Content type", "Access tier"]] + blob_rows))

    ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    rel_ns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    package_ns = "http://schemas.openxmlformats.org/package/2006/relationships"
    content_ns = "http://schemas.openxmlformats.org/package/2006/content-types"
    workbook = ET.Element("workbook", {"xmlns": ns, "xmlns:r": rel_ns})
    sheet_list = ET.SubElement(workbook, "sheets")
    root_relationships = ET.Element("Relationships", {"xmlns": package_ns})
    content_types = ET.Element("Types", {"xmlns": content_ns})
    ET.SubElement(content_types, "Default", {"Extension": "rels", "ContentType": "application/vnd.openxmlformats-package.relationships+xml"})
    ET.SubElement(content_types, "Default", {"Extension": "xml", "ContentType": "application/xml"})
    ET.SubElement(content_types, "Override", {"PartName": "/xl/workbook.xml", "ContentType": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"})
    ET.SubElement(root_relationships, "Relationship", {
        "Id": "rId1",
        "Type": "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument",
        "Target": "xl/workbook.xml",
    })
    relationships = ET.Element("Relationships", {"xmlns": package_ns})
    for index, (name, _) in enumerate(sheets, 1):
        ET.SubElement(sheet_list, "sheet", {
            "name": name,
            "sheetId": str(index),
            "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id": "rId{}".format(index),
        })
        ET.SubElement(relationships, "Relationship", {
            "Id": "rId{}".format(index),
            "Type": "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet",
            "Target": "worksheets/sheet{}.xml".format(index),
        })
        ET.SubElement(content_types, "Override", {
            "PartName": "/xl/worksheets/sheet{}.xml".format(index),
            "ContentType": "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml",
        })

    directory = os.path.dirname(os.path.abspath(path))
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".azure-report-", suffix=".xlsx", dir=directory, delete=False) as handle:
            temporary = handle.name
        with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED) as workbook_file:
            workbook_file.writestr("_rels/.rels", ET.tostring(root_relationships, encoding="utf-8", xml_declaration=True))
            workbook_file.writestr("[Content_Types].xml", ET.tostring(content_types, encoding="utf-8", xml_declaration=True))
            workbook_file.writestr("xl/workbook.xml", ET.tostring(workbook, encoding="utf-8", xml_declaration=True))
            workbook_file.writestr("xl/_rels/workbook.xml.rels", ET.tostring(relationships, encoding="utf-8", xml_declaration=True))
            for index, (_, rows) in enumerate(sheets, 1):
                workbook_file.writestr("xl/worksheets/sheet{}.xml".format(index), worksheet_xml(rows))
        os.replace(temporary, path)
    except OSError:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)
        raise
def main():
    containers_data = az_json(
        "storage", "container", "list", "--account-name", ACCOUNT,
        "--auth-mode", "login", "--num-results", "*",
    )
    containers = sorted(container["name"] for container in containers_data)
    blobs_by_container = []
    for container in containers:
        blobs_data = az_json(
            "storage", "blob", "list", "--account-name", ACCOUNT,
            "--container-name", container, "--auth-mode", "login", "--num-results", "*",
        )
        blobs = [blob_fields(blob) for blob in blobs_data]
        blobs_by_container.append(blobs)
        if VERBOSE:
            print("verbose: {}: {} blobs".format(container, len(blobs)), file=sys.stderr)

    total_blobs = sum(len(blobs) for blobs in blobs_by_container)
    total_bytes = sum(fields[1] for blobs in blobs_by_container for fields in blobs)
    if MODE == "detail":
        write_workbook(OUTPUT, containers, blobs_by_container)
        print("Excel report written to {}".format(OUTPUT))
    print("Azure Storage Blob report: {}".format(ACCOUNT))
    print("Containers: {} | Blobs: {} | Total size: {:.3f} GB".format(len(containers), total_blobs, gigabytes(total_bytes)))
    print("{:<32} {:>12} {:>20}".format("Container", "Blobs", "Size (GB)"))
    for container, blobs in zip(containers, blobs_by_container):
        print("{:<32} {:>12} {:>20.3f}".format(container, len(blobs), gigabytes(sum(fields[1] for fields in blobs))))


try:
    main()
except (OSError, RuntimeError, ValueError, KeyError) as error:
    print("Error: {}".format(error), file=sys.stderr)
    sys.exit(1)
PY
