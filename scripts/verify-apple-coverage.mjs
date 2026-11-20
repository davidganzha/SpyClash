// Read-only verifier for a fixed, privately reviewed historical Apple cohort.
// Dependencies expose reads and authenticated decryption, never entity writes.
export function createCoverageVerifier({authenticate,targets,expiresAt,readCredential,readUser,identityKey,verifyEncryptedBinding,now=()=>new Date()}) {
  const fail=code=>{throw Object.assign(new Error(code),{coverageCode:code});};
  const fields=['source_record_id','source_revision','identity_key','subject_key','legacy_user_id','user_id'];
  if(!Array.isArray(targets)||!targets.length||targets.length>200||!Number.isFinite(Date.parse(expiresAt)))throw Error('invalid_coverage_plan');
  for(const field of fields)if(new Set(targets.map(t=>t[field])).size!==targets.length)throw Error('ambiguous_coverage_plan');
  return async request=>{
    const headers={'Cache-Control':'no-store','Content-Type':'application/json'};
    try{
      const actor=await authenticate(request);
      if(actor?.role!=='admin')return Response.json({code:'admin_required'},{status:403,headers});
      if(request.method!=='POST')return Response.json({code:'method_not_allowed'},{status:405,headers});
      if(now().getTime()>=Date.parse(expiresAt))return Response.json({code:'coverage_plan_expired'},{status:410,headers});
      const text=await request.text();if(text.length>256)fail('invalid_request');
      const body=JSON.parse(text||'{}');if(!body||Array.isArray(body)||Object.keys(body).length)fail('invalid_request');
      const records=[];
      for(const target of targets){
        const row=await readCredential(target.source_record_id),user=await readUser(target.legacy_user_id);
        if(!row||row.id!==target.source_record_id||row.revision!==target.source_revision||row.identity_key!==target.identity_key||row.subject_key!==target.subject_key||row.client_id!=='com.spyclash.ios'||row.credential_kind!=='token'||row.state!=='pending'||row.user_id||row.manual_revocation_required)fail('source_credential_changed');
        if(!user||user.id!==target.legacy_user_id||user.disabled===true||user.is_service===true||user.is_verified!==true||await identityKey(user.email)!==target.identity_key)fail('source_user_conflict');
        if(!await verifyEncryptedBinding(row))fail('grant_binding_unverified');
        records.push({...target,client_id:row.client_id,source_state:row.state,encrypted_binding_verified:true,source_user_verified:true});
      }
      return Response.json({version:1,captured_at:now().toISOString(),verified_count:records.length,records},{headers});
    }catch(error){
      const allowed=new Set(['invalid_request','source_credential_changed','source_user_conflict','grant_binding_unverified']);
      const code=allowed.has(error?.coverageCode)?error.coverageCode:'coverage_verification_failed';
      return Response.json({code},{status:409,headers});
    }
  };
}
