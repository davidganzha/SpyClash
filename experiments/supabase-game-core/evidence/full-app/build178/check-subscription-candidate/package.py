"""Verify the reviewed bundle, or rebuild it from the exact recorded pull.

This program only reads and writes local files. It never deploys or calls APIs.
"""
import argparse
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, help="Directory containing the eight pulled runtime .ts files")
parser.add_argument("--output", type=Path, help="New empty project directory for a byte-identical rebuild")
args = parser.parse_args()
if bool(args.source) != bool(args.output):
    parser.error("--source and --output must be supplied together")

manifest = json.loads((ROOT / "source-manifest.json").read_text())
source = args.source or ROOT / "base44/functions/checkSubscription"
expected = {item["file"] for item in manifest["files"]}
actual = {path.name for path in source.iterdir() if path.suffix == ".ts"}
if actual != expected:
    raise SystemExit("Runtime file set differs from the reviewed eight-file bundle")
payloads = {}
for item in manifest["files"]:
    data = (source / item["file"]).read_bytes()
    if len(data) != item["bytes"] or hashlib.sha256(data).hexdigest() != item["sha256"]:
        raise SystemExit("Source integrity mismatch: " + item["file"])
    payloads[item["file"]] = data

if args.output:
    if args.output.exists() and any(args.output.iterdir()):
        raise SystemExit("Output must be absent or empty; existing files will not be replaced")
    destination = args.output / "base44/functions/checkSubscription"
    destination.mkdir(parents=True, exist_ok=True)
    for name, data in payloads.items():
        (destination / name).write_bytes(data)
    for relative in ["base44/config.jsonc", "base44/functions/checkSubscription/function.jsonc"]:
        (args.output / relative).write_bytes((ROOT / relative).read_bytes())
    (args.output / "source-manifest.json").write_bytes((ROOT / "source-manifest.json").read_bytes())
    print("Rebuilt one local function bundle. No application binding or deployment performed.")
else:
    function_directories = [p.name for p in (ROOT / "base44/functions").iterdir() if p.is_dir()]
    if function_directories != ["checkSubscription"]:
        raise SystemExit("Unexpected extra function in deployment project")
    configuration = json.loads((source / "function.jsonc").read_text())
    if configuration != {"name": "checkSubscription", "entry": "entry.ts"}:
        raise SystemExit("Unexpected function name or entrypoint")
    print("Verified eight byte-identical runtime files and the single-function deployment scope.")
