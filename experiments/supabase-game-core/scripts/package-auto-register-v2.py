"""Build the reviewed, single-function autoRegisterUserV2 package locally.

Reads only tracked source and test fixtures. Preserves the four reviewed runtime
files byte-for-byte; does not contact a service, deploy, or include app binding.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath


EXPERIMENT = Path(__file__).resolve().parents[1]
REPOSITORY = EXPERIMENT.parents[1]
REVIEW = EXPERIMENT / "evidence/full-app/build180/auto-register-v2-candidate"
TESTS = EXPERIMENT / "tests/auto-register-v2"
FUNCTION = "autoRegisterUserV2"


def digest(content):
    return hashlib.sha256(content).hexdigest()


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", required=True, type=Path,
                    help="Absent or empty directory; existing content is never replaced")
args = parser.parse_args()
output = args.output.resolve()
if output.exists() and (not output.is_dir() or any(output.iterdir())):
    raise SystemExit("Output must be an absent or empty directory")

manifest_bytes = (REVIEW / "source-manifest.json").read_bytes()
manifest = json.loads(manifest_bytes)
if manifest.get("function") != FUNCTION or manifest.get("entry") != "entry.ts":
    raise SystemExit("Unexpected reviewed function metadata")
expected_files = {"entry.ts", "apple-sign-in-credential.ts", "base44-context.ts",
                  "billing-identity-lifecycle.ts"}
if (len(manifest.get("files", [])) != 4 or
        {item.get("file") for item in manifest["files"]} != expected_files):
    raise SystemExit("Unexpected reviewed runtime file set")

# Validate everything before creating the output package. Any source drift
# requires review rather than silently including another implementation.
runtime = {}
for item in manifest["files"]:
    source_path = PurePosixPath(item["source"])
    if (source_path.is_absolute() or ".." in source_path.parts or
            source_path.as_posix() != item["source"]):
        raise SystemExit("Invalid reviewed source path")
    source = (REPOSITORY / source_path).resolve()
    if not source.is_relative_to(REPOSITORY):
        raise SystemExit("Source must remain inside the repository")
    content = source.read_bytes()
    if len(content) != item["bytes"] or digest(content) != item["sha256"]:
        raise SystemExit("Reviewed source changed: " + item["source"])
    runtime[item["file"]] = content

test_files = {name: (TESTS / name).read_bytes() for name in
              ("sdk-stub.ts", "legacy-runtime-fixture.js", "deno.json")}
if digest(test_files["legacy-runtime-fixture.js"]) != manifest["legacyRegressionFixture"]["sha256"]:
    raise SystemExit("Legacy regression source changed; re-review required")
suite = (TESTS / "contract_test.ts").read_text()
source_prefix = "../../../../base44/functions/autoRegisterUser/"
source_entry = source_prefix + "main.ts"
if suite.count(source_prefix) != 3 or suite.count(source_entry) != 1:
    raise SystemExit("Contract test import layout changed; re-review required")
suite = suite.replace(source_entry, "../base44/functions/" + FUNCTION + "/entry.ts")
suite = suite.replace(source_prefix, "../base44/functions/" + FUNCTION + "/")
test_files["contract_test.ts"] = suite.encode()

function_root = output / "base44/functions" / FUNCTION
function_root.mkdir(parents=True, exist_ok=True)
for name, content in runtime.items():
    (function_root / name).write_bytes(content)
(function_root / "function.jsonc").write_text(json.dumps({
    "name": FUNCTION, "entry": "entry.ts",
}, indent=2) + "\n")
(output / "base44/config.jsonc").write_text(json.dumps({
    "name": "SpyClash verified Apple registration", "functionsDir": "./functions",
}, indent=2) + "\n")
(output / "tests").mkdir()
for name, content in test_files.items():
    (output / "tests" / name).write_bytes(content)
manifest["reviewedManifestSHA256"] = digest(manifest_bytes)
manifest["generatedTests"] = [
    {"file": name, "sha256": digest(content)}
    for name, content in sorted(test_files.items())
]
(output / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("Generated one local autoRegisterUserV2 package with four reviewed runtime files and actual-handler tests.")
