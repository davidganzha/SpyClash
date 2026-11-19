"""Opt-in SQL round trips against the isolated localhost:56322 test database.

Run with SPYCLASH_APPLE_IMPORT_LOCAL_DB_TEST=1. The endpoint is deliberately
fixed; no environment or argument can redirect these destructive fixtures to
production. Only this module's reserved synthetic UUIDs are cleaned up.
"""

import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess
import unittest

from prepare_apple_supabase_import_test import compiler, fixture, reward_row, transfer_receipt, transfer_targets


ROOT = Path(__file__).resolve().parents[2]
OWNERS = ["47000000-0000-4000-8000-000000000001", "47000000-0000-4000-8000-000000000002"]
FOREIGN = "47000000-0000-4000-8000-000000000003"
NODE_DB = """
import postgres from './experiments/supabase-game-core/node_modules/postgres/src/index.js';
let data=''; for await (const part of process.stdin) data+=part;
const db=postgres('postgres://postgres:postgres@127.0.0.1:56322/postgres',{max:1,connect_timeout:5});
try { const rows=await db.unsafe(JSON.parse(data).sql).simple(); console.log(JSON.stringify({rows})); }
catch(error) { console.log(JSON.stringify({error:error.message,code:error.code})); }
finally { await db.end({timeout:2}); }
"""


def database(sql):
    result = subprocess.run(["node", "--input-type=module", "-e", NODE_DB], cwd=ROOT,
                            input=json.dumps({"sql": sql}), text=True, capture_output=True, timeout=40, check=True)
    return json.loads(result.stdout)


def literal(value):
    return "convert_from(decode('" + value.encode().hex() + "','hex'),'UTF8')"


@unittest.skipUnless(os.environ.get("SPYCLASH_APPLE_IMPORT_LOCAL_DB_TEST") == "1", "explicit isolated-local DB opt-in required")
class AppleImportLocalSQLTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        found = database("select to_regclass('apple_private.reward_attempt_aliases')::text as name")
        if found.get("error"):
            raise RuntimeError(found["error"])
        if found["rows"][0]["name"] is None:
            migration = ROOT / "experiments/supabase-game-core/supabase/migrations/20261119112119_apple_pending_reward_transfer.sql"
            result = database(migration.read_text())
            if result.get("error"):
                raise RuntimeError(result["error"])

    def cleanup(self):
        owners = ",".join("'" + owner + "'::uuid" for owner in OWNERS)
        owners_with_foreign = owners + ",'" + FOREIGN + "'::uuid"
        statements = []
        for table in ["apple_private.reward_attempt_aliases", "game_center_private.generation_reward_attempts",
                      "apple_private.billing_token_aliases", "apple_private.migration_snapshots",
                      "apple_private.deletions", "apple_private.accounts", "app_private.native_accounts",
                      "app_private.main_account_deletions", "app_private.legacy_links",
                      "app_private.legacy_session_accounts", "app_private.profiles"]:
            statements.append(f"delete from {table} where user_id in ({owners})")
        statements.append(f"delete from app_private.apple_accounts where user_id in ({owners_with_foreign})")
        statements.append(f"delete from auth.users where id in ({owners})")
        result = database("begin;\n" + ";\n".join(statements) + ";\ncommit;")
        self.assertNotIn("error", result, result)

    def setUp(self):
        self.cleanup()
        self.now = dt.datetime.now(dt.timezone.utc)
        self.data = fixture()
        for index, account in enumerate(self.data[0]["accounts"]):
            account["user_id"] = OWNERS[index]
            account["shadow_email"] = OWNERS[index].replace("-", "") + "@accounts.spyclash.invalid"
            account["identity_key"] = hashlib.sha256(("apple-import-synthetic-" + str(index)).encode()).hexdigest()
            account["subject_key"] = "apple-subject:" + hashlib.sha256(("apple-import-subject-" + str(index)).encode()).hexdigest()
        self.data[1]["GenerationReward"] = [reward_row(state, index) for index, state in enumerate(("pending", "earned", "spent"), 1)]
        self.receipt = transfer_receipt(self.data[1]["GenerationReward"])
        self.targets = transfer_targets(self.data)
        for record in self.receipt["records"]:
            record["transfer_user_id"] = OWNERS[0]
            record["transferred_at"] = self.now.isoformat()
        statements = []
        for account in self.data[0]["accounts"]:
            owner, email, legacy = account["user_id"], account["shadow_email"], account["legacy_user_id"]
            legacy_key = hashlib.sha256(("synthetic-legacy-" + owner).encode()).hexdigest()
            statements += [
                f"insert into auth.users(id,email,role,aud,created_at,updated_at) values('{owner}',{literal(email)},'authenticated','authenticated',now(),now())",
                f"insert into app_private.profiles(user_id,state) values('{owner}','active')",
                f"insert into app_private.legacy_links(user_id,legacy_user_id,source_origin,verified_at) values('{owner}',{literal(legacy)},'https://synthetic.spyclash.invalid',now())",
                "insert into app_private.legacy_session_accounts(identity_key,legacy_user_id,source_origin,source_app_id,user_id,shadow_email,import_completed,state) "
                + f"values('{legacy_key}',{literal(legacy)},'https://synthetic.spyclash.invalid','synthetic-only','{owner}',{literal(email)},true,'ready')",
            ]
        result = database("begin;" + ";".join(statements) + ";commit;")
        self.assertNotIn("error", result, result)

    def tearDown(self):
        self.cleanup()

    def sql(self, receipt=True):
        return compiler.render_sql(*compiler.compile_plan(*self.data, as_of=self.now,
            reward_transfer_receipt=self.receipt if receipt else None, reward_transfer_targets=self.targets))

    def state(self):
        owners = ",".join("'" + owner + "'::uuid" for owner in OWNERS)
        query = f"""select
          (select count(*) from apple_private.accounts where user_id in ({owners}) and state='ready')::int as ready,
          (select count(*) from apple_private.billing_token_aliases where user_id in ({owners}))::int as aliases,
          (select count(*) from app_private.apple_accounts where user_id in ({owners}))::int as primaries,
          (select count(*) from apple_private.reward_attempt_aliases where user_id in ({owners}))::int as reward_aliases,
          (select count(*) from game_center_private.generation_reward_attempts where user_id in ({owners}) and state='pending')::int as pending,
          (select count(*) from game_center_private.generation_reward_attempts where user_id in ({owners}) and state='earned' and consumed_request_id is null)::int as earned,
          (select count(*) from game_center_private.generation_reward_attempts where user_id in ({owners}) and consumed_request_id is not null)::int as spent,
          (select string_agg(source_sha256,',' order by user_id) from apple_private.migration_snapshots where user_id in ({owners})) as snapshot_hashes"""
        result = database(query)
        self.assertNotIn("error", result, result)
        return result["rows"][0]

    def test_full_import_and_identical_reapply_preserve_three_tokens_and_all_reward_states(self):
        plan = self.sql()
        result = database(plan)
        self.assertNotIn("error", result, result)
        state = self.state()
        self.assertEqual({k: state[k] for k in ["ready", "aliases", "primaries", "reward_aliases", "pending", "earned", "spent"]},
                         {"ready": 2, "aliases": 3, "primaries": 2, "reward_aliases": 3, "pending": 1, "earned": 1, "spent": 1})
        result = database(plan)
        self.assertNotIn("error", result, result)
        self.assertEqual(self.state(), state)

    def test_provisional_plan_cannot_mutate_accounts(self):
        result = database(self.sql(receipt=False))
        self.assertIn("source reward transfer receipt required", result.get("error", ""))
        self.assertEqual(self.state()["ready"], 0)
        self.assertEqual(self.state()["aliases"], 0)

    def test_foreign_billing_owner_rolls_back_the_whole_pilot(self):
        token = self.data[1]["AppStoreAccount"][0]["app_account_token"]
        result = database(f"insert into app_private.apple_accounts(user_id,app_account_token) values('{FOREIGN}','{token}')")
        self.assertNotIn("error", result, result)
        result = database(self.sql())
        self.assertIn("billing token owner conflict", result.get("error", ""))
        self.assertEqual(self.state()["ready"], 0)
        self.assertEqual(self.state()["aliases"], 0)

    def test_deletion_fence_prevents_ready_and_preserves_source_mapping(self):
        result = database(f"""insert into app_private.main_account_deletions
          (user_id,request_id,legacy_user_id,source_origin,source_app_id)
          values('{OWNERS[1]}','47000000-0000-4000-8000-000000000099','legacy-b','https://synthetic.spyclash.invalid','synthetic-only')""")
        self.assertNotIn("error", result, result)
        result = database(self.sql())
        self.assertIn("account deletion fence present", result.get("error", ""))
        self.assertEqual(self.state()["ready"], 0)
        self.assertEqual(self.state()["aliases"], 0)

    def test_changed_transfer_receipt_cannot_overwrite_a_completed_snapshot(self):
        result = database(self.sql())
        self.assertNotIn("error", result, result)
        before = self.state()
        self.receipt["records"][0]["transfer_id"] = "47000000-0000-4000-8000-000000000088"
        self.targets["targets"][0]["transfer_id"] = self.receipt["records"][0]["transfer_id"]
        result = database(self.sql())
        self.assertIn("source snapshot changed", result.get("error", ""))
        self.assertEqual(self.state(), before)

    def test_existing_other_native_identity_cannot_be_reassigned(self):
        result = database(f"""insert into app_private.native_accounts
          (user_id,provider,identity_key,state,migration_complete,migration_version)
          values('{OWNERS[1]}','game_center','{'7' * 64}','ready',true,1)""")
        self.assertNotIn("error", result, result)
        result = database(self.sql())
        self.assertIn("native identity conflict", result.get("error", ""))
        self.assertEqual(self.state()["ready"], 0)
        self.assertEqual(self.state()["aliases"], 0)


if __name__ == "__main__":
    unittest.main()
