import json
import os
from pathlib import Path
import pty
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "cloud" / "phototools_unarchive_container.sh"

FAKE_AZ = """#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
root = os.environ["FAKE_AZ_DIR"]
def option(name):
    for arg in args:
        if arg.startswith(name + "="):
            return arg.split("=", 1)[1]
    return args[args.index(name) + 1] if name in args else None
if args[:3] == ["storage", "blob", "list"]:
    with open(os.path.join(root, "blobs.json")) as handle:
        blobs = json.load(handle).get(option("--container-name"))
    if blobs is None:
        sys.stderr.write("ERROR: container not found\\n")
        sys.exit(1)
    print(json.dumps(blobs))
elif args[:3] == ["storage", "blob", "set-tier"]:
    name = option("--name")
    if name.endswith("fail.jpg"):
        sys.stderr.write("ERROR: boom\\n")
        sys.exit(1)
    with open(os.path.join(root, "calls.log"), "a") as handle:
        handle.write(option("--container-name") + " " + name + " " + option("--tier") + "\\n")
else:
    sys.exit(3)
"""


def blob(name, size=1000, tier="Archive", kind="BlockBlob", rehydration=None):
    properties = {"contentLength": size, "blobTier": tier, "blobType": kind}
    if rehydration:
        properties["rehydrationStatus"] = rehydration
    return {"name": name, "properties": properties}


BLOBS = {
    "alpha": [
        blob("20261017/a.jpg"),
        blob("20261017/b.dng"),
        blob("20261018/c.jpg", tier="Hot"),
        blob("20261018/d.jpg", rehydration="rehydrate-pending-to-hot"),
        blob("20261018/page.vhd", kind="PageBlob"),
        blob("root.txt"),
    ],
    "beta": [blob("other.jpg")],
    "empty": [],
}


class UnarchiveContainerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        az = self.root / "az"
        az.write_text(FAKE_AZ)
        az.chmod(0o755)
        self.write_blobs(BLOBS)
        self.env = os.environ.copy()
        self.env.update({
            "PATH": str(self.root) + os.pathsep + self.env["PATH"],
            "FAKE_AZ_DIR": str(self.root),
            "PHOTO_AZ_AUTH": "user",
        })
        self.env.pop("PHOTO_AZ_ACCOUNT", None)

    def tearDown(self):
        self.tmp.cleanup()

    def write_blobs(self, blobs):
        (self.root / "blobs.json").write_text(json.dumps(blobs))

    def run_script(self, *args, stdin=subprocess.DEVNULL):
        return subprocess.run(
            ["bash", str(SCRIPT), "-a", "account", *args],
            env=self.env, stdin=stdin, capture_output=True, text=True,
        )

    def calls(self):
        log = self.root / "calls.log"
        return sorted(log.read_text().splitlines()) if log.exists() else []

    def run_with_answer(self, answer, *args):
        master, slave = pty.openpty()
        try:
            os.write(master, answer)
            return self.run_script(*args, stdin=slave)
        finally:
            os.close(master)
            os.close(slave)

    def test_container_is_required(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertIn("container is required", result.stderr)

    def test_invalid_container_name_rejected(self):
        result = self.run_script("-c", "Bad_Name")
        self.assertEqual(result.returncode, 1)
        self.assertIn("not a valid container name", result.stderr)

    def test_dry_run_reports_counts_and_changes_nothing(self):
        result = self.run_script("-c", "alpha", "-n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("to the Hot tier (dry run)", result.stdout)
        self.assertIn("Total: 3 blob(s)", result.stdout)
        self.assertIn("Already being rehydrated (skipped): 1", result.stdout)
        self.assertIn("Not in the Archive tier (skipped): 1", result.stdout)
        self.assertIn("cannot be archived (skipped): 1", result.stdout)
        self.assertIn("20261017", result.stdout)
        self.assertIn("(container root)", result.stdout)
        self.assertNotIn("a.jpg", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_list_shows_blob_names(self):
        result = self.run_script("-c", "alpha", "-n", "-l")
        self.assertIn("20261017/a.jpg", result.stdout)
        self.assertIn("20261018/c.jpg (not in Archive tier, skipped)", result.stdout)
        self.assertIn("20261018/d.jpg (already being rehydrated, skipped)", result.stdout)
        self.assertIn("20261018/page.vhd (skipped, not a block blob)", result.stdout)

    def test_nothing_changed_without_terminal_or_force(self):
        result = self.run_script("-c", "alpha")
        self.assertEqual(result.returncode, 1)
        self.assertIn("-y", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_force_moves_to_hot_by_default(self):
        result = self.run_script("-c", "alpha", "-y")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [
            "alpha 20261017/a.jpg Hot",
            "alpha 20261017/b.dng Hot",
            "alpha root.txt Hot",
        ])
        self.assertIn("Requested 3 blob(s) to be moved to the Hot tier", result.stdout)

    def test_tier_option_chooses_the_tier(self):
        result = self.run_script("-c", "beta", "-y", "-t", "cool")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), ["beta other.jpg Cool"])
        self.assertIn("to the Cool tier", result.stdout)

    def test_invalid_tier_rejected(self):
        for tier in ("Archive", "warm"):
            result = self.run_script("-c", "alpha", "-y", "-t", tier)
            self.assertEqual(result.returncode, 1)
            self.assertIn("-t must be Hot, Cool or Cold", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_prompt_answer_no_cancels_and_yes_proceeds(self):
        result = self.run_with_answer(b"n\n", "-c", "alpha")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Archive tier", result.stdout)
        self.assertEqual(self.calls(), [])
        result = self.run_with_answer(b"y\n", "-c", "alpha")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls()), 3)

    def test_empty_container_has_nothing_to_do(self):
        result = self.run_script("-c", "empty", "-y")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nothing to unarchive", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_missing_container_is_an_error(self):
        result = self.run_script("-c", "missing", "-y")
        self.assertEqual(result.returncode, 1)
        self.assertIn("container not found", result.stderr)

    def test_failures_are_reported(self):
        self.write_blobs({"alpha": [blob("fail.jpg"), blob("ok.jpg")]})
        result = self.run_script("-c", "alpha", "-y")
        self.assertEqual(result.returncode, 2)
        self.assertIn("alpha/fail.jpg", result.stderr)
        self.assertEqual(self.calls(), ["alpha ok.jpg Hot"])


if __name__ == "__main__":
    unittest.main()
