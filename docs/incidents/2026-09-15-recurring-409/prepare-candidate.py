#!/usr/bin/env python3
"""Prepare two reviewed functions from a verified live snapshot; no network writes."""

import argparse
import hashlib
import json
from pathlib import Path
import runpy
import shutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    args = parser.parse_args()
    docs = Path(__file__).resolve().parent
    source = docs.parents[2]
    manifest = json.loads((docs / "candidate-manifest.json").read_text())
    verify = runpy.run_path(str(docs.parent / "2026-09-06-reliability/verify-candidate.py"))
    baseline = args.baseline_root.resolve(strict=True)
    output = args.output_root.absolute()
    if output.exists():
        raise ValueError("Candidate destination must be new")
    verify["verify_functions"](baseline, "baseline", manifest)
    for item in manifest["source_inputs"]:
        path = source / item["source_path"]
        if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != item["source_sha256"]:
            raise ValueError(f"Reviewed source differs: {item['source_path']}")
    target = output / "base44"
    target.mkdir(parents=True)
    for name in [".app.jsonc", "config.jsonc"]:
        shutil.copy2(baseline / "base44" / name, target / name)
    for row in manifest["functions"]:
        if row["name"] not in manifest["target_functions"]:
            continue
        original = baseline / "base44/functions" / row["name"]
        config = verify["read_jsonc"](original / "function.jsonc")
        runtime = original / Path(config["entry"]).parent
        staged = target / "functions" / row["name"]
        staged.mkdir(parents=True)
        for name in row["baseline_files"]:
            (staged / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(runtime / name, staged / name)
        config["entry"] = row["entry_basename"]
        (staged / "function.jsonc").write_text(json.dumps(config, indent=2) + "\n")
    for item in manifest["source_inputs"]:
        shutil.copy2(source / item["source_path"], output / item["runtime_path"])
    verify["verify_functions"](output, "candidate", manifest)
    print(f"Prepared candidate at {output}; production remains unchanged.")


if __name__ == "__main__":
    main()
