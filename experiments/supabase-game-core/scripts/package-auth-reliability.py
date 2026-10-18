"""Prepare only the two reviewed authentication functions, without app binding.

Requires a fresh local CLI pull matching the recorded build 187 backend baseline.
All candidate runtime bytes come from explicitly mapped, Git-tracked files. This
script never contacts a service, deploys, or packages tests or credentials.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess


EXPERIMENT = Path(__file__).resolve().parents[1]
REPOSITORY = EXPERIMENT.parents[1]
BASELINE = EXPERIMENT / "evidence/full-app/build187/backend-baseline.json"
BASELINE_COMMIT = "4fce416b3acde02877d338100d8b8ba93ac61ea4"
FROZEN_LIFECYCLE = (
    "experiments/supabase-game-core/evidence/full-app/build178/"
    "check-subscription-candidate/base44/functions/checkSubscription/"
    "billing-identity-lifecycle.ts"
)
LIVE_LIFECYCLE_SHA256 = "0802f14dc7edbc4107c96db19dbd2c09f5ac010003aad9adff385adacd152851"

# Keep this explicit: directory copying could silently include unrelated runtime.
RUNTIME = {
    "appleAuthBroker": {
        "entry.ts": "base44/functions/appleAuthBroker/main.ts",
        "apple-code-exchange.ts": "base44/functions/appleAuthBroker/apple-code-exchange.ts",
        "apple-credential-error-policy.ts": "base44/functions/appleAuthBroker/apple-credential-error-policy.ts",
        "apple-sign-in-credential.ts": "base44/functions/appleAuthBroker/apple-sign-in-credential.ts",
        "apple-token-compensation.ts": "base44/functions/appleAuthBroker/apple-token-compensation.ts",
        "auth-store-recovery.ts": "base44/functions/appleAuthBroker/auth-store-recovery.ts",
        "billing-identity-lifecycle.ts": FROZEN_LIFECYCLE,
        "confirmation.ts": "base44/functions/appleAuthBroker/confirmation.ts",
        "google-state-recovery.ts": "base44/functions/appleAuthBroker/google-state-recovery.ts",
        "handoff.ts": "base44/functions/appleAuthBroker/handoff.ts",
        "native-handoff.ts": "base44/functions/appleAuthBroker/native-handoff.ts",
        "provider.ts": "base44/functions/appleAuthBroker/provider.ts",
        "service-role-request.ts": "base44/functions/appleAuthBroker/service-role-request.ts",
        "transaction.ts": "base44/functions/appleAuthBroker/transaction.ts",
    },
    "autoRegisterUserV2": {
        "entry.ts": "base44/functions/autoRegisterUser/main.ts",
        "apple-sign-in-credential.ts": "base44/functions/autoRegisterUser/apple-sign-in-credential.ts",
        "auth-store-recovery.ts": "base44/functions/autoRegisterUser/auth-store-recovery.ts",
        "base44-context.ts": "base44/functions/autoRegisterUser/base44-context.ts",
        "billing-identity-lifecycle.ts": FROZEN_LIFECYCLE,
    },
}


def digest(content):
    return hashlib.sha256(content).hexdigest()


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def git(*arguments):
    return subprocess.check_output(
        ["git", "-C", str(REPOSITORY), *arguments], stderr=subprocess.PIPE,
    )


def read_inside(root, relative):
    path = root / relative
    resolved = path.resolve()
    if not resolved.is_relative_to(root.resolve()) or path.is_symlink():
        raise ValueError("File must remain inside its source root: " + str(relative))
    return resolved.read_bytes()


def normalized_config(content, function):
    config = json.loads(content)
    if not isinstance(config, dict) or set(config) != {"name", "entry"}:
        raise ValueError("Unexpected function configuration fields: " + function)
    entry = config["entry"]
    if config["name"] != function or entry not in {
        "entry.ts", "base44/functions/" + function + "/entry.ts",
    }:
        raise ValueError("Unexpected function name or entry: " + function)
    return {"name": function, "entry": "entry.ts"}, PurePosixPath(entry)


def original_source(function, filename):
    directory = "autoRegisterUser" if function == "autoRegisterUserV2" else function
    return "base44/functions/" + directory + "/" + (
        "main.ts" if filename == "entry.ts" else filename
    )


def validate_baseline(live_root):
    baseline_bytes = BASELINE.read_bytes()
    baseline = json.loads(baseline_bytes)
    if (baseline.get("schemaVersion") != 1 or
            baseline.get("build") != 187 or
            baseline.get("sourceCommit") != BASELINE_COMMIT or
            set(baseline.get("functions", {})) != set(RUNTIME)):
        raise ValueError("Unexpected backend baseline metadata")
    verified = {}
    for function, mapping in RUNTIME.items():
        expected = baseline["functions"][function]
        expected_files = set(mapping) - {"auth-store-recovery.ts"}
        if set(expected.get("runtime", {})) != expected_files:
            raise ValueError("Unexpected baseline runtime set: " + function)
        function_root = live_root / "base44/functions" / function
        config_bytes = read_inside(function_root, "function.jsonc")
        config, entry = normalized_config(config_bytes, function)
        if config != expected.get("normalizedConfig"):
            raise ValueError("Live function configuration changed: " + function)
        runtime_root = function_root / entry.parent
        expected_paths = {Path("function.jsonc")} | {
            Path(entry.parent) / name for name in expected_files
        }
        actual_paths = {
            path.relative_to(function_root)
            for path in function_root.rglob("*") if path.is_file() or path.is_symlink()
        }
        if actual_paths != expected_paths:
            raise ValueError("Live function file set changed: " + function)
        live_runtime = {}
        for filename in sorted(expected_files):
            recorded = expected["runtime"][filename]
            content = read_inside(runtime_root, filename)
            if (len(content) != recorded.get("bytes") or
                    digest(content) != recorded.get("sha256")):
                raise ValueError("Live runtime changed: " + function + "/" + filename)
            source = original_source(function, filename)
            original = git("show", BASELINE_COMMIT + ":" + source)
            if (recorded.get("originalSource") != source or
                    digest(original) != recorded.get("originalSHA256")):
                raise ValueError("Original tracked source differs from baseline: " + source)
            if filename == "billing-identity-lifecycle.ts":
                if digest(content) != LIVE_LIFECYCLE_SHA256:
                    raise ValueError("Unreviewed lifecycle implementation")
            elif original != content:
                raise ValueError("Unreviewed original/live runtime difference: " + source)
            live_runtime[filename] = content
        verified[function] = {
            "configuration": config,
            "liveConfigSHA256": digest(config_bytes),
            "runtime": live_runtime,
        }
    return baseline_bytes, verified


def prepare(live_root):
    baseline_bytes, live = validate_baseline(live_root)
    sources = sorted({source for mapping in RUNTIME.values() for source in mapping.values()})
    git("ls-files", "--error-unmatch", "--", *sources)
    source_bytes = {source: read_inside(REPOSITORY, source) for source in sources}
    if digest(source_bytes[FROZEN_LIFECYCLE]) != LIVE_LIFECYCLE_SHA256:
        raise ValueError("Frozen lifecycle source differs from the live baseline")
    output_files = {}
    functions = []
    for function, mapping in RUNTIME.items():
        prefix = "base44/functions/" + function + "/"
        configuration = live[function]["configuration"]
        output_files[prefix + "function.jsonc"] = json_bytes(configuration)
        files = []
        for filename, source in sorted(mapping.items()):
            content = source_bytes[source]
            # Every local runtime import must resolve within this exact function.
            imports = re.findall(
                r'''(?:from\s*|import\s*\(\s*)["'](\.[^"']+)["']''',
                content.decode(),
            )
            for specifier in imports:
                if not specifier.startswith("./") or specifier[2:] not in mapping:
                    raise ValueError("Unmapped local runtime import: " + function + "/" + filename)
            output_files[prefix + filename] = content
            prior = live[function]["runtime"].get(filename)
            files.append({
                "file": filename, "source": source,
                "bytes": len(content), "sha256": digest(content),
                "baselineSHA256": digest(prior) if prior is not None else None,
                "changedFromLive": prior != content,
            })
        functions.append({
            "name": function, "normalizedConfig": configuration,
            "liveConfigSHA256": live[function]["liveConfigSHA256"],
            "files": files,
        })
    output_files["base44/config.jsonc"] = json_bytes({
        "name": "SpyClash authentication reliability candidate",
        "functionsDir": "./functions",
    })
    output_files["source-manifest.json"] = json_bytes({
        "schemaVersion": 1, "build": 187,
        "baselineCommit": BASELINE_COMMIT,
        "sourceCommit": git("rev-parse", "HEAD").decode().strip(),
        "sourceContent": "Explicitly mapped Git-tracked working-tree bytes",
        "backendBaselineSHA256": digest(baseline_bytes),
        "packagerSHA256": digest(Path(__file__).read_bytes()),
        "liveBaselineVerified": True, "localOnly": True,
        "appBindingIncluded": False, "testsIncluded": False,
        "functions": functions,
    })
    return output_files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live-root", required=True, type=Path,
                        help="Local CLI pull containing the two deployed functions")
    parser.add_argument("--output", required=True, type=Path,
                        help="Absent or empty directory; existing content is never replaced")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise ValueError("Output must be an absent or empty directory")
    # Validate and freeze every byte before creating any output.
    output_files = prepare(args.live_root.resolve())
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise ValueError("Output changed during validation")
    for relative, content in sorted(output_files.items()):
        destination = output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open("xb") as stream:
            stream.write(content)
    print("Prepared two local functions: appleAuthBroker (14 runtime files), "
          "autoRegisterUserV2 (5). No app binding or tests included.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
