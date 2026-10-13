import { AppServiceError } from './contracts.ts';
import { decryptToken, digest } from './integration-crypto.ts';
import { TEST_PUSH_BUNDLE, registrationBinding } from './push.ts';
import { liveActivityPayload, liveActivityTerminationPayload } from './live-activity-policy.ts';
type Config=Record<string,string|undefined>;
type DeliveryResult={delivered:boolean,retryable:boolean,invalidateToken?:boolean,reason:string};

/** Bounded, lease-fenced delivery. Database transactions only claim/finalize;
 * APNs runs outside them. APNs is at-least-once after a lost ACK; stable collapse
 * IDs limit duplicate presentation without pretending exactly-once network I/O. */
export async function drainPushOutbox(db:any,config:Config,options:{limit?:number,send?:(input:any)=>Promise<DeliveryResult>}={}) {
  if(config.APP_PUSH_DELIVERY_ENABLED!=='true'||config.APNS_TOPIC!==TEST_PUSH_BUNDLE)throw new AppServiceError('push_delivery_unconfigured','Isolated APNs delivery is not configured.',503);
  const limit=Math.max(1,Math.min(25,options.limit||10));
  const jobs=await db.begin(async(tx:any)=>{
    const rows=await tx`select id from app_private.push_outbox where
      ((state='pending' and available_at<=clock_timestamp()) or (state='sending' and lease_until<clock_timestamp()))
      order by available_at for update skip locked limit ${limit}`;
    const jobs=[];
    for(const row of rows){
      const lease=crypto.randomUUID();
      const [job]=await tx`update app_private.push_outbox set state='sending',lease_id=${lease},lease_until=clock_timestamp()+interval '90 seconds',attempts=attempts+1 where id=${row.id} returning *`;
      jobs.push(job);
    }
    return jobs;
  });
  const summary={claimed:jobs.length,delivered:0,retried:0,cancelled:0,failed:0,skipped:0};
  for(const job of jobs){
    // A bounded batch can wait longer than its original lease. Never send a
    // tail job after expiry/reclaim/cancellation; atomically renew only the
    // still-current, unexpired owner immediately before processing it.
    const [renewed]=await db`update app_private.push_outbox set lease_until=clock_timestamp()+interval '90 seconds'
      where id=${job.id} and lease_id=${job.lease_id} and state='sending' and lease_until>clock_timestamp() returning id`;
    if(!renewed){summary.skipped++;continue;}
    const [row]=await db`select r.*,p.state as account_state from app_private.push_registrations r
      left join app_private.profiles p on p.user_id=r.user_id where r.id=${job.registration_id}`;
    let cancellation:string|null=null;
    if(!row||!row.active||row.account_state!=='active'||row.user_id!==job.user_id)cancellation='account_or_registration_inactive';
    else if(row.bundle_id!==TEST_PUSH_BUNDLE)cancellation='topic_forbidden';
    else if(new Date(job.expires_at).getTime()<=Date.now())cancellation='expired';
    else if(job.kind==='alert'){
      if(job.payload.announcement_id){
        const [announcement]=await db`select status,revision,expires_at from app_private.notification_announcements where id::text=${String(job.payload.announcement_id)}`;
        if(!announcement||announcement.status!=='published'||announcement.revision!==job.payload.announcement_revision||new Date(announcement.expires_at).getTime()<=Date.now())cancellation='announcement_not_visible';
      }else{
        const [event]=await db`select visible from app_private.notification_events where id::text=${job.event_key} and recipient_id=${job.user_id}`;
        if(!event?.visible)cancellation='source_not_visible';
      }
    }else {
      const end=job.payload?.aps?.event==='end';
      if(end){
        // A replay/deleted room must not suppress an old activity's durable end.
        // The private outbox and exact per-activity token binding authorize it.
        if(row.kind!=='activity'||row.room_id!==job.room_id||row.match_id!==job.match_id)cancellation='stale_activity_binding';
      }else{
        const [room]=await db`select state,closed from full_game_private.rooms where id=${job.room_id}`;
        if(!room||room.closed||room.state.status!=='playing'||room.state.match_id!==job.match_id
          ||!(room.state.players||[]).some((p:any)=>p.user_id===job.user_id)
          ||(room.state.departed_player_emails||[]).includes(job.user_id+'@example.test'))cancellation='stale_match';
        if(job.payload?.aps?.event==='update'&&Number(job.payload.aps['content-state']?.revision)<Date.parse(room?.state?.updated_date||''))cancellation='stale_room_revision';
        if(row.kind==='push_to_start'){
          const [already]=await db`select id from app_private.push_registrations where user_id=${row.user_id} and installation_id=${row.installation_id} and room_id=${job.room_id} and match_id=${job.match_id} and kind='activity' and active`;
          if(already)cancellation='activity_already_started';
        }
      }
    }
    if(cancellation){
      const cancelled=await db`update app_private.push_outbox set state='cancelled',last_reason=${cancellation},lease_until=null where id=${job.id} and lease_id=${job.lease_id} and state='sending' and lease_until>clock_timestamp() returning id`;
      if(cancelled.length)summary.cancelled++;else summary.skipped++;continue;
    }
    let result:DeliveryResult;
    try{
      const token=await decryptToken(row.token_ciphertext,config.PUSH_TOKEN_ENCRYPTION_KEY,registrationBinding(row));
      // Source checks/crypto may wait on infrastructure; verify again at the
      // actual send boundary. APNs has a 15-second deadline, below this lease.
      const [sendLease]=await db`update app_private.push_outbox set lease_until=clock_timestamp()+interval '90 seconds'
        where id=${job.id} and lease_id=${job.lease_id} and state='sending' and lease_until>clock_timestamp() returning id`;
      if(!sendLease){summary.skipped++;continue;}
      result=await (options.send||((input:any)=>sendAPNs(input,config)))({token,environment:row.environment,bundleID:row.bundle_id,
        kind:job.kind,payload:job.payload,collapseID:await digest(job.event_key+':'+row.id),expiresAt:new Date(job.expires_at),eventID:job.id});
    }catch{result={delivered:false,retryable:true,reason:'transport_or_configuration_unavailable'};}
    const retry=result.retryable&&job.attempts<8;
    const finalized=await db.begin(async(tx:any)=>{
      const [owned]=await tx`select id from app_private.push_outbox where id=${job.id} and lease_id=${job.lease_id} and state='sending' and lease_until>clock_timestamp() for update`;
      if(!owned)return false;
      if(result.invalidateToken)await tx`update app_private.push_registrations set active=false where id=${job.registration_id}`;
      if(result.delivered&&job.kind==='liveactivity'&&job.payload?.aps?.event==='end')await tx`update app_private.push_registrations set active=false where id=${job.registration_id} and kind='activity' and match_id=${job.match_id}`;
      const next=result.delivered?'delivered':retry?'pending':'failed';
      const delay=Math.min(3600,Math.pow(2,job.attempts)*5);
      // Only bounded controlled reasons from our adapter are persisted, never an
      // external response body which could echo tokens/authorization material.
      const reason=/^[a-zA-Z0-9_]{1,80}$/.test(result.reason)?result.reason:'delivery_failed';
      await tx`update app_private.push_outbox set state=${next},lease_until=null,last_reason=${reason},
        delivered_at=${result.delivered?new Date():null},available_at=${new Date(Date.now()+delay*1000)} where id=${job.id} and lease_id=${job.lease_id}`;
      return true;
    });
    if(!finalized){summary.skipped++;continue;}
    if(result.delivered)summary.delivered++;else if(retry)summary.retried++;else summary.failed++;
  }
  return summary;
}

/** Converts committed terminal/start events and current room revisions into
 * personalized APNs work atomically. delivered_at here means bridge consumption,
 * while app_private.push_outbox retains independent delivery/retry status. */
export async function reconcileCommittedEvents(db:any,_config:Config,options:{limit?:number}={}) {
  const limit=Math.max(1,Math.min(100,options.limit||25));
  return db.begin(async(tx:any)=>{
    const now=new Date();let consumed=0,queued=0,reconciled=0;
    const events=await tx`select * from full_game_private.outbox where delivered_at is null order by created_at for update skip locked limit ${limit}`;
    for(const entry of events){
      const event=entry.event,terminal=['game_finished','room_closed'].includes(event.type);
      if(terminal){
        const rows=await tx`select * from app_private.push_registrations where room_id=${entry.room_id} and kind='activity' and active
          and (${event.type==='room_closed'} or match_id=${String(event.match_id||'')})`;
        for(const registration of rows)queued+=await queueLive(tx,registration,'core:'+entry.id,entry.room_id,registration.match_id,
          liveActivityTerminationPayload({now,locale:registration.locale}),now);
      }else if(event.type==='game_started'){
        const [stored]=await tx`select state,closed from full_game_private.rooms where id=${entry.room_id} for share`;
        if(stored&&!stored.closed&&stored.state.status==='playing'&&stored.state.match_id===event.match_id){
          const recipients=Array.isArray(event.recipient_user_ids)?event.recipient_user_ids.filter((id:unknown)=>typeof id==='string'):[];
          if(recipients.length){
            const rows=await tx`select * from app_private.push_registrations where user_id=any(${recipients}::uuid[]) and kind='push_to_start' and active`;
            for(const registration of rows){
              const built=await liveActivityPayload({room:stored.state,registration:{...registration,token_kind:'push_to_start'},now});
              if(built)queued+=await queueLive(tx,registration,'core:'+entry.id,entry.room_id,event.match_id,built.payload,now);
            }
          }
        }
      }
      await tx`update full_game_private.outbox set delivered_at=${now} where id=${entry.id}`;consumed++;
    }
    // Catch missing final events, registration after terminal commit, and a
    // missed ordinary room revision. Exact revision/binding keys prevent repeats.
    const registrations=await tx`select r.*,g.state as room_state,g.closed as room_closed,g.revision as room_revision
      from app_private.push_registrations r left join full_game_private.rooms g on g.id=r.room_id
      where r.active and r.kind='activity' order by r.updated_at,r.id for update of r skip locked limit ${limit}`;
    for(const registration of registrations){
      const room=registration.room_state;
      const shouldEnd=!room||registration.room_closed||room.match_id!==registration.match_id
        ||room.status!=='playing'||!(room.players||[]).some((p:any)=>p.user_id===registration.user_id)
        ||(room.departed_player_emails||[]).includes(registration.user_id+'@example.test');
      const eventID='reconcile:'+registration.room_id+':'+registration.match_id+':'+(shouldEnd?'end':String(registration.room_revision));
      const built=shouldEnd?{payload:liveActivityTerminationPayload({now,locale:registration.locale,revision:Number(registration.room_revision||0)})}
        :await liveActivityPayload({room,registration:{...registration,token_kind:'activity'},now});
      if(built)queued+=await queueLive(tx,registration,eventID,registration.room_id,registration.match_id,built.payload,now);
      // Fair bounded rotation; successful registration separately updates token state.
      await tx`update app_private.push_registrations set updated_at=${now} where id=${registration.id}`;reconciled++;
    }
    return {consumed,queued,reconciled};
  });
}
async function queueLive(tx:any,registration:any,eventID:string,roomID:string,matchID:string,payload:any,now:Date){
  if(registration.bundle_id!==TEST_PUSH_BUNDLE)return 0;
  const [active]=await tx`select state from app_private.profiles where user_id=${registration.user_id}`;
  if(active?.state!=='active')return 0;
  // A terminal outbox event and periodic reconciliation may observe the same
  // ending concurrently. They share one delivery identity for the bound token.
  if(payload?.aps?.event==='end')eventID='live-end:'+roomID+':'+matchID;
  const rows=await tx`insert into app_private.push_outbox(event_key,registration_id,user_id,room_id,match_id,payload,kind,expires_at)
    values(${eventID},${registration.id},${registration.user_id},${roomID},${matchID},${tx.json(payload)},'liveactivity',${new Date(now.getTime()+3600_000)}) on conflict(event_key,registration_id) do nothing returning id`;
  return rows.length;
}

const base64url=(bytes:Uint8Array)=>btoa(String.fromCharCode(...bytes)).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
async function providerToken(config:Config){
  if(!config.APNS_KEY_ID||!config.APNS_TEAM_ID||!config.APNS_PRIVATE_KEY)throw new AppServiceError('apns_unconfigured','APNs provider credentials are not configured.',503);
  const encoder=new TextEncoder();
  const header=base64url(encoder.encode(JSON.stringify({alg:'ES256',kid:config.APNS_KEY_ID})));
  const payload=base64url(encoder.encode(JSON.stringify({iss:config.APNS_TEAM_ID,iat:Math.floor(Date.now()/1000)})));
  const raw=config.APNS_PRIVATE_KEY.replace(/\\n/g,'\n').replace(/-----[^-]+-----|\s/g,'');
  const bytes=Uint8Array.from(atob(raw),c=>c.charCodeAt(0));
  const key=await crypto.subtle.importKey('pkcs8',bytes,{name:'ECDSA',namedCurve:'P-256'},false,['sign']);
  const signature=await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},key,encoder.encode(header+'.'+payload));
  return header+'.'+payload+'.'+base64url(new Uint8Array(signature));
}
async function sendAPNs(input:any,config:Config):Promise<DeliveryResult>{
  if(input.bundleID!==TEST_PUSH_BUNDLE||config.APNS_TOPIC!==TEST_PUSH_BUNDLE)throw new AppServiceError('topic_forbidden','Production APNs topics are not allowed.',503);
  const bytes=new TextEncoder().encode(JSON.stringify(input.payload));
  if(bytes.length>4096)return {delivered:false,retryable:false,reason:'payload_too_large'};
  const host=input.environment==='production'?'https://api.push.apple.com':'https://api.sandbox.push.apple.com';
  const response=await fetch(host+'/3/device/'+input.token,{method:'POST',redirect:'error',signal:AbortSignal.timeout(15_000),
    headers:{authorization:'bearer '+await providerToken(config),'apns-topic':input.bundleID+(input.kind==='liveactivity'?'.push-type.liveactivity':''),
      'apns-push-type':input.kind==='liveactivity'?'liveactivity':'alert','apns-priority':'10','apns-id':input.eventID,
      'apns-expiration':String(Math.floor(input.expiresAt.getTime()/1000)),'apns-collapse-id':input.collapseID,'content-type':'application/json'},body:bytes});
  if(response.ok)return {delivered:true,retryable:false,reason:'delivered'};
  let reason='http_'+response.status;try{const body=await response.json();if(typeof body.reason==='string'&&/^[A-Za-z]{1,60}$/.test(body.reason))reason=body.reason;}catch{/* preserve bounded status */}
  return {delivered:false,retryable:response.status===429||response.status>=500,invalidateToken:response.status===410||reason==='BadDeviceToken'||reason==='DeviceTokenNotForTopic',reason};
}
