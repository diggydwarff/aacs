"""Stage the AACS in-game updater without changing configuration or live state."""
import argparse
import hashlib
import subprocess
import os
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from zipfile import ZipFile


def fresh_install():
    parser = argparse.ArgumentParser(description="Create fresh private AACS nodes and install them. Target CC computers must be powered off; Minecraft may remain online.")
    parser.add_argument("--fresh", action="store_true", required=True)
    parser.add_argument("--hq", type=int, required=True)
    for role in ("station", "kiosk", "registrar", "beacon"):
        parser.add_argument("--" + role, action="append", default=[])
    parser.add_argument("--dimension", default="minecraft:overworld")
    parser.add_argument("--computer-root", type=Path, default=Path("server/computercraft/computer"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--reset-aacs", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="aacs-package-") as temporary:
        unpacked = Path(temporary)
        with ZipFile(Path(sys.argv[0]).resolve()) as archive:
            checksums = dict(line.split("  ", 1)[::-1] for line in archive.read("AACS/SHA256SUMS.txt").decode().splitlines())
            for relative, expected in checksums.items():
                target = unpacked / "AACS" / relative
                if (unpacked / "AACS").resolve() not in target.resolve().parents:
                    raise ValueError("Unsafe package path")
                content = archive.read("AACS/" + relative)
                if hashlib.sha256(content).hexdigest() != expected:
                    raise ValueError("Package checksum failed: " + relative)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(content)
        source = unpacked / "AACS"
        # Use a uniquely named private directory; never overwrite previous keys.
        output = args.output or Path("aacs-private-" + datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-" ) + os.urandom(3).hex())
        command = [sys.executable, str(source / "tools/provision.py"), "--hq", str(args.hq),
                   "--dimension", args.dimension, "--output", str(output)]
        for role in ("station", "kiosk", "registrar", "beacon"):
            for spec in getattr(args, role):
                command.extend(["--" + role, spec])
        subprocess.run(command, check=True)
        subprocess.run([sys.executable, str(source / "tools/deploy.py"), "--deployment", str(output),
                        "--computer-root", str(args.computer_root)] + (["--reset-aacs"] if args.reset_aacs else []), check=True)


def main():
    if "--fresh" in sys.argv[1:]:
        fresh_install()
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--computers", nargs="+", type=int, required=True)
    parser.add_argument("--computer-root", default="server/computercraft/computer")
    args = parser.parse_args()
    if any(number < 0 or number > 2147483647 for number in args.computers):
        raise ValueError("Computer IDs must be nonnegative integers.")
    if len(set(args.computers)) != len(args.computers):
        raise ValueError("List each computer only once.")

    os.umask(0o077)
    base = Path(args.computer_root).resolve()
    roots = [base / str(number) for number in args.computers]
    for root in roots:
        if not root.is_dir() or root.is_symlink():
            raise ValueError(f"Computer folder missing: {root}")
        target = root / "aacs_install.lua"
        if target.is_symlink() or (target.exists() and not target.is_file()):
            raise ValueError(f"Installer target is not a regular file: {target}")
        if (root / "aacs/data/run.lock").exists():
            raise ValueError(f"Stop AACS on computer {root.name} with Q first.")

    with ZipFile(Path(sys.argv[0]).resolve()) as archive:
        installer = archive.read("AACS/aacs_install.lua")
        checksums = dict(line.split("  ", 1)[::-1]
                         for line in archive.read("AACS/SHA256SUMS.txt").decode().splitlines())
        if hashlib.sha256(installer).hexdigest() != checksums.get("aacs_install.lua"):
            raise ValueError("Installer checksum failed.")

    backup_root = Path("aacs-update-backups")
    backup_root.mkdir(mode=0o700, exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-")
    backup = Path(tempfile.mkdtemp(prefix=timestamp, dir=backup_root))

    for root in roots:
        target = root / "aacs_install.lua"
        owner = target.stat() if target.exists() else root.stat()
        if target.exists():
            shutil.copy2(target, backup / f"computer-{root.name}-installer.lua")
        descriptor, temporary = tempfile.mkstemp(prefix="aacs-update-", dir=root)
        try:
            with os.fdopen(descriptor, "wb") as output:
                output.write(installer)
            os.chown(temporary, owner.st_uid, owner.st_gid)
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        print(f"Updated installer on computer {root.name}.")

    print("On each computer: aacs_install.lua --upgrade")
    print("Then run /aacs/start.lua selftest and start HQ before stations.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Update stopped: {error}", file=sys.stderr)
        sys.exit(1)
