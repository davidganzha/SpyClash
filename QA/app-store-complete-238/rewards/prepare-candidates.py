#!/usr/bin/env python3
"""Assemble local-only candidates from the captured live bundles. No network/CLI.

Run from any directory with Python 3. Inputs are the ignored .local snapshots.
Never reads the eject export. Nothing in this script deploys or changes config.
"""
import difflib
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LOCAL = ROOT / ".local/rewards238"
OUT = LOCAL / "prepared"
QA = Path(__file__).resolve().parent
SUPABASE = ROOT / "experiments/supabase-game-core/supabase/functions"
RELATIVE_IMPORT = re.compile(r"(?:from\s*|import\s*\(?\s*)['\"](\.[^'\"]+\.ts)['\"]")


def sha(value):
    return hashlib.sha256(value).hexdigest()


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(value)


def imports(path, content):
    for imported in RELATIVE_IMPORT.findall(content.decode()):
        yield (path.parent / imported).resolve()


def finish(name, baseline, target, metadata):
    directory = OUT / name
    # Refuse to silently retain an obsolete file from an earlier assembly.
    existing = {str(p.relative_to(directory)) for p in directory.rglob("*") if p.is_file()} if directory.exists() else set()
    assert not existing - set(target), (name, "unexpected stale candidate files", existing - set(target))
    for path, content in target.items():
        write(directory / path, content)
    rows = []
    patch = []
    for path in sorted(set(baseline) | set(target)):
        before, after = baseline.get(path), target.get(path)
        row = {"path": path, "before_sha256": sha(before) if before is not None else None,
               "after_sha256": sha(after) if after is not None else None, "changed": before != after}
        rows.append(row)
        if before == after:
            continue
        lines = difflib.unified_diff((before or b"").decode().splitlines(keepends=True),
                                     (after or b"").decode().splitlines(keepends=True),
                                     fromfile="a/" + path if before is not None else "/dev/null",
                                     tofile="b/" + path if after is not None else "/dev/null", n=0)
        for line in lines:
            patch.append(line if line.endswith("\n") else line + "\n\\ No newline at end of file\n")
    patch_path = QA / (name.replace("/", "-") + ".patch")
    patch_path.write_text("".join(patch))
    manifest = {"prepared_only": True, "production_target_changed": False,
                "candidate_directory": str(directory.relative_to(ROOT)), **metadata,
                "baseline_files": len(baseline), "candidate_files": len(target),
                "changed_files": [r["path"] for r in rows if r["changed"]],
                "preserved_files": sum(not r["changed"] for r in rows),
                "all_unrelated_files_byte_identical": True,
                "patch": str(patch_path.relative_to(ROOT)), "patch_sha256": sha(patch_path.read_bytes()), "files": rows}
    (QA / (name.replace("/", "-") + "-manifest.json")).write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def supabase(slug, overlays):
    live = LOCAL / "live-supabase" / slug
    metadata = json.loads((live / "_metadata.json").read_text())
    baseline = {str(p.relative_to(live)): p.read_bytes() for p in live.rglob("*") if p.is_file() and not p.name.startswith("_")}
    target = dict(baseline)
    for path in overlays:
        target[path] = (SUPABASE / path).read_bytes()
    surgical = []
    if slug == "app-services":
        # The source also has a separately prepared push transport bridge.
        # Preserve live transport and copy only the reviewed invitation recheck.
        path = "app-services/worker.ts"
        current = target[path].decode()
        source = (SUPABASE / path).read_text()
        start = "        const [event]="
        end = "\n      }\n    }else {"
        old_start, new_start = current.index(start), source.index(start)
        old_end, new_end = current.index(end, old_start), source.index(end, new_start)
        target[path] = (current[:old_start] + source[new_start:new_end] + current[old_end:]).encode()
        surgical.append("app-services/worker.ts: queued invitation recheck only")
    # Include missing source dependencies while preserving every existing live
    # dependency unless it is in the reviewed overlay allowlist above.
    pending = list(overlays)
    additions = []
    while pending:
        path = pending.pop()
        for dependency in imports(SUPABASE / path, target[path]):
            relative = str(dependency.relative_to(SUPABASE))
            if relative not in target:
                target[relative] = dependency.read_bytes()
                pending.append(relative)
                additions.append(relative)
    return finish("supabase/" + slug, baseline, target,
                  {"project_id": "bbkfsgnordtdiblgdzkg", "function": slug,
                   "baseline_version": metadata["version"], "verify_jwt": metadata["verify_jwt"],
                   "entrypoint": slug + "/index.ts", "reviewed_overlays": overlays,
                   "surgical_overlays": surgical,
                   "missing_dependencies_added": sorted(additions)})


def base44(name, overlays):
    snapshot = json.loads((LOCAL / "live-base44/canonical-functions.json").read_text())
    live = next(f for f in snapshot["functions"] if f["name"] == name)
    baseline = {f["path"]: f["content"].encode() for f in live["files"]}
    target = dict(baseline)
    base = "base44/functions/" + name + "/"
    for destination, source in overlays.items():
        target[base + destination] = (ROOT / base / source).read_bytes()
    pending = [base + p for p in overlays]
    additions = []
    while pending:
        path = pending.pop()
        for dependency in imports(ROOT / path, target[path]):
            relative = str(dependency.relative_to(ROOT))
            if relative not in target:
                assert relative.startswith(base), ("cross-function dependency", relative)
                target[relative] = dependency.read_bytes()
                pending.append(relative)
                additions.append(relative)
    return finish("base44/" + name, baseline, target,
                  {"app_id": "69a0e57fa939f578082f8091", "function": name,
                   "baseline_deployment_id": live["deployment_id"], "entrypoint": live["entry"],
                   "automations_preserved": live.get("automations", []), "reviewed_overlays": overlays,
                   "missing_dependencies_added": sorted(additions)})


def main():
    QA.mkdir(parents=True, exist_ok=True)
    manifests = [supabase("app-services", ["app-services/" + p for p in [
        "generation-reward-ledger.ts", "generation-rewards.ts", "unity-ssv.ts",
        "generation-reward-deletion.ts", "native-generation.ts", "lifecycle.ts",
        "membership.ts", "native-apple.ts", "legacy-billing.ts",
        "profile.ts", "community.ts", "inbox.ts", "policies/community.ts",
        "billing-rules/apple-subscription-status.ts", "billing-rules/apple-products.ts"]]),
        supabase("rewarded-generation-ssv", ["app-services/generation-reward-ledger.ts",
            "app-services/generation-rewards.ts", "app-services/unity-ssv.ts",
            "rewarded-generation-ssv/handler.ts", "rewarded-generation-ssv/index.ts"]),
        base44("generateWordPack", {"entry.ts": "main.ts", "generation-rewards.ts": "generation-rewards.ts"}),
        base44("generationRewardAction", {"entry.ts": "main.ts", "generation-rewards.ts": "generation-rewards.ts", "unity-ssv.ts": "unity-ssv.ts"}),
        base44("deleteAccount", {"entry.ts": "main.ts"}),
        base44("app-store-entitlement", {p: p for p in ["entry.ts", "apple-entitlement.ts", "apple-subscription-status.ts", "limitless-rollout.ts"]})]
    prerequisites = ["base44/entities/generation-reward-enrollment.jsonc",
                     "experiments/supabase-game-core/supabase/migrations/20261111184822_rewarded_generation_enrollment.sql"]
    summary = {"prepared_only": True, "targets": [{k: m[k] for k in ["function", "candidate_directory", "candidate_files", "changed_files", "preserved_files", "patch"]} for m in manifests],
               "required_schema_files": [{"path": p, "sha256": sha((ROOT / p).read_bytes())} for p in prerequisites],
               "excluded_input": ".local/rewards238/base44-eject",
               "activation": "Separate approval required for deployment, schema/migration and configuration. Unity S2S secret/activation and real callback acceptance remain unverified."}
    (QA / "candidate-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({m["function"]: {"files": m["candidate_files"], "changed": len(m["changed_files"]), "preserved": m["preserved_files"]} for m in manifests}, indent=2))


if __name__ == "__main__":
    main()
