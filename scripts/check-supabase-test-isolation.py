#!/usr/bin/env python3
"""Read-only checks for the generated actual-app Supabase test target.

Checks configuration and packaging boundaries, not runtime networking or signing.
Run after xcodegen; the XCTest URLProtocol observer covers transport isolation.
"""
import json
import plistlib
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
FLAG = "SPYCLASH_SUPABASE_TEST"
ENGINE = {"BackendClient.swift", "LabStore.swift", "LabConfiguration.swift", "JSONValue.swift"}


def require(value, message):
    if not value:
        raise AssertionError(message)


def flags(settings):
    return str(settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "")) + " " + str(settings.get("OTHER_SWIFT_FLAGS", ""))


def main():
    process = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(ROOT / "SpyClash.xcodeproj/project.pbxproj")],
        check=True, capture_output=True, text=True,
    )
    project = json.loads(process.stdout)
    objects = project["objects"]
    targets = {value["name"]: value for value in objects.values() if value.get("isa") == "PBXNativeTarget"}
    require("SpyClash" in targets and "SpyClashSupabaseTest" in targets and "SpyClashSupabaseTests" in targets,
            "Generate the production, Supabase app and Supabase unit-test targets first")

    def configurations(owner):
        return [objects[key] for key in objects[owner["buildConfigurationList"]]["buildConfigurations"]]

    def sources(target):
        names = set()
        for phase_id in target.get("buildPhases", []):
            phase = objects[phase_id]
            if phase.get("isa") != "PBXSourcesBuildPhase":
                continue
            for file_id in phase.get("files", []):
                reference = objects[objects[file_id]["fileRef"]]
                names.add(Path(reference.get("path", reference.get("name", ""))).name)
        return names

    shared = objects[project["rootObject"]]
    for config in configurations(shared):
        require(FLAG not in flags(config.get("buildSettings", {})), "Test compilation flag leaked into shared project settings")
    for name, target in targets.items():
        if name in {"SpyClashSupabaseTest", "SpyClashSupabaseTests"}:
            continue
        for config in configurations(target):
            require(FLAG not in flags(config.get("buildSettings", {})), "Test compilation flag leaked into a production target")

    production = targets["SpyClash"]
    test_app = targets["SpyClashSupabaseTest"]
    for config in configurations(production):
        require(config.get("buildSettings", {}).get("PRODUCT_BUNDLE_IDENTIFIER") == "com.spyclash.ios",
                "Production bundle identifier changed")
    require(not sources(production).intersection(ENGINE), "Lab transport sources entered the production target")
    require(ENGINE.issubset(sources(test_app)), "Test target is missing the real Supabase transport sources")
    require("SupabaseGameAdapter.swift" in sources(test_app), "Test target is missing the GameRoom integration adapter")

    for config in configurations(test_app):
        settings = config.get("buildSettings", {})
        require(FLAG in flags(settings), "Test app configuration is missing the test compilation flag")
        require(settings.get("PRODUCT_BUNDLE_IDENTIFIER") == "com.spyclash.ios.supabasetest", "Test bundle is not isolated")
        entitlements = settings.get("CODE_SIGN_ENTITLEMENTS")
        if entitlements:
            with (ROOT / entitlements).open("rb") as handle:
                values = plistlib.load(handle)
            require(set(values).issubset({"application-identifier", "com.apple.developer.team-identifier", "get-task-allow", "keychain-access-groups"}),
                    "Test app has capabilities outside its local wildcard signing contract")
        info_path = settings.get("INFOPLIST_FILE")
        require(info_path, "Test app has no explicit isolated Info.plist")
        with (ROOT / info_path).open("rb") as handle:
            info = plistlib.load(handle)
        schemes = {scheme for item in info.get("CFBundleURLTypes", []) for scheme in item.get("CFBundleURLSchemes", [])}
        require("spyclash" not in schemes, "Test app would compete for production OAuth/deep-link callbacks")
        require(schemes.issubset({"spyclash-supabasetest"}), "Unexpected test app URL scheme")

    for dependency_id in test_app.get("dependencies", []):
        dependency = objects[dependency_id]
        dependency_target = objects.get(dependency.get("target"), {})
        require(dependency_target.get("name") not in {"SpyClash", "SpyClashWidgets"}, "Test app embeds or depends on a production target")
    require({"SupabaseGameAdapterTests.swift", "Base44IsolationTests.swift"}.issubset(sources(targets["SpyClashSupabaseTests"])),
            "Targeted integration/isolation tests are not included")
    print(json.dumps({"status": "PASS", "audit": "actual_app_supabase_target_isolation", "runtime_networking": "requires_XCTest", "signing_install_launch": "not_assessed"}))


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
        print(json.dumps({"status": "FAIL", "audit": "actual_app_supabase_target_isolation", "reason": str(error)}))
        sys.exit(1)
