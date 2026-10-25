import {randomBytes,randomUUID} from 'node:crypto';
import {mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {experimentalProjectReference} from '../backend/cloud-configuration.mjs';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const origin='https://'+experimentalProjectReference+'.supabase.co';
if(experimentalProjectReference!=='ovowoixuyabccgkxcexp')throw new Error('Cloud smoke test target changed; review before use.');
const key='sb_publishable_t8dcSC9JZ015cUtZsYTVpw_aO1zB0bj';
const recordPath=resolve(root,'.local/cloud-smoke-user.json');
mkdirSync(resolve(root,'.local'),{recursive:true,mode:0o700});
async function request(path,body,token){
 const response=await fetch(origin+path,{method:'POST',headers:{apikey:key,'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},body:JSON.stringify(body),redirect:'error',signal:AbortSignal.timeout(30000)});
 const value=await response.json();
 if(!response.ok)throw new Error('HTTP '+response.status+' '+String(value.error_code||value.code||value.error||'request_failed')+' '+String(value.msg||value.message||''));
 return value;
}
const action=process.argv[2];
if(action==='signup'){
 const marker=randomUUID();const record={email:'gc000-'+marker+'@example.com',password:randomBytes(24).toString('base64url')+'aA1!',userID:''};
 writeFileSync(recordPath,JSON.stringify(record),{mode:0o600});
 try{
  const response=await request('/auth/v1/signup',{email:record.email,password:record.password,data:{full_name:'GC000 cloud smoke '+marker}});
  record.userID=response.user?.id||response.id;
  writeFileSync(recordPath,JSON.stringify(record),{mode:0o600});
  console.log(JSON.stringify({email:record.email,userID:record.userID,needsConfirmation:!response.access_token}));
 }catch(error){console.log(JSON.stringify({email:record.email,error:String(error.message)}));process.exitCode=1;}
}else if(action==='verify'){
 const record=JSON.parse(readFileSync(recordPath,'utf8'));
 let session=await request('/auth/v1/token?grant_type=password',{email:record.email,password:record.password});
 if(session.user.id!==record.userID)throw new Error('Unexpected test actor');
 const current=await request('/functions/v1/app-services',{service:'profile',action:'current'},session.access_token);
 if(current.id!==record.userID||current.onboarding_completed!==false)throw new Error('Initial profile was not new and unfinished');
 const saved=await request('/functions/v1/app-services',{service:'profile',action:'onboarding',language:'en',onboarding_version:1,acquisition_source:'other',request_id:randomUUID()},session.access_token);
 const readback=await request('/functions/v1/app-services',{service:'profile',action:'current'},session.access_token);
 if(!saved.onboarding_completed||!readback.onboarding_completed)throw new Error('Onboarding did not persist');
 const refreshed=await request('/auth/v1/token?grant_type=refresh_token',{refresh_token:session.refresh_token});
 if(refreshed.user.id!==record.userID)throw new Error('Refresh changed identity');
 await request('/functions/v1/app-services',{service:'profile',action:'current'},refreshed.access_token);
 const response=await fetch(origin+'/auth/v1/logout?scope=local',{method:'POST',headers:{apikey:key,Authorization:'Bearer '+refreshed.access_token},signal:AbortSignal.timeout(15000)});
 if(!response.ok)throw new Error('Logout failed');
 console.log(JSON.stringify({userID:record.userID,passwordLogin:true,newProfile:true,onboardingWriteReadback:true,refresh:true,logout:true}));
}else throw new Error('Use signup then exact test-user confirmation, then verify. Delete only this exact test user afterward.');
