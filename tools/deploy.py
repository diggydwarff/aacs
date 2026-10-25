#!/usr/bin/env python3
"""Install private AACS node images onto dedicated, powered-off CC computers.

Minecraft can remain online. Exit AACS with Q, then run shutdown in each target
computer first. Filesystem access cannot independently verify its power state.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import tempfile


def atomic_file(source: Path, target: Path, owner: os.stat_result) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix="aacs-stage-", dir=target.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(source.read_bytes())
        if hasattr(os, "chown"):
            os.chown(temporary, owner.st_uid, owner.st_gid)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def secure_tree(root: Path, owner: os.stat_result) -> None:
    for path in [root, *root.rglob("*")]:
        if path.is_symlink():
            raise ValueError(f"Symlinks are not supported: {path}")
        os.chmod(path, 0o700 if path.is_dir() else 0o600)
        if hasattr(os, "chown"):
            os.chown(path, owner.st_uid, owner.st_gid)


def targets(deployment: Path, computer_root: Path, reset: bool) -> list[tuple[Path, Path]]:
    inventory = json.loads((deployment / "inventory.json").read_text())
    result = []
    for node in inventory:
        number = node["computer"]
        if not isinstance(number, int) or not 0 <= number <= 2147483647:
            raise ValueError("Invalid computer ID in deployment")
        name = node["node"]
        if not isinstance(name, str) or not name.replace("_", "").replace("-", "").isalnum():
            raise ValueError("Invalid node name in deployment")
        image = deployment / name
        if image.is_symlink() or any(path.is_symlink() for path in image.rglob("*")):
            raise ValueError(f"Refusing a private node image containing symlinks: {image}")
        root = computer_root / str(number)
        if not root.is_dir() or root.is_symlink():
            raise ValueError(f"Computer folder missing or unsafe: {root}. Boot the computer once and verify its id.")
        for relative in ("aacs", "startup.lua", ".settings"):
            existing = root / relative
            if existing.is_symlink() or (existing.is_dir() and any(p.is_symlink() for p in existing.rglob("*"))):
                raise ValueError(f"Refusing to modify a symlink: {existing}")
            if existing.exists() and not (existing.is_dir() if relative == "aacs" else existing.is_file()):
                raise ValueError(f"Unexpected file type at {existing}")
        if (root / "aacs/data/run.lock").exists():
            raise ValueError(f"Computer {number}: exit AACS with Q before shutting it down. AACS run.lock still exists.")
        if ((root / "aacs").exists() or (root / "startup.lua").exists()) and not reset:
            raise ValueError(f"Computer {number} already has AACS/startup. Use --reset-aacs only for a deliberate fresh start, or use the code updater.")
        if not (image / "aacs/config.json").is_file() or not (image / "aacs/data/transport.json").is_file():
            raise ValueError(f"Incomplete private node image: {image}")
        config = json.loads((image / "aacs/config.json").read_text())
        if config["computer"] != number or config["node"] != name:
            raise ValueError("Deployment config and inventory disagree")
        result.append((image, root))
    if len({str(root) for _, root in result}) != len(result):
        raise ValueError("Duplicate computer IDs")
    return result


def install(deployment: Path, computer_root: Path, reset: bool = False) -> Path:
    # Preflight every node before changing any live computer files.
    planned = targets(deployment, computer_root, reset)
    backup_base = Path("aacs-fresh-backups")
    backup_base.mkdir(mode=0o700, exist_ok=True)
    prefix = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-")
    backup = Path(tempfile.mkdtemp(prefix=prefix, dir=backup_base)).resolve()
    for _, root in planned:
        destination = backup / root.name
        destination.mkdir(mode=0o700)
        for name in ("aacs", "startup.lua", ".settings"):
            source = root / name
            if source.is_dir():
                shutil.copytree(source, destination / name)
            elif source.is_file():
                shutil.copy2(source, destination / name)
    staged = []
    committed = []
    try:
        for image, root in planned:
            stage = Path(tempfile.mkdtemp(prefix="aacs-fresh-", dir=root))
            staged.append((image, root, stage))
            shutil.copytree(image / "aacs", stage / "aacs")
            secure_tree(stage, root.stat())
        for image, root, stage in staged:
            old = stage / "previous-aacs"
            had_aacs = (root / "aacs").exists()
            if had_aacs:
                os.replace(root / "aacs", old)
            committed.append((root, stage, had_aacs))
            os.replace(stage / "aacs", root / "aacs")
            atomic_file(image / "startup.lua", root / "startup.lua", root.stat())
            # Keep existing non-AACS settings; setup saves shell.allow_disk_startup=false.
            if not (root / ".settings").exists():
                atomic_file(image / ".settings", root / ".settings", root.stat())
            print(f"Installed fresh node {image.name} on computer {root.name}.")
    except Exception:
        # Restore all computer roots touched by this attempt, including startup/settings.
        for root, stage, had_aacs in reversed(committed):
            if (root / "aacs").exists():
                shutil.rmtree(root / "aacs")
            if had_aacs:
                os.replace(stage / "previous-aacs", root / "aacs")
            for name in ("startup.lua", ".settings"):
                saved = backup / root.name / name
                if saved.is_file():
                    atomic_file(saved, root / name, root.stat())
                elif (root / name).exists():
                    (root / name).unlink()
        raise
    finally:
        for _, _, stage in staged:
            shutil.rmtree(stage, ignore_errors=True)
    print(f"Backup: {backup}")
    print("Boot each computer. Run /aacs/start.lua selftest and /aacs/start.lua setup.")
    print("Start HQ first; then stations. Fresh keys/registries are a separate network from the old deployment.")
    return backup


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deployment", type=Path, required=True)
    parser.add_argument("--computer-root", type=Path, default=Path("server/computercraft/computer"))
    parser.add_argument("--reset-aacs", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    install(args.deployment.resolve(), args.computer_root.resolve(), args.reset_aacs)


if __name__ == "__main__":
    main()
