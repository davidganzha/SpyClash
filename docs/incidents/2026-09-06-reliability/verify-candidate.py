#!/usr/bin/env python3
"""Read-only exact inventory/hash guard for the scoped reliability candidate."""

import argparse
import hashlib
import json
from pathlib import Path
import sys


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def read_jsonc(path):
    return json.loads("\n".join(
        line for line in path.read_text().splitlines()
        if not line.lstrip().startswith("//")
    ))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_root(root, resource, manifest):
    base = root / "base44"
    for path in [base, *base.rglob("*")]:
        require(not path.is_symlink(), "Symlinked Base44 resource")
    require({p.name for p in base.iterdir()} == {".app.jsonc", "config.jsonc", resource},
            "Unexpected resource/configuration inventory")
    require(read_jsonc(base / ".app.jsonc") == {"id": manifest["canonical_app_id"]},
            "Wrong app binding")
    require(digest((base / "config.jsonc").read_bytes()) == manifest["project_config_sha256"],
            "Project configuration differs")
    return base / resource


def verify_functions(root, mode, manifest):
    directory = validate_root(root, "functions", manifest)
    selected = [row for row in manifest["functions"]
                if mode != "candidate" or row["name"] in manifest["target_functions"]]
    require({p.name for p in directory.iterdir()} == {row["name"] for row in selected},
            "Function inventory differs")
    count = 0
    for row in selected:
        function = directory / row["name"]
        config_file = function / "function.jsonc"
        config = read_jsonc(config_file)
        entry = row["entry_basename"]
        require(config.get("entry") in [entry, f"base44/functions/{row['name']}/{entry}"],
                f"{row['name']}: unexpected runtime entry")
        runtime = function / Path(config["entry"]).parent
        config["entry"] = entry
        require(digest(canonical(config)) == row["normalized_config_sha256"],
                f"{row['name']}: function configuration differs")
        hashes = row["baseline_files" if mode == "baseline" else "candidate_files"]
        expected = {config_file, *(runtime / path for path in hashes)}
        observed = {p for p in function.rglob("*") if p.is_file()}
        require(observed == expected, f"{row['name']}: runtime file inventory differs")
        expected_dirs = {function}
        for path in expected:
            expected_dirs.update(parent for parent in path.parents
                                 if parent == function or function in parent.parents)
        require({function, *(p for p in function.rglob('*') if p.is_dir())} == expected_dirs,
                f"{row['name']}: runtime directory inventory differs")
        for path, expected_hash in hashes.items():
            require(digest((runtime / path).read_bytes()) == expected_hash,
                    f"{row['name']}/{path}: runtime hash differs")
        count += len(hashes)
    print(f"Verified {mode}: {len(selected)} functions, {count} runtime files; exact configuration and binding.")


def verify_schemas(root, response, mode, manifest):
    if response:
        payload = json.loads(response.read_text())
        rows = payload["schemas"]
        require(payload["total"] == len(rows), "Remote schema count differs from rows")
        require(all(row["entity_name"] == row["entity_schema"]["name"] for row in rows),
                "Remote schema/name mismatch")
        schemas = [row["entity_schema"] for row in rows]
    else:
        directory = validate_root(root, "entities", manifest)
        files = list(directory.iterdir())
        require(all(p.is_file() and p.suffix == ".jsonc" for p in files),
                "Unexpected entity resource")
        schemas = [read_jsonc(path) for path in files]
    names = [row["name"] for row in schemas]
    require(len(set(names)) == len(names), "Duplicate entity name")
    actual = {row["name"]: digest(canonical(row)) for row in schemas}
    expected = manifest["baseline_schemas" if mode == "baseline" else "candidate_schemas"]
    require(actual == expected, "Schema inventory/content differs from reviewed set")
    print(f"Verified {mode}: {len(schemas)} schemas; all existing schema content preserved exactly.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("resource", choices=["functions", "schemas"])
    parser.add_argument("--mode", choices=["baseline", "candidate", "postflight"], required=True)
    parser.add_argument("--root", type=Path)
    parser.add_argument("--schema-response", type=Path)
    parser.add_argument("--source-root", type=Path, help="Also reject changes to reviewed source inputs")
    args = parser.parse_args()
    manifest = json.loads(Path(__file__).with_name("candidate-manifest.json").read_text())
    require(manifest["status"] == "reviewed_local_candidate", "Candidate is not finalized")
    require(digest(Path(__file__).with_name("runtime.patch").read_bytes()) == manifest["runtime_patch_sha256"],
            "Reviewed runtime patch changed")
    if args.source_root:
        source = args.source_root.resolve(strict=True)
        for row in manifest["source_inputs"]:
            path = source / row["source_path"]
            require(path.is_file() and not path.is_symlink() and digest(path.read_bytes()) == row["source_sha256"],
                    f"Source input changed: {row['source_path']}")
    require(bool(args.root) != bool(args.schema_response), "Choose exactly one root or schema response")
    if args.resource == "functions":
        require(args.root is not None, "Functions require a root")
        verify_functions(args.root.resolve(strict=True), args.mode, manifest)
    else:
        verify_schemas(args.root.resolve(strict=True) if args.root else None,
                       args.schema_response, args.mode, manifest)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"STOP: {error}", file=sys.stderr)
        sys.exit(1)
