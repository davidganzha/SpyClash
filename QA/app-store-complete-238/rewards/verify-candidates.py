#!/usr/bin/env python3
"""Verify local candidates only; uses cached Deno dependencies and a local DB.

Set REWARDED_TEST_DATABASE_URL to the existing local PostgreSQL URL. No cloud
calls, Base44 CLI, deployment, migration, provider purchase or ad is performed.
Existing Node tests read local Supabase status and own synthetic local fixtures.
"""
import concurrent.futures
import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
QA = Path(__file__).resolve().parent
LOCAL = ROOT / ".local/rewards238"
PREP = LOCAL / "prepared"
HARNESS = LOCAL / "exact-tests"
WORK = ROOT / "experiments/supabase-game-core"
DENO = WORK / "node_modules/.bin/deno"
APP = PREP / "supabase/app-services"
SSV = PREP / "supabase/rewarded-generation-ssv"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def prepare_harness():
    HARNESS.mkdir(exist_ok=True)
    source = WORK / "tests/game-center/rewarded-generation-integration.ts"
    text = source.read_text().replace("../../supabase/functions/rewarded-generation-ssv/", (SSV / "rewarded-generation-ssv").as_uri() + "/")
    text = text.replace("../../supabase/functions/", APP.as_uri() + "/")
    text = text.replace("../../supabase/migrations/", (WORK / "supabase/migrations").as_uri() + "/")
    text = text.replace((APP / "game-center-session/schema.sql").as_uri(), (WORK / "supabase/functions/game-center-session/schema.sql").as_uri())
    (HARNESS / "native-integration.ts").write_text(text)
    base = ROOT / "base44/tests/rewarded-generation"
    text = (base / "integration_test.ts").read_text()
    for name in ["generateWordPack", "generationRewardAction"]:
        text = text.replace("../../functions/" + name + "/main.ts", (PREP / "base44" / name / "base44/functions" / name / "entry.ts").as_uri())
    (HARNESS / "base44-integration_test.ts").write_text(text)
    for name in ["sdk-stub.ts", "deno.json"]:
        (HARNESS / name).write_bytes((base / name).read_bytes())
    text = (WORK / "supabase/functions/rewarded-generation-ssv/handler_test.ts").read_text().replace("./handler.ts", (SSV / "rewarded-generation-ssv/handler.ts").as_uri())
    (HARNESS / "gateway_test.ts").write_text(text)
    for name in ["apple-entitlement_test.ts", "apple-subscription-status_test.ts"]:
        text = (ROOT / "base44/functions/app-store-entitlement" / name).read_text()
        target = PREP / "base44/app-store-entitlement/base44/functions/app-store-entitlement"
        text = re.sub(r"(['\"])(\./[^'\"]+\.ts)\1", lambda m: m[1] + (target / m[2]).resolve().as_uri() + m[1], text)
        (HARNESS / name).write_text(text)
    for name in ["achievements_test.ts", "invitation-permissions_test.ts"]:
        text = (WORK / "tests/app-services" / name).read_text().replace("../../supabase/functions/", APP.as_uri() + "/")
        (HARNESS / name).write_text(text)
    link = HARNESS / "node_modules"
    if not link.exists():
        link.symlink_to(WORK / "node_modules", target_is_directory=True)
    node_tests = []
    for name in ["billing-push.test.mjs", "legacy-billing-push.test.mjs", "native-game-center-billing.test.mjs", "monthly-apple-verification.test.mjs", "services.integration.test.mjs"]:
        text = (WORK / "tests/app-services" / name).read_text().replace("../../supabase/functions/", APP.as_uri() + "/")
        text = text.replace("../../base44-prepared/", (WORK / "base44-prepared").as_uri() + "/")
        if name == "legacy-billing-push.test.mjs":
            # Three dormant bridge tests are explicitly excluded below. Their
            # module imports stay loadable using source-only test helpers; no
            # dormant push module is added to the deployment candidate.
            text = text.replace("dispatchPush,enqueueAppPush,allowedPushBundle", "dispatchPush,enqueueAppPush")
            text = "import {allowedPushBundle} from '" + (WORK / "supabase/functions/app-services/push.ts").as_uri() + "';\n" + text
            text = text.replace((APP / "app-services/legacy-push.ts").as_uri(), (WORK / "supabase/functions/app-services/legacy-push.ts").as_uri())
        (HARNESS / name).write_text(text)
        node_tests.append(str(HARNESS / name))
    return node_tests


def reconstruct():
    snapshot = json.loads((LOCAL / "live-base44/canonical-functions.json").read_text())
    results = []
    for path in sorted(QA.glob("*-manifest.json")):
        manifest = json.loads(path.read_text())
        if "candidate_directory" not in manifest:
            continue
        with tempfile.TemporaryDirectory(prefix="spyclash-238-patch-") as directory:
            target = Path(directory).resolve()
            if "project_id" in manifest:
                baseline = LOCAL / "live-supabase" / manifest["function"]
                files = {str(p.relative_to(baseline)): p.read_bytes() for p in baseline.rglob("*") if p.is_file() and not p.name.startswith("_")}
            else:
                files = {x["path"]: x["content"].encode() for f in snapshot["functions"] if f["name"] == manifest["function"] for x in f["files"]}
            for name, data in files.items():
                (target / name).parent.mkdir(parents=True, exist_ok=True)
                (target / name).write_bytes(data)
            subprocess.run(["git", "apply", "--unsafe-paths", "--unidiff-zero", "--directory=" + str(target), str(ROOT / manifest["patch"])], check=True, capture_output=True)
            actual = {str(p.relative_to(target)): sha(p.read_bytes()) for p in target.rglob("*") if p.is_file()}
            expected = {x["path"]: x["after_sha256"] for x in manifest["files"] if x["after_sha256"]}
            assert actual == expected, manifest["function"]
            results.append({"function": manifest["function"], "exact_reconstruction": True, "files": len(actual)})
    (QA / "patch-reconstruction.json").write_text(json.dumps(results, indent=2) + "\n")


def main():
    database = os.environ.get("REWARDED_TEST_DATABASE_URL", "")
    from urllib.parse import urlparse
    assert urlparse(database).hostname == "127.0.0.1" and urlparse(database).port == 56322, "Existing local PostgreSQL required"
    node_tests = prepare_harness()
    reconstruct()
    environment = dict(os.environ, DATABASE_URL=database, DENO_NO_UPDATE_CHECK="1",
        HTTP_PROXY="http://127.0.0.1:9", HTTPS_PROXY="http://127.0.0.1:9", ALL_PROXY="http://127.0.0.1:9", NO_PROXY="127.0.0.1,localhost")
    flags = ["--cached-only", "--no-lock", "--node-modules-dir=none"]
    test = [str(DENO), "test", *flags, "--allow-env", "--deny-net"]
    check = [str(DENO), "check", *flags]
    jobs = [
        ("candidate-app-typecheck.log", [*check, "--config", str(APP / "app-services/deno.json"), str(APP / "app-services/index.ts")]),
        ("candidate-ssv-typecheck.log", [*check, "--config", str(SSV / "rewarded-generation-ssv/deno.json"), str(SSV / "rewarded-generation-ssv/index.ts")]),
        ("candidate-base44-typecheck.log", [*check, "--no-config", *[str(PREP / "base44" / n / "base44/functions" / n / "entry.ts") for n in ["generateWordPack", "generationRewardAction", "deleteAccount", "app-store-entitlement"]]]),
        ("candidate-native-integration.log", [str(DENO), "run", *flags, "--config", str(APP / "app-services/deno.json"), "--allow-env", "--allow-read", "--allow-net=127.0.0.1", str(HARNESS / "native-integration.ts")]),
        ("candidate-base44-integration.log", [*test, "--config", str(HARNESS / "deno.json"), str(HARNESS / "base44-integration_test.ts")]),
        ("candidate-gateway-tests.log", [*test, "--no-config", str(HARNESS / "gateway_test.ts")]),
        ("candidate-base44-monthly-tests.log", [*test, "--no-config", *[str(HARNESS / n) for n in ["apple-entitlement_test.ts", "apple-subscription-status_test.ts"]]]),
        ("candidate-profile-policy-tests.log", [*test, "--no-config", *[str(HARNESS / n) for n in ["achievements_test.ts", "invitation-permissions_test.ts"]]]),
        ("candidate-billing-community-tests.tap", ["node", "--experimental-transform-types", "--test", "--test-concurrency=1",
            "--test-skip-pattern=main-topic push reaches|relay rejects missing signature|main-bundle UUID-room Live Activity", *node_tests]),
    ]
    def run(job):
        filename, command = job
        with (QA / filename).open("w") as output:
            result = subprocess.run(command, cwd=WORK, env=environment, stdout=output, stderr=subprocess.STDOUT)
        return {"log": filename, "exit_code": result.returncode}
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
        results = list(executor.map(run, jobs))
    (QA / "verification-summary.json").write_text(json.dumps({"checks": results,
        "excluded_source_tests": ["main-topic push reaches only authenticated prepared Base44 relay and retains outbox fencing", "relay rejects missing signature, tampering and expired requests without APNs calls", "main-bundle UUID-room Live Activity keeps private words out of relay and ends after closure"],
        "reason": "Dormant main-app Base44 push bridge is outside the active release scope; live push transport preserved."}, indent=2) + "\n")
    print(json.dumps(results, indent=2))
    raise SystemExit(1 if any(r["exit_code"] for r in results) else 0)


if __name__ == "__main__":
    main()
