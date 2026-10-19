/** Read-only preparation. Produces a sealed operator packet; does not connect
 * to Supabase or change either provider. Never commit the generated packet. */
import {canonical,digest} from '../../supabase/functions/app-services/integration-crypto.ts';
import {assertPlanReady} from './core.ts';
import {buildAncillaryPlan,assertAncillaryPlanReady} from './ancillary.ts';
import {buildDispositionManifest} from './archive.ts';
const folder=Deno.args[0]||'.local/bulk-migration';
if(!folder.includes('.local/'))throw new Error('Private ignored output folder required');
const load=async(name:string)=>JSON.parse(await Deno.readTextFile(folder+'/'+name));
const snapshot=await load('source-snapshot.json'),core=await load('core-plan.json'),target=await load('target-baseline.json');
const remoteSchemaEvidence=JSON.parse(await Deno.readTextFile(Deno.args[1]||'evidence/full-app/build191/remote-schema-inventory.json'));
const deployed=snapshot.inventory.filter((e:any)=>e.sourceAvailability==='deployed').map((e:any)=>e.entity).sort();
if(remoteSchemaEvidence.source_snapshot_digest!==snapshot.digest||remoteSchemaEvidence.two_complete_schema_reads_match!==true||remoteSchemaEvidence.all_remote_entities_exported!==true||canonical([...remoteSchemaEvidence.remote_entity_names].sort())!==canonical(deployed)||remoteSchemaEvidence.unknown_remote_entities.length)throw new Error('Independent source schema inventory does not match snapshot');
assertPlanReady(core);
if(core.sourceDigest!==snapshot.digest)throw new Error('Reviewed plan does not match source snapshot');
const {digest:sourceDigest,...raw}=snapshot;
if(await digest(canonical(raw))!==sourceDigest)throw new Error('Source snapshot digest mismatch');
const ancillary=await buildAncillaryPlan(snapshot,core,{announcements:target.announcements||[],events:target.events||[],readReceipts:target.readReceipts||[],reports:target.reports||[]});
assertAncillaryPlanReady(ancillary);
const manifest=buildDispositionManifest(snapshot,core,ancillary);
const payload={snapshot,core,ancillary,manifest,remoteSchemaEvidence},planDigest=await digest(canonical(payload));
const sourceContentDigest=await digest(canonical({source:snapshot.source,entities:snapshot.entities,schemas:snapshot.sourceSchemas}));
const id=crypto.randomUUID(),token=[...crypto.getRandomValues(new Uint8Array(32))].map(v=>v.toString(16).padStart(2,'0')).join(''),tokenDigest=await digest(token);
const sql=`insert into app_private.bulk_migration_jobs(id,source_key,source_digest,source_content_digest,plan_digest,token_digest,token_expires_at,payload) values('${id}','https://spyclash.com/69a0e57fa939f578082f8091','${sourceDigest}','${sourceContentDigest}','${planDigest}','${tokenDigest}',clock_timestamp()+interval '30 minutes','{}'::jsonb);\n`;
await Deno.mkdir(folder,{recursive:true,mode:0o700});
for(const [name,value] of Object.entries({'job-payload.json':JSON.stringify(payload),'job-init.sql':sql,'operator-job.json':JSON.stringify({id,token,sourceDigest,sourceContentDigest,planDigest,project:'bbkfsgnordtdiblgdzkg',payloadPath:folder+'/job-payload.json'})}))await Deno.writeTextFile(folder+'/'+name,value,{createNew:true,mode:0o600});
const summary={production_mutations:false,source_rows:Object.values(snapshot.entities).reduce((n:any,r:any)=>n+r.length,0),source_entities:snapshot.inventory.filter((e:any)=>e.sourceAvailability==='deployed').length,source_digest:sourceDigest,plan_digest:planDigest,core:core.counts,ancillary:ancillary.counts,issues:core.issues.length+ancillary.issues.length,source_spy_ids_preserved:core.accounts.filter((a:any)=>snapshot.entities.User.find((u:any)=>u.id===a.legacy_user_id)?.spy_id).length,new_spy_ids:core.accounts.filter((a:any)=>!snapshot.entities.User.find((u:any)=>u.id===a.legacy_user_id)?.spy_id).length,source_inventory_complete:true};
await Deno.writeTextFile(folder+'/prepared-summary.json',JSON.stringify(summary,null,2)+'\n',{createNew:true,mode:0o600});
console.log(JSON.stringify(summary));
