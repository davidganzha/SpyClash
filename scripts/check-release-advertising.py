#!/usr/bin/env python3
"""Validate release advertising configuration, not live provider/backend readiness."""
import json
from pathlib import Path
import plistlib
import re
import sys


def enabled(value):
    return value is True or str(value).upper() in {"YES", "TRUE", "1"}


def validate(info, expected_networks):
    for key in ["SpyClashIntegratedTestAdsEnabled", "SpyClashOwnedAdMobSimulatorTestEnabled",
                "SpyClashUnityTestAdsEnabled", "SpyClashUnityTestMode"]:
        if enabled(info.get(key)):
            raise ValueError(f"Release advertising contains a test override: {key}")
    if not enabled(info.get("SpyClashAdsEnabled")):
        return "advertising disabled"
    provider = info.get("SpyClashRewardedAdProvider", "admob")
    app_id = info.get("GADApplicationIdentifier", "")
    if not re.fullmatch(r"ca-app-pub-[0-9]{16}~[0-9]{10}", app_id):
        raise ValueError("Release requires an owned Google SDK bootstrap application ID.")
    if app_id.startswith("ca-app-pub-3940256099942544"):
        raise ValueError("Release must not contain Google's sample publisher ID.")
    if provider == "unity":
        if info.get("SpyClashUnityGameID") != "800429660":
            raise ValueError("Unity release must use the reviewed SpyClash Game ID.")
        if info.get("SpyClashUnityRewardedAdUnitID") != "BP_Rewarded_iOS":
            raise ValueError("Unity release must use the reviewed rewarded placement.")
        networks = {row.get("SKAdNetworkIdentifier") for row in info.get("SKAdNetworkItems", [])}
        if not set(expected_networks).issubset(networks):
            raise ValueError("Unity release is missing reviewed SKAdNetwork identifiers.")
    elif provider == "admob":
        unit = info.get("SpyClashRewardedAdUnitID", "")
        if not re.fullmatch(r"ca-app-pub-[0-9]{16}/[0-9]{10}", unit):
            raise ValueError("AdMob release requires an owned rewarded unit.")
        if unit.split("/")[0] != app_id.split("~")[0]:
            raise ValueError("AdMob application and rewarded unit publishers differ.")
    else:
        raise ValueError("Unknown release advertising provider.")
    return f"{provider} release configuration; live reward delivery is not established by this check"


def main():
    path = Path(sys.argv[1])
    with path.open("rb") as file:
        info = plistlib.load(file)
    config = Path(__file__).resolve().parents[1] / "release/UnitySKAdNetworkIDs.json"
    print(validate(info, json.loads(config.read_text())["identifiers"]))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        sys.exit(str(error))
