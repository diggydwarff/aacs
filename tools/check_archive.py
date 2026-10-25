#!/usr/bin/env python3
"""Exercise the executable ZIP against temporary computer roots only."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from zipfile import ZipFile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    archive = parser.parse_args().archive.resolve()
    with ZipFile(archive) as bundle:
        assert bundle.testzip() is None
        for line in bundle.read("AACS/SHA256SUMS.txt").decode().splitlines():
            expected, name = line.split("  ", 1)
            assert hashlib.sha256(bundle.read("AACS/" + name)).hexdigest() == expected, name
        installer = bundle.read("AACS/aacs_install.lua")
    with tempfile.TemporaryDirectory(prefix="aacs-archive-review-") as directory:
        base = Path(directory)
        computers = base / "server/computercraft/computer"
        for number in (108, 112):
            root = computers / str(number)
            root.mkdir(parents=True)
            (root / "other.lua").write_text("KEEP UNRELATED PROGRAM")

        def run(*arguments, success=True):
            result = subprocess.run([sys.executable, str(archive), *arguments], cwd=base,
                                    capture_output=True, text=True)
            if success:
                assert result.returncode == 0, result.stdout + result.stderr
            else:
                assert result.returncode != 0, "Invalid installation unexpectedly succeeded"
            return result

        run("--fresh", "--hq", "112", "--station", "capital=108", "--output", "private")
        station_path = computers / "108/aacs/config.json"
        original_config = station_path.read_bytes()
        station = json.loads(original_config)
        hq = json.loads((computers / "112/aacs/config.json").read_text())
        assert station["computer"] == 108 and hq["computer"] == 112
        assert station["peers"]["hq"]["key"] == hq["peers"]["capital"]["key"]
        assert "function M.event" in (computers / "108/aacs/lib/chat.lua").read_text()
        print("PASS executable ZIP fresh install and matched node identities/keys")

        for number in (108, 112):
            (computers / str(number) / "aacs/data/registry-marker.txt").write_text("KEEP REGISTRY")
        before = {path: path.read_bytes() for path in computers.rglob("*") if path.is_file()}
        run("--computers", "108", "112")
        for path, content in before.items():
            assert path.read_bytes() == content, path
        assert (computers / "108/aacs_install.lua").read_bytes() == installer
        print("PASS code staging preserves configuration, counters, registry, startup and unrelated files")

        (computers / "108/aacs/data/run.lock").write_text("running")
        (computers / "112/aacs_install.lua").write_bytes(b"UNCHANGED ON PREFLIGHT FAILURE")
        before = {path: path.read_bytes() for path in computers.rglob("*") if path.is_file()}
        run("--computers", "112", "108", success=False)
        for path, content in before.items():
            assert path.read_bytes() == content, path
        (computers / "108/aacs/data/run.lock").unlink()
        print("PASS active target refusal happens before any other selected computer is modified")

        outside = base / "outside.txt"
        outside.write_text("DO NOT TOUCH")
        target = computers / "108/aacs_install.lua"
        target.unlink()
        target.symlink_to(outside)
        run("--computers", "108", success=False)
        assert outside.read_text() == "DO NOT TOUCH"
        target.unlink()
        print("PASS code staging refuses a symlinked installer target")

        run("--fresh", "--hq", "112", "--station", "capital=108", "--output", "new-private", "--reset-aacs")
        assert not (computers / "112/aacs/data/registry-marker.txt").exists()
        backups = list(base.glob("aacs-fresh-backups/*/112/aacs/data/registry-marker.txt"))
        assert len(backups) == 1 and backups[0].read_text() == "KEEP REGISTRY"
        assert station_path.read_bytes() != original_config
        assert (computers / "108/other.lua").read_text() == "KEEP UNRELATED PROGRAM"
        print("PASS explicit fresh reset keeps complete old AACS backups and preserves other programs")


if __name__ == "__main__":
    main()
