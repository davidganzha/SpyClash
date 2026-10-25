import {createActorAuthenticator} from '../backend/service.mjs';
import {createExperimentalRuntime} from '../backend/runtime.mjs';
import {ensureProfile} from '../../supabase-game-core/supabase/functions/app-services/profile.ts';
import {createAppHandler} from '../../supabase-game-core/supabase/functions/app-services/handler.ts';
import {AppServiceError} from '../../supabase-game-core/supabase/functions/app-services/contracts.ts';
import {createHandler as createGameHandler} from '../../supabase-game-core/supabase/functions/full-game-core/handler.ts';
const runtime=createExperimentalRuntime(Deno.env.toObject(),ensureProfile);
if(!runtime.config.local)throw new Error('Local router refuses cloud environments.');
const authenticate=createActorAuthenticator(runtime.auth,()=>new AppServiceError('unauthorized','Sign in to continue.',401));
const app=createAppHandler({db:runtime.db,authenticate,config:{}});
const game=createGameHandler({db:runtime.db,authenticate});
Deno.serve({hostname:'127.0.0.1',port:56330,onListen:()=>console.log('Experimental 000 backend listening at http://127.0.0.1:56330 (loopback only).')},async request=>{
  const url=new URL(request.url);
  if(url.pathname==='/functions/v1/game-center-session')return runtime.handler(request);
  if(url.pathname==='/functions/v1/app-services')return app(request);
  if(url.pathname==='/functions/v1/full-game-core')return game(request);
  // Native classical registration and token refresh talk to genuine local Auth.
  // Never proxy admin operations, arbitrary URLs, or a cloud environment.
  if(/^\/auth\/v1\/(signup|token|user|verify|otp|resend|recover|logout)$/.test(url.pathname)&&['GET','POST','PUT'].includes(request.method)){
    const headers=new Headers(request.headers);headers.delete('host');
    return fetch(runtime.config.origin+url.pathname+url.search,{method:request.method,headers,
      body:['GET','HEAD'].includes(request.method)?undefined:await request.arrayBuffer(),redirect:'manual',signal:AbortSignal.timeout(15000)});
  }
  return Response.json({code:'not_found'},{status:404});
});
