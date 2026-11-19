import copy
import contextlib
import datetime as dt
import importlib.util
import io
import json
from pathlib import Path
import re
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("apple_import", Path(__file__).parents[1] / "prepare-apple-supabase-import.py")
compiler = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compiler)
NOW = dt.datetime(2026, 11, 19, 15, tzinfo=dt.timezone.utc)
OWNER_A = "11111111-1111-4111-8111-111111111111"
OWNER_B = "22222222-2222-4222-8222-222222222222"
TOKEN_A = "33333333-3333-4333-8333-333333333333"
TOKEN_B = "44444444-4444-4444-8444-444444444444"
TOKEN_C = "55555555-5555-4555-8555-555555555555"


def fixture():
    accounts = [{"identity_key": char * 64, "subject_key": "apple-subject:" + other * 64,
                 "client_id": "com.spyclash.ios", "user_id": owner,
                 "shadow_email": owner.replace("-", "") + "@accounts.spyclash.invalid",
                 "legacy_user_id": "legacy-" + char, "legacy_credential_identity_key": "apple-email:" + legacy * 64,
                 "source_record_id": "bound-" + char,
                 "source_revision": revision, "migration_complete": False, "state": "pending"}
                for char, other, legacy, owner, revision in [
                    ("a", "c", "e", OWNER_A, TOKEN_A), ("b", "d", "f", OWNER_B, TOKEN_B)]]
    rights = {table: [] for table in compiler.TABLES}
    rights["AppStoreAccount"] = [
        {"id": "bill-old-a", "user_id": "legacy-a", "app_account_token": TOKEN_A,
         "reservation_state": "active", "created_at": "2026-07-01T00:00:00Z", "last_used_at": "2026-11-01T00:00:00Z"},
        {"id": "bill-new-a", "user_id": "legacy-a", "app_account_token": TOKEN_B,
         "reservation_state": "active", "created_at": "2026-08-01T00:00:00Z", "last_used_at": "2026-11-15T00:00:00Z"},
        {"id": "bill-b", "user_id": "legacy-b", "app_account_token": TOKEN_C,
         "reservation_state": "active", "created_at": "2026-09-01T00:00:00Z", "last_used_at": "2026-11-10T00:00:00Z"},
    ]
    rights["Entitlement"] = [{"id": "expired-subscription", "user_id": "legacy-a", "provider": "apple",
                              "status": "expired", "expires_at": "2026-11-14T00:00:00Z",
                              "environment": "sandbox", "app_account_token": TOKEN_A}]
    rights["AiGenerationUsage"] = [{"id": "old-quota", "user_id": "legacy-a", "usage_date": "2026-07-01",
                                    "quota_key": "legacy-a:2026-07-01", "generations_used": 5}]
    return {"bound_count": 2, "matched_count": 2, "issues": [], "accounts": accounts}, rights, []


def reward_row(state="pending", index=1, issued="2026-11-07T12:00:00Z"):
    attempt = f"70000000-0000-4000-8000-{index:012d}"
    return {"id": "reward-" + str(index), "user_id": "legacy-a", "state": state, "issued_at": issued,
            "attempt_id": attempt, "custom_data": attempt + ".legacy." + "a" * 64,
            "ad_unit_id": "ca-app-pub-1234567890123456/1234567890",
            "transaction_id": "provider-transaction-" + str(index) if state in ("earned", "spent") else None,
            "earned_at": "2026-11-07T12:01:00Z" if state in ("earned", "spent") else None,
            "generation_request_id": f"80000000-0000-4000-8000-{index:012d}" if state == "spent" else None}


def transfer_receipt(rows):
    return {"version": 1, "records": [dict(copy.deepcopy(row), state="transferred", transfer_state=row["state"],
            transfer_user_id=OWNER_A, transfer_id="90000000-0000-4000-8000-000000000001",
            transferred_at="2026-11-19T14:00:00Z") for row in rows]}


def transfer_targets(data):
    owners = {row["legacy_user_id"]: row["user_id"] for row in data[0]["accounts"]}
    return {"version": 1, "targets": [{"source_record_id": row["id"], "legacy_user_id": row["user_id"],
        "native_user_id": owners[row["user_id"]], "transfer_id": "90000000-0000-4000-8000-000000000001",
        "fingerprint": compiler.reward_fingerprint(row)} for row in data[1]["GenerationReward"]]}


class OfflineAppleImportTests(unittest.TestCase):
    def compile(self, data=None, **kwargs):
        data = data or fixture()
        kwargs.setdefault("reward_transfer_targets", transfer_targets(data))
        return compiler.compile_plan(*data, as_of=NOW, **kwargs)

    def rejected(self, data, code, **kwargs):
        with self.assertRaisesRegex(compiler.ImportRejected, code):
            self.compile(data, **kwargs)

    def test_all_three_historical_tokens_and_expired_rights_are_retained(self):
        manifest, report = self.compile()
        first, second = manifest["accounts"]
        self.assertEqual(first["primary_token"], TOKEN_B)
        self.assertEqual(second["primary_token"], TOKEN_C)
        self.assertEqual({a["app_account_token"] for item in manifest["accounts"] for a in item["aliases"]},
                         {TOKEN_A, TOKEN_B, TOKEN_C})
        self.assertEqual(first["snapshot"]["source_rights"]["Entitlement"], fixture()[1]["Entitlement"])
        self.assertEqual(report["counts"]["billing_aliases"], 3)
        self.assertEqual(report["counts"]["archived_quota_rows"], 1)
        self.assertEqual(report["counts"]["active_rights_imported"], 0)
        self.assertFalse(report["production_executed"])
        self.assertFalse(report["new_signup_coverage"])

    def test_existing_primary_wins_over_newer_source_token(self):
        data = fixture()
        data[2].append({"user_id": OWNER_A, "app_account_token": TOKEN_A, "state": "active"})
        manifest, report = self.compile(data)
        self.assertEqual(manifest["accounts"][0]["primary_token"], TOKEN_A)
        self.assertEqual(len(manifest["accounts"][0]["aliases"]), 2)
        self.assertEqual(report["counts"]["existing_primaries_retained"], 1)

    def test_same_token_cannot_be_adopted_from_another_existing_owner(self):
        data = fixture()
        data[2].append({"user_id": OWNER_B, "app_account_token": TOKEN_A, "state": "active"})
        self.rejected(data, "BILLING_TOKEN_OTHER_OWNER")

    def test_duplicate_source_tokens_and_deleted_primary_fail(self):
        data = fixture()
        data[1]["AppStoreAccount"][2]["app_account_token"] = TOKEN_A
        self.rejected(data, "DUPLICATE_SOURCE_BILLING_TOKEN")
        data = fixture()
        data[2].append({"user_id": OWNER_A, "app_account_token": TOKEN_A, "state": "deleted"})
        self.rejected(data, "EXISTING_PRIMARY_NOT_ACTIVE")

    def test_identity_ambiguity_and_partial_pilot_fail(self):
        for field in ("identity_key", "subject_key", "legacy_user_id", "user_id", "shadow_email"):
            data = fixture()
            data[0]["accounts"][1][field] = data[0]["accounts"][0][field]
            self.rejected(data, "DUPLICATE_ACCOUNT")
        data = fixture()
        data[0]["matched_count"] = 1
        self.rejected(data, "EXACT_TWO_ACCOUNT_PILOT_REQUIRED")

    def test_email_never_selects_source_owner(self):
        data = fixture()
        data[1]["Entitlement"][0]["user_id"] = "unknown-source-user"
        data[1]["Entitlement"][0]["email"] = data[0]["accounts"][0]["shadow_email"]
        self.rejected(data, "UNMATCHED_SOURCE_OWNER")

    def test_missing_export_table_and_duplicate_source_rows_fail(self):
        data = fixture()
        del data[1]["MembershipGrant"]
        self.rejected(data, "RIGHTS_EXPORT_INCOMPLETE")
        data = fixture()
        data[1]["Entitlement"].append(copy.deepcopy(data[1]["Entitlement"][0]))
        self.rejected(data, "DUPLICATE_RIGHTS_SOURCE_ID")

    def test_live_apple_and_stripe_rights_require_canonical_verification(self):
        for provider in ("apple", "stripe"):
            for status, expiry in [("active", "2026-11-14T00:00:00Z"), ("expired", "2027-01-01T00:00:00Z")]:
                data = fixture()
                data[1]["Entitlement"][0].update(provider=provider, status=status, expires_at=expiry)
                self.rejected(data, "ACTIVE_ENTITLEMENT_REQUIRES_CANONICAL_VERIFICATION")

    def test_grants_enrollments_and_unknown_entitlement_owners_fail(self):
        for table, code in [("MembershipGrant", "UNSUPPORTED_MEMBERSHIP_GRANTS"),
                            ("GenerationRewardEnrollment", "UNSUPPORTED_REWARD_ENROLLMENT")]:
            data = fixture()
            data[1][table].append({"id": "right", "user_id": "legacy-a"})
            self.rejected(data, code)
        data = fixture()
        data[1]["Entitlement"][0]["app_account_token"] = TOKEN_C
        self.rejected(data, "ENTITLEMENT_TOKEN_OWNER_UNPROVEN")

    def test_current_quota_and_malformed_quota_cannot_reset_allowance(self):
        for count in (1, 10):
            data = fixture()
            data[1]["AiGenerationUsage"][0].update(usage_date="2026-11-19", quota_key="legacy-a:2026-11-19", generations_used=count)
            self.rejected(data, "CURRENT_QUOTA_REQUIRES_LEDGER_IMPORT")
        data = fixture()
        data[1]["AiGenerationUsage"][0]["generations_used"] = True
        self.rejected(data, "QUOTA_COUNT_INVALID")
        data = fixture()
        data[1]["AiGenerationUsage"][0]["quota_key"] = "legacy-b:2026-07-01"
        self.rejected(data, "QUOTA_OWNER_KEY_MISMATCH")

    def test_reserved_and_malformed_rewards_are_rejected(self):
        for state, code in [("reserved", "UNSUPPORTED_RESERVED_REWARD_CREDIT"),
                            ("unknown", "UNSUPPORTED_RESERVED_REWARD_CREDIT")]:
            data = fixture()
            data[1]["GenerationReward"].append(reward_row(state))
            self.rejected(data, code)
        data = fixture()
        data[1]["GenerationReward"].append(reward_row())
        data[1]["GenerationReward"][0]["transaction_id"] = "already-earned"
        self.rejected(data, "PENDING_REWARD_HAS_CREDIT_STATE")

    def test_old_pending_reward_is_not_silently_called_expired(self):
        data = fixture()
        data[1]["GenerationReward"].append(reward_row())
        manifest, report = self.compile(data)
        self.assertFalse(report["ready_for_import"])
        self.assertEqual(report["counts"]["source_fences_required"], 1)
        self.assertEqual(manifest["accounts"][0]["rewards"][0]["state"], "pending")
        self.assertEqual(manifest["accounts"][0]["rewards"][0]["expires_at"], "2026-11-08T12:00:00+00:00")
        self.assertIn("draft cannot execute", compiler.render_sql(manifest, report))

    def test_receipted_pending_earned_and_spent_rewards_preserve_exact_capability(self):
        data = fixture()
        data[1]["GenerationReward"] = [reward_row(state, index) for index, state in enumerate(("pending", "earned", "spent"), 1)]
        receipt = transfer_receipt(data[1]["GenerationReward"])
        manifest, report = self.compile(data, reward_transfer_receipt=receipt)
        self.assertTrue(report["ready_for_import"])
        self.assertEqual(report["counts"]["reward_transfers_receipted"], 3)
        self.assertEqual(report["counts"]["source_fences_required"], 0)
        mapped = {row["source_state"]: row for row in manifest["accounts"][0]["rewards"]}
        self.assertEqual(mapped["pending"]["state"], "pending")
        self.assertEqual(mapped["earned"]["state"], "earned")
        self.assertIsNone(mapped["earned"]["consumed_request_id"])
        self.assertEqual(mapped["spent"]["state"], "earned")
        self.assertEqual(mapped["spent"]["consumed_request_id"], data[1]["GenerationReward"][2]["generation_request_id"])
        self.assertEqual(mapped["earned"]["transaction_id"], data[1]["GenerationReward"][1]["transaction_id"])
        self.assertEqual(manifest["accounts"][0]["snapshot"]["reward_transfer_receipts"], compiler.sorted_rows(receipt["records"]))

    def test_partial_changed_and_other_owner_transfer_receipts_fail(self):
        data = fixture()
        data[1]["GenerationReward"] = [reward_row()]
        for field, value, code in [("transfer_user_id", OWNER_B, "TRANSFER_RECEIPT_OWNER_MISMATCH"),
                                   ("transfer_state", "earned", "TRANSFER_RECEIPT_STATE_MISMATCH"),
                                   ("custom_data", "changed", "TRANSFER_RECEIPT_FINGERPRINT_MISMATCH"),
                                   ("transaction_id", "unexpected-credit", "TRANSFER_RECEIPT_SOURCE_CHANGED")]:
            receipt = transfer_receipt(data[1]["GenerationReward"])
            receipt["records"][0][field] = value
            self.rejected(data, code, reward_transfer_receipt=receipt)
        self.rejected(data, "TRANSFER_RECEIPT_INCOMPLETE", reward_transfer_receipt={"version": 1, "records": []})

    def test_receipt_cannot_choose_an_arbitrary_transfer_id_or_target_fingerprint(self):
        data = fixture()
        data[1]["GenerationReward"] = [reward_row()]
        receipt = transfer_receipt(data[1]["GenerationReward"])
        receipt["records"][0]["transfer_id"] = TOKEN_C
        self.rejected(data, "TRANSFER_RECEIPT_ID_MISMATCH", reward_transfer_receipt=receipt)
        targets = transfer_targets(data)
        targets["targets"][0]["fingerprint"] = "0" * 64
        self.rejected(data, "TRANSFER_TARGET_FINGERPRINT_MISMATCH", reward_transfer_targets=targets)

    def test_duplicate_reward_transaction_cannot_create_two_credits(self):
        data = fixture()
        data[1]["GenerationReward"] = [reward_row("earned", 1), reward_row("earned", 2)]
        data[1]["GenerationReward"][1]["transaction_id"] = data[1]["GenerationReward"][0]["transaction_id"]
        self.rejected(data, "DUPLICATE_REWARD_TRANSACTION")

    def test_stable_hashes_survive_source_order_but_change_with_source_revision(self):
        first, first_report = self.compile()
        data = fixture()
        data[0]["accounts"].reverse()
        data[1]["AppStoreAccount"].reverse()
        second, second_report = self.compile(data)
        self.assertEqual(first, second)
        self.assertEqual(first_report["source_manifest_sha256"], second_report["source_manifest_sha256"])
        data[0]["accounts"][0]["source_revision"] = TOKEN_C
        _, changed = self.compile(data)
        self.assertNotEqual(changed["source_manifest_sha256"], first_report["source_manifest_sha256"])

    def test_sql_source_data_is_hex_encoded_not_interpolated(self):
        data = fixture()
        attack = "source'); COMMIT; DROP TABLE auth.users; -- $apple_import$ \\ unicode ☃"
        data[1]["AppStoreAccount"][0]["id"] = attack
        manifest, report = self.compile(data)
        sql = compiler.render_sql(manifest, report)
        self.assertNotIn(attack, sql)
        payload_hex = re.search(r"decode\('([0-9a-f]+)','hex'\)", sql).group(1)
        decoded = json.loads(bytes.fromhex(payload_hex))
        self.assertEqual(decoded["accounts"], manifest["accounts"])
        self.assertIn(attack, [row["id"] for row in decoded["accounts"][0]["snapshot"]["source_rights"]["AppStoreAccount"]])

    def test_sql_is_atomic_fail_closed_and_ready_transition_is_last(self):
        sql = compiler.render_sql(*self.compile())
        for guard in ("set transaction isolation level serializable", "lock table auth.users in share mode",
                      "deleted_at is null", "banned_until", "legacy.import_completed", "source_origin=legacy.source_origin",
                      "main_account_deletions", "native identity conflict", "source snapshot changed",
                      "reviewed primary billing token changed", "historical billing token owner conflict",
                      "source snapshot digest mismatch", "apple import review is stale"):
            self.assertIn(guard, sql)
        self.assertGreater(sql.index("set state='ready'"), sql.index("insert into apple_private.billing_token_aliases"))
        self.assertTrue(sql.endswith("commit;\n"))
        self.assertNotIn("update auth.users", sql)
        self.assertNotIn("delete from", sql)

    def test_private_artifacts_and_duplicate_json_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "private.sql"
            path.touch(mode=0o644)
            compiler.write_private(path, "sensitive")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            path.write_text('{"accounts": [], "accounts": []}')
            with self.assertRaisesRegex(compiler.ImportRejected, "DUPLICATE_JSON_KEY"):
                compiler.read_json(path)

    def test_failed_refresh_invalidates_the_previous_executable_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data = fixture()
            for name, value in zip(("apple-import-candidate.json", "base44-apple-rights.json", "supabase-billing-accounts.json"), data):
                (root / name).write_text(json.dumps(value))
            args = ["--directory", directory, "--as-of", NOW.isoformat()]
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(compiler.main(args), 0)
                self.assertTrue(json.loads((root / "apple-import-report.json").read_text())["ready_for_import"])
                data[1]["MembershipGrant"].append({"id": "new-live-grant", "user_id": "legacy-a"})
                (root / "base44-apple-rights.json").write_text(json.dumps(data[1]))
                self.assertEqual(compiler.main(args), 2)
            self.assertFalse(json.loads((root / "apple-import-report.json").read_text())["ready_for_import"])
            self.assertNotIn("insert into", (root / "apple-import-plan.sql").read_text())
            self.assertIn("raise exception", (root / "apple-import-plan.sql").read_text())


if __name__ == "__main__":
    unittest.main()
