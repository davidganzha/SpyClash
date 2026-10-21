#!/usr/bin/env python3
"""Reject Simulator apps that cannot safely persist the app's Keychain session.

Usage: python3 scripts/check-ios-simulator-bundle.py /absolute/path/SpyClash.app
       Add --json for machine-readable evidence, or --bundle-id for a test target.
This checks an existing artifact. It never signs or modifies it.
"""

import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import re
import struct
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
MACHO_MAGIC = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


class GateError(Exception):
    pass


def command(arguments):
    result = subprocess.run(arguments, capture_output=True, check=False)
    if result.returncode:
        # Signing diagnostics contain paths and validation failures, never session data.
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise GateError(f"{arguments[0]} failed: {detail or result.returncode}")
    return result.stdout


def project_team():
    teams = set(re.findall(r"^\s+DEVELOPMENT_TEAM:\s*([A-Z0-9]+)\s*$",
                           (ROOT / "project.yml").read_text(), re.MULTILINE))
    if len(teams) != 1:
        raise GateError("The project must declare one unambiguous development team.")
    return teams.pop()


def load_plist(path):
    try:
        with path.open("rb") as stream:
            return plistlib.load(stream)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise GateError(f"Cannot read plist: {path}") from error


def bundle_files(app):
    for path in sorted(app.rglob("*")):
        if path.is_symlink():
            try:
                path.resolve(strict=True).relative_to(app)
            except (OSError, ValueError) as error:
                raise GateError(f"Bundle symlink escapes the app or is broken: {path}") from error
        if path.is_file() or path.is_symlink():
            yield path


def bundle_digest(app, files):
    digest = hashlib.sha256()
    for path in files:
        name = path.relative_to(app).as_posix().encode()
        digest.update(len(name).to_bytes(8, "big"))
        digest.update(name)
        if path.is_symlink():
            value = str(path.readlink()).encode()
            digest.update(b"L" + len(value).to_bytes(8, "big") + value)
        else:
            digest.update(b"F" + path.stat().st_size.to_bytes(8, "big"))
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
    return digest.hexdigest()


def simulated_entitlements(executable):
    """Read Xcode's Simulator __TEXT,__entitlements section from every slice.

    Simulator signatures commonly contain an empty plist: Xcode links the
    simulated entitlements into Mach-O instead. The validated signature seals
    these bytes too. Never infer effective entitlements from a source .xcent.
    """
    data = executable.read_bytes()

    def thin(start, length):
        end = start + length
        magic = data[start:start + 4]
        formats = {b"\xcf\xfa\xed\xfe": ("<", True), b"\xfe\xed\xfa\xcf": (">", True),
                   b"\xce\xfa\xed\xfe": ("<", False), b"\xfe\xed\xfa\xce": (">", False)}
        if magic not in formats:
            raise GateError("Unsupported Mach-O executable slice.")
        endian, wide = formats[magic]
        header_size = 32 if wide else 28
        if end > len(data) or length < header_size:
            raise GateError("Truncated Mach-O executable header.")
        count, commands_size = struct.unpack_from(endian + "II", data, start + 16)
        position = start + header_size
        commands_end = position + commands_size
        if commands_end > end or count > commands_size // 8:
            raise GateError("Invalid Mach-O load-command bounds.")
        found = []
        for _ in range(count):
            if position + 8 > commands_end:
                raise GateError("Truncated Mach-O load command.")
            kind, size = struct.unpack_from(endian + "II", data, position)
            if size < 8 or position + size > commands_end:
                raise GateError("Invalid Mach-O load command.")
            segment_kind, segment_size, section_size = (0x19, 72, 80) if wide else (1, 56, 68)
            if kind == segment_kind:
                if size < segment_size:
                    raise GateError("Invalid Mach-O segment.")
                section_count = struct.unpack_from(endian + "I", data, position + (64 if wide else 48))[0]
                if segment_size + section_count * section_size > size:
                    raise GateError("Invalid Mach-O section bounds.")
                for index in range(section_count):
                    section = position + segment_size + index * section_size
                    name = data[section:section + 16].rstrip(b"\0")
                    segment = data[section + 16:section + 32].rstrip(b"\0")
                    if name == b"__entitlements" and segment == b"__TEXT":
                        _, section_length, offset = struct.unpack_from(endian + ("QQI" if wide else "III"), data, section + 32)
                        if offset + section_length > length or section_length > 1024 * 1024:
                            raise GateError("Invalid embedded Simulator entitlement bounds.")
                        try:
                            value = plistlib.loads(data[start + offset:start + offset + section_length].rstrip(b"\0"))
                        except (ValueError, plistlib.InvalidFileException) as error:
                            raise GateError("Malformed embedded Simulator entitlements.") from error
                        if not isinstance(value, dict):
                            raise GateError("Malformed embedded Simulator entitlements.")
                        found.append(value)
            position += size
        if len(found) > 1:
            raise GateError("Ambiguous embedded Simulator entitlements.")
        return found[0] if found else {}

    magic = data[:4]
    fat_formats = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
                   b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
    if magic not in fat_formats:
        return [thin(0, len(data))]
    endian, wide = fat_formats[magic]
    if len(data) < 8:
        raise GateError("Truncated universal Mach-O header.")
    count = struct.unpack_from(endian + "I", data, 4)[0]
    entry_size = 32 if wide else 20
    if not 1 <= count <= 64 or 8 + count * entry_size > len(data):
        raise GateError("Invalid universal Mach-O slices.")
    slices = []
    for index in range(count):
        offset, length = struct.unpack_from(endian + ("QQ" if wide else "II"), data, 8 + index * entry_size + 8)
        slices.append(thin(offset, length))
    return slices


def inspect_bundle(app_path, expected_bundle_id="com.spyclash.ios"):
    app = Path(app_path).expanduser().resolve()
    if not app.is_dir() or app.suffix != ".app":
        raise GateError("Pass an existing .app bundle.")
    info = load_plist(app / "Info.plist")
    if info.get("DTPlatformName") != "iphonesimulator":
        raise GateError("Only DTPlatformName=iphonesimulator is allowed.")
    if info.get("CFBundleIdentifier") != expected_bundle_id:
        raise GateError(f"Bundle identifier does not match {expected_bundle_id}.")
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or Path(executable).name != executable:
        raise GateError("The app executable name is invalid.")
    if not (app / executable).is_file():
        raise GateError("The app executable is missing.")

    # The resource seal matters: linker-only ad-hoc signatures can launch on a
    # Simulator while lacking the application identity required by securityd.
    command(["codesign", "--verify", "--deep", "--strict", str(app)])
    try:
        raw_entitlements = command(["codesign", "-d", "--entitlements", ":-", str(app)])
        signed_entitlements = plistlib.loads(raw_entitlements) if raw_entitlements.strip() else {}
    except (ValueError, plistlib.InvalidFileException) as error:
        raise GateError("The app has no readable signing entitlements.") from error
    if not isinstance(signed_entitlements, dict):
        raise GateError("The app's effective signing entitlements are malformed.")
    team = project_team()
    identity = team + "." + expected_bundle_id
    embedded = simulated_entitlements(app / executable)
    for simulated in embedded:
        if any(key in signed_entitlements and signed_entitlements[key] != value for key, value in simulated.items()):
            raise GateError("Signed and embedded Simulator entitlements conflict.")
        entitlements = {**signed_entitlements, **simulated}
        if entitlements.get("application-identifier") != identity:
            raise GateError(f"Effective application-identifier must be {identity}.")
        if entitlements.get("com.apple.developer.team-identifier", team) != team:
            raise GateError("Effective team identifier does not match the project.")
        groups = entitlements.get("keychain-access-groups")
        # These stores omit kSecAttrAccessGroup. A declared first group is their
        # default; without groups, Keychain uses application-identifier.
        if groups is not None and (not isinstance(groups, list) or not groups or
                                   any(not isinstance(group, str) or not group or "*" in group for group in groups) or
                                   groups[0] != identity):
            raise GateError("The default effective Keychain access group must match the app identity.")

    files = list(bundle_files(app))
    verified_executables = 0
    for path in files:
        if path.is_symlink():
            continue
        with path.open("rb") as stream:
            is_macho = stream.read(4) in MACHO_MAGIC
        if is_macho:
            command(["codesign", "--verify", "--strict", str(path)])
            verified_executables += 1
    if verified_executables == 0:
        raise GateError("No signed Mach-O executables were found in the app.")
    return {
        "app_path": str(app),
        "bundle_id": expected_bundle_id,
        "version": str(info.get("CFBundleShortVersionString", "")),
        "build": str(info.get("CFBundleVersion", "")),
        "backend_mode": str(info.get("SpyClashBackendMode", "unspecified")),
        "application_identifier": identity,
        "keychain_identity": identity,
        "entitlement_source": "macho_simulated" if any(embedded) else "code_signature",
        "verified_executables": verified_executables,
        "bundle_sha256": bundle_digest(app, files),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app")
    parser.add_argument("--bundle-id", default="com.spyclash.ios")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        evidence = inspect_bundle(args.app, args.bundle_id)
    except (GateError, OSError) as error:
        print(f"Simulator install gate FAILED: {error}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(evidence, indent=2))
    else:
        print(f"PASS: {evidence['bundle_id']} {evidence['version']} ({evidence['build']}); "
              f"backend={evidence['backend_mode']}; Keychain identity={evidence['keychain_identity']}; "
              f"verified executables={evidence['verified_executables']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
