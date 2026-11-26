import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "cloud" / "phototools_report_azure.ps1"
PWSH = shutil.which("pwsh")
NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}

FAKE_AZ = """#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
root = os.environ["FAKE_AZ_DIR"]
def option(name):
    return args[args.index(name) + 1] if name in args else None
with open(os.path.join(root, "data.json")) as handle:
    data = json.load(handle)
if args[:3] == ["storage", "container", "list"]:
    print(json.dumps([{"name": name} for name in data]))
elif args[:3] == ["storage", "blob", "list"]:
    blobs = data.get(option("--container-name"))
    if blobs is None:
        sys.stderr.write("ERROR: container not found\\n")
        sys.exit(1)
    print(json.dumps(blobs))
else:
    sys.exit(3)
"""


def blob(name, size, tier="Hot", modified="2026-10-17T12:30:45+00:00", content_type="image/jpeg"):
    return {
        "name": name,
        "properties": {
            "contentLength": size,
            "blobTier": tier,
            "blobType": "BlockBlob",
            "lastModified": modified,
            "contentSettings": {"contentType": content_type},
        },
    }


LONG = "a" * 31
DATA = {
    "beta": [blob("x/<b>&.jpg", 1500000000), blob("y.dng", 500000000, tier="Archive")],
    "alpha": [blob("one.jpg", 1000)],
    "summary": [],
    LONG + "x": [blob("p", 1)],
    LONG + "y": [blob("q", 2)],
}


def read_sheet(workbook, index):
    root = ET.fromstring(workbook.read("xl/worksheets/sheet{}.xml".format(index)))
    rows = []
    for row in root.find("m:sheetData", NS):
        values = []
        for cell in row:
            text = cell.find("m:is/m:t", NS)
            number = cell.find("m:v", NS)
            values.append(text.text if text is not None else float(number.text))
        rows.append(values)
    return rows


@unittest.skipUnless(PWSH and os.name != "nt", "PowerShell and a Unix-like test host are required")
class PowerShellReportAzureTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        az = self.root / "az"
        az.write_text(FAKE_AZ)
        az.chmod(0o755)
        (self.root / "data.json").write_text(json.dumps(DATA))
        self.env = os.environ.copy()
        self.env.update({
            "PATH": str(self.root) + os.pathsep + self.env["PATH"],
            "FAKE_AZ_DIR": str(self.root),
            "PHOTO_AZ_AUTH": "user",
        })
        self.env.pop("PHOTO_AZ_ACCOUNT", None)

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *args):
        return subprocess.run(
            [PWSH, "-NoLogo", "-NoProfile", "-File", str(SCRIPT), "-Account", "account", *args],
            env=self.env, cwd=self.root, stdin=subprocess.DEVNULL, capture_output=True, text=True,
        )

    def test_summary_lists_containers_with_totals(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[0], "Azure Storage Blob report: account")
        self.assertEqual(lines[1], "Containers: 5 | Blobs: 5 | Total size: 2.000 GB")
        self.assertEqual(lines[2], "{:<32} {:>12} {:>20}".format("Container", "Blobs", "Size (GB)"))
        self.assertEqual(lines[3], "{:<32} {:>12} {:>20}".format(LONG + "x", 1, "0.000"))
        self.assertEqual(lines[5], "{:<32} {:>12} {:>20}".format("alpha", 1, "0.000"))
        self.assertEqual(lines[6], "{:<32} {:>12} {:>20}".format("beta", 2, "2.000"))
        self.assertEqual(lines[7], "{:<32} {:>12} {:>20}".format("summary", 0, "0.000"))

    def test_detail_writes_a_workbook_with_a_tab_per_container(self):
        result = self.run_script("-Detail", "report.xlsx")
        self.assertEqual(result.returncode, 0, result.stderr)
        report = self.root / "report.xlsx"
        self.assertIn("Excel report written to {}".format(report), result.stdout)
        self.assertEqual(sorted(path.name for path in self.root.iterdir() if path.suffix == ".tmp"), [])
        with zipfile.ZipFile(report) as workbook:
            self.assertIsNone(workbook.testzip())
            self.assertEqual(
                set(workbook.namelist()),
                {"_rels/.rels", "[Content_Types].xml", "xl/workbook.xml", "xl/_rels/workbook.xml.rels"}
                | {"xl/worksheets/sheet{}.xml".format(index) for index in range(1, 7)},
            )
            sheets = ET.fromstring(workbook.read("xl/workbook.xml")).findall("m:sheets/m:sheet", NS)
            names = [sheet.get("name") for sheet in sheets]
            self.assertEqual(names, [
                "Summary", LONG, LONG[:27] + " (2)", "alpha", "beta", "summary (2)",
            ])
            self.assertEqual(read_sheet(workbook, 1)[:4], [
                ["Storage account", "account"],
                ["Container count", 5.0],
                ["Blob count", 5.0],
                ["Total size (GB)", 2.0],
            ])
            self.assertEqual(read_sheet(workbook, 1)[5:], [
                ["Container", "Blob count", "Size (GB)"],
                [LONG + "x", 1.0, 0.0],
                [LONG + "y", 1.0, 0.0],
                ["alpha", 1.0, 0.0],
                ["beta", 2.0, 2.0],
                ["summary", 0.0, 0.0],
            ])
            self.assertEqual(read_sheet(workbook, 5), [
                ["Blob name", "Size (GB)", "Last modified", "Blob type", "Content type", "Access tier"],
                ["x/<b>&.jpg", 1.5, "2026-10-17T12:30:45+00:00", "BlockBlob", "image/jpeg", "Hot"],
                ["y.dng", 0.5, "2026-10-17T12:30:45+00:00", "BlockBlob", "image/jpeg", "Archive"],
            ])

    def test_summary_and_detail_cannot_be_combined(self):
        result = self.run_script("-Summary", "-Detail", "report.xlsx")
        self.assertEqual(result.returncode, 1)
        self.assertIn("cannot be used together", result.stderr)
        self.assertFalse((self.root / "report.xlsx").exists())

    def test_account_is_required_and_validated(self):
        result = subprocess.run(
            [PWSH, "-NoLogo", "-NoProfile", "-File", str(SCRIPT)],
            env=self.env, stdin=subprocess.DEVNULL, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("storage account is required", result.stderr)
        result = subprocess.run(
            [PWSH, "-NoLogo", "-NoProfile", "-File", str(SCRIPT), "-Account", "Bad_Name"],
            env=self.env, stdin=subprocess.DEVNULL, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid storage account name", result.stderr)

    def test_azure_errors_are_reported(self):
        (self.root / "data.json").write_text("{}")
        os.remove(self.root / "az")
        broken = self.root / "az"
        broken.write_text("#!/bin/sh\necho 'ERROR: denied' >&2\nexit 1\n")
        broken.chmod(0o755)
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertIn("denied", result.stderr)


if __name__ == "__main__":
    unittest.main()
