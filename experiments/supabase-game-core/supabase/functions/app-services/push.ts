import { AppServiceError, requireUUID, type AppContext } from './contracts.ts';
import { digest, encryptToken } from './integration-crypto.ts';
import { legacyPushConfigured, MAIN_PUSH_BUNDLE } from './legacy-push.ts';

export const TEST_PUSH_BUNDLE = 'com.spyclash.ios.supabasetest';
const text = (value:unknown,max=200) => typeof value==='string'?value.trim().slice(0,max):'';
export function allowedPushBundle(config:Record<string,string|undefined>) {
  return config.APNS_TOPIC===TEST_PUSH_BUNDLE && (!config.APP_PUSH_DELIVERY_PROVIDER || config.APP_PUSH_DELIVERY_PROVIDER==='apns')
    ? TEST_PUSH_BUNDLE : legacyPushConfigured(config) ? MAIN_PUSH_BUNDLE : null;
}
export function pushCapabilities(config: Record<string,string|undefined>) {
  return {registration_enabled:config.APP_PUSH_ENABLED==='true' && !!allowedPushBundle(config)
    && /^[a-f0-9]{64}$/i.test(config.PUSH_TOKEN_ENCRYPTION_KEY||''),delivery_enabled:config.APP_PUSH_DELIVERY_ENABLED==='true'};
}
export function registrationBinding(row: {user_id:string,bundle_id:string,environment:string,kind:string,binding:string}) {
  return [row.user_id,row.bundle_id,row.environment,row.kind,row.binding].join(':');
}
export async function dispatchPush(ctx:AppContext,body:Record<string,any>) {
  const action = body.action;
  const installation = text(body.installation_id);
  if(installation.length<16) throw new AppServiceError('invalid_installation_id','A valid installation identifier is required.');
  const live = ['register_live_activity_token','unregister_live_activity_token'].includes(action);
  const kind = live ? body.token_kind : 'device';
  if(!['device','push_to_start','activity'].includes(kind)) throw new AppServiceError('invalid_token_kind','Invalid push token kind.');
  const binding = kind==='activity'?text(body.activity_id):'';
  if(kind==='activity'&&!binding) throw new AppServiceError('invalid_activity_id','An activity identifier is required.');
  if(action==='unregister_device'||action==='unregister_live_activity_token') {
    await ctx.tx`update app_private.push_registrations set active=false,updated_at=${ctx.now}
      where user_id=${ctx.actor.id} and installation_id=${installation} and kind=${kind} and binding=${binding}`;
    await ctx.tx`update app_private.push_outbox set state='cancelled',last_reason='unregistered'
      where registration_id in (select id from app_private.push_registrations where user_id=${ctx.actor.id} and installation_id=${installation} and kind=${kind} and binding=${binding}) and state in ('pending','sending')`;
    return {ok:true};
  }
  if(!['register_device','register_live_activity_token'].includes(action)) throw new AppServiceError('invalid_action','Unknown push action.');
  if(!pushCapabilities(ctx.config).registration_enabled) throw new AppServiceError('push_unconfigured','Push registration is not configured for this isolated app.',503);
  const bundleID=allowedPushBundle(ctx.config)!;
  if(body.bundle_id!==bundleID) throw new AppServiceError('push_topic_forbidden','This push registration belongs to a different app.',403);
  const environment=body.environment;
  if(!['sandbox','production'].includes(environment)) throw new AppServiceError('invalid_environment','Invalid APNs environment.');
  const token=text(live?body.live_activity_token:body.apns_token,256).replace(/[<>\s-]/g,'').toLowerCase();
  if(!/^[0-9a-f]{32,256}$/.test(token)||token.length%2) throw new AppServiceError('invalid_push_token','Invalid push token.');
  let roomID:string|null=null,matchID:string|null=null;
  if(kind==='activity') {
    roomID=requireUUID(body.room_id,'room_id');matchID=text(body.match_id);
    const [room]=await ctx.tx`select state,closed from full_game_private.rooms where id=${roomID} for share`;
    if(!room||room.closed||room.state.match_id!==matchID||!(room.state.players||[]).some((p:any)=>p.user_id===ctx.actor.id)
      ||(room.state.departed_player_emails||[]).includes(ctx.actor.email)) throw new AppServiceError('activity_membership_mismatch','This activity does not belong to the current match.',403);
  }
  await ctx.tx`select pg_advisory_xact_lock(hashtextextended(${installation+':'+kind+':'+binding},0))`;
  const hash=await digest(token);
  const existing=await ctx.tx`select id,user_id,installation_id,binding from app_private.push_registrations where (installation_id=${installation} and kind=${kind} and binding=${binding}) or (bundle_id=${bundleID} and environment=${environment} and kind=${kind} and token_hash=${hash}) for update`;
  if(existing.some((r:any)=>r.user_id!==ctx.actor.id)) throw new AppServiceError('push_owner_mismatch','This registration belongs to another signed-in account.',409);
  if(existing.length>1||existing.some((r:any)=>r.installation_id!==installation||r.binding!==binding))throw new AppServiceError('push_binding_mismatch','Unregister the previous token binding before replacing it.',409);
  const id=existing[0]?.id||crypto.randomUUID();
  const descriptor={user_id:ctx.actor.id,bundle_id:bundleID,environment,kind,binding};
  const ciphertext=await encryptToken(token,ctx.config.PUSH_TOKEN_ENCRYPTION_KEY,registrationBinding(descriptor));
  const preferences=Object.fromEntries(['friend_requests','room_invites','game_updates','announcements'].map(k=>[k,body.preferences?.[k]!==false]));
  await ctx.tx`insert into app_private.push_registrations(id,user_id,installation_id,kind,binding,room_id,match_id,bundle_id,environment,token_hash,token_ciphertext,locale,alert_authorized,preferences,updated_at)
    values(${id},${ctx.actor.id},${installation},${kind},${binding},${roomID},${matchID},${bundleID},${environment},${hash},${ctx.tx.json(ciphertext)},${text(body.locale,12)||'en'},${body.alert_authorized===true},${ctx.tx.json(preferences)},${ctx.now})
    on conflict(id) do update set token_hash=excluded.token_hash,token_ciphertext=excluded.token_ciphertext,locale=excluded.locale,alert_authorized=excluded.alert_authorized,preferences=excluded.preferences,active=true,updated_at=excluded.updated_at`;
  return {ok:true,registration_id:id,updated_at:ctx.now.toISOString()};
}

export async function enqueueAppPush(ctx:AppContext,event:{id:string,event_type:string,recipient_id:string,room_id?:string|null,data:Record<string,any>,actor_id?:string}) {
  const preference=event.event_type.includes('friend')?'friend_requests':event.event_type.includes('invite')?'room_invites':event.event_type.includes('announcement')?'announcements':'game_updates';
  const registrations=await ctx.tx`select id,locale from app_private.push_registrations where user_id=${event.recipient_id} and kind='device' and active and alert_authorized and coalesce((preferences->>${preference})::boolean,true)`;
  for(const row of registrations) {
    const locale=String(row.locale).toLowerCase().split('-')[0];
    const payload={aps:{alert:{title:text(event.data['title_'+locale]||event.data.title_en||event.data.title,160),body:text(event.data['body_'+locale]||event.data.body_en||event.data.body,500)},'mutable-content':1},
      event_id:event.id,notification_event_id:event.id,type:event.event_type,room_id:event.room_id||null,deep_link:text(event.data.deep_link,500),
      ...(event.data.announcement_id?{announcement_id:event.data.announcement_id,announcement_revision:event.data.announcement_revision}: {})};
    await ctx.tx`insert into app_private.push_outbox(event_key,registration_id,user_id,room_id,payload,expires_at)
    values(${event.id},${row.id},${event.recipient_id},${event.room_id||null},${ctx.tx.json(payload)},${new Date(ctx.now.getTime()+3600_000)}) on conflict(event_key,registration_id) do nothing`;
  }
}

export async function cancelAppPush(ctx:AppContext,eventIDs:string[]) {
  if(!eventIDs.length)return;
  await ctx.tx`update app_private.push_outbox set state='cancelled',last_reason='source_cancelled' where event_key in ${ctx.tx(eventIDs)} and state in ('pending','sending')`;
}

/** The caller supplies a server-built, role-redacted ActivityKit projection.
 * This helper is never routed directly from a native command body. */
export async function enqueueLiveActivity(ctx:AppContext,input:{eventID:string,roomID:string,matchID:string,contentState:Record<string,unknown>,end:boolean}) {
  const registrations=await ctx.tx`select id,user_id from app_private.push_registrations where room_id=${input.roomID} and match_id=${input.matchID} and kind='activity' and active`;
  const payload={aps:{timestamp:Math.floor(ctx.now.getTime()/1000),event:input.end?'end':'update','content-state':input.contentState,
    ...(input.end?{'dismissal-date':Math.floor(ctx.now.getTime()/1000)+60}:{'stale-date':Math.floor(ctx.now.getTime()/1000)+90})}};
  for(const row of registrations)await ctx.tx`insert into app_private.push_outbox(event_key,registration_id,user_id,room_id,match_id,payload,kind,expires_at)
    values(${input.eventID},${row.id},${row.user_id},${input.roomID},${input.matchID},${ctx.tx.json(payload)},'liveactivity',${new Date(ctx.now.getTime()+3600_000)}) on conflict(event_key,registration_id) do nothing`;
}
