import {canonical,digest} from '../../supabase/functions/app-services/integration-crypto.ts';
import type {SourceSnapshot,Row} from './core.ts';

const archiveReasons:Record<string,string>={
  Entitlement:'billing_provider_remains_authoritative',MembershipGrant:'billing_provider_remains_authoritative',AppStoreAccount:'billing_provider_remains_authoritative',
  AppleSignInCredential:'encrypted_provider_revocation_credentials_preserved',BillingIdentityLifecycle:'deletion_and_ownership_fences_preserved',AccountDeletionReceipt:'deletion_receipts_preserved',
  AiGenerationQuota:'ai_provider_remains_authoritative',AiGenerationUsage:'ai_provider_remains_authoritative',AiWordPackCacheVariant:'ai_provider_remains_authoritative',AiWordPackOperation:'ai_provider_remains_authoritative',AiWordPackRequestResult:'ai_provider_remains_authoritative',
  PushDeviceRegistration:'device_tokens_preserved_without_replaying_delivery',LiveActivityRegistration:'old_activity_tokens_preserved_without_restarting_activities',
  CommunityProfileSignal:'transient_signal_history_preserved',GameRoomSignal:'transient_signal_history_preserved',MembershipSignal:'transient_signal_history_preserved',
};
export function buildDispositionManifest(snapshot:SourceSnapshot,core:Row,ancillary:Row):Row[] {
  const declared=new Map<string,Row>();
  for(const row of [...core.dispositions,...ancillary.dispositions]) {
    const key=row.entity+'\n'+row.source_id;
    if(declared.has(key))throw new Error('archive_duplicate_disposition');
    declared.set(key,row);
  }
  const manifest:Row[]=[];
  for(const [entity,rows] of Object.entries(snapshot.entities))for(const row of rows) {
    const key=entity+'\n'+row.id,decision=declared.get(key);
    if(!decision&&!archiveReasons[entity])throw new Error('archive_missing_disposition');
    manifest.push({entity,source_id:row.id,disposition:decision?.action||'archive_only',target_id:decision?.target_id||null,reason:decision?.reason||archiveReasons[entity]||'materialized_or_preserved_by_reviewed_plan'});
    declared.delete(key);
  }
  if(declared.size)throw new Error('archive_unknown_disposition');
  return manifest.sort((a,b)=>(a.entity+'\n'+a.source_id).localeCompare(b.entity+'\n'+b.source_id));
}
export async function archiveSnapshot(tx:any,jobID:string,snapshot:SourceSnapshot,manifest:Row[]) {
  const sourceKey=snapshot.source.origin+'/'+snapshot.source.appID;
  let count=0;
  const existing=await tx`select entity,source_id,source_digest from app_private.bulk_migration_archive where job_id=${jobID}`;
  const hashes=new Map(existing.map((r:Row)=>[r.entity+'\n'+r.source_id,r.source_digest]));
  const decisions=new Map(manifest.map(r=>[r.entity+'\n'+r.source_id,r]));
  const inserts:Row[]=[];
  for(const [entity,rows] of Object.entries(snapshot.entities))for(const row of rows) {
    const hash=await digest(canonical(row));
    const prior=hashes.get(entity+'\n'+row.id);
    if(prior&&prior!==hash)throw new Error('archive_source_changed');
    const decision=decisions.get(entity+'\n'+row.id);
    if(!decision)throw new Error('archive_missing_disposition');
    if(!prior)inserts.push({job_id:jobID,source_key:sourceKey,entity,source_id:row.id,source_digest:hash,payload:row,disposition:decision.disposition,target_id:decision.target_id,reason:decision.reason});
    count++;
  }
  if(manifest.length!==count||decisions.size!==count)throw new Error('archive_manifest_count_mismatch');
  for(let offset=0;offset<inserts.length;offset+=100)await tx`insert into app_private.bulk_migration_archive select * from jsonb_populate_recordset(null::app_private.bulk_migration_archive,${tx.json(inserts.slice(offset,offset+100).map(r=>({...r,archived_at:new Date().toISOString()})))})`;
  const [stored]=await tx`select count(*)::int as count from app_private.bulk_migration_archive where job_id=${jobID}`;
  if(stored.count!==count)throw new Error('archive_row_count_mismatch');
  return count;
}

/** Fixed table/PK allowlist. Captures only data changed by this migration.
 * Auth identities are deliberately excluded; session-aware Admin cleanup is a
 * separate action and never a cascading database delete during rollback. */
export const JOURNAL_TABLES:Record<string,string[]>={
  'app_private.profiles':['user_id'],
  'app_private.friendships':['id'],
  'app_private.profile_comments':['id'],
  'full_game_private.word_packs':['id'],
  'full_game_private.history':['match_id','player_id'],
  'app_private.legacy_import_rows':['source_key','entity','source_id'],
  'app_private.legacy_import_runs':['user_id','source_key'],
  'app_private.legacy_import_history_stage':['user_id','source_key','source_id'],
  'app_private.legacy_session_accounts':['identity_key'],
  'app_private.bulk_migration_rows':['source_key','entity','source_id'],
  'app_private.notification_announcements':['id'],
  'app_private.notification_events':['id'],
  'app_private.notification_read_receipts':['user_id','notification_key'],
  'app_private.community_reports':['id'],
  'public.app_user_signals':['recipient_user_id'],
};
export async function readJournalState(tx:any):Promise<Record<string,Row[]>> {
  const state:Record<string,Row[]>={};
  for(const table of Object.keys(JOURNAL_TABLES))state[table]=(await tx.unsafe('select to_jsonb(t) as value from '+table+' t')).map((r:Row)=>r.value);
  return JSON.parse(JSON.stringify(state));
}
export function diffJournal(before:Record<string,Row[]>,after:Record<string,Row[]>) {
  const changes:Row[]=[];
  for(const [table,keys] of Object.entries(JOURNAL_TABLES)) {
    const key=(row:Row)=>canonical(keys.map(k=>row[k]));
    const a=new Map((before[table]||[]).map(r=>[key(r),r])),b=new Map((after[table]||[]).map(r=>[key(r),r]));
    for(const id of new Set([...a.keys(),...b.keys()]))if(canonical(a.get(id)||null)!==canonical(b.get(id)||null))changes.push({table,keys,before:a.get(id)||null,after:b.get(id)||null});
  }
  return changes;
}
/** Local/operator recovery only. Caller supplies a separate explicit rollback
 * authorization. Any newer user edit rejects the ENTIRE rollback transaction. */
export async function rollbackJournal(tx:any,changes:Row[]) {
  await tx.unsafe('lock table '+Object.keys(JOURNAL_TABLES).join(',')+' in share row exclusive mode');
  for(const change of changes) {
    const keys=JOURNAL_TABLES[change.table];
    if(!keys||canonical(keys)!==canonical(change.keys))throw new Error('rollback_table_forbidden');
    const row=change.after||change.before;
    const predicate=keys.map((k,i)=>'"'+k+'" is not distinct from $'+(i+1)).join(' and ');
    const current=await tx.unsafe('select to_jsonb(t) as value from '+change.table+' t where '+predicate,keys.map(k=>row[k]));
    if(canonical(current[0]?.value||null)!==canonical(change.after))throw new Error('rollback_newer_activity');
  }
  // Reverse order removes dependent imported records before their profiles.
  for(const change of [...changes].reverse()) {
    const keys=JOURNAL_TABLES[change.table],row=change.after||change.before;
    const predicate=keys.map((k,i)=>'"'+k+'" is not distinct from $'+(i+1)).join(' and ');
    if(!change.before)await tx.unsafe('delete from '+change.table+' where '+predicate,keys.map(k=>row[k]));
    else {
      const columns=Object.keys(change.before).filter(k=>change.table!=='app_private.friendships'||!['pair_low','pair_high'].includes(k));
      // jsonb_populate_record preserves database types without guessing casts.
      await tx.unsafe('insert into '+change.table+' ('+columns.map(k=>'"'+k+'"').join(',')+') select '+columns.map(k=>'r."'+k+'"').join(',')+' from jsonb_populate_record(null::'+change.table+',$1::jsonb) r on conflict ('+keys.map(k=>'"'+k+'"').join(',')+') do update set '+columns.filter(k=>!keys.includes(k)).map(k=>'"'+k+'"=excluded."'+k+'"').join(','),[change.before]);
    }
  }
}
