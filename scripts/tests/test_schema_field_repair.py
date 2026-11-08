import copy
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "prepare-base44-schema-field-repair.py"
SPEC = importlib.util.spec_from_file_location("schema_field_repair", SCRIPT)
repair = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(repair)


class SchemaFieldRepairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.canonical = self.root / "canonical"
        self.canonical.mkdir()
        self.field = {"type": "string", "rls": {"write": {"user_condition": {"role": "admin"}}}}
        self.source = {"name": "WordPack", "type": "object", "properties": {"owner_user_id": self.field}}
        self.source_path = self.canonical / "word-pack.jsonc"
        self.source_path.write_text(json.dumps(self.source))
        self.live_schema = {
            "name": "WordPack", "type": "object", "properties": {
                "name": {"type": "string", "enum": ["A", "B"]}},
            "required": ["name"], "rls": {"read": {"user_condition": {"role": "admin"}}},
            "unknown_metadata": {"preserve": [1, False, None]},
        }
        self.export = {"schemas": [{"entity_name": "WordPack", "entity_schema": self.live_schema}], "total": 1}
        self.fields = {"WordPack": ["owner_user_id"]}

    def prepare(self, export=None, fields=None):
        return repair.prepare(self.export if export is None else export,
                              self.fields if fields is None else fields, self.canonical)

    def test_addition_preserves_every_existing_value_and_unknown_entity(self):
        unknown = {"name": "UnknownLiveEntity", "properties": {"custom": {"type": "boolean"}},
                   "rls": {"read": False}, "required": ["custom"], "other": "unchanged"}
        self.export["schemas"].append({"entity_name": "UnknownLiveEntity", "entity_schema": unknown})
        self.export["total"] = 2
        original = copy.deepcopy(self.export)
        before, candidate, manifest = self.prepare()
        removed = copy.deepcopy(candidate)
        self.assertEqual(removed["WordPack"]["properties"].pop("owner_user_id"), self.field)
        self.assertEqual(removed, before)
        self.assertEqual(candidate["UnknownLiveEntity"], unknown)
        self.assertEqual(self.export, original)
        self.assertEqual(len(manifest["added_fields"]), 1)
        output = self.root / "review"
        repair.write_candidate(output, before, candidate, manifest)
        files = list((output / "stage/base44/entities").glob("*.jsonc"))
        self.assertEqual({p.stem: repair.read_json(p) for p in files}, candidate)
        self.assertIn("owner_user_id", (output / "schema.diff").read_text())

    def test_empty_allowlist_is_noop(self):
        before, candidate, manifest = self.prepare(fields={})
        self.assertEqual(candidate, before)
        self.assertEqual(manifest["added_fields"], [])
        self.assertEqual(manifest["before_sha256"], manifest["candidate_sha256"])

    def test_identical_existing_target_is_noop(self):
        self.live_schema["properties"]["owner_user_id"] = copy.deepcopy(self.field)
        before, candidate, manifest = self.prepare()
        self.assertEqual(before, candidate)
        self.assertEqual(manifest["added_fields"], [])

    def test_check_mode_reports_missing_without_writing(self):
        live, fields = self.root / "live.json", self.root / "fields.json"
        live.write_text(json.dumps(self.export))
        fields.write_text(json.dumps(self.fields))
        prior_paths = sorted(self.root.rglob("*"))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = repair.main(["--live-schemas", str(live), "--fields", str(fields), "--check"])
        self.assertEqual(result, 1)
        self.assertEqual(json.loads(output.getvalue())["missing_fields"], ["WordPack.owner_user_id"])
        self.assertEqual(sorted(self.root.rglob("*")), prior_paths)

    def test_check_mode_accepts_present_fields_without_writing(self):
        canonical = repair.read_json(SCRIPT.parents[1] / "base44/entities/WordPack.jsonc")
        self.live_schema["properties"]["owner_user_id"] = canonical["properties"]["owner_user_id"]
        live, fields = self.root / "live.json", self.root / "fields.json"
        live.write_text(json.dumps(self.export))
        fields.write_text(json.dumps(self.fields))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = repair.main(["--live-schemas", str(live), "--fields", str(fields), "--check"])
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(output.getvalue())["missing_fields"], [])

    def test_conflicting_existing_definition_refuses_even_if_only_metadata_differs(self):
        self.live_schema["properties"]["owner_user_id"] = {**self.field, "description": "Live definition"}
        with self.assertRaisesRegex(ValueError, "Conflicting existing field"):
            self.prepare()

    def test_missing_source_field_refuses(self):
        with self.assertRaisesRegex(ValueError, "Canonical field missing"):
            self.prepare(fields={"WordPack": ["not_in_source"]})

    def test_missing_target_entity_refuses(self):
        with self.assertRaisesRegex(ValueError, "Target entity absent"):
            self.prepare(fields={"Missing": ["owner_user_id"]})

    def test_duplicate_entities_refuse(self):
        self.export["schemas"] *= 2
        self.export["total"] = 2
        with self.assertRaisesRegex(ValueError, "duplicate live entity"):
            self.prepare()

    def test_duplicate_canonical_entities_refuse(self):
        (self.canonical / "duplicate.json").write_text(json.dumps(self.source))
        with self.assertRaisesRegex(ValueError, "Duplicate canonical entity"):
            self.prepare()

    def test_incomplete_and_empty_snapshots_refuse(self):
        for export in ({"schemas": [], "total": 0}, {**self.export, "total": 2}):
            with self.subTest(export=export), self.assertRaises(ValueError):
                self.prepare(export=export)

    def test_malformed_inputs_refuse(self):
        for fields in ([], {"WordPack": "owner_user_id"}, {"WordPack": ["x", "x"]},
                       {"WordPack": ["../escape"]}, {"WordPack": [{}]}):
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                self.prepare(fields=fields)
        for schema in ({}, {"name": "Wrong", "properties": {}}, {"name": "WordPack", "properties": []}):
            with self.subTest(schema=schema), self.assertRaises(ValueError):
                self.prepare(export={"schemas": [{"entity_name": "WordPack", "entity_schema": schema}]})

    def test_duplicate_json_keys_and_nonfinite_values_refuse(self):
        path = self.root / "invalid.json"
        for value in ('{"WordPack": [], "WordPack": []}', '{"nested": {"x": 1, "x": 2}}', '{"x": NaN}'):
            path.write_text(value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                repair.read_json(path)

    def test_manifest_and_diff_are_deterministic(self):
        first = self.prepare()
        reordered = copy.deepcopy(self.export)
        reordered["schemas"][0]["entity_schema"] = dict(reversed(list(self.live_schema.items())))
        second = self.prepare(export=reordered)
        self.assertEqual(first[2], second[2])
        for index, values in enumerate((first, second)):
            repair.write_candidate(self.root / str(index), *values)
        for name in ("manifest.json", "before.json", "candidate.json", "schema.diff"):
            self.assertEqual((self.root / "0" / name).read_bytes(), (self.root / "1" / name).read_bytes())

    def test_nonempty_output_cannot_be_overwritten(self):
        output = self.root / "review"
        output.mkdir()
        existing = output / "keep.txt"
        existing.write_text("untouched")
        with self.assertRaisesRegex(ValueError, "absent or empty"):
            repair.write_candidate(output, *self.prepare())
        self.assertEqual(existing.read_text(), "untouched")

    def test_symlink_output_refuses(self):
        target = self.root / "target"
        target.mkdir()
        link = self.root / "link"
        link.symlink_to(target, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "absent or empty"):
            repair.write_candidate(link, *self.prepare())
        self.assertEqual(list(target.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
