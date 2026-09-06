#!/usr/bin/env python3
"""Prepare local function/schema artifacts only; never performs network or deploy operations."""

import argparse
import datetime
import difflib
import hashlib
import json
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import tempfile


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--baseline-root", type=Path, required=True)
    parser.add_argument("--schema-response", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    args = parser.parse_args()
    source = args.source_root.resolve(strict=True)
    baseline = args.baseline_root.resolve(strict=True)
    output = args.output_root.absolute()
    require(not output.exists(), "Output must be a new isolated directory")
    docs = Path(__file__).resolve().parent
    snapshot = json.loads((docs / "baseline-manifest.json").read_text())
    verify = runpy.run_path(str(docs / "verify-candidate.py"))
    functions = [{**row, "baseline_files": {item["path"]: item["sha256"] for item in row["files"]}}
                 for row in snapshot["functions"]]
    baseline_schemas = {row["name"]: row["sha256"] for row in snapshot["schemas"]}
    baseline_view = {**snapshot, "functions": functions, "baseline_schemas": baseline_schemas}
    verify["verify_functions"](baseline, "baseline", baseline_view)
    verify["verify_schemas"](None, args.schema_response, "baseline", baseline_view)

    helpers = ["appleAuthBroker", "autoRegisterUser", "checkSubscription", "communityAction",
               "createCheckout", "deleteAccount", "gameRoomAction", "generateWordPack",
               "pushNotificationAction", "stripe-entitlement-webhook", "wordPackAction"]
    targets = sorted([*helpers, "googleAuthCallback"])
    specs = {row["name"]: row for row in functions}
    changes = {}
    provenance = []

    def at_base(path):
        return subprocess.run(["git", "show", f"{snapshot['source_head']}:{path}"], cwd=source,
                              capture_output=True, check=True).stdout

    def add(name, filename, source_path, *, require_base=True):
        deployed = baseline / "base44/functions" / name / filename
        if require_base:
            require(deployed.read_bytes() == at_base(source_path),
                    f"{name}/{filename}: deployed bytes do not match today's patch basis")
        source_file = source / source_path
        require(not source_file.is_symlink(), "Symlinked source input")
        data = source_file.read_bytes()
        changes[(name, filename)] = data
        provenance.append({"source_path": source_path, "source_sha256": digest(data),
                           "runtime_path": f"base44/functions/{name}/{filename}"})

    for name in helpers:
        add(name, "billing-identity-lifecycle.ts", f"base44/functions/{name}/billing-identity-lifecycle.ts")
    require(len({digest(changes[(name, "billing-identity-lifecycle.ts")]) for name in helpers}) == 1,
            "The eleven updated identity helpers are not identical")
    for name in ["generateWordPack", "deleteAccount"]:
        add(name, specs[name]["entry_basename"], f"base44/functions/{name}/main.ts")
    add("deleteAccount", "relationship-cleanup.ts", "base44/functions/deleteAccount/relationship-cleanup.ts")
    require(not (baseline / "base44/functions/generateWordPack/generation-operation.ts").exists(),
            "Operation journal unexpectedly exists in baseline")
    add("generateWordPack", "generation-operation.ts", "base44/functions/generateWordPack/generation-operation.ts",
        require_base=False)
    require((source / "base44/functions/generateWordPack/generation-retry-contract.ts").read_bytes() ==
            (baseline / "base44/functions/generateWordPack/generation-retry-contract.ts").read_bytes(),
            "Already deployed generation retry contract changed outside this scope")

    # These complete helper/caller diffs were separately reviewed against the
    # fixed remote snapshot; no other HEAD entry changes are selected.
    for name, filename in [
        ("gameRoomAction", "room-membership-generation.ts"),
        ("gameRoomAction", "community-profile-signal.ts"),
        ("gameRoomAction", "committed-game-start-repair.ts"),
        ("gameRoomAction", "terminal-side-effect-dispatch.ts"),
        ("pushNotificationAction", "main.ts"),
        ("pushNotificationAction", "error-response.ts"),
        ("pushNotificationAction", "inbox-backfill.ts"),
        ("pushNotificationAction", "safe-error.ts"),
    ]:
        source_path = f"base44/functions/{name}/{filename}"
        require((source / source_path).read_bytes() == at_base(source_path),
                f"{source_path}: reviewed historical fix changed")
        add(name, specs[name]["entry_basename"] if filename == "main.ts" else filename,
            source_path, require_base=False)
    selective_patch = docs / "game-room-followup.patch"
    relative = "base44/functions/gameRoomAction/entry.ts"
    headers = [line for line in selective_patch.read_text().splitlines()
               if line.startswith("--- ") or line.startswith("+++ ")]
    require(headers == [f"--- a/{relative}", f"+++ b/{relative}"],
            "Selective game-room patch must address only the reviewed entry")
    with tempfile.TemporaryDirectory(prefix="spyclash-146-game-patch-") as temporary:
        target = Path(temporary) / relative
        target.parent.mkdir(parents=True)
        shutil.copy2(baseline / relative, target)
        result = subprocess.run(["patch", "--batch", "--fuzz=0", "-p1", "-i", str(selective_patch)],
                                cwd=temporary, capture_output=True)
        require(result.returncode == 0, "Selective game-room patch does not apply exactly")
        changes[("gameRoomAction", "entry.ts")] = target.read_bytes()
    game_source_path = "base44/functions/gameRoomAction/main.ts"
    require(changes[("gameRoomAction", "entry.ts")] == at_base(game_source_path) ==
            (source / game_source_path).read_bytes(),
            "Connected game-room patch differs from its explicitly reviewed source revision")
    provenance.append({"source_path": str(selective_patch.relative_to(source)),
                       "source_sha256": digest(selective_patch.read_bytes()),
                       "runtime_path": relative, "transformation": "exact patch against verified baseline"})
    provenance.append({"source_path": game_source_path,
                       "source_sha256": digest((source / game_source_path).read_bytes()),
                       "runtime_path": relative, "transformation": "reviewed connected-hunk patch"})

    old_auth = json.loads((source / "docs/incidents/2026-09-06-authentication/backend-runtime-manifest.json").read_text())
    for name in ["appleAuthBroker", "googleAuthCallback"]:
        previous = next(row for row in old_auth["functions"] if row["name"] == name)
        entry = specs[name]["entry_basename"]
        hashes = next(row for row in previous["files"] if row["path"] == entry)
        require(specs[name]["baseline_files"][entry] == hashes["baseline_sha256"],
                f"{name}: fresh runtime drifted from reviewed recovery145 baseline")
        source_path = f"base44/functions/{name}/main.ts"
        require(digest(at_base(source_path)) == hashes["candidate_sha256"],
                f"{name}: source basis differs from reviewed recovery145 candidate")
        add(name, entry, source_path, require_base=False)
    add("appleAuthBroker", "google-state-recovery.ts", "base44/functions/appleAuthBroker/google-state-recovery.ts",
        require_base=False)

    raw_schemas = json.loads(args.schema_response.read_text())["schemas"]
    schemas = {row["entity_name"]: row["entity_schema"] for row in raw_schemas}
    ledger_path = source / "base44/entities/ai-word-pack-operation.jsonc"
    ledger = json.loads(ledger_path.read_text())
    require(ledger["name"] == "AiWordPackOperation" and ledger["name"] not in schemas,
            "Schema addition is not exactly a new AiWordPackOperation")
    require(ledger["rls"] == {action: {"user_condition": {"role": "admin"}}
                              for action in ["create", "read", "update", "delete"]},
            "Operation journal must remain admin-only for all operations")
    schemas[ledger["name"]] = ledger
    provenance.append({"source_path": str(ledger_path.relative_to(source)),
                       "source_sha256": digest(ledger_path.read_bytes()),
                       "runtime_path": "base44/entities/ai-word-pack-operation.jsonc"})
    output.mkdir()
    if (source / "node_modules").exists():
        (output / "node_modules").symlink_to((source / "node_modules").resolve(strict=True),
                                             target_is_directory=True)
    for kind in ["functions", "schemas"]:
        base = output / kind / "base44"
        base.mkdir(parents=True)
        for name in ["config.jsonc", ".app.jsonc"]:
            shutil.copy2(baseline / "base44" / name, base / name)
    function_stage = output / "functions/base44/functions"
    function_stage.mkdir()
    for name in targets:
        shutil.copytree(baseline / "base44/functions" / name, function_stage / name)
    for (name, filename), data in changes.items():
        (function_stage / name / filename).write_bytes(data)
    entity_stage = output / "schemas/base44/entities"
    entity_stage.mkdir()
    for name, schema in sorted(schemas.items()):
        filename = re.sub(r"(?<!^)(?=[A-Z][a-z]|(?<=[a-z0-9])[A-Z])", "-", name).lower() + ".jsonc"
        (entity_stage / filename).write_text(json.dumps(schema, sort_keys=True, indent=2) + "\n")

    patch = []
    for row in functions:
        name = row["name"]
        candidate = dict(row["baseline_files"])
        for (changed_name, filename), data in sorted(changes.items()):
            if changed_name != name:
                continue
            old_path = baseline / "base44/functions" / name / filename
            before = old_path.read_bytes() if old_path.exists() else b""
            candidate[filename] = digest(data)
            if before != data:
                relative = f"base44/functions/{name}/{filename}"
                patch.extend(difflib.unified_diff(before.decode().splitlines(keepends=True),
                                                  data.decode().splitlines(keepends=True),
                                                  fromfile=f"a/{relative}" if old_path.exists() else "/dev/null",
                                                  tofile=f"b/{relative}", n=0))
        row["candidate_files"] = candidate
        del row["files"]
    patch_bytes = "".join(patch).encode()
    (docs / "runtime.patch").write_bytes(patch_bytes)
    manifest = {"status": "reviewed_local_candidate", "canonical_app_id": snapshot["canonical_app_id"],
                "prepared_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "baseline_acquired_at_utc": snapshot["fetched_at_utc"], "source_base_revision": snapshot["source_head"],
                "output_root": str(output), "project_config_sha256": snapshot["project_config_sha256"],
                "target_functions": targets, "functions": functions, "baseline_schemas": baseline_schemas,
                "candidate_schemas": {name: digest(canonical(schema)) for name, schema in schemas.items()},
                "schema_additions": ["AiWordPackOperation"], "source_inputs": provenance,
                "runtime_patch_sha256": digest(patch_bytes)}
    (docs / "candidate-manifest.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
    verify["verify_functions"](output / "functions", "candidate", manifest)
    verify["verify_schemas"](output / "schemas", None, "candidate", manifest)
    print(f"Prepared local candidate only: {output}")


if __name__ == "__main__":
    main()
