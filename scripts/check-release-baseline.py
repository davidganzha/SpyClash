#!/usr/bin/env python3
"""Read-only gate against accidentally replacing newer production code.

Without --remote-dir, checks source ancestry. Before preparing a server package,
pass the root of a NEW Base44 functions pull to compare every deployed runtime
file and function configuration with the recorded, verified production baseline.
This tool neither creates a package nor authorizes a deployment.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "docs/incidents/2026-09-15-409-hardening/deployment-postflight.json"


def require_current_checkout(checkout: Path, commit: str) -> None:
    result = subprocess.run(
        ["git", "-C", str(checkout), "merge-base", "--is-ancestor", commit, "HEAD"],
        capture_output=True, text=True,
    )
    if result.returncode:
        raise ValueError(
            f"STALE_CHECKOUT: HEAD does not contain production code {commit}. "
            "Use the current integration branch; do not deploy this checkout. "
            "A shallow clone must fetch the missing history first."
        )


def logical_path(function: str, relative: Path, entry: Path) -> Path:
    prefix = Path("base44/functions") / function
    normalized = relative.relative_to(prefix) if relative.is_relative_to(prefix) else relative
    if normalized.name == "entry.ts":
        if relative != entry:
            raise ValueError(f"Unexpected entry alias in {function}: {relative}")
        normalized = normalized.with_name("main.ts")
    return prefix / normalized


def remote_inventory(remote: Path):
    functions = remote / "base44/functions"
    if not functions.is_dir():
        raise ValueError("Expected a complete Base44 pull root with base44/functions")
    runtime, configs = {}, {}
    for folder in sorted(functions.iterdir()):
        if not folder.is_dir() or folder.is_symlink():
            raise ValueError(f"Unexpected function entry: {folder.name}")
        config = json.loads((folder / "function.jsonc").read_text())
        if config.get("name") != folder.name:
            raise ValueError(f"Function name mismatch: {folder.name}")
        entry = Path(config["entry"])
        if entry.is_absolute() or ".." in entry.parts or not (folder / entry).is_file():
            raise ValueError(f"Invalid function entry: {folder.name}")
        normalized_config = dict(config)
        normalized_config["entry"] = str(logical_path(folder.name, entry, entry))
        configs[folder.name] = normalized_config
        for file in sorted(folder.rglob("*")):
            if file.is_symlink():
                raise ValueError(f"Symlink in function {folder.name}")
            if not file.is_file() or file.suffix not in (".ts", ".js") or file.name.endswith("_test.ts"):
                continue
            key = str(logical_path(folder.name, file.relative_to(folder), entry))
            if key in runtime:
                raise ValueError(f"Duplicate normalized runtime: {key}")
            runtime[key] = hashlib.sha256(file.read_bytes()).hexdigest()
    return runtime, configs


def compare_inventory(actual, expected):
    missing = sorted(expected.keys() - actual.keys())
    extra = sorted(actual.keys() - expected.keys())
    changed = sorted(key for key in actual.keys() & expected.keys() if actual[key] != expected[key])
    if missing or extra or changed:
        raise ValueError("PRODUCTION_DRIFT: " + json.dumps({
            "missing": missing, "extra": extra, "changed": changed,
        }))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", type=Path, default=ROOT)
    parser.add_argument("--remote-dir", type=Path)
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text())
    require_current_checkout(args.checkout, manifest["code_commit"])
    if args.remote_dir:
        app_source = (args.remote_dir / "base44/.app.jsonc").read_text()
        app = json.loads("\n".join(line for line in app_source.splitlines() if not line.lstrip().startswith("//")))
        if app.get("id") != manifest["app_id"]:
            raise ValueError("Wrong Base44 application")
        actual, configs = remote_inventory(args.remote_dir)
        compare_inventory(actual, manifest["runtime_files"])
        expected_configs = {}
        for name, config in manifest["configs"].items():
            entry = Path(config["entry"])
            expected_configs[name] = {**config, "entry": str(logical_path(name, entry, entry))}
        compare_inventory(configs, expected_configs)
        print(f"PASS: current source ancestry; {len(configs)} functions / {len(actual)} runtime hashes match production baseline")
    else:
        print("PASS: source contains the verified production fixes. Live server was not checked; use --remote-dir before package preparation.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
