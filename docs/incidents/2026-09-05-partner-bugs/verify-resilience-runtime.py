#!/usr/bin/env python3
"""Read-only Build 144 runtime/configuration guard; accepts staging or CLI pull layout."""

import argparse
import hashlib
import json
from pathlib import Path
import sys


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--mode", choices=["baseline", "candidate"], required=True)
    args = parser.parse_args()
    args.root = args.root.resolve(strict=True)
    manifest = json.loads(Path(__file__).with_name("resilience-144-runtime-manifest.json").read_text())
    binding = args.root / "base44/.app.jsonc"
    if binding.is_symlink() or json.loads(binding.read_text()).get("id") != manifest["canonical_app_id"]:
        raise ValueError("App binding is not the reviewed SpyClash target")
    failures = []
    count = 0
    for function in manifest["functions"]:
        name = function["name"]
        directory = args.root / "base44/functions" / name
        config_file = directory / "function.jsonc"
        if config_file.is_symlink():
            raise ValueError("Symlinked function configuration")
        config = json.loads(config_file.read_text())
        entry = config.get("entry")
        if entry not in ["entry.ts", f"base44/functions/{name}/entry.ts"]:
            raise ValueError(f"{name}: unexpected runtime entry")
        runtime = directory / Path(entry).parent
        if any(path.is_symlink() for path in [directory, runtime, *runtime.parents]):
            raise ValueError(f"{name}: symlinked runtime directory")
        config["entry"] = "entry.ts"
        encoded = json.dumps(config, sort_keys=True, separators=(",", ":")).encode()
        if digest(encoded) != function["normalized_config_sha256"]:
            failures.append(f"{name}: function configuration differs")
        expected = {row["path"]: row[f"{args.mode}_sha256"] for row in function["files"] if row[f"{args.mode}_sha256"] is not None}
        observed = {path.name for path in runtime.iterdir()}
        if runtime == directory:
            observed.discard("function.jsonc")
        if observed != set(expected):
            failures.append(f"{name}: runtime inventory differs")
        for relative, expected_hash in expected.items():
            path = runtime / relative
            if not path.is_file() or path.is_symlink() or digest(path.read_bytes()) != expected_hash:
                failures.append(f"{name}/{relative}: runtime hash differs or file missing")
            count += 1
    if failures:
        print("STOP: reviewed runtime does not match.\n" + "\n".join(failures), file=sys.stderr)
        return 1
    print(f"Verified {args.mode}: {count} runtime files and {len(manifest['functions'])} configurations.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError) as error:
        print(f"STOP: verification failed: {error}", file=sys.stderr)
        sys.exit(1)
