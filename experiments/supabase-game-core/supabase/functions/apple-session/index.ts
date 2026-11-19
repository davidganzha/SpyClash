import postgres from 'npm:postgres@3.4.9';
import {ensureProfile} from '../app-services/profile.ts';
import {appleConfiguration} from './configuration.ts';
import {createAppleAPI,createAppleVerifier} from './apple.ts';
import {createAppleRepository} from './repository.ts';
import {createAppleHandler,createAuthAPI} from './service.ts';
const environment=Deno.env.toObject();
// Deployment does not enable sign-in, create accounts or change a provider.
if(environment.APPLE_SESSION_ENABLED!=='true') {
  Deno.serve(()=>Response.json({code:'apple_session_disabled',retryable:false},{status:503,headers:{'Cache-Control':'no-store'}}));
} else {
  const config=appleConfiguration(environment);
  const db=postgres(config.databaseURL,{prepare:false,max:3,idle_timeout:15,connect_timeout:8,onnotice:()=>{},...(config.local?{}:{ssl:'require'})});
  Deno.serve(createAppleHandler({config,repository:createAppleRepository(db,config,ensureProfile),auth:createAuthAPI(config),apple:createAppleAPI(config),verifier:createAppleVerifier(config)}));
}
