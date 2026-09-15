import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("guard", Path(__file__).parents[1] / "check-release-baseline.py")
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


class ReleaseBaselineTests(unittest.TestCase):
    def test_unrelated_history_cannot_be_used_as_current_source(self):
        # A real historical commit exists, but HEAD of an empty checkout cannot
        # prove it contains the production changes (also catches shallow clones).
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "STALE_CHECKOUT"):
                guard.require_current_checkout(Path(directory), "d487470d050debd452679a8e3f1b850eb993e90f")

    def test_missing_extra_and_changed_runtime_all_fail(self):
        for actual in [{}, {"a": "old"}, {"a": "ok", "extra": "new"}]:
            with self.subTest(actual=actual), self.assertRaisesRegex(ValueError, "PRODUCTION_DRIFT"):
                guard.compare_inventory(actual, {"a": "ok"})
        guard.compare_inventory({"a": "ok"}, {"a": "ok"})

    def test_only_declared_entry_alias_is_normalized(self):
        entry = Path("base44/functions/gameRoomAction/entry.ts")
        self.assertEqual(str(guard.logical_path("gameRoomAction", entry, entry)),
                         "base44/functions/gameRoomAction/main.ts")
        with self.assertRaisesRegex(ValueError, "Unexpected entry alias"):
            guard.logical_path("gameRoomAction", Path("other/entry.ts"), entry)

    def test_pull_normalizes_layout_and_detects_actual_file_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "base44/functions/gameRoomAction"
            folder.mkdir(parents=True)
            (folder / "function.jsonc").write_text(json.dumps({"name": "gameRoomAction", "entry": "entry.ts"}))
            runtime = folder / "entry.ts"
            runtime.write_text("export const revision = 1;\n")
            baseline, config = guard.remote_inventory(root)
            runtime.write_text("export const revision = 2;\n")
            changed, same_config = guard.remote_inventory(root)
            self.assertEqual(config, same_config)
            with self.assertRaisesRegex(ValueError, "PRODUCTION_DRIFT"):
                guard.compare_inventory(changed, baseline)
            (folder / "function.jsonc").write_text(json.dumps({"name": "gameRoomAction", "entry": "../entry.ts"}))
            with self.assertRaisesRegex(ValueError, "Invalid function entry"):
                guard.remote_inventory(root)


if __name__ == "__main__":
    unittest.main()
