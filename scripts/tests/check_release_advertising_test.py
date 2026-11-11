import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("advertising", Path(__file__).parents[1] / "check-release-advertising.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class AdvertisingReleaseTests(unittest.TestCase):
    def setUp(self):
        self.info = {
            "SpyClashAdsEnabled": "YES", "SpyClashRewardedAdProvider": "unity",
            "GADApplicationIdentifier": "ca-app-pub-5081830513960558~9442838104",
            "SpyClashUnityGameID": "800429660", "SpyClashUnityRewardedAdUnitID": "BP_Rewarded_iOS",
            "SKAdNetworkItems": [{"SKAdNetworkIdentifier": "4dzt52r2t5.skadnetwork"}],
        }
        self.networks = ["4dzt52r2t5.skadnetwork"]

    def test_owned_unity_release(self):
        self.assertIn("unity release", gate.validate(self.info, self.networks))

    def test_all_preview_and_test_switches_rejected(self):
        for key in ["SpyClashUnityTestAdsEnabled", "SpyClashUnityTestMode",
                    "SpyClashIntegratedTestAdsEnabled", "SpyClashOwnedAdMobSimulatorTestEnabled"]:
            for value in [True, "YES", "true", "1"]:
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    gate.validate({**self.info, key: value}, self.networks)

    def test_unknown_provider_and_wrong_owned_identifiers_rejected(self):
        for key, value in [("SpyClashRewardedAdProvider", "other"), ("SpyClashUnityGameID", "14850"),
                           ("SpyClashUnityGameID", "00014850"), ("SpyClashUnityRewardedAdUnitID", "rewardedVideo"),
                           ("GADApplicationIdentifier", "ca-app-pub-3940256099942544~1458002511")]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                gate.validate({**self.info, key: value}, self.networks)

    def test_missing_attribution_ids_rejected(self):
        with self.assertRaises(ValueError):
            gate.validate({**self.info, "SKAdNetworkItems": []}, self.networks)

    def test_owned_admob_compatibility_and_cross_publisher_rejection(self):
        info = {**self.info, "SpyClashRewardedAdProvider": "admob",
                "SpyClashRewardedAdUnitID": "ca-app-pub-5081830513960558/6816674766"}
        self.assertIn("admob release", gate.validate(info, []))
        with self.assertRaises(ValueError):
            gate.validate({**info, "SpyClashRewardedAdUnitID": "ca-app-pub-1111111111111111/6816674766"}, [])

    def test_disabled_historical_bundles_remain_valid(self):
        self.assertEqual(gate.validate({}, []), "advertising disabled")


if __name__ == "__main__":
    unittest.main()
