import json
import os
from pathlib import Path
import pty
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "cloud" / "prune_nef.sh"

FAKE_AZ = """#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
root = os.environ["FAKE_AZ_DIR"]
def option(name):
    for arg in args:
        if arg.startswith(name + "="):
            return arg.split("=", 1)[1]
    return args[args.index(name) + 1] if name in args else None
if args[:3] == ["storage", "container", "list"]:
    print(json.dumps([{"name": "beta"}, {"name": "alpha"}]))
elif args[:3] == ["storage", "blob", "list"]:
    with open(os.path.join(root, "blobs.json")) as handle:
        blobs = json.load(handle)[option("--container-name")]
    prefix = option("--prefix") or ""
    print(json.dumps([b for b in blobs if b["name"].startswith(prefix)]))
elif args[:3] in (["storage", "blob", "delete"], ["storage", "blob", "set-tier"]):
    name = option("--name")
    if name.endswith("fail.nef"):
        sys.stderr.write("ERROR: boom\\n")
        sys.exit(1)
    with open(os.path.join(root, "calls.log"), "a") as handle:
        handle.write(" ".join(args[:3]) + " " + option("--container-name") + " " + name + "\\n")
else:
    sys.exit(3)
"""


def blob(name, size=1000, tier="Hot"):
    return {"name": name, "properties": {"contentLength": size, "blobTier": tier}}


BLOBS = {
    "alpha": [
        blob("20261017/NEF.zip", 5000),
        blob("20261017/NEF/a.NEF", 2000),
        blob("20261017/NEF/b.NEF", 2000),
        blob("20261017/NEF/lonely.NEF", 2000),
        blob("20261017/DNG/a.dng", 900),
        blob("20261017/DNG/B.DNG", 900),
        blob("20261017/JPG/a.jpg", 100),
        blob("20261018/NEF/empty.NEF", 2000),
        blob("20261018/DNG/empty.dng", 0),
        blob("20261019/NEF/done.NEF", 2000, "Archive"),
        blob("20261019/DNG/done.dng", 900),
    ],
    "beta": [
        blob("flat.nef", 10),
        blob("flat.dng", 5),
        blob("x/old.nef.zip", 10),
    ],
}


class PruneNefTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        az = self.root / "az"
        az.write_text(FAKE_AZ)
        az.chmod(0o755)
        (self.root / "blobs.json").write_text(json.dumps(BLOBS))
        self.env = os.environ.copy()
        self.env.update({
            "PATH": str(self.root) + os.pathsep + self.env["PATH"],
            "FAKE_AZ_DIR": str(self.root),
            "PHOTO_AZ_AUTH": "user",
        })
        self.env.pop("PHOTO_AZ_ACCOUNT", None)

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *args, stdin=subprocess.DEVNULL):
        return subprocess.run(
            ["bash", str(SCRIPT), "-a", "account", *args],
            env=self.env, stdin=stdin, capture_output=True, text=True,
        )

    def calls(self):
        log = self.root / "calls.log"
        return sorted(log.read_text().splitlines()) if log.exists() else []

    def test_dry_run_reports_counts_and_changes_nothing(self):
        result = self.run_script("-n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Container: alpha", result.stdout)
        self.assertIn("Container: beta", result.stdout)
        self.assertIn("Total: 5 blob(s)", result.stdout)
        self.assertIn("to archive", result.stdout)
        self.assertIn("NEF files kept (no matching non-empty DNG): 2", result.stdout)
        self.assertNotIn("a.NEF", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_list_shows_file_names(self):
        result = self.run_script("-n", "-l")
        self.assertIn("20261017/NEF/a.NEF (NEF,", result.stdout)
        self.assertIn("20261017/NEF.zip (NEF.zip", result.stdout)
        self.assertIn("20261017/NEF/lonely.NEF (kept)", result.stdout)
        self.assertIn("20261018/NEF/empty.NEF (kept)", result.stdout)
        self.assertNotIn(".dng", result.stdout.lower())

    def test_nothing_deleted_without_terminal_or_force(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertIn("-y", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_force_deletes_only_matched_nefs_and_nef_zip(self):
        result = self.run_script("-y", "-D")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), sorted([
            "storage blob delete alpha 20261017/NEF.zip",
            "storage blob delete alpha 20261017/NEF/a.NEF",
            "storage blob delete alpha 20261017/NEF/b.NEF",
            "storage blob delete alpha 20261019/NEF/done.NEF",
            "storage blob delete beta flat.nef",
            "storage blob delete beta x/old.nef.zip",
        ]))

    def test_archive_is_the_default_and_skips_archived(self):
        result = self.run_script("-y")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual(calls, sorted([
            "storage blob set-tier alpha 20261017/NEF.zip",
            "storage blob set-tier alpha 20261017/NEF/a.NEF",
            "storage blob set-tier alpha 20261017/NEF/b.NEF",
            "storage blob set-tier beta flat.nef",
            "storage blob set-tier beta x/old.nef.zip",
        ]))
        self.assertIn("Already in the Archive tier (skipped): 1", result.stdout)
        self.assertIn("NEF files kept (no matching non-empty DNG): 2", result.stdout)

    def test_default_prompt_does_not_archive_when_declined(self):
        master, slave = pty.openpty()
        try:
            os.write(master, b"n\n")
            result = self.run_script(stdin=slave)
        finally:
            os.close(master)
            os.close(slave)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Archive tier", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_container_limits_scope(self):
        result = self.run_script("-y", "-D", "-c", "beta")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [
            "storage blob delete beta flat.nef",
            "storage blob delete beta x/old.nef.zip",
        ])

    def test_prompt_answer_no_cancels_and_yes_proceeds(self):
        for answer, expected in ((b"n\n", 0), (b"y\n", 6)):
            log = self.root / "calls.log"
            if log.exists():
                log.unlink()
            master, slave = pty.openpty()
            try:
                os.write(master, answer)
                result = self.run_script("-D", stdin=slave)
            finally:
                os.close(master)
                os.close(slave)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(self.calls()), expected)

    def test_failures_are_reported(self):
        BLOBS["beta"].extend([blob("fail.nef", 1), blob("fail.dng", 1)])
        try:
            (self.root / "blobs.json").write_text(json.dumps(BLOBS))
            result = self.run_script("-y", "-D", "-c", "beta")
        finally:
            del BLOBS["beta"][-2:]
        self.assertEqual(result.returncode, 2)
        self.assertIn("beta/fail.nef", result.stderr)

    def test_matching_is_case_insensitive_scoped_and_requires_nonempty_dng(self):
        blobs = {
            "alpha": [
                blob("NEF/root.NEF"), blob("dNg/ROOT.dng"),
                blob("event/NeF/sibling.NEF"), blob("EVENT/dnG/SIBLING.DNG"),
                blob("folder/same.NEF"), blob("FOLDER/SAME.dng"),
                blob("event/NEF/other.nef"), blob("other/DNG/other.dng"),
                blob("event/NEF/cross.nef"), blob("event/NEF/zero.nef"),
                blob("event/DNG/zero.dng", 0),
                blob("event/NEF/missing.nef"),
                {"name": "event/DNG/missing.dng", "properties": {}},
                blob("event/notNEF/wrong.nef"), blob("event/DNG/wrong.dng"),
                blob("event/NEF/already.nef", tier="Archive"),
            ],
            "beta": [blob("event/DNG/cross.dng")],
        }
        (self.root / "blobs.json").write_text(json.dumps(blobs))
        for mode in ((), ("-D",)):
            with self.subTest(mode=mode):
                result = self.run_script("-y", *mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("NEF files kept (no matching non-empty DNG): 6", result.stdout)
                action = "delete" if mode else "set-tier"
                self.assertEqual(self.calls(), sorted([
                    "storage blob {} alpha NEF/root.NEF".format(action),
                    "storage blob {} alpha event/NeF/sibling.NEF".format(action),
                    "storage blob {} alpha folder/same.NEF".format(action),
                ]))
                (self.root / "calls.log").unlink()

    def test_prefix_excluding_dng_keeps_nefs_in_both_modes(self):
        for mode in ((), ("-D",)):
            with self.subTest(mode=mode):
                result = self.run_script("-y", "-c", "alpha", "-p", "20261017/NEF/", *mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("NEF files kept (no matching non-empty DNG): 3", result.stdout)
                self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
