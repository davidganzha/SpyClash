import {canonicalAdministratorRequest,transferReward,RewardTransferError,type Target} from './transfer.ts';
export function createRewardTransferHandler(deps:{targets:Target[];expiresAt:number;now?:()=>number;
  authenticate:(request:Request)=>Promise<any>;entities:(request:Request)=>any;withLease:(input:any)=>Promise<any>}) {
  return async(request:Request)=>{
    const headers={'Cache-Control':'no-store'},now=deps.now||Date.now;
    const fail=(status:number,code:string)=>Response.json({code},{status,headers});
    if(request.method!=='POST')return fail(405,'method_not_allowed');
    if(!deps.targets.length||!Number.isFinite(deps.expiresAt)||now()>=deps.expiresAt)return fail(410,'reward_transfer_expired');
    try {
      const canonical=canonicalAdministratorRequest(request);
      let user;try{user=await deps.authenticate(canonical);}catch{return fail(401,'authentication_required');}
      if(!user?.id||user.role!=='admin')return fail(403,'administrator_required');
      const raw=await request.text();if(raw.length>128)return fail(400,'invalid_request');
      const body=JSON.parse(raw);if(!body||Array.isArray(body)||Object.keys(body).length!==1||body.action!=='transfer')return fail(400,'invalid_request');
      const serverHeaders=new Headers(canonical.headers);
      const service=request.headers.get('Base44-Service-Authorization');if(service)serverHeaders.set('Base44-Service-Authorization',service);
      const entities=deps.entities(new Request(canonical.url,{method:'POST',headers:serverHeaders}));
      const records=[];
      for(const target of deps.targets) records.push(await deps.withLease({lifecycleStore:entities.BillingIdentityLifecycle,userID:target.legacy_user_id,
        action:(guard:any)=>transferReward(entities.GenerationReward,guard,target,new Date(now()))}));
      // Private operator receipt. Never log callback capabilities or user rows.
      return Response.json({version:1,records},{headers});
    } catch(error) {return fail(error instanceof RewardTransferError?409:503,error instanceof RewardTransferError?error.code:'reward_transfer_unavailable');}
  };
}
