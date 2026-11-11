#!/usr/bin/env bash
#
# report_azure.sh — report read-only statistics for an Azure Blob account.
#
# Usage:
#   report_azure.sh [-a ACCOUNT] [-s | -d FILE] [-v]
#
#   -a ACCOUNT  storage account name (default: $PHOTO_AZ_ACCOUNT)
#   -s          print a summary to the terminal (default)
#   -d FILE     write an Excel workbook with a summary and one tab per container
#   -v          show the Azure CLI commands being run (default: off)
#
# Requires: Azure CLI, Python 3.
# Works with the stock macOS bash 3.2.

set -u

ACCOUNT="${PHOTO_AZ_ACCOUNT:-}"
MODE="summary"
MODE_SET=0
OUTPUT=""
VERBOSE=0

usage() { sed -n '/^# Usage:/,/^# Requires/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d' >&2; exit 1; }
die() { echo "Error: $*" >&2; exit 1; }

while getopts ":a:sd:vh" opt; do
    case "$opt" in
        a) ACCOUNT="$OPTARG" ;;
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
if [ "$MODE" = "detail" ] && [ -z "$OUTPUT" ]; then
    die "an output file is required with -d."
fi

command -v az >/dev/null 2>&1 || die "Azure CLI (az) is required."
command -v python3 >/dev/null 2>&1 || die "Python 3 is required."

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
        ["Total size (bytes)", sum(fields[1] for blobs in blobs_by_container for fields in blobs)],
        [],
        ["Container", "Blob count", "Size (bytes)"],
    ]
    for container, blobs in zip(containers, blobs_by_container):
        summary.append([container, len(blobs), sum(fields[1] for fields in blobs)])
    sheets = [("Summary", summary)]
    for name, blobs in zip(sheet_names(containers), blobs_by_container):
        if len(blobs) + 1 > 1048576:
            raise RuntimeError("container has too many blobs for a single Excel worksheet.")
        sheets.append((name, [["Blob name", "Size (bytes)", "Last modified", "Blob type", "Content type", "Access tier"]] + blobs))

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
    print("Containers: {} | Blobs: {} | Total size: {} bytes".format(len(containers), total_blobs, total_bytes))
    print("{:<32} {:>12} {:>20}".format("Container", "Blobs", "Size (bytes)"))
    for container, blobs in zip(containers, blobs_by_container):
        print("{:<32} {:>12} {:>20}".format(container, len(blobs), sum(fields[1] for fields in blobs)))


try:
    main()
except (OSError, RuntimeError, ValueError, KeyError) as error:
    print("Error: {}".format(error), file=sys.stderr)
    sys.exit(1)
PY
