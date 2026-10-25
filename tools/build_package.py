#!/usr/bin/env python3
"""Rebuild the offline Lua installer, checksum manifest and source ZIP."""
from pathlib import Path
import argparse
import hashlib
import json
import re
from zipfile import ZipFile, ZIP_DEFLATED

ROOT = Path(__file__).resolve().parents[1]


def build(destination: Path) -> None:
    installer = ROOT / "aacs_install.lua"
    previous = installer.read_text()
    header = re.sub(r"AACS \d+\.\d+\.\d+[\w.-]*:", "AACS 0.2.3-beta.1:", previous.split("local files={", 1)[0], count=1)
    tail = previous[previous.rindex("}\nlocal paths={}"):]
    entries = []
    for path in sorted((ROOT / "aacs").rglob("*.lua")):
        source = path.read_text()
        if "]===]" in source:
            raise ValueError(f"Lua long-string delimiter conflict: {path}")
        name = "/" + path.relative_to(ROOT).as_posix()
        entries.append("    [" + json.dumps(name) + "] = [===[\n" + source + "]===],\n")
    installer.write_text(header + "local files={\n" + "".join(entries) + tail)
    paths = sorted(path for path in ROOT.rglob("*") if path.is_file()
                   and "__pycache__" not in path.parts and path.name != "SHA256SUMS.txt"
                   and path.suffix not in (".pyc", ".zip") and not any(part.startswith(".") for part in path.relative_to(ROOT).parts))
    manifest = ROOT / "SHA256SUMS.txt"
    manifest.write_text("".join(hashlib.sha256(path.read_bytes()).hexdigest() + "  "
                                + path.relative_to(ROOT).as_posix() + "\n" for path in paths))
    destination = destination.resolve()
    with ZipFile(destination, "w", ZIP_DEFLATED) as archive:
        for path in [*paths, manifest]:
            archive.write(path, "AACS/" + path.relative_to(ROOT).as_posix())
        archive.write(ROOT / "tools/stage_update.py", "__main__.py")
    with ZipFile(destination) as archive:
        assert archive.testzip() is None
        for line in archive.read("AACS/SHA256SUMS.txt").decode().splitlines():
            expected, name = line.split("  ", 1)
            assert hashlib.sha256(archive.read("AACS/" + name)).hexdigest() == expected, name
        assert archive.read("__main__.py") == archive.read("AACS/tools/stage_update.py")
    print(f"Built {destination}: {destination.stat().st_size} bytes, {len(entries)} runtime Lua files")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    build(parser.parse_args().output)
