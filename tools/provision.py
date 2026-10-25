#!/usr/bin/env python3
"""Create a fresh AACS network with OS-generated, pairwise 256-bit keys.

Run on your own PC/server. Output contains secrets. Never distribute the whole
output folder to players: give each machine ONLY its own node directory.
Requires Python 3.9+, standard library only; no network connections.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil


def store(path: Path, value: dict) -> None:
    payload = json.dumps(value, separators=(",", ":"), ensure_ascii=True)
    data = {"payload": payload, "sha256": hashlib.sha256(payload.encode()).hexdigest()}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")


def node_spec(text: str) -> tuple[str, int]:
    try:
        name, number = text.split("=", 1)
        computer = int(number)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("Use NAME=COMPUTER_ID, e.g. capital=12") from exc
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,31}", name) or name == "hq" or not 0 <= computer <= 2147483647:
        raise argparse.ArgumentTypeError("Invalid node name or computer ID")
    return name, computer


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hq", required=True, type=int, help="HQ Minecraft computer ID (the in-game id command)")
    for role in ("station", "kiosk", "registrar", "beacon"):
        parser.add_argument("--" + role, type=node_spec, action="append", default=[], metavar="NAME=ID")
    parser.add_argument("--output", type=Path, default=Path("aacs-deployment"))
    parser.add_argument("--dimension", default="minecraft:overworld")
    args = parser.parse_args()
    if not 0 <= args.hq <= 2147483647:
        parser.error("HQ ID must be an integer from 0 to 2147483647")
    if args.output.exists():
        parser.error("Output already exists. Refusing to overwrite keys or replay counters.")
    if not re.fullmatch(r"[a-z0-9_.-]+:[a-z0-9_./-]+", args.dimension):
        parser.error("Use a dimension resource ID, such as minecraft:overworld")
    nodes = [("hq", args.hq, "hq")]
    for role in ("station", "kiosk", "registrar", "beacon"):
        nodes.extend((name, number, role) for name, number in getattr(args, role))
    if len({n for n, _, _ in nodes}) != len(nodes) or len({i for _, i, _ in nodes}) != len(nodes):
        parser.error("Every node name and computer ID must be unique")
    if len(nodes) > 33:
        parser.error("This testing release supports up to 32 peers")
    args.output.mkdir(parents=True, mode=0o700)
    realm = "ard-" + secrets.token_hex(12)
    keys = {name: secrets.token_hex(32) for name, _, role in nodes if role != "hq"}
    source = Path(__file__).resolve().parents[1] / "aacs"
    inventory = []
    for name, number, role in nodes:
        root = args.output / name
        shutil.copytree(source, root / "aacs")
        config = {
            "schema": 1, "realm": realm, "node": name, "computer": number,
            "role": role, "hq": "hq", "dimension": args.dimension, "modems": [],
            "monitor": "", "peers": {}, "scanSeconds": 2,
            "logBytes": 49152, "logSegments": 3,
        }
        if role == "hq":
            for other, other_id, other_role in nodes:
                if other != name:
                    config["peers"][other] = {
                        "computer": other_id, "role": other_role, "key": keys[other],
                        "namespace": "radar-" + other, "dimension": args.dimension,
                    }
        else:
            config["peers"]["hq"] = {"computer": args.hq, "role": "hq", "key": keys[name]}
        if role == "station":
            config.update({
                "radars": [], "playerDetector": "", "playerRange": 128,
                "namespace": "radar-" + name, "radarFreshMs": 15000,
                "coverage": {"x": 0, "y": 64, "z": 0, "radius": 4096},
                "alarmSide": "", "faultSide": "", "sensorsConfigured": False,
                "chatBox": "", "chatPublicHails": False, "chatIntervalSeconds": 1.5,
            })
        (root / "aacs" / "config.json").write_text(json.dumps(config, indent=2), encoding="utf-8")
        store(root / "aacs" / "data" / "transport.json", {
            "realm": realm, "node": name, "sentThrough": 0, "received": {},
        })
        (root / "startup.lua").write_text('shell.run("/aacs/start.lua", "boot")\n', encoding="utf-8")
        (root / ".settings").write_text('{ ["shell.allow_disk_startup"] = false }\n', encoding="utf-8")
        inventory.append({"node": name, "computer": number, "role": role})
        # Best effort on Unix. Windows users must secure the directory with ACLs.
        for path in root.rglob("*"):
            try:
                os.chmod(path, 0o700 if path.is_dir() else 0o600)
            except OSError:
                pass
    (args.output / "inventory.json").write_text(json.dumps(inventory, indent=2), encoding="utf-8")
    print(f"Created {len(nodes)} nodes in {args.output.resolve()}")
    print("Each node directory is a complete computer root. Copy ONLY that node to its matching computer.")
    print("Keep this deployment private. Never reuse transport.json or a computer image for a second live machine.")
    print("For an existing computer, preserve its .settings/startup files and use the setup guide to merge settings.")
    print("Before use, run: /aacs/start.lua selftest ; /aacs/start.lua setup")


if __name__ == "__main__":
    main()
