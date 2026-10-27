import {AppServiceError, type AppContext} from './contracts.ts';
import {canonical, digest} from './integration-crypto.ts';

type Row = Record<string, any>;
const SOURCE = 'https://spyclash.com/69a0e57fa939f578082f8091';
const ownIDFields = new Set(['user_id','legacy_user_id','owner_id','owner_user_id','player_id','player_user_id',
  'actor_id','actor_user_id','recipient_id','recipient_user_id','author_user_id','target_user_id',
  'sender_user_id','requester_id','addressee_id','reporter_user_id','reported_user_id','profile_user_id','viewer_id']);
const emailFields = new Set(['email','contact_email','user_email','owner_email','player_email']);
const trim = (value: unknown) => typeof value === 'string' ? value.trim() : '';
const email = (value: unknown) => trim(value).toLowerCase();
const object = (value: unknown): value is Row => !!value && typeof value === 'object' && !Array.isArray(value);
const retry = (code: string) => new AppServiceError(code,'Account archive cleanup needs verified ownership. Retry deletion after verification.',503,true);

export type ArchiveSubject = {userID:string;legacyID:string;aliases:Set<string>;appleKeys:Set<string>;appleRecordIDs:Set<string>;lifecycleKeys:Set<string>};
/** The input is server-owned User snapshots, never a request alias or metadata.
 * Any alias reused by another immutable User is rejected before erasure. */
export function verifiedArchiveAliases(users: Row[], legacyID: string): string[] {
  const aliases = new Set(users.filter(row=>row.id===legacyID).map(row=>email(row.email)).filter(Boolean));
  for (const row of users) if (row.id!==legacyID && aliases.has(email(row.email))) throw retry('archive_alias_owner_conflict');
  return [...aliases].sort();
}
function idMatches(value: unknown, subject: ArchiveSubject) { return value===subject.userID || value===subject.legacyID; }
function scalarMatches(value: unknown, subject: ArchiveSubject) {
  return idMatches(value,subject) || typeof value==='string' && (subject.aliases.has(email(value)) || subject.appleKeys.has(value));
}
/** Stable owner fields outrank a matching email. Another bound account's Apple
 * credential is preserved even when its email selector happens to be equal. */
function rowOwned(row: Row, subject: ArchiveSubject, entity?: string) {
  if(entity==='AppleSignInCredential' || typeof row.identity_key==='string' && row.identity_key.startsWith('apple-email:')) {
    const owner=trim(row.user_id);
    if(owner)return idMatches(owner,subject);
    return subject.appleRecordIDs.has(trim(row.id)) || subject.appleKeys.has(trim(row.identity_key));
  }
  if(entity==='BillingIdentityLifecycle')return subject.lifecycleKeys.has(trim(row.subject_key));
  if(entity==='User')return idMatches(row.id,subject);
  if(entity==='GameRoom')return false;
  if(idMatches(row.id,subject) || row.entity==='User' && idMatches(row.source_id,subject))return true;
  const owners=Object.entries(row).filter(([key,value])=>ownIDFields.has(key)&&trim(value)).map(([,value])=>value);
  if(owners.length)return owners.some(value=>idMatches(value,subject));
  if(entity==='AiGenerationQuota' && idMatches(row.created_by_id,subject))return true;
  return Object.entries(row).some(([key,value])=>emailFields.has(key)&&subject.aliases.has(email(value)));
}

/** Removes only the subject's participant objects, map entries and scalar
 * references from shared containers. Unrelated participants retain their data. */
export function redactArchiveValue(value: any, subject: ArchiveSubject, entity?: string): any {
  if(Array.isArray(value))return value.map(item=>redactArchiveValue(item,subject)).filter(item=>item!==undefined);
  if(!object(value))return scalarMatches(value,subject)?undefined:value;
  if(rowOwned(value,subject,entity))return undefined;
  if(entity==='AppleSignInCredential' || typeof value.identity_key==='string' && value.identity_key.startsWith('apple-email:'))return value; // foreign binding dominates selector equality in snapshots and journals
  const result:Row={};
  for(const [key,item] of Object.entries(value)) {
    if(scalarMatches(key,subject))continue;
    const redacted=redactArchiveValue(item,subject);
    if(redacted!==undefined)result[key]=redacted;
  }
  return result;
}
function collectUsers(job: Row): Row[] {
  const snapshot=job.payload?.snapshot?.entities?.User;
  return Array.isArray(snapshot)?snapshot:[];
}
function redactSnapshotPayload(payload: Row, subject: ArchiveSubject) {
  // Arrays in plans/baselines use the same explicit owner fields as domain
  // rows. The source snapshot needs entity names for User/Apple/shared rooms.
  const {snapshot,...rest}=payload;
  const result=redactArchiveValue(rest,subject) || {};
  if(object(snapshot)) {
    const {entities,...metadata}=snapshot;
    result.snapshot=redactArchiveValue(metadata,subject) || {};
    if(object(entities)) {
      result.snapshot.entities={};
      for(const [entity,rows] of Object.entries(entities)) {
        if(!Array.isArray(rows))throw retry('archive_snapshot_shape_unavailable');
        result.snapshot.entities[entity]=rows.map(row=>redactArchiveValue(row,subject,entity)).filter(row=>row!==undefined);
      }
    }
  }
  return result;
}
/** A changed journal entry is removed in full: rewriting its before/after
 * images could make an operator rollback resurrect a deleted identity. Entries
 * for wholly unrelated accounts remain byte-for-byte intact. */
export function redactRollbackJournal(journal: Row, subject: ArchiveSubject) {
  if(canonical(redactArchiveValue(journal,subject))===canonical(journal))return journal;
  if(!object(journal) || !Array.isArray(journal.changes)) {
    if(canonical(journal)==='{}')return journal;
    throw retry('archive_journal_shape_unavailable');
  }
  return {...journal,changes:journal.changes.filter((entry:Row)=>canonical(redactArchiveValue(entry,subject))===canonical(entry))};
}

/** Gather aliases before any remote deletion; the exact same server-owned
 * identity is rechecked under the account's exclusive transaction at erasure. */
export async function loadArchiveAliases(db:any,userID:string,legacyID:string):Promise<string[]> {
  const [present]=await db`select to_regclass('app_private.bulk_migration_archive') is not null as archive,
    to_regclass('app_private.bulk_migration_jobs') is not null as jobs`;
  if(!present.archive && !present.jobs)return [];
  if(!present.archive || !present.jobs)throw retry('archive_schema_incomplete');
  const rows=await db`select payload from app_private.bulk_migration_archive where source_key=${SOURCE} and entity='User'`;
  const jobs=await db`select payload,rollback_journal,status,lease_until>clock_timestamp() as lease_active from app_private.bulk_migration_jobs where source_key=${SOURCE}`;
  const aliases=verifiedArchiveAliases([...rows.map((r:Row)=>r.payload),...jobs.flatMap(collectUsers)],legacyID);
  // A matching email never establishes this binding; current session ownership
  // was proved by Base44 and persisted in the immutable private link.
  const links=await db`select legacy_user_id from app_private.legacy_links where user_id=${userID} and source_origin='https://spyclash.com'`;
  if(links.length!==1 || links[0].legacy_user_id!==legacyID)throw new AppServiceError('legacy_owner_mismatch','The original account does not match this game account.',409);
  const subject:ArchiveSubject={userID,legacyID,aliases:new Set(aliases),appleKeys:new Set(),appleRecordIDs:new Set(),lifecycleKeys:new Set()};
  for(const job of jobs) {
    const affected=canonical(redactSnapshotPayload(job.payload,subject))!==canonical(job.payload)
      ||canonical(redactRollbackJournal(job.rollback_journal,subject))!==canonical(job.rollback_journal);
    if(affected && (!['applied','rolled_back'].includes(job.status) || job.lease_active))throw retry('archive_migration_busy');
  }
  return aliases;
}

/** All mutations run inside lifecycle's exclusive account transaction. Tables
 * may be absent on local/non-migrated installations, but a partial schema never
 * becomes silent success. No archive payload or credential is logged. */
export async function eraseAccountArchives(ctx:AppContext,intent?:Row) {
  const {tx,actor}=ctx;
  const [present]=await tx`select to_regclass('app_private.bulk_migration_archive') is not null as archive,
    to_regclass('app_private.bulk_migration_jobs') is not null as jobs,
    to_regclass('app_private.bulk_migration_rows') is not null as rows`;
  if(!present.archive && !present.jobs && !present.rows)return;
  if(!present.archive || !present.jobs || !present.rows)throw retry('archive_schema_incomplete');
  const links=await tx`select legacy_user_id from app_private.legacy_links where user_id=${actor.id} and source_origin='https://spyclash.com'`;
  const reservations=await tx`select legacy_user_id from app_private.legacy_session_accounts where user_id=${actor.id}
    and source_origin='https://spyclash.com' and source_app_id='69a0e57fa939f578082f8091'`;
  const legacyIDs=new Set([...links,...reservations].map((r:Row)=>r.legacy_user_id));
  if(!legacyIDs.size)return; // Native Game Center has no legacy source account.
  if(legacyIDs.size!==1 || !intent || intent.native_account || intent.legacy_user_id!==[...legacyIDs][0])throw retry('archive_identity_proof_required');
  if(!['legacy_deleted','complete'].includes(intent.phase))throw retry('archive_identity_proof_required');
  if(intent.phase==='complete')return; // This transaction previously committed the archive purge.
  const legacyID=String(intent.legacy_user_id);
  const [lock]=await tx`select pg_try_advisory_xact_lock(hashtextextended('spyclash-archive-erasure',0)) as acquired`;
  if(!lock.acquired)throw retry('archive_erasure_busy');
  const jobs=await tx`select * from app_private.bulk_migration_jobs where source_key=${SOURCE} order by id for update`;
  const archived=await tx`select * from app_private.bulk_migration_archive where source_key=${SOURCE} order by job_id,entity,source_id for update`;
  const aliases=verifiedArchiveAliases([...archived.filter((r:Row)=>r.entity==='User').map((r:Row)=>r.payload),...jobs.flatMap(collectUsers)],legacyID);
  const proof=intent.erasure_proof;
  if(!object(proof) || proof.version!==1 || !Array.isArray(proof.apple_identity_keys) || !Array.isArray(proof.apple_record_ids)
    || proof.archive_alias_digest!==await digest(canonical(aliases)))throw retry('archive_selector_proof_required');
  const subject:ArchiveSubject={userID:actor.id,legacyID,aliases:new Set([...aliases,actor.email]),
    appleKeys:new Set(proof.apple_identity_keys),appleRecordIDs:new Set(proof.apple_record_ids),lifecycleKeys:new Set()};
  for(const identity of [legacyID,...[...subject.appleKeys].map(key=>'spyclash-apple-refresh-token-v1:identity-lifecycle:'+key)])
    subject.lifecycleKeys.add('billing:'+(await digest('spyclash-billing-lifecycle:'+identity)).slice(0,40));
  const removed=new Set<string>();
  for(const row of archived) {
    const redacted=redactArchiveValue(row.payload,subject,row.entity);
    if(redacted===undefined) {
      await tx`delete from app_private.bulk_migration_archive where job_id=${row.job_id} and entity=${row.entity} and source_id=${row.source_id}`;
      removed.add(row.entity+'\n'+row.source_id);
    } else if(canonical(redacted)!==canonical(row.payload)) {
      await tx`update app_private.bulk_migration_archive set payload=${tx.json(redacted)},source_digest=${await digest(canonical(redacted))},reason='account_erasure_redacted'
        where job_id=${row.job_id} and entity=${row.entity} and source_id=${row.source_id}`;
    }
  }
  // Ledger rows for deleted source objects are not retained as a restore path.
  for(const key of removed) {
    const [entity,sourceID]=key.split('\n');
    await tx`delete from app_private.bulk_migration_rows where source_key=${SOURCE} and entity=${entity} and source_id=${sourceID}`;
  }
  for(const job of jobs) {
    const payload=redactSnapshotPayload(job.payload,subject),journal=redactRollbackJournal(job.rollback_journal,subject);
    if(canonical(payload)===canonical(job.payload) && canonical(journal)===canonical(job.rollback_journal))continue;
    if(!['applied','rolled_back'].includes(job.status) || job.lease_until && new Date(job.lease_until)>ctx.now)throw retry('archive_migration_busy');
    // Invalidate the sealed import capability and digest. An operator must make
    // a new reviewed snapshot; this historical job cannot re-import erased data.
    await tx`update app_private.bulk_migration_jobs set payload=${tx.json(payload)},rollback_journal=${tx.json(journal)},
      token_expires_at=least(token_expires_at,clock_timestamp()),plan_digest=${await digest(canonical(payload))},
      source_attested_at=null,source_attested_digest=null,updated_at=clock_timestamp() where id=${job.id}`;
  }
}
