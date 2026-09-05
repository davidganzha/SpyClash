#!/usr/bin/env python3
"""Read-only hash/inventory guard for the reviewed incident-only backend patch."""

import argparse
import hashlib
import json
from pathlib import Path
import sys


def digest(data):
    return hashlib.sha256(data).hexdigest()


def config_digest(path):
    value = json.loads(path.read_text())
    return digest(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="Root containing base44/functions")
    parser.add_argument("--mode", choices=["baseline", "candidate"], required=True)
    args = parser.parse_args()
    manifest = json.loads(Path(__file__).with_name("backend-runtime-manifest.json").read_text())
    failures = []
    count = 0
    for function in manifest["functions"]:
        name = function["name"]
        directory = args.root / "base44" / "functions" / name
        runtime = directory / "base44" / "functions" / name if args.mode == "baseline" else directory
        expected = {row["path"] for row in function["files"]}
        observed = {path.name for path in runtime.iterdir()} if runtime.is_dir() else set()
        if args.mode == "candidate":
            observed.discard("function.jsonc")
        if observed != expected:
            failures.append(f"{name}: runtime inventory differs")
        for row in function["files"]:
            file = runtime / row["path"]
            if not file.is_file() or file.is_symlink() or digest(file.read_bytes()) != row[f"{args.mode}_sha256"]:
                failures.append(f"{name}/{row['path']}: hash differs or file missing")
            count += 1
        config = directory / "function.jsonc"
        if not config.is_file() or config.is_symlink() or config_digest(config) != function[f"{args.mode}_config_sha256"]:
            failures.append(f"{name}/function.jsonc: configuration differs")
    if failures:
        print("STOP: reviewed runtime does not match.", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"Verified {args.mode}: {count} runtime files and 2 function configurations.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError) as error:
        print(f"STOP: runtime verification failed: {error}", file=sys.stderr)
        sys.exit(1)
