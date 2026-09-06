#!/usr/bin/env python3
"""Read-only guard for the isolated two-function Google sign-in recovery candidate."""

import argparse
import hashlib
import json
from pathlib import Path
import sys


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_jsonc(path):
    # The reviewed project/binding files contain only whole-line comments.
    # Reject unsupported JSONC instead of guessing at strings or inline syntax.
    return json.loads("\n".join(
        line for line in path.read_text().splitlines()
        if not line.lstrip().startswith("//")
    ))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--mode", choices=["baseline", "candidate"], required=True)
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    manifest = json.loads(Path(__file__).with_name("backend-runtime-manifest.json").read_text())
    failures = []
    base = root / "base44"
    for path in [base, *base.rglob("*")]:
        if path.is_symlink():
            raise ValueError("Symlinked Base44 resource")
    if {path.name for path in base.iterdir()} != {".app.jsonc", "config.jsonc", "functions"}:
        raise ValueError("Unexpected Base44 resource/configuration inventory")
    if read_jsonc(base / ".app.jsonc") != {"id": manifest["canonical_app_id"]}:
        raise ValueError("App binding is not the reviewed SpyClash target")
    if digest((base / "config.jsonc").read_bytes()) != manifest["project_config_sha256"]:
        raise ValueError("Project configuration differs from the reviewed candidate")
    functions = base / "functions"
    if {path.name for path in functions.iterdir()} != {row["name"] for row in manifest["functions"]}:
        raise ValueError("Function inventory is not exactly the two reviewed functions")

    count = 0
    for function in manifest["functions"]:
        name = function["name"]
        directory = functions / name
        config_file = directory / "function.jsonc"
        config = read_jsonc(config_file)
        entry = config.get("entry")
        expected_entry = function["entry_basename"]
        if entry not in [expected_entry, f"base44/functions/{name}/{expected_entry}"]:
            raise ValueError(f"{name}: unexpected runtime entry")
        runtime = directory / Path(entry).parent
        config["entry"] = expected_entry
        encoded = json.dumps(config, sort_keys=True, separators=(",", ":")).encode()
        if digest(encoded) != function["normalized_config_sha256"]:
            failures.append(f"{name}: function configuration differs")
        expected = {
            row["path"]: row[f"{args.mode}_sha256"]
            for row in function["files"] if row[f"{args.mode}_sha256"] is not None
        }
        expected_files = {config_file, *(runtime / relative for relative in expected)}
        observed_files = {path for path in directory.rglob("*") if path.is_file()}
        expected_dirs = {directory}
        for path in expected_files:
            expected_dirs.update(parent for parent in path.parents if parent == directory or directory in parent.parents)
        observed_dirs = {directory, *(path for path in directory.rglob("*") if path.is_dir())}
        if observed_files != expected_files or observed_dirs != expected_dirs:
            failures.append(f"{name}: runtime/resource inventory differs")
        for relative, expected_hash in expected.items():
            path = runtime / relative
            if not path.is_file() or digest(path.read_bytes()) != expected_hash:
                failures.append(f"{name}/{relative}: runtime hash differs or file missing")
            count += 1
    if failures:
        print("STOP: reviewed runtime does not match.\n" + "\n".join(failures), file=sys.stderr)
        return 1
    print(f"Verified {args.mode}: {count} runtime files, 2 configurations, exact two-function scope and app binding.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError) as error:
        print(f"STOP: verification failed: {error}", file=sys.stderr)
        sys.exit(1)
