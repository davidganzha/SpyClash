#!/usr/bin/env python3
"""Mutate local copies to prove release guards stop drift; no remote operations."""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    docs = Path(__file__).resolve().parent
    manifest = json.loads((docs / "candidate-manifest.json").read_text())
    output = Path(manifest["output_root"])
    passed = []
    with tempfile.TemporaryDirectory(prefix="spyclash-146-guard-tests-") as temporary:
        temporary = Path(temporary)

        def check(name, resource, mutate, mode="candidate", source_tree=None):
            tree = temporary / name
            shutil.copytree(source_tree or output / resource, tree)
            mutate(tree / "base44")
            result = subprocess.run([sys.executable, str(docs / "verify-candidate.py"), resource,
                                     "--mode", mode, "--root", str(tree)],
                                    capture_output=True, text=True)
            assert result.returncode != 0 and "STOP:" in result.stderr, name
            passed.append(name)

        def change_json(path, transform):
            content = json.loads(path.read_text())
            transform(content)
            path.write_text(json.dumps(content))

        def one_entity(base, name):
            return next(p for p in (base / "entities").iterdir()
                        if json.loads(p.read_text())["name"] == name)

        check("runtime-byte-drift", "functions", lambda base:
              (base / "functions/generateWordPack/entry.ts").write_text("unauthorized runtime"))
        check("runtime-extra-file", "functions", lambda base:
              (base / "functions/generateWordPack/unreviewed.ts").write_text("export {};"))
        check("runtime-missing-file", "functions", lambda base:
              (base / "functions/generateWordPack/generation-operation.ts").unlink())
        check("wrong-app-binding", "functions", lambda base:
              (base / ".app.jsonc").write_text('{"id":"wrong-app"}'))
        check("automation-config-drift", "functions", lambda base:
              change_json(base / "functions/pushNotificationAction/function.jsonc",
                          lambda obj: obj["automations"][0].update({"repeat_interval": 1})))
        check("unexpected-function", "functions", lambda base:
              (base / "functions/advanceRound").mkdir())
        check("extra-resource", "functions", lambda base: (base / "entities").mkdir())
        check("runtime-symlink", "functions", lambda base:
              (base / "functions/generateWordPack/foreign.ts").symlink_to("entry.ts"))
        check("existing-schema-drift", "schemas", lambda base:
              change_json(one_entity(base, "GameRoom"), lambda obj: obj.update({"required": []})))
        check("missing-existing-schema", "schemas", lambda base: one_entity(base, "User").unlink())
        check("extra-schema", "schemas", lambda base:
              (base / "entities/unreviewed.jsonc").write_text('{"name":"Unreviewed","type":"object"}'))
        check("weakened-ledger-rls", "schemas", lambda base:
              change_json(one_entity(base, "AiWordPackOperation"),
                          lambda obj: obj["rls"].update({"read": {}})))
        check("unselected-production-function-drift", "functions", lambda base:
              (base / "functions/advanceRound/main.ts").write_text("unreviewed production change"),
              mode="baseline", source_tree=output.parent / "baseline")

        source = temporary / "changed-source"
        for row in manifest["source_inputs"]:
            target = source / row["source_path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(docs.parents[2] / row["source_path"], target)
        (source / "base44/functions/generateWordPack/main.ts").write_text("later source edit")
        result = subprocess.run([sys.executable, str(docs / "verify-candidate.py"), "functions",
                                 "--mode", "candidate", "--root", str(output / "functions"),
                                 "--source-root", str(source)], capture_output=True, text=True)
        assert result.returncode != 0 and "Source input changed:" in result.stderr
        passed.append("source-input-drift")

        changed_docs = temporary / "changed-patch"
        changed_docs.mkdir()
        for name in ["verify-candidate.py", "candidate-manifest.json", "runtime.patch"]:
            shutil.copy2(docs / name, changed_docs / name)
        (changed_docs / "runtime.patch").write_text("unreviewed patch")
        result = subprocess.run([sys.executable, str(changed_docs / "verify-candidate.py"), "functions",
                                 "--mode", "candidate", "--root", str(output / "functions")],
                                capture_output=True, text=True)
        assert result.returncode != 0 and "Reviewed runtime patch changed" in result.stderr
        passed.append("runtime-patch-drift")

    print(json.dumps({"negative_checks_passed": len(passed), "checks": passed}, indent=2))


if __name__ == "__main__":
    main()
