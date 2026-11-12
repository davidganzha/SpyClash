import {createAppleVerifierFixtures} from '../../../experiments/supabase-game-core/tests/app-services/apple-verifier-fixtures.ts';
import {runAppleVerifierRegressionCases} from '../../../experiments/supabase-game-core/tests/app-services/apple-verifier-regression.ts';
import {ensureAppleX509Compatibility} from '../../../experiments/supabase-game-core/supabase/functions/app-services/billing-rules/apple-x509-compatibility.ts';
const fixtures=createAppleVerifierFixtures('http://127.0.0.1:9000');
ensureAppleX509Compatibility(fixtures.rootDER);
let running=false;
Deno.serve(async request=>{
 const path=new URL(request.url).pathname;
 if(path==='/leaf'||path==='/intermediate')return fixtures.respond(request);
 if(path!=='/run')return Response.json({ready:true,runtime:Deno.version});
 if(running)return Response.json({error:'busy'},{status:409});
 running=true;
 try{const results=await runAppleVerifierRegressionCases(fixtures);return Response.json({ok:true,runtime:Deno.version,count:results.length,results});}
 catch(error){const messages=[];let e:any=error;for(let i=0;e&&i<5;i++,e=e.cause)messages.push({message:e.message,status:e.status,stack:e.stack});return Response.json({ok:false,runtime:Deno.version,errors:messages},{status:500});}
 finally{running=false;}
});
