#!/usr/bin/env python3
"""Reject accidental production or localhost distribution of the 0000 target."""
import json
import os
from pathlib import Path

root = Path(os.environ.get("SRCROOT", Path(__file__).resolve().parents[1]))
config = json.loads((root / "SpyClashGameCenterTests/Support/GameCenterAppConfiguration.json").read_text())
cloud = "https://ovowoixuyabccgkxcexp.supabase.co"
local = "http://127.0.0.1:56330"
assert config["backendURL"] in (cloud, local), "Unapproved experimental backend"
assert not any(config.get(key, False) for key in (
    "appleSignInEnabled", "googleSignInEnabled", "permitsLegacyBilling",
    "permitsLegacyPush", "mainAccountDeletionEnabled")), "Production integration in isolated experiment"
if os.environ.get("CONFIGURATION", "Release") != "Debug":
    assert config["backendURL"] == cloud, "A distributed build cannot use a Mac-local backend"
    assert config["publishableKey"].startswith("sb_publishable_"), "A public client key is required"
assert os.environ.get("PRODUCT_BUNDLE_IDENTIFIER", "com.spyclash.ios.gamecenter000") == "com.spyclash.ios.gamecenter000"
print("Game Center 0000 configuration is isolated.")
