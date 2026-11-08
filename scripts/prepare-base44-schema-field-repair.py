#!/usr/bin/env python3
"""Prepare an additive schema candidate from an exported live snapshot; never deploy.

Usage: --live-schemas export.json --fields fields.json --output review-directory
Use --check instead of --output to fail when any allowlisted field is absent.
Canonical .jsonc files must contain strict JSON, as the repository schemas do.
"""

import argparse
import copy
import difflib
import hashlib
import json
from pathlib import Path
import re
import sys


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path):
    def invalid_constant(value):
        raise ValueError(f"Invalid JSON constant: {value}")
    return json.loads(Path(path).read_text(), object_pairs_hook=unique_object,
                      parse_constant=invalid_constant)


def serialized(value):
    return json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False,
                      allow_nan=False) + "\n"


def digest(value):
    return hashlib.sha256(serialized(value).encode()).hexdigest()


def valid_name(value):
    return isinstance(value, str) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", value)


def schemas_from_export(export):
    if not isinstance(export, dict) or not isinstance(export.get("schemas"), list):
        raise ValueError("Live snapshot must contain a schemas array")
    rows = export["schemas"]
    if not rows:
        raise ValueError("Refusing an empty live schema snapshot")
    if "total" in export and (type(export["total"]) is not int or export["total"] != len(rows)):
        raise ValueError("Live snapshot total does not match its schema count")
    schemas = {}
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("Malformed live schema row")
        name, schema = row.get("entity_name"), row.get("entity_schema")
        if not valid_name(name) or name in schemas:
            raise ValueError(f"Invalid or duplicate live entity: {name}")
        if (not isinstance(schema, dict) or schema.get("name") != name
                or not isinstance(schema.get("properties"), dict)):
            raise ValueError(f"Malformed schema for {name}")
        schemas[name] = copy.deepcopy(schema)
    return schemas


def prepare(export, fields, canonical_directory):
    before = schemas_from_export(export)
    if not isinstance(fields, dict):
        raise ValueError("Field allowlist must map entity names to field arrays")
    for entity, names in fields.items():
        if (not valid_name(entity) or not isinstance(names, list)
                or any(not valid_name(name) for name in names)
                or len(names) != len(set(names))):
            raise ValueError(f"Malformed field allowlist for {entity}")
        if entity not in before:
            raise ValueError(f"Target entity absent from live snapshot: {entity}")

    canonical = {}
    if fields:
        for path in sorted(Path(canonical_directory).iterdir()):
            if path.suffix not in (".json", ".jsonc"):
                continue
            schema = read_json(path)
            if not isinstance(schema, dict) or not valid_name(schema.get("name")):
                raise ValueError(f"Malformed canonical schema: {path.name}")
            name = schema["name"]
            if name in canonical:
                raise ValueError(f"Duplicate canonical entity: {name}")
            canonical[name] = schema

    candidate, additions = copy.deepcopy(before), []
    for entity, names in sorted(fields.items()):
        source = canonical.get(entity, {}).get("properties")
        if not isinstance(source, dict):
            raise ValueError(f"Canonical entity missing properties: {entity}")
        for name in sorted(names):
            definition = source.get(name)
            if not isinstance(definition, dict) or not definition:
                raise ValueError(f"Canonical field missing or malformed: {entity}.{name}")
            properties = candidate[entity]["properties"]
            if name in properties:
                if serialized(properties[name]) != serialized(definition):
                    raise ValueError(f"Conflicting existing field: {entity}.{name}")
                continue
            properties[name] = copy.deepcopy(definition)
            additions.append({"entity": entity, "field": name,
                              "definition_sha256": digest(definition)})

    manifest = {
        "format_version": 1,
        "operation": "prepare_additive_schema_fields",
        "entity_count": len(before),
        "requested_fields": {key: sorted(value) for key, value in sorted(fields.items())},
        "before_sha256": digest(before),
        "candidate_sha256": digest(candidate),
        "added_fields": additions,
        "entities": [{"name": name, "before_sha256": digest(before[name]),
                      "candidate_sha256": digest(candidate[name])} for name in sorted(before)],
    }
    return before, candidate, manifest


def write_candidate(output, before, candidate, manifest):
    output = Path(output)
    if output.is_symlink() or (output.exists() and (not output.is_dir() or any(output.iterdir()))):
        raise ValueError("Output must be an absent or empty directory")
    output.mkdir(parents=True, exist_ok=True)
    stage = output / "stage" / "base44" / "entities"
    stage.mkdir(parents=True)
    for name, schema in sorted(candidate.items()):
        (stage / f"{name}.jsonc").write_text(serialized(schema))
    for name, value in (("before.json", before), ("candidate.json", candidate),
                        ("manifest.json", manifest)):
        (output / name).write_text(serialized(value))
    diff = difflib.unified_diff(serialized(before).splitlines(keepends=True),
                               serialized(candidate).splitlines(keepends=True),
                               fromfile="before.json", tofile="candidate.json")
    (output / "schema.diff").write_text("".join(diff))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live-schemas", required=True, type=Path)
    parser.add_argument("--fields", required=True, type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--output", type=Path)
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    canonical = Path(__file__).resolve().parents[1] / "base44" / "entities"
    try:
        before, candidate, manifest = prepare(read_json(args.live_schemas),
                                              read_json(args.fields), canonical)
        if args.check:
            missing = [f"{item['entity']}.{item['field']}" for item in manifest["added_fields"]]
            print(json.dumps({"missing_fields": missing, "before_sha256": manifest["before_sha256"]}))
            return int(bool(missing))
        write_candidate(args.output, before, candidate, manifest)
        print(f"Prepared {len(manifest['added_fields'])} field additions across "
              f"{manifest['entity_count']} preserved schemas. No deployment performed.")
        return 0
    except (OSError, ValueError) as error:
        print(f"Schema preparation refused: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
