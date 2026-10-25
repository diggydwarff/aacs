#!/usr/bin/env python3
"""Host-side deployment tests; all computers and backups are temporary fixtures."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import deploy

SOURCE = Path(__file__).resolve().parents[1]


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="aacs-deploy-test-")
        self.base = Path(self.temporary.name)
        self.old_directory = Path.cwd()
        os.chdir(self.base)
        self.computers = self.base / "server/computercraft/computer"
        for number in (108, 112):
            (self.computers / str(number)).mkdir(parents=True)
        self.output = self.base / "private"
        self.provision(self.output)

    def tearDown(self):
        os.chdir(self.old_directory)
        self.temporary.cleanup()

    def provision(self, output):
        subprocess.run([sys.executable, str(SOURCE / "tools/provision.py"), "--hq", "112",
                        "--station", "capital=108", "--output", str(output)],
                       check=True, capture_output=True, text=True)

    def install(self, reset=False):
        with contextlib.redirect_stdout(io.StringIO()):
            return deploy.install(self.output, self.computers, reset)

    def test_fresh_install_has_correct_ids_keys_and_chat_defaults(self):
        self.install()
        station = json.loads((self.computers / "108/aacs/config.json").read_text())
        hq = json.loads((self.computers / "112/aacs/config.json").read_text())
        self.assertEqual(station["computer"], 108)
        self.assertEqual(station["chatBox"], "")
        self.assertFalse(station["chatPublicHails"])
        self.assertEqual(station["peers"]["hq"]["key"], hq["peers"]["capital"]["key"])
        self.assertEqual(len(station["peers"]["hq"]["key"]), 64)
        self.assertTrue((self.computers / "108/aacs/lib/chat.lua").exists())
        self.assertEqual((self.computers / "108/aacs/config.json").stat().st_mode & 0o777, 0o600)

    def test_all_targets_are_checked_before_any_write(self):
        (self.computers / "112/aacs/data").mkdir(parents=True)
        (self.computers / "112/aacs/data/run.lock").write_text("running")
        with self.assertRaisesRegex(ValueError, "run.lock"):
            self.install(reset=True)
        self.assertFalse((self.computers / "108/aacs").exists())

    def test_existing_deployment_refused_unless_reset_is_explicit(self):
        self.install()
        original = (self.computers / "108/aacs/config.json").read_bytes()
        with self.assertRaisesRegex(ValueError, "already has"):
            self.install()
        self.assertEqual((self.computers / "108/aacs/config.json").read_bytes(), original)

    def test_reset_backs_up_old_registry_keys_and_settings(self):
        self.install()
        registry = self.computers / "112/aacs/data/database.json"
        registry.write_text("OLD REGISTRY")
        original = (self.computers / "108/aacs/config.json").read_bytes()
        other_output = self.base / "new-private"
        self.provision(other_output)
        self.output = other_output
        backup = self.install(reset=True)
        self.assertEqual((backup / "112/aacs/data/database.json").read_text(), "OLD REGISTRY")
        self.assertEqual((backup / "108/aacs/config.json").read_bytes(), original)
        self.assertNotEqual((self.computers / "108/aacs/config.json").read_bytes(), original)
        self.assertFalse(registry.exists())

    def test_unrelated_programs_and_existing_settings_are_preserved(self):
        (self.computers / "108/other.lua").write_text("OTHER PROGRAM")
        (self.computers / "108/.settings").write_text("OTHER SETTINGS")
        self.install()
        self.assertEqual((self.computers / "108/other.lua").read_text(), "OTHER PROGRAM")
        self.assertEqual((self.computers / "108/.settings").read_text(), "OTHER SETTINGS")

    def test_mid_install_failure_rolls_back_all_modified_computers(self):
        self.install()
        for number in (108, 112):
            (self.computers / f"{number}/aacs/data/marker.txt").write_text(f"OLD-{number}")
        original = deploy.atomic_file
        writes = 0

        def failure(source, target, owner):
            nonlocal writes
            writes += 1
            if writes == 2:
                raise OSError("Simulated disk failure")
            return original(source, target, owner)

        with patch.object(deploy, "atomic_file", failure):
            with self.assertRaisesRegex(OSError, "Simulated"):
                self.install(reset=True)
        for number in (108, 112):
            self.assertEqual((self.computers / f"{number}/aacs/data/marker.txt").read_text(), f"OLD-{number}")

    def test_unexpected_startup_or_settings_directory_is_refused_before_writes(self):
        (self.computers / "112/.settings").mkdir()
        with self.assertRaisesRegex(ValueError, "Unexpected file type"):
            self.install(reset=True)
        self.assertFalse((self.computers / "108/aacs").exists())

    def test_symlinks_in_live_or_private_roots_are_refused(self):
        (self.computers / "108/aacs").symlink_to(self.output / "capital/aacs", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.install(reset=True)
        (self.computers / "108/aacs").unlink()
        (self.output / "capital/aacs/leak").symlink_to(self.base / "not-a-computer")
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.install()
        self.assertFalse((self.computers / "112/aacs").exists())

    def test_provision_refuses_duplicate_ids_and_overwriting_private_output(self):
        args = [sys.executable, str(SOURCE / "tools/provision.py"), "--hq", "112",
                "--station", "capital=112", "--output", str(self.base / "bad")]
        result = subprocess.run(args, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        with self.assertRaises(subprocess.CalledProcessError):
            self.provision(self.output)


if __name__ == "__main__":
    unittest.main()
