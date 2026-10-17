"""Build a local, single-function checkSubscriptionV2 deployment candidate.

Uses the existing reviewed package generator and preserves all eight runtime
files byte-for-byte. No network, deployment, app binding, or secrets are used.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import sys


EXPERIMENT = Path(__file__).resolve().parents[1]
REVIEWED = EXPERIMENT / "evidence/full-app/build178/check-subscription-candidate"
FUNCTION = "checkSubscriptionV2"
BRIDGE = EXPERIMENT / "supabase/functions/app-services/legacy-billing.ts"
BRIDGE_DELTA = """// Fixed canonical route: the original name currently serves an obsolete
// Stripe-only contract. Never accept an endpoint from client input or fall back
// to that response when the verified membership route is unavailable.
const MEMBERSHIP_FUNCTION = 'checkSubscriptionV2';
"""


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", required=True, type=Path,
                    help="Absent or empty directory; no existing files will be replaced")
parser.add_argument("--live-app-services", type=Path,
                    help="Fresh Supabase v7 get_edge_function JSON; emits candidate and rollback from its 55 files")
args = parser.parse_args()
output = args.output.resolve()

# Validate the entire live snapshot and the exact allowed bridge delta before
# writing files. Local app-services has other unreleased changes and must never
# become the deployment source for this focused repair.
live = None
live_files = {}
bridge_for_tests = BRIDGE
if args.live_app_services:
    live = json.loads(args.live_app_services.read_text())
    if (live.get("id") != "a271cf0c-f0c7-4589-8448-406e286082fa"
            or live.get("slug") != "app-services" or live.get("version") != 7
            or live.get("verify_jwt") is not True or live.get("import_map") is not True
            or len(live.get("files", [])) != 55):
        raise SystemExit("Unexpected live app-services identity/version/configuration/file count")
    for item in live["files"]:
        name, content = item.get("name"), item.get("content")
        if not isinstance(name, str) or not isinstance(content, str):
            raise SystemExit("Invalid live source file")
        path = PurePosixPath(name)
        if (path.is_absolute() or ".." in path.parts or str(path) != name
                or path.parts[0] not in {"app-services", "full-game-core"}
                or name in live_files):
            raise SystemExit("Unsafe or duplicate live source path")
        live_files[name] = content.encode()
    original_bridge = live_files["app-services/legacy-billing.ts"]
    approved = json.loads((EXPERIMENT / "evidence/full-app/build176/billing-bundle-manifest.json").read_text())
    original_hash = next(item["afterSHA256"] for item in approved["changedFiles"]
                         if item["path"] == "app-services/legacy-billing.ts")
    if hashlib.sha256(original_bridge).hexdigest() != original_hash:
        raise SystemExit("Live bridge changed since reviewed baseline; re-review required")
    source = original_bridge.decode()
    anchor = "const WEEKLY = 'com.spyclash.ios.limitless.weekly';\n"
    old_call = "invoke('checkSubscription',{})"
    if source.count(anchor) != 1 or source.count(old_call) != 2:
        raise SystemExit("Unexpected bridge layout")
    expected = source.replace(anchor, anchor + BRIDGE_DELTA).replace(old_call, "invoke(MEMBERSHIP_FUNCTION,{})")
    if BRIDGE.read_bytes() != expected.encode():
        raise SystemExit("Current bridge has changes beyond the two fixed route uses")
    bridge_for_tests = output / "supabase-candidate/source/app-services/legacy-billing.ts"

subprocess.run([
    sys.executable, str(REVIEWED / "package.py"),
    "--source", str(REVIEWED / "base44/functions/checkSubscription"),
    "--output", str(output),
], check=True)
old = output / "base44/functions/checkSubscription"
runtime = old.with_name(FUNCTION)
old.rename(runtime)
(runtime / "function.jsonc").write_text(json.dumps({
    "name": FUNCTION, "entry": "entry.ts",
}, indent=2) + "\n")
(output / "base44/config.jsonc").write_text(json.dumps({
    "name": "SpyClash verified membership route", "functionsDir": "./functions",
}, indent=2) + "\n")

supabase_manifest = None
if live:
    entries = []
    for name, original in sorted(live_files.items()):
        candidate = BRIDGE.read_bytes() if name == "app-services/legacy-billing.ts" else original
        for directory, data in (("supabase-candidate", candidate), ("supabase-rollback", original)):
            path = output / directory / "source" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        entries.append({"name": name, "beforeSHA256": hashlib.sha256(original).hexdigest(),
                        "afterSHA256": hashlib.sha256(candidate).hexdigest()})
    changed = [item["name"] for item in entries if item["beforeSHA256"] != item["afterSHA256"]]
    if changed != ["app-services/legacy-billing.ts"]:
        raise SystemExit("Unexpected Supabase deployment delta")
    supabase_manifest = {
        "project_ref": "bbkfsgnordtdiblgdzkg", "function": "app-services",
        "baseline_version": live["version"], "baseline_bundle_sha256": live["ezbr_sha256"],
        "live_snapshot_sha256": sha256(args.live_app_services),
        "verify_jwt": live["verify_jwt"], "import_map": live["import_map"],
        "entrypoint_path": "source/app-services/index.ts", "import_map_path": "source/app-services/deno.json",
        "file_count": len(entries), "changed_files": changed, "files": entries,
        "candidate_root": "supabase-candidate", "rollback_root": "supabase-rollback",
        "secrets_configuration_schema_changes": False,
    }
    (output / "supabase-manifest.json").write_text(json.dumps(supabase_manifest, indent=2) + "\n")

# Reuse the tests, replacing only module locations so the actual generated
# handler and the current bridge are exercised together. Test behavior is not
# rewritten, and no code from the local package is loaded with network access.
tests = output / "tests"
tests.mkdir()
for name in ("sdk-stub.ts", "stripe-stub.ts", "deno.json"):
    (tests / name).write_bytes((REVIEWED / "tests" / name).read_bytes())
suite = (REVIEWED / "tests/contract_test.ts").read_text()
old_bridge = '"../../../../../supabase/functions/app-services/legacy-billing.ts"'
old_entry = '"../base44/functions/checkSubscription/entry.ts"'
if suite.count(old_bridge) != 1 or suite.count(old_entry) != 1:
    raise SystemExit("Review required: contract suite module paths changed")
suite = suite.replace(old_bridge, json.dumps(bridge_for_tests.as_uri()))
suite = suite.replace(old_entry, json.dumps(f"../base44/functions/{FUNCTION}/entry.ts"))
(tests / "contract_test.ts").write_text(suite)

manifest = json.loads((REVIEWED / "source-manifest.json").read_text())
manifest.update({
    "function": FUNCTION,
    "source": "Byte-identical reviewed build-178 modern membership handler; only function registration name changes.",
    "source_manifest_sha256": sha256(REVIEWED / "source-manifest.json"),
    "bridge_sha256": sha256(BRIDGE),
    "supabase_fenced_from_live": supabase_manifest is not None,
    "deployment_status": "local_only_not_deployed",
    "scope": "Exactly one new Base44 function; no original function, entity, site, secret, or auth configuration changes.",
    "collision_check": "No checkSubscriptionV2 in retained 17-function management snapshot dated 2026-10-17T18:33:36.824Z; recheck current inventory before any deployment.",
    "rollback": "Do not switch app-services unless V2 passes live contract probes. Restore the saved app-services bridge artifact to route to checkSubscription if needed; retain V2 unreferenced. This restores the prior behavior, including the unresolved old-route failure.",
})
for item in manifest["files"]:
    candidate = runtime / item["file"]
    if sha256(candidate) != item["sha256"] or candidate.stat().st_size != item["bytes"]:
        raise SystemExit("Generated runtime differs from the reviewed candidate")
if sorted(path.name for path in (output / "base44/functions").iterdir()) != [FUNCTION]:
    raise SystemExit("Unexpected additional deployment function")
(output / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("Generated one local checkSubscriptionV2 package with byte-identical runtime and actual-handler tests.")
