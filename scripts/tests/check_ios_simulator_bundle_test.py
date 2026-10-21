#!/usr/bin/env python3
"""Focused signing/install failure checks with synthetic files and no Simulator writes."""

import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gate = load("gate_under_test", "check-ios-simulator-bundle.py")
installer = load("installer_under_test", "install-ios-simulator-app.py")


class SimulatorBundleGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name).resolve() / "SpyClash.app"
        self.app.mkdir()
        self.info = {"DTPlatformName": "iphonesimulator", "CFBundleIdentifier": "com.spyclash.ios",
                     "CFBundleExecutable": "SpyClash", "CFBundleVersion": "195",
                     "CFBundleShortVersionString": "1.0.3", "SpyClashBackendMode": "supabase-main-candidate"}
        self.write_info()
        (self.app / "SpyClash").write_bytes(struct.pack("<IIIIIIII", 0xFEEDFACF, 0x100000C, 0, 2, 0, 0, 0, 0))
        (self.app / "Frameworks").mkdir()
        (self.app / "Frameworks" / "nested.dylib").write_bytes(b"\xcf\xfa\xed\xfe" + b"nested")
        identity = gate.project_team() + ".com.spyclash.ios"
        self.entitlements = {"application-identifier": identity,
                             "com.apple.developer.team-identifier": gate.project_team(),
                             "keychain-access-groups": [identity]}

    def write_info(self):
        (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info))

    def signing_command(self, arguments):
        return plistlib.dumps(self.entitlements) if "-d" in arguments else b""

    def test_valid_signed_bundle_verifies_each_macho_and_reports_identity(self):
        with patch.object(gate, "command", side_effect=self.signing_command) as run:
            evidence = gate.inspect_bundle(self.app)
        self.assertEqual(evidence["verified_executables"], 2)
        self.assertEqual(evidence["build"], "195")
        self.assertEqual(len(evidence["bundle_sha256"]), 64)
        run.assert_any_call(["codesign", "--verify", "--strict", str(self.app / "Frameworks" / "nested.dylib")])

    def test_invalid_resource_seal_rejected_before_entitlements(self):
        with patch.object(gate, "command", side_effect=gate.GateError("invalid resource seal")) as run:
            with self.assertRaisesRegex(gate.GateError, "invalid resource seal"):
                gate.inspect_bundle(self.app)
        self.assertEqual(run.call_count, 1)

    def test_missing_effective_entitlements_rejected(self):
        with patch.object(gate, "command", return_value=b""):
            with self.assertRaisesRegex(gate.GateError, "application-identifier"):
                gate.inspect_bundle(self.app)

    def test_xcode_simulated_entitlements_with_empty_signature_plist(self):
        identity = gate.project_team() + ".com.spyclash.ios"
        payload = plistlib.dumps({"application-identifier": identity})
        header = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x100000C, 0, 2, 1, 152, 0, 0)
        segment = struct.pack("<II16sQQQQIIII", 0x19, 152, b"__TEXT", 0, 184 + len(payload),
                              0, 184 + len(payload), 7, 5, 1, 0)
        section = struct.pack("<16s16sQQIIIIIIII", b"__entitlements", b"__TEXT", 184, len(payload),
                              184, 0, 0, 0, 0, 0, 0, 0)
        (self.app / "SpyClash").write_bytes(header + segment + section + payload)
        self.entitlements = {}
        with patch.object(gate, "command", side_effect=self.signing_command):
            result = gate.inspect_bundle(self.app)
        self.assertEqual(result["entitlement_source"], "macho_simulated")
        self.assertEqual(result["keychain_identity"], identity)

    def test_malformed_macho_is_rejected(self):
        (self.app / "SpyClash").write_bytes(b"\xcf\xfa\xed\xfe")
        with patch.object(gate, "command", side_effect=self.signing_command):
            with self.assertRaisesRegex(gate.GateError, "Truncated Mach-O"):
                gate.inspect_bundle(self.app)

    def test_wrong_app_or_team_and_unusable_keychain_groups_rejected(self):
        for key, value in [("application-identifier", "OTHER.com.spyclash.ios"),
                           ("com.apple.developer.team-identifier", "OTHER"),
                           ("keychain-access-groups", []),
                           ("keychain-access-groups", ["3Z64QKNL54.*"]),
                           ("keychain-access-groups", ["3Z64QKNL54.other"])]:
            with self.subTest(key=key, value=value):
                original = self.entitlements[key]
                self.entitlements[key] = value
                with patch.object(gate, "command", side_effect=self.signing_command):
                    with self.assertRaises(gate.GateError):
                        gate.inspect_bundle(self.app)
                self.entitlements[key] = original

    def test_application_identifier_is_default_keychain_group(self):
        del self.entitlements["keychain-access-groups"]
        with patch.object(gate, "command", side_effect=self.signing_command):
            self.assertEqual(gate.inspect_bundle(self.app)["keychain_identity"], self.entitlements["application-identifier"])

    def test_declared_default_keychain_group_must_preserve_app_identity(self):
        identity = self.entitlements["application-identifier"]
        shared = gate.project_team() + ".shared"
        self.entitlements["keychain-access-groups"] = [shared, identity]
        with patch.object(gate, "command", side_effect=self.signing_command):
            with self.assertRaisesRegex(gate.GateError, "default effective Keychain"):
                gate.inspect_bundle(self.app)
        self.entitlements["keychain-access-groups"] = [identity, shared]
        with patch.object(gate, "command", side_effect=self.signing_command):
            self.assertEqual(gate.inspect_bundle(self.app)["keychain_identity"], identity)

    def test_device_bundle_and_wrong_bundle_never_reach_signing(self):
        for key, value in [("DTPlatformName", "iphoneos"), ("CFBundleIdentifier", "other.app")]:
            with self.subTest(key=key):
                old = self.info[key]
                self.info[key] = value
                self.write_info()
                with patch.object(gate, "command") as run:
                    with self.assertRaises(gate.GateError):
                        gate.inspect_bundle(self.app)
                run.assert_not_called()
                self.info[key] = old

    def test_invalid_nested_signature_rejected(self):
        def signing(arguments):
            if arguments[-1].endswith("nested.dylib"):
                raise gate.GateError("invalid nested signature")
            return self.signing_command(arguments)
        with patch.object(gate, "command", side_effect=signing):
            with self.assertRaisesRegex(gate.GateError, "invalid nested"):
                gate.inspect_bundle(self.app)

    def test_bundle_digest_detects_resource_changes(self):
        with patch.object(gate, "command", side_effect=self.signing_command):
            before = gate.inspect_bundle(self.app)
            (self.app / "resource.txt").write_text("changed")
            after = gate.inspect_bundle(self.app)
        self.assertNotEqual(before["bundle_sha256"], after["bundle_sha256"])


class SimulatorInstallerTests(unittest.TestCase):
    udid = "CF9C8F53-AC2A-437D-9EC9-87F61A31644F"

    def evidence(self, digest="verified"):
        return {"app_path": "/synthetic/SpyClash.app", "bundle_id": "com.spyclash.ios", "version": "1.0.3",
                "build": "195", "backend_mode": "supabase-main-candidate", "bundle_sha256": digest}

    def simctl(self, arguments):
        if "list" in arguments:
            return json.dumps({"devices": {"runtime": [{"udid": self.udid, "state": "Booted", "isAvailable": True}]}}).encode()
        if "get_app_container" in arguments:
            return b"/installed/SpyClash.app\n"
        return b""

    def test_invalid_artifact_never_installed(self):
        with patch.object(installer.gate, "inspect_bundle", side_effect=installer.gate.GateError("unsigned")):
            with patch.object(installer.gate, "command") as run:
                with self.assertRaisesRegex(installer.gate.GateError, "unsigned"):
                    installer.install("/synthetic/SpyClash.app", self.udid, "com.spyclash.ios")
                run.assert_not_called()

    def test_explicit_udid_required(self):
        with patch.object(installer.gate, "inspect_bundle") as inspect:
            with self.assertRaisesRegex(installer.gate.GateError, "explicit"):
                installer.install("/synthetic/SpyClash.app", "booted", "com.spyclash.ios")
            inspect.assert_not_called()

    def test_install_checks_both_artifacts_and_never_uninstalls(self):
        with patch.object(installer.gate, "inspect_bundle", side_effect=[self.evidence(), self.evidence()]) as inspect:
            with patch.object(installer.gate, "command", side_effect=self.simctl) as run:
                installer.install("/synthetic/SpyClash.app", self.udid, "com.spyclash.ios")
        self.assertEqual(inspect.call_count, 2)
        inspect.assert_any_call("/installed/SpyClash.app", "com.spyclash.ios")
        self.assertEqual([call.args[0][2] for call in run.call_args_list], ["list", "install", "get_app_container"])

    def test_postinstall_content_drift_fails(self):
        with patch.object(installer.gate, "inspect_bundle", side_effect=[self.evidence(), self.evidence("different")]):
            with patch.object(installer.gate, "command", side_effect=self.simctl):
                with self.assertRaisesRegex(installer.gate.GateError, "differ"):
                    installer.install("/synthetic/SpyClash.app", self.udid, "com.spyclash.ios")


if __name__ == "__main__":
    unittest.main()
