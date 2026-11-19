#!/usr/bin/env python3
"""Compile a private, reviewable two-account Apple import. Never connects to a DB.

This is an offline pilot compiler, not a general new-account importer. Source
exports must be refreshed and the SQL reviewed before separately authorized use.
Unsupported live rights stop compilation; their absence is never inferred from
missing tables. Every accepted source row is retained in a migration snapshot.
"""

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import uuid


UTC = dt.timezone.utc
TABLES = ("AppStoreAccount", "MembershipGrant", "Entitlement", "AiGenerationUsage",
          "GenerationReward", "GenerationRewardEnrollment")
ACCOUNT_FIELDS = {"identity_key", "subject_key", "client_id", "user_id", "shadow_email",
                  "legacy_user_id", "legacy_credential_identity_key", "source_record_id",
                  "source_revision", "migration_complete", "state"}


class ImportRejected(ValueError):
    pass


def require(condition, code):
    if not condition:
        raise ImportRejected(code)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def text(value, code):
    require(isinstance(value, str) and 0 < len(value) <= 4096 and "\x00" not in value, code)
    return value


def canonical_uuid(value, code):
    try:
        parsed = str(uuid.UUID(value))
    except (TypeError, ValueError, AttributeError):
        raise ImportRejected(code) from None
    require(value == parsed and parsed != "00000000-0000-0000-0000-000000000000", code)
    return parsed


def timestamp(value, code):
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError, AttributeError):
        raise ImportRejected(code) from None
    require(parsed.tzinfo is not None, code)
    return parsed.astimezone(UTC)


def sorted_rows(rows):
    return sorted(rows, key=canonical)


def reward_fingerprint(row):
    # Matches the source operation's JSON.stringify([immutable fields]) hash.
    return digest([row.get(field) for field in
                   ("id", "user_id", "attempt_id", "custom_data", "ad_unit_id", "issued_at")])


def transfer_targets(document, source_rows, by_legacy):
    if not source_rows and document is None:
        return {}
    require(isinstance(document, dict) and type(document.get("version")) is int
            and document["version"] == 1 and isinstance(document.get("targets"), list), "TRANSFER_TARGETS_REQUIRED")
    source = {row["id"]: row for row in source_rows}
    result = {}
    for target in document["targets"]:
        require(isinstance(target, dict) and set(target) == {"source_record_id", "legacy_user_id", "native_user_id", "transfer_id", "fingerprint"}
                and target.get("source_record_id") in source, "TRANSFER_TARGET_INVALID")
        row = source[target["source_record_id"]]
        require(target["source_record_id"] not in result, "TRANSFER_TARGET_DUPLICATE")
        require(target["legacy_user_id"] == row["user_id"] and target["native_user_id"] == by_legacy[row["user_id"]]["user_id"],
                "TRANSFER_TARGET_OWNER_MISMATCH")
        canonical_uuid(target["transfer_id"], "TRANSFER_ID_INVALID")
        require(target["fingerprint"] == reward_fingerprint(row), "TRANSFER_TARGET_FINGERPRINT_MISMATCH")
        result[row["id"]] = target
    require(set(result) == set(source), "TRANSFER_TARGETS_INCOMPLETE")
    return result


def transfer_receipts(receipt, source_rows, by_legacy, targets, as_of):
    """Check a separately captured source-write receipt against the exact export.

    This validates local provenance, not a live Base44 write. The operator must
    obtain the receipt from the authorized transfer operation; fabrication would
    defeat the source fence. Missing receipt yields a non-executable draft.
    """
    if receipt is None:
        return {}
    require(isinstance(receipt, dict) and type(receipt.get("version")) is int
            and receipt["version"] == 1 and isinstance(receipt.get("records"), list), "TRANSFER_RECEIPT_INVALID")
    source = {row["id"]: row for row in source_rows}
    result = {}
    for record in receipt["records"]:
        require(isinstance(record, dict) and record.get("id") in source, "TRANSFER_RECEIPT_UNKNOWN_ROW")
        original = source[record["id"]]
        require(record["id"] not in result, "TRANSFER_RECEIPT_DUPLICATE_ROW")
        require(record.get("state") == "transferred" and record.get("transfer_state") == original["state"],
                "TRANSFER_RECEIPT_STATE_MISMATCH")
        require(record.get("transfer_user_id") == by_legacy[original["user_id"]]["user_id"],
                "TRANSFER_RECEIPT_OWNER_MISMATCH")
        canonical_uuid(record.get("transfer_id"), "TRANSFER_ID_INVALID")
        require(record["transfer_id"] == targets[record["id"]]["transfer_id"], "TRANSFER_RECEIPT_ID_MISMATCH")
        require(reward_fingerprint(record) == targets[record["id"]]["fingerprint"], "TRANSFER_RECEIPT_FINGERPRINT_MISMATCH")
        for field, value in original.items():
            if field != "state":
                require(record.get(field) == value, "TRANSFER_RECEIPT_SOURCE_CHANGED")
        transferred = timestamp(record.get("transferred_at"), "TRANSFER_TIME_INVALID")
        require(timestamp(original.get("issued_at"), "REWARD_ISSUED_TIME_INVALID") <= transferred <= as_of,
                "TRANSFER_TIME_INVALID")
        result[record["id"]] = record
    require(set(result) == set(source), "TRANSFER_RECEIPT_INCOMPLETE")
    return result


def compile_plan(candidate, rights, billing, *, as_of, reward_transfer_receipt=None, reward_transfer_targets=None):
    require(as_of.tzinfo is not None, "AS_OF_REQUIRES_TIMEZONE")
    as_of = as_of.astimezone(UTC)
    require(isinstance(candidate, dict) and candidate.get("issues") == [], "CANDIDATE_HAS_ISSUES")
    require(candidate.get("bound_count") == 2 and candidate.get("matched_count") == 2
            and isinstance(candidate.get("accounts"), list) and len(candidate["accounts"]) == 2,
            "EXACT_TWO_ACCOUNT_PILOT_REQUIRED")
    accounts = candidate["accounts"]
    for account in accounts:
        require(isinstance(account, dict) and set(account) == ACCOUNT_FIELDS, "ACCOUNT_SHAPE")
        require(re.fullmatch(r"[0-9a-f]{64}", account.get("identity_key", "")) is not None, "IDENTITY_KEY_INVALID")
        require(re.fullmatch(r"apple-email:[0-9a-f]{64}", account.get("legacy_credential_identity_key", "")) is not None,
                "LEGACY_CREDENTIAL_IDENTITY_INVALID")
        require(re.fullmatch(r"apple-subject:[0-9a-f]{64}", account.get("subject_key", "")) is not None,
                "SUBJECT_KEY_INVALID")
        canonical_uuid(account["user_id"], "USER_UUID_INVALID")
        canonical_uuid(account["source_revision"], "SOURCE_REVISION_INVALID")
        for field in ["legacy_user_id", "source_record_id", "shadow_email"]:
            text(account[field], "ACCOUNT_FIELD_INVALID")
        require(re.fullmatch(r"[a-z0-9._+-]+@accounts\.spyclash\.invalid", account["shadow_email"]) is not None,
                "SHADOW_EMAIL_INVALID")
        require(account["client_id"] == "com.spyclash.ios", "CLIENT_ID_INVALID")
        require(account["migration_complete"] is False and account["state"] == "pending",
                "CANDIDATE_MUST_BE_UNPROMOTED")
    for field in ["identity_key", "subject_key", "user_id", "legacy_user_id", "shadow_email",
                  "source_record_id", "legacy_credential_identity_key"]:
        require(len({a[field] for a in accounts}) == 2, "DUPLICATE_ACCOUNT_" + field.upper())
    by_legacy = {a["legacy_user_id"]: a for a in accounts}
    by_user = {a["user_id"]: a for a in accounts}

    require(isinstance(rights, dict) and set(rights) == set(TABLES), "RIGHTS_EXPORT_INCOMPLETE")
    grouped = {legacy: {table: [] for table in TABLES} for legacy in by_legacy}
    for table in TABLES:
        require(isinstance(rights[table], list), "RIGHTS_TABLE_INVALID")
        ids = set()
        for row in rights[table]:
            require(isinstance(row, dict), "RIGHTS_ROW_INVALID")
            source_id = text(row.get("id"), "RIGHTS_SOURCE_ID_MISSING")
            require(source_id not in ids, "DUPLICATE_RIGHTS_SOURCE_ID")
            ids.add(source_id)
            require(row.get("user_id") in by_legacy, "UNMATCHED_SOURCE_OWNER")
            grouped[row["user_id"]][table].append(row)
    targets = transfer_targets(reward_transfer_targets, rights["GenerationReward"], by_legacy)
    receipts = transfer_receipts(reward_transfer_receipt, rights["GenerationReward"], by_legacy, targets, as_of)

    require(isinstance(billing, list), "BILLING_EXPORT_INVALID")
    existing_by_user = {}
    token_owners = {}
    for row in billing:
        require(isinstance(row, dict), "BILLING_ROW_INVALID")
        owner = canonical_uuid(row.get("user_id"), "BILLING_OWNER_INVALID")
        token = canonical_uuid(row.get("app_account_token"), "BILLING_TOKEN_INVALID")
        require(owner not in existing_by_user and token not in token_owners, "DUPLICATE_EXISTING_BILLING")
        require(row.get("state") in ("active", "deleted"), "BILLING_STATE_INVALID")
        existing_by_user[owner] = {"user_id": owner, "app_account_token": token, "state": row["state"]}
        token_owners[token] = owner

    manifest_accounts = []
    counts = {"accounts": 2, "billing_aliases": 0, "existing_primaries_retained": 0,
              "new_primaries": 0, "archived_entitlements": 0, "archived_quota_rows": 0,
              "pending_rewards_preserved": 0, "earned_rewards_preserved": 0, "spent_rewards_preserved": 0,
              "reward_transfers_planned": 0, "reward_transfers_receipted": 0, "source_fences_required": 0,
              "active_rights_imported": 0}
    source_tokens = set()
    reward_custom_data = set()
    reward_attempts = set()
    reward_transactions = set()
    reward_consumptions = set()
    for account in sorted(accounts, key=lambda a: a["user_id"]):
        owner = account["user_id"]
        rows = grouped[account["legacy_user_id"]]
        require(not rows["MembershipGrant"], "UNSUPPORTED_MEMBERSHIP_GRANTS")
        require(not rows["GenerationRewardEnrollment"], "UNSUPPORTED_REWARD_ENROLLMENT")
        aliases = []
        dated_tokens = []
        existing = existing_by_user.get(owner)
        require(existing is None or existing["state"] == "active", "EXISTING_PRIMARY_NOT_ACTIVE")
        for row in rows["AppStoreAccount"]:
            token = canonical_uuid(row.get("app_account_token"), "SOURCE_BILLING_TOKEN_INVALID")
            require(row.get("reservation_state") == "active", "SOURCE_BILLING_NOT_ACTIVE")
            require(token not in source_tokens, "DUPLICATE_SOURCE_BILLING_TOKEN")
            require(token not in token_owners or token_owners[token] == owner, "BILLING_TOKEN_OTHER_OWNER")
            source_tokens.add(token)
            token_owners[token] = owner
            created = timestamp(row.get("created_at"), "SOURCE_BILLING_TIME_INVALID")
            used = timestamp(row.get("last_used_at") or row.get("created_at"), "SOURCE_BILLING_TIME_INVALID")
            require(created <= used <= as_of, "SOURCE_BILLING_TIME_INVALID")
            aliases.append({"app_account_token": token, "source_record_id": row["id"]})
            dated_tokens.append((used, created, row["id"], token))
        # Existing primary ownership takes precedence over any source recency.
        primary = existing["app_account_token"] if existing else (max(dated_tokens)[3] if dated_tokens else None)
        if existing:
            counts["existing_primaries_retained"] += 1
        elif primary:
            counts["new_primaries"] += 1
        counts["billing_aliases"] += len(aliases)
        owned_tokens = {a["app_account_token"] for a in aliases} | ({primary} if primary else set())

        for row in rows["Entitlement"]:
            provider, status = row.get("provider"), row.get("status")
            require(provider in ("apple", "stripe"), "UNSUPPORTED_ENTITLEMENT_PROVIDER")
            require(status in ("expired", "revoked", "canceled", "cancelled", "inactive"),
                    "ACTIVE_ENTITLEMENT_REQUIRES_CANONICAL_VERIFICATION")
            expires = row.get("expires_at")
            require(expires is not None, "ENTITLEMENT_EXPIRY_UNKNOWN")
            require(timestamp(expires, "ENTITLEMENT_EXPIRY_INVALID") <= as_of,
                    "ACTIVE_ENTITLEMENT_REQUIRES_CANONICAL_VERIFICATION")
            if provider == "apple":
                token = canonical_uuid(row.get("app_account_token"), "ENTITLEMENT_TOKEN_INVALID")
                require(token in owned_tokens, "ENTITLEMENT_TOKEN_OWNER_UNPROVEN")
            counts["archived_entitlements"] += 1

        for row in rows["AiGenerationUsage"]:
            try:
                day = dt.date.fromisoformat(row.get("usage_date"))
            except (TypeError, ValueError):
                raise ImportRejected("QUOTA_DATE_INVALID") from None
            used = row.get("generations_used")
            require(type(used) is int and used >= 0, "QUOTA_COUNT_INVALID")
            require(row.get("quota_key") == account["legacy_user_id"] + ":" + day.isoformat(),
                    "QUOTA_OWNER_KEY_MISMATCH")
            require(day <= as_of.date(), "FUTURE_QUOTA_UNSUPPORTED")
            require(day != as_of.date() or used == 0, "CURRENT_QUOTA_REQUIRES_LEDGER_IMPORT")
            counts["archived_quota_rows"] += 1

        rewards = []
        for row in rows["GenerationReward"]:
            state = row.get("state")
            require(state in ("spent", "pending", "earned"), "UNSUPPORTED_RESERVED_REWARD_CREDIT")
            issued = timestamp(row.get("issued_at"), "REWARD_ISSUED_TIME_INVALID")
            require(issued <= as_of, "REWARD_ISSUED_TIME_INVALID")
            attempt = canonical_uuid(row.get("attempt_id"), "REWARD_ATTEMPT_INVALID")
            custom_data = text(row.get("custom_data"), "REWARD_CUSTOM_DATA_INVALID")
            require(re.fullmatch(re.escape(attempt) + r"\.legacy\.[0-9a-f]{64}", custom_data) is not None,
                    "REWARD_CUSTOM_DATA_INVALID")
            require(isinstance(row.get("ad_unit_id"), str)
                    and re.fullmatch(r"ca-app-pub-\d{16}/\d{10}", row["ad_unit_id"]) is not None
                    and not row["ad_unit_id"].startswith("ca-app-pub-3940256099942544/"), "REWARD_AD_UNIT_UNSUPPORTED")
            require(custom_data not in reward_custom_data and (owner, attempt) not in reward_attempts,
                    "DUPLICATE_REWARD_IDENTITY")
            reward_custom_data.add(custom_data)
            reward_attempts.add((owner, attempt))
            transaction, earned, consumed = row.get("transaction_id"), row.get("earned_at"), row.get("generation_request_id")
            if state == "pending":
                require(transaction is None and earned is None and consumed is None, "PENDING_REWARD_HAS_CREDIT_STATE")
            else:
                text(transaction, "EARNED_REWARD_TRANSACTION_MISSING")
                require(transaction not in reward_transactions, "DUPLICATE_REWARD_TRANSACTION")
                reward_transactions.add(transaction)
                require(issued - dt.timedelta(minutes=1) <= timestamp(earned, "EARNED_REWARD_TIME_INVALID") <= as_of,
                        "EARNED_REWARD_TIME_INVALID")
                if state == "spent":
                    canonical_uuid(consumed, "SPENT_REWARD_CONSUMPTION_MISSING")
                    require((owner, consumed) not in reward_consumptions, "DUPLICATE_REWARD_CONSUMPTION")
                    reward_consumptions.add((owner, consumed))
                else:
                    require(consumed is None, "EARNED_REWARD_ALREADY_RESERVED")
                    counts["active_rights_imported"] += 1
            receipt = receipts.get(row["id"])
            counts["reward_transfers_planned"] += 1
            counts["reward_transfers_receipted" if receipt else "source_fences_required"] += 1
            counts[state + "_rewards_preserved"] += 1
            rewards.append({"source_record_id": row["id"], "legacy_user_id": row["user_id"],
                "source_state": state, "transfer_id": targets[row["id"]]["transfer_id"],
                "user_id": owner, "attempt_id": attempt, "custom_data": custom_data, "ad_unit_id": row["ad_unit_id"],
                "state": "pending" if state == "pending" else "earned", "transaction_id": transaction,
                "reward_at": earned, "consumed_request_id": consumed,
                "created_at": issued.isoformat(), "expires_at": (issued + dt.timedelta(days=1)).isoformat()})

        snapshot = {"format": "apple-pilot-source-v1", "account": account,
                    "source_rights": {t: sorted_rows(rows[t]) for t in TABLES},
                    "reviewed_existing_primary": existing,
                    "reward_transfer_targets": sorted_rows([targets[r["id"]] for r in rows["GenerationReward"]]),
                    "reward_transfer_receipts": sorted_rows([receipts[r["id"]] for r in rows["GenerationReward"] if r["id"] in receipts])}
        manifest_accounts.append({"account": account, "snapshot": snapshot, "snapshot_canonical": canonical(snapshot), "source_sha256": digest(snapshot),
                                  "aliases": sorted_rows(aliases), "primary_token": primary,
                                  "existing_primary": existing, "rewards": sorted_rows(rewards)})
    manifest = {"format": "apple-pilot-import-v1", "accounts": manifest_accounts}
    report = {"format": manifest["format"], "counts": counts, "source_manifest_sha256": digest(manifest),
              "source_sha256": [a["source_sha256"] for a in manifest_accounts],
              "evaluated_at": as_of.isoformat(), "plan_expires_at": (as_of + dt.timedelta(hours=6)).isoformat(),
              "production_executed": False, "requires_fresh_source_export_before_execution": True,
              "ready_for_import": counts["source_fences_required"] == 0,
              "new_signup_coverage": False}
    return manifest, report


SQL_BODY = r"""begin;
set transaction isolation level serializable;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
-- This artifact does not execute itself. Review and authorize separately.
-- Source rights are an offline snapshot: refresh exports before execution.
-- Global new-signup coverage is deliberately not enabled by this pilot.
lock table app_private.profiles, app_private.legacy_links,
  app_private.legacy_session_accounts, app_private.main_account_deletions,
  app_private.apple_accounts, app_private.native_accounts,
  apple_private.accounts, apple_private.billing_token_aliases,
  apple_private.migration_snapshots, apple_private.deletions,
  apple_private.reward_attempt_aliases, game_center_private.generation_reward_attempts
  in share row exclusive mode;
lock table auth.users in share mode;
do $apple_import$
declare
  plan jsonb := convert_from(decode('__PAYLOAD_HEX__','hex'),'UTF8')::jsonb;
  item jsonb; a jsonb; alias jsonb; reward jsonb; old_apple apple_private.accounts%rowtype;
  saved_snapshot apple_private.migration_snapshots%rowtype;
  saved_primary app_private.apple_accounts%rowtype;
  legacy app_private.legacy_session_accounts%rowtype;
  owner uuid; seen integer := 0; prior_snapshot boolean;
begin
  if not (plan->>'ready_for_import')::boolean
    then raise exception 'source reward transfer receipt required; draft cannot execute'; end if;
  if clock_timestamp() < (plan->>'evaluated_at')::timestamptz - interval '5 minutes'
    or clock_timestamp() > (plan->>'plan_expires_at')::timestamptz
    or (clock_timestamp() at time zone 'UTC')::date <> ((plan->>'evaluated_at')::timestamptz at time zone 'UTC')::date
  then raise exception 'apple import review is stale'; end if;
  if jsonb_array_length(plan->'accounts') <> 2 then raise exception 'exact pilot required'; end if;
  for item in select value from jsonb_array_elements(plan->'accounts') loop
    a := item->'account'; owner := (a->>'user_id')::uuid; seen := seen + 1;
    if encode(sha256(convert_to(item->>'snapshot_canonical','UTF8')),'hex')<>item->>'source_sha256'
      or (item->>'snapshot_canonical')::jsonb<>item->'snapshot'
      then raise exception 'source snapshot digest mismatch'; end if;
    if not exists(select 1 from app_private.profiles where user_id=owner and state='active')
      then raise exception 'active profile required'; end if;
    if not exists(select 1 from auth.users where id=owner and email=a->>'shadow_email'
      and deleted_at is null and (banned_until is null or banned_until<=clock_timestamp()))
      then raise exception 'exact active Auth owner required'; end if;
    select * into legacy from app_private.legacy_session_accounts where user_id=owner;
    if not found or legacy.legacy_user_id<>a->>'legacy_user_id' or legacy.shadow_email<>a->>'shadow_email'
      or legacy.state<>'ready' or not legacy.import_completed
      or (legacy.lease_until is not null and legacy.lease_until>clock_timestamp())
      then raise exception 'reviewed legacy owner/import required'; end if;
    if not exists(select 1 from app_private.legacy_links where user_id=owner
      and legacy_user_id=a->>'legacy_user_id' and state='active' and source_origin=legacy.source_origin)
      then raise exception 'exact active legacy link required'; end if;
    if exists(select 1 from app_private.main_account_deletions
      where user_id=owner or legacy_user_id=a->>'legacy_user_id')
      or exists(select 1 from apple_private.deletions where user_id=owner)
      then raise exception 'account deletion fence present'; end if;
    if exists(select 1 from app_private.native_accounts where
      (user_id=owner or (provider='apple' and identity_key=a->>'identity_key'))
      and (user_id<>owner or provider<>'apple' or identity_key<>a->>'identity_key'
        or legacy_user_id is distinct from a->>'legacy_user_id' or state not in ('pending','ready')))
      then raise exception 'native identity conflict'; end if;
    if exists(select 1 from apple_private.accounts where
      (identity_key=a->>'identity_key' or subject_key=a->>'subject_key' or user_id=owner
        or shadow_email=a->>'shadow_email' or legacy_user_id=a->>'legacy_user_id')
      and (identity_key<>a->>'identity_key' or subject_key<>a->>'subject_key' or user_id<>owner
        or client_id<>a->>'client_id' or shadow_email<>a->>'shadow_email'
        or legacy_user_id is distinct from a->>'legacy_user_id'))
      then raise exception 'Apple subject ownership conflict'; end if;
    select * into old_apple from apple_private.accounts where user_id=owner;
    if found and (old_apple.state not in ('pending','ready') or old_apple.migration_version not in (0,1)
      or old_apple.lease_id is not null)
      then raise exception 'Apple account state/lease changed'; end if;
    select * into saved_snapshot from apple_private.migration_snapshots where user_id=owner;
    prior_snapshot := found;
    if prior_snapshot and (saved_snapshot.source_sha256<>item->>'source_sha256'
      or saved_snapshot.data<>item->'snapshot') then raise exception 'source snapshot changed'; end if;
    if old_apple.state='ready' and (not prior_snapshot or not old_apple.migration_complete
      or old_apple.migration_version<>1) then raise exception 'unreviewed ready account'; end if;

    select * into saved_primary from app_private.apple_accounts where user_id=owner;
    if item->'existing_primary'<>'null'::jsonb then
      if not found or saved_primary.state<>'active'
        or saved_primary.app_account_token<>(item->'existing_primary'->>'app_account_token')::uuid
        then raise exception 'reviewed primary billing token changed'; end if;
    elsif found and (not prior_snapshot or saved_primary.state<>'active'
      or saved_primary.app_account_token::text is distinct from item->>'primary_token')
      then raise exception 'unreviewed primary billing token'; end if;
    if item->>'primary_token' is not null and exists(select 1 from app_private.apple_accounts
      where app_account_token=(item->>'primary_token')::uuid and user_id<>owner)
      then raise exception 'primary billing owner conflict'; end if;
    if item->>'primary_token' is not null and exists(select 1 from apple_private.billing_token_aliases
      where app_account_token=(item->>'primary_token')::uuid and user_id<>owner)
      then raise exception 'primary billing alias owner conflict'; end if;
    if exists(select 1 from apple_private.billing_token_aliases saved where saved.user_id=owner
      and not exists(select 1 from jsonb_array_elements(item->'aliases') expected
        where saved.app_account_token=(expected->>'app_account_token')::uuid
          and saved.source_record_id=expected->>'source_record_id' and saved.state='active'))
      then raise exception 'unreviewed billing aliases'; end if;
    for alias in select value from jsonb_array_elements(item->'aliases') loop
      if exists(select 1 from app_private.apple_accounts where
        app_account_token=(alias->>'app_account_token')::uuid and user_id<>owner)
        or exists(select 1 from apple_private.billing_token_aliases where
          (app_account_token=(alias->>'app_account_token')::uuid or source_record_id=alias->>'source_record_id')
          and (user_id<>owner or state<>'active' or app_account_token<>(alias->>'app_account_token')::uuid
            or source_record_id<>alias->>'source_record_id'))
        then raise exception 'historical billing token owner conflict'; end if;
    end loop;
    if exists(select 1 from apple_private.reward_attempt_aliases saved where saved.user_id=owner
      and not exists(select 1 from jsonb_array_elements(item->'rewards') expected
        where saved.custom_data=expected->>'custom_data' and saved.source_record_id=expected->>'source_record_id'))
      then raise exception 'unreviewed reward aliases'; end if;
    for reward in select value from jsonb_array_elements(item->'rewards') loop
      if exists(select 1 from apple_private.reward_attempt_aliases saved where
        (saved.custom_data=reward->>'custom_data' or saved.source_record_id=reward->>'source_record_id'
          or (saved.user_id=owner and saved.attempt_id=(reward->>'attempt_id')::uuid))
        and (not prior_snapshot or saved.user_id<>owner or saved.custom_data<>reward->>'custom_data'
          or saved.source_record_id<>reward->>'source_record_id' or saved.legacy_user_id<>reward->>'legacy_user_id'
          or saved.attempt_id<>(reward->>'attempt_id')::uuid or saved.transfer_id<>(reward->>'transfer_id')::uuid
          or saved.source_state<>reward->>'source_state'))
        then raise exception 'reward alias ownership/provenance conflict'; end if;
      if exists(select 1 from game_center_private.generation_reward_attempts saved where
        (saved.custom_data=reward->>'custom_data' or saved.transaction_id=reward->>'transaction_id'
          or (saved.user_id=owner and (saved.attempt_id=(reward->>'attempt_id')::uuid
            or saved.consumed_request_id=(reward->>'consumed_request_id')::uuid)))
        and (not prior_snapshot or saved.user_id<>owner or saved.attempt_id<>(reward->>'attempt_id')::uuid
          or saved.custom_data<>reward->>'custom_data' or saved.ad_unit_id<>reward->>'ad_unit_id'
          or saved.state<>reward->>'state' or saved.transaction_id is distinct from reward->>'transaction_id'
          or saved.reward_at is distinct from (reward->>'reward_at')::timestamptz
          or saved.consumed_request_id is distinct from (reward->>'consumed_request_id')::uuid
          or saved.created_at<>(reward->>'created_at')::timestamptz
          or saved.expires_at<>(reward->>'expires_at')::timestamptz))
        then raise exception 'reward ledger ownership/state changed'; end if;
    end loop;

    insert into apple_private.accounts(identity_key,subject_key,client_id,user_id,shadow_email,legacy_user_id)
      values(a->>'identity_key',a->>'subject_key',a->>'client_id',owner,a->>'shadow_email',a->>'legacy_user_id')
      on conflict(identity_key) do nothing;
    insert into apple_private.migration_snapshots(user_id,source_sha256,data)
      values(owner,item->>'source_sha256',item->'snapshot') on conflict(user_id) do nothing;
    for alias in select value from jsonb_array_elements(item->'aliases') loop
      insert into apple_private.billing_token_aliases(app_account_token,user_id,source_record_id)
        values((alias->>'app_account_token')::uuid,owner,alias->>'source_record_id')
        on conflict(app_account_token) do nothing;
    end loop;
    if item->>'primary_token' is not null then
      insert into app_private.apple_accounts(user_id,app_account_token)
        values(owner,(item->>'primary_token')::uuid) on conflict(user_id) do nothing;
    end if;
    for reward in select value from jsonb_array_elements(item->'rewards') loop
      insert into game_center_private.generation_reward_attempts
        (user_id,attempt_id,custom_data,ad_unit_id,state,transaction_id,reward_at,consumed_request_id,created_at,expires_at)
        values(owner,(reward->>'attempt_id')::uuid,reward->>'custom_data',reward->>'ad_unit_id',reward->>'state',
          reward->>'transaction_id',(reward->>'reward_at')::timestamptz,(reward->>'consumed_request_id')::uuid,
          (reward->>'created_at')::timestamptz,(reward->>'expires_at')::timestamptz)
        on conflict(user_id,attempt_id) do nothing;
      insert into apple_private.reward_attempt_aliases
        (custom_data,source_record_id,legacy_user_id,user_id,attempt_id,transfer_id,source_state)
        values(reward->>'custom_data',reward->>'source_record_id',reward->>'legacy_user_id',owner,
          (reward->>'attempt_id')::uuid,(reward->>'transfer_id')::uuid,reward->>'source_state')
        on conflict(custom_data) do nothing;
    end loop;
  end loop;
  -- No identity becomes ready until both accounts and every historical alias
  -- have passed all checks. Any exception rolls back this entire transaction.
  if seen<>2 then raise exception 'pilot count changed'; end if;
  for item in select value from jsonb_array_elements(plan->'accounts') loop
    a := item->'account'; owner := (a->>'user_id')::uuid;
    update apple_private.accounts set state='ready', migration_complete=true, migration_version=1,
      updated_at=case when state='ready' then updated_at else clock_timestamp() end
      where user_id=owner and identity_key=a->>'identity_key' and state in ('pending','ready');
    if not found then raise exception 'ready transition ownership changed'; end if;
    if not exists(select 1 from app_private.native_accounts where user_id=owner and provider='apple'
      and identity_key=a->>'identity_key' and legacy_user_id=a->>'legacy_user_id'
      and state='ready' and migration_complete and migration_version=1)
      then raise exception 'native identity registry mismatch'; end if;
  end loop;
end $apple_import$;
commit;
"""


def render_sql(manifest, report):
    payload = {**manifest, "ready_for_import": report["ready_for_import"],
               "evaluated_at": report["evaluated_at"], "plan_expires_at": report["plan_expires_at"]}
    # Source strings cannot become SQL tokens, including quotes, backslashes,
    # dollar delimiters or Unicode. Only generated hexadecimal enters SQL.
    encoded = canonical(payload).encode().hex()
    return "-- Source manifest SHA-256: " + report["source_manifest_sha256"] + "\n" + SQL_BODY.replace("__PAYLOAD_HEX__", encoded)


def read_json(path):
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "DUPLICATE_JSON_KEY")
            result[key] = value
        return result
    with path.open(encoding="utf-8") as source:
        return json.load(source, object_pairs_hook=unique_object,
                         parse_constant=lambda _: (_ for _ in ()).throw(ImportRejected("NONFINITE_JSON")))


def write_private(path, content):
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as target:
        os.fchmod(target.fileno(), 0o600)
        target.write(content)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path(".local/apple-migration"))
    parser.add_argument("--as-of", help="Timezone-aware assessment timestamp; defaults to now (UTC).")
    parser.add_argument("--reward-transfer-receipt", type=Path, help="Receipt from the separately authorized source reward transfer.")
    parser.add_argument("--reward-transfer-targets", type=Path, help="Reviewed fixed transfer IDs/fingerprints; defaults to reward-transfer-targets.json in the input directory.")
    parser.add_argument("--dry-run", action="store_true", help="Validate and print counts only; do not write artifacts.")
    args = parser.parse_args(argv)
    try:
        targets_path = args.reward_transfer_targets or args.directory / "reward-transfer-targets.json"
        manifest, report = compile_plan(read_json(args.directory / "apple-import-candidate.json"),
            read_json(args.directory / "base44-apple-rights.json"),
            read_json(args.directory / "supabase-billing-accounts.json"),
            as_of=timestamp(args.as_of, "AS_OF_INVALID") if args.as_of else dt.datetime.now(UTC),
            reward_transfer_receipt=read_json(args.reward_transfer_receipt) if args.reward_transfer_receipt else None,
            reward_transfer_targets=read_json(targets_path) if targets_path.exists() else None)
        if not args.dry_run:
            write_private(args.directory / "apple-import-plan.sql", render_sql(manifest, report))
            write_private(args.directory / "apple-import-report.json", json.dumps(report, indent=2) + "\n")
        print(json.dumps({"result": "validated_offline" if report["ready_for_import"] else "provisional_source_fence_required",
                          "counts": report["counts"], "ready_for_import": report["ready_for_import"],
                          "production_executed": False}, sort_keys=True))
        return 0
    except (ImportRejected, OSError, json.JSONDecodeError) as error:
        # Codes contain no account IDs, provider tokens, or source-row content.
        code = str(error) if isinstance(error, ImportRejected) else type(error).__name__
        rejected = {"result": "rejected", "reason": code, "ready_for_import": False, "production_executed": False}
        if not args.dry_run:
            # A failed refresh must not leave a previously executable plan at
            # the well-known output path. Dry runs intentionally write nothing.
            try:
                write_private(args.directory / "apple-import-plan.sql",
                    "begin;\ndo $$ begin raise exception 'Apple import validation failed; regenerate the reviewed plan'; end $$;\nrollback;\n")
                write_private(args.directory / "apple-import-report.json", json.dumps(rejected, indent=2) + "\n")
            except OSError:
                pass
        print(json.dumps(rejected), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
