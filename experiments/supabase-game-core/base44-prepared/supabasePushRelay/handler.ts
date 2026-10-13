type Result = {delivered:boolean,retryable:boolean,invalidateToken:boolean,reason:string};
type Dependencies = {config:Record<string,string|undefined>,send:(value:any)=>Promise<Result>,now?:()=>number};

/** Narrow server-to-server relay. A native credential, API key, or guessed room
 * ID cannot authorize delivery. Supabase owns recipient/source checks; Base44
 * owns only its existing APNs signing material and canonical silent transport. */
export function createRelayHandler({config,send,now=Date.now}:Dependencies) {
  return async(request:Request):Promise<Response> => {
    const headers = {'Cache-Control':'no-store'};
    if (request.method !== 'POST') return Response.json({error:'method_not_allowed'},{status:405,headers});
    if (config.SPYCLASH_SUPABASE_PUSH_RELAY_ENABLED !== 'true' || !/^[a-f0-9]{64}$/i.test(config.SPYCLASH_SUPABASE_PUSH_RELAY_SECRET||'')) return Response.json({error:'relay_disabled'},{status:503,headers});
    try {
      if (Number(request.headers.get('content-length'))>12_000) return Response.json({error:'request_too_large'},{status:413,headers});
      const raw=await request.text();
      if (new TextEncoder().encode(raw).length>12_000) return Response.json({error:'request_too_large'},{status:413,headers});
      const timestamp=request.headers.get('X-SpyClash-Relay-Timestamp')||'',signature=request.headers.get('X-SpyClash-Relay-Signature')||'';
      if (!/^\d{10}$/.test(timestamp) || Math.abs(now()/1000-Number(timestamp))>60 || !/^[a-f0-9]{64}$/.test(signature)) return Response.json({error:'relay_unauthorized'},{status:401,headers});
      const key=await crypto.subtle.importKey('raw',Uint8Array.from(config.SPYCLASH_SUPABASE_PUSH_RELAY_SECRET!.match(/../g)!,v=>parseInt(v,16)),{name:'HMAC',hash:'SHA-256'},false,['verify']);
      const valid=await crypto.subtle.verify('HMAC',key,Uint8Array.from(signature.match(/../g)!,v=>parseInt(v,16)),new TextEncoder().encode(timestamp+'\n'+raw));
      if (!valid) return Response.json({error:'relay_unauthorized'},{status:401,headers});
      const body=JSON.parse(raw),uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
      if (body.version!==1 || body.source_project!=='bbkfsgnordtdiblgdzkg' || body.bundle_id!=='com.spyclash.ios'
        || !uuid.test(body.event_id||'') || !['alert','liveactivity'].includes(body.kind) || !['sandbox','production'].includes(body.environment)
        || !/^[a-f0-9]{32,256}$/.test(body.token||'') || body.token.length%2 || !/^[a-f0-9]{64}$/.test(body.collapse_id||'')
        || !Number.isInteger(body.expires_at) || body.expires_at<now()/1000 || body.expires_at>now()/1000+86_400
        || !body.payload?.aps || new TextEncoder().encode(JSON.stringify(body.payload)).length>4096) return Response.json({error:'relay_payload_invalid'},{status:422,headers});
      if (body.kind==='liveactivity' && (!['start','update','end'].includes(body.payload.aps.event) || body.payload.aps['content-state']?.privateIntel != null)) return Response.json({error:'relay_payload_invalid'},{status:422,headers});
      const result=await send({token:body.token,environment:body.environment,bundleID:body.bundle_id,kind:body.kind,
        collapseID:body.collapse_id,expiration:body.expires_at,payload:body.payload});
      return Response.json(result,{headers});
    } catch {return Response.json({error:'relay_unavailable'},{status:503,headers});}
  };
}
