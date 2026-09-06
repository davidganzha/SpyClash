#!/usr/bin/env python3
"""Read-only canonical pull/schema GET; bearer tokens are never printed, saved, or passed in argv."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

APP_ID = "69a0e57fa939f578082f8091"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def secure_auth_file():
    path = Path.home() / ".base44/auth/auth.json"
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and not path.is_symlink() and
            info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o600,
            "CLI auth must be a current-user-owned regular mode-600 file")
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    args = parser.parse_args()
    project = args.project_root.resolve(strict=True)
    output = args.output_root.absolute()
    require(not output.exists(), "Output must be a new isolated directory")
    require(os.environ.get("BASE44_APP_ID", APP_ID) == APP_ID, "Wrong environment app override")
    binding = json.loads("\n".join(line for line in (project / "base44/.app.jsonc").read_text().splitlines()
                                    if not line.lstrip().startswith("//")))
    require(binding == {"id": APP_ID}, "Wrong project app binding")
    manifest = json.loads(Path(__file__).with_name("baseline-manifest.json").read_text())
    config = (project / "base44/config.jsonc").read_bytes()
    require(hashlib.sha256(config).hexdigest() == manifest["project_config_sha256"],
            "Project configuration differs from reviewed baseline")
    secure_auth_file()
    result = subprocess.run(["npx", "--no-install", "base44", "whoami"], cwd=project,
                            capture_output=True)
    require(result.returncode == 0, "CLI authentication failed; no resources requested")
    auth_file = secure_auth_file()
    output.mkdir(mode=0o700)
    base = output / "fresh/base44"
    base.mkdir(parents=True)
    (base / ".app.jsonc").write_text(json.dumps({"id": APP_ID}) + "\n")
    (base / "config.jsonc").write_bytes(config)
    if (project / "node_modules").exists():
        (output / "fresh/node_modules").symlink_to((project / "node_modules").resolve(strict=True),
                                                  target_is_directory=True)
    result = subprocess.run(["npx", "--no-install", "base44", "functions", "pull"],
                            cwd=output / "fresh", capture_output=True)
    require(result.returncode == 0, "Read-only function pull failed; raw output suppressed")
    # curl receives the bearer header through stdin, never argv or a saved file.
    auth_file = secure_auth_file()
    token = json.loads(auth_file.read_text())["accessToken"]
    require(isinstance(token, str) and token and not any(char in token for char in '\r\n"\\'),
            "Unsupported CLI access-token encoding")
    result = subprocess.run(["curl", "--silent", "--show-error", "--fail", "--connect-timeout", "10",
                             "--max-time", "60", "--config", "-",
                             f"https://app.base44.com/api/apps/{APP_ID}/entity-schemas"],
                            input=(f'header = "Authorization: Bearer {token}"\n').encode(), capture_output=True)
    del token
    require(result.returncode == 0, "Read-only schema GET failed; raw response suppressed")
    payload = json.loads(result.stdout)
    rows = payload["schemas"]
    require(payload["total"] == len(rows) and len(rows) > 0, "Inconsistent schema count")
    require(len({row["entity_name"] for row in rows}) == len(rows), "Duplicate schema name")
    require(all(row["entity_name"] == row["entity_schema"]["name"] for row in rows),
            "Schema/name mismatch")
    sanitized = {"total": len(rows), "schemas": [{"entity_name": row["entity_name"],
                                                   "entity_schema": row["entity_schema"]} for row in rows]}
    (output / "remote-schemas.json").write_text(json.dumps(sanitized, sort_keys=True, indent=2) + "\n")
    functions = sorted(path.name for path in (base / "functions").iterdir() if path.is_dir())
    metadata = {"canonical_app_id": APP_ID,
                "fetched_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "function_names": functions, "schema_count": len(rows),
                "raw_schema_response_sha256": hashlib.sha256(result.stdout).hexdigest()}
    (output / "acquisition.json").write_text(json.dumps(metadata, sort_keys=True, indent=2) + "\n")
    print(f"Read-only snapshot: {len(functions)} functions, {len(rows)} schemas in {output}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError):
        print("STOP: read-only acquisition failed; raw diagnostics suppressed", file=sys.stderr)
        sys.exit(1)
