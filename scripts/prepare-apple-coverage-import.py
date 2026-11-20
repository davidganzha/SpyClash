#!/usr/bin/env python3
"""Prepare the exact historical coverage cohort; never connects to production.

A plan stays non-executable until the fixed server verifier's actual receipt is
supplied. Existing Auth UUIDs, profiles, purchases and rewards are not rewritten.
"""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import uuid

COUNT = 22
TABLES = {"AppStoreAccount", "MembershipGrant", "Entitlement", "AiGenerationUsage",
          "GenerationReward", "GenerationRewardEnrollment"}


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def require(condition, code):
    if not condition:
        raise ValueError(code)


def compile_plan(document, receipt=None):
    now = dt.datetime.now(dt.timezone.utc)
    targets, owners, users = document["targets"], document["owners"], document["source_users"]
    require(len(targets) == COUNT and len(owners) == COUNT, "EXACT_REVIEWED_COHORT_REQUIRED")
    for key in ["source_record_id", "source_revision", "identity_key", "subject_key", "legacy_user_id", "user_id"]:
        require(len({t[key] for t in targets}) == COUNT, "AMBIGUOUS_TARGETS")
    require(set(document["rights"]) == TABLES and all(not x for x in document["rights"].values()), "NONEMPTY_RIGHTS_REQUIRE_FULL_RIGHTS_IMPORT")
    by_owner = {o["user_id"]: o for o in owners}
    by_source = {u["id"]: u for u in users}
    verified = {}
    if receipt is not None:
        require(receipt.get("version") == 1 and receipt.get("verified_count") == COUNT and len(receipt.get("records", [])) == COUNT, "INCOMPLETE_VERIFICATION_RECEIPT")
        captured = dt.datetime.fromisoformat(str(receipt.get("captured_at", "")).replace("Z", "+00:00"))
        require(captured.tzinfo is not None and now-dt.timedelta(minutes=15) <= captured <= now+dt.timedelta(minutes=1), "STALE_VERIFICATION_RECEIPT")
        for row in receipt["records"]:
            require(row.get("source_record_id") not in verified, "DUPLICATE_VERIFICATION")
            verified[row["source_record_id"]] = row
    accounts = []
    for target in targets:
        owner, user = by_owner[target["user_id"]], by_source[target["legacy_user_id"]]
        require(str(uuid.UUID(target["user_id"])) == target["user_id"], "INVALID_OWNER_UUID")
        require(re.fullmatch(r"apple-subject:[0-9a-f]{64}", target["subject_key"]) is not None, "INVALID_SUBJECT")
        require(re.fullmatch(r"apple-email:[0-9a-f]{64}", target["identity_key"]) is not None, "INVALID_SOURCE_IDENTITY")
        require(owner["legacy_user_id"] == user["id"] and owner["auth_exists"] and owner["auth_mail_matches"] and not owner["auth_deleted"] and not owner["auth_banned"] and not owner["deletion_fenced"] and owner["profile_state"] == "active" and owner["reservation_imported"] and not owner["native_provider"], "EXISTING_OWNER_NOT_READY")
        require(owner["reservation_state"] in ["reserved", "ready"] and owner["link_state"] in [None, "active"], "LEGACY_STATE_UNSUPPORTED")
        proof = verified.get(target["source_record_id"])
        if receipt is not None:
            require(proof is not None and all(proof.get(k) == v for k, v in target.items()) and proof.get("encrypted_binding_verified") is True and proof.get("source_user_verified") is True and proof.get("source_state") == "pending" and proof.get("client_id") == "com.spyclash.ios", "VERIFICATION_PROVENANCE_MISMATCH")
        identity = hashlib.sha256(("https://appleid.apple.com\n" + target["subject_key"]).encode()).hexdigest()
        snapshot = {"format": "apple-historical-coverage-v1", "target": target,
                    "source_user": user, "source_rights": document["rights"], "verification": proof}
        accounts.append({**target, "native_identity_key": identity, "shadow_email": owner["shadow_email"],
                         "snapshot": snapshot, "snapshot_canonical": canonical(snapshot), "source_sha256": digest(snapshot)})
    return {"format": "apple-historical-coverage-import-v1", "evaluated_at": now.isoformat(),
            "expires_at": (now + dt.timedelta(hours=6)).isoformat(), "ready_for_import": receipt is not None,
            "verification_sha256": digest(receipt) if receipt is not None else None, "accounts": accounts}


SQL = r"""begin;
set transaction isolation level serializable;
set local lock_timeout='5s';
set local statement_timeout='30s';
lock table app_private.legacy_session_accounts,app_private.legacy_links,
 app_private.profiles,app_private.main_account_deletions,app_private.native_accounts,
 apple_private.accounts,apple_private.deletions,apple_private.migration_snapshots
 in share row exclusive mode;
lock table auth.users in share mode;
do $coverage_import$
declare
 plan jsonb:=convert_from(decode('__PLAN_HEX__','hex'),'UTF8')::jsonb;
 item jsonb; owner uuid; source_id text; reservation app_private.legacy_session_accounts%rowtype;
 snapshot apple_private.migration_snapshots%rowtype; profiles_before jsonb; profiles_after jsonb;
begin
 if not (plan->>'ready_for_import')::boolean or plan->>'verification_sha256' is null
 then raise exception 'actual fixed-cohort source verification receipt required'; end if;
 if jsonb_array_length(plan->'accounts')<>22 or clock_timestamp()>(plan->>'expires_at')::timestamptz
 then raise exception 'coverage plan changed or expired'; end if;
 select jsonb_object_agg(user_id::text,encode(sha256(convert_to(data::text,'UTF8')),'hex'))
 into profiles_before from app_private.profiles where user_id in
 (select (x->>'user_id')::uuid from jsonb_array_elements(plan->'accounts') x);
 for item in select value from jsonb_array_elements(plan->'accounts') loop
  owner:=(item->>'user_id')::uuid; source_id:=item->>'legacy_user_id';
  if encode(sha256(convert_to(item->>'snapshot_canonical','UTF8')),'hex')<>item->>'source_sha256'
   or (item->>'snapshot_canonical')::jsonb<>item->'snapshot'
   then raise exception 'snapshot digest mismatch'; end if;
  select * into reservation from app_private.legacy_session_accounts where user_id=owner;
  if not found or reservation.legacy_user_id<>source_id or reservation.shadow_email<>item->>'shadow_email'
   or reservation.source_origin<>'https://spyclash.com' or reservation.source_app_id<>'69a0e57fa939f578082f8091'
   or reservation.identity_key<>encode(sha256(convert_to(reservation.source_origin||E'\n'||reservation.source_app_id||E'\n'||source_id,'UTF8')),'hex')
   or not reservation.import_completed or reservation.state not in ('reserved','ready')
   or (reservation.lease_until is not null and reservation.lease_until>clock_timestamp())
   then raise exception 'canonical reservation changed'; end if;
  if not exists(select 1 from auth.users where id=owner and email=item->>'shadow_email'
   and role='authenticated' and deleted_at is null and (banned_until is null or banned_until<=clock_timestamp()))
   or not exists(select 1 from app_private.profiles where user_id=owner and state='active')
   or not exists(select 1 from app_private.legacy_import_runs where user_id=owner and legacy_user_id=source_id and status='complete')
   then raise exception 'existing imported Auth/profile owner required'; end if;
  if exists(select 1 from app_private.main_account_deletions where user_id=owner or legacy_user_id=source_id)
   or exists(select 1 from apple_private.deletions where user_id=owner)
   then raise exception 'deletion fence present'; end if;
  if exists(select 1 from app_private.legacy_links where (user_id=owner or legacy_user_id=source_id)
   and (user_id<>owner or legacy_user_id<>source_id or state<>'active' or source_origin<>reservation.source_origin))
   then raise exception 'legacy link conflict'; end if;
  if exists(select 1 from app_private.native_accounts where
   (user_id=owner or (provider='apple' and identity_key=item->>'native_identity_key'))
   and (user_id<>owner or provider<>'apple' or identity_key<>item->>'native_identity_key'
    or legacy_user_id is distinct from source_id or state<>'ready' or not migration_complete))
   then raise exception 'native ownership conflict'; end if;
  if exists(select 1 from apple_private.accounts where
   (user_id=owner or identity_key=item->>'native_identity_key' or subject_key=item->>'subject_key' or legacy_user_id=source_id)
   and (user_id<>owner or identity_key<>item->>'native_identity_key' or subject_key<>item->>'subject_key'
    or legacy_user_id is distinct from source_id or shadow_email<>item->>'shadow_email' or state<>'ready'
    or not migration_complete or migration_version<>1 or lease_id is not null))
   then raise exception 'Apple ownership conflict'; end if;
  select * into snapshot from apple_private.migration_snapshots where user_id=owner;
  if found and (snapshot.source_sha256<>item->>'source_sha256' or snapshot.data<>item->'snapshot')
   then raise exception 'existing snapshot conflict'; end if;
  insert into apple_private.accounts(identity_key,subject_key,client_id,user_id,shadow_email,legacy_user_id)
   values(item->>'native_identity_key',item->>'subject_key','com.spyclash.ios',owner,item->>'shadow_email',source_id)
   on conflict(identity_key) do nothing;
  insert into apple_private.migration_snapshots(user_id,source_sha256,data)
   values(owner,item->>'source_sha256',item->'snapshot') on conflict(user_id) do nothing;
  insert into app_private.legacy_links(user_id,legacy_user_id,verified_at,source_origin)
   values(owner,source_id,clock_timestamp(),reservation.source_origin) on conflict(user_id) do nothing;
  update app_private.legacy_session_accounts set state='ready',updated_at=case when state='ready' then updated_at else clock_timestamp() end
   where user_id=owner;
 end loop;
 for item in select value from jsonb_array_elements(plan->'accounts') loop
  owner:=(item->>'user_id')::uuid;
  update apple_private.accounts set state='ready',migration_complete=true,migration_version=1,
   updated_at=case when state='ready' then updated_at else clock_timestamp() end
   where user_id=owner and identity_key=item->>'native_identity_key' and state in ('pending','ready');
  if not found or not exists(select 1 from app_private.native_accounts where user_id=owner and provider='apple'
   and identity_key=item->>'native_identity_key' and legacy_user_id=item->>'legacy_user_id'
   and state='ready' and migration_complete and migration_version=1)
   then raise exception 'native ready transition failed'; end if;
 end loop;
 select jsonb_object_agg(user_id::text,encode(sha256(convert_to(data::text,'UTF8')),'hex'))
 into profiles_after from app_private.profiles where user_id in
 (select (x->>'user_id')::uuid from jsonb_array_elements(plan->'accounts') x);
 if profiles_before is distinct from profiles_after then raise exception 'profiles changed'; end if;
end $coverage_import$;
commit;
"""


def render_sql(plan):
    return SQL.replace("__PLAN_HEX__", canonical(plan).encode().hex())


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--input", required=True)
    p.add_argument("--receipt")
    p.add_argument("--output-dir", required=True)
    args = p.parse_args()
    plan = compile_plan(json.loads(Path(args.input).read_text()), json.loads(Path(args.receipt).read_text()) if args.receipt else None)
    out = Path(args.output_dir); out.mkdir(parents=True, exist_ok=True, mode=0o700)
    for name, content in {"plan.private.json": json.dumps(plan, indent=2)+"\n", "import.private.sql": render_sql(plan)}.items():
        path = out/name; path.write_text(content); path.chmod(0o600)
    print(json.dumps({"accounts": len(plan["accounts"]), "ready_for_import": plan["ready_for_import"], "sql_sha256": hashlib.sha256((out/"import.private.sql").read_bytes()).hexdigest()}))


if __name__ == "__main__":
    main()
