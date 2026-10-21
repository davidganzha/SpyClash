#!/usr/bin/env python3
"""Install a verified Simulator app while preserving existing app data.

Usage: python3 scripts/install-ios-simulator-app.py --simulator UDID /path/SpyClash.app
Build with Simulator signing enabled before invoking this wrapper. It validates
the source artifact and the installed copy. It never signs, uninstalls, clears
data, launches the app, or changes a physical device / production environment.
"""

import argparse
import importlib.util
import json
from pathlib import Path
import sys
import uuid


spec = importlib.util.spec_from_file_location(
    "simulator_bundle_gate", Path(__file__).with_name("check-ios-simulator-bundle.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def install(app, simulator, bundle_id):
    try:
        simulator = str(uuid.UUID(simulator)).upper()
    except ValueError as error:
        raise gate.GateError("An explicit Simulator UDID is required; 'booted' is not accepted.") from error
    before = gate.inspect_bundle(app, bundle_id)
    devices = json.loads(gate.command(["xcrun", "simctl", "list", "devices", "--json"]))
    matches = [device for group in devices.get("devices", {}).values() for device in group
               if device.get("udid", "").upper() == simulator]
    if len(matches) != 1 or matches[0].get("state") != "Booted" or not matches[0].get("isAvailable", False):
        raise gate.GateError("The specified Simulator must exist, be available, and already be booted.")
    print(f"Installing {before['bundle_id']} {before['version']} ({before['build']}); "
          f"backend={before['backend_mode']}; simulator={simulator}", flush=True)
    gate.command(["xcrun", "simctl", "install", simulator, before["app_path"]])
    installed_path = gate.command(["xcrun", "simctl", "get_app_container", simulator, bundle_id, "app"]).decode().strip()
    if not Path(installed_path).is_absolute():
        raise gate.GateError("Simulator returned an invalid installed-app path.")
    after = gate.inspect_bundle(installed_path, bundle_id)
    if before["bundle_sha256"] != after["bundle_sha256"]:
        raise gate.GateError("Installed app contents differ from the validated source artifact. Do not launch it.")
    print(f"PASS: installed build {after['build']}; backend={after['backend_mode']}; "
          f"signature and Keychain identity verified; bundle SHA-256={after['bundle_sha256']}")
    return after


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app")
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--bundle-id", default="com.spyclash.ios")
    args = parser.parse_args()
    try:
        install(args.app, args.simulator, args.bundle_id)
    except (gate.GateError, OSError, ValueError) as error:
        print(f"Simulator installation FAILED: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
