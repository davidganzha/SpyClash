import {cloudEnvironment} from '../game-center-session/backend/cloud-configuration.mjs';
import postgres from 'postgres';
import {experimentalConfiguration} from '../game-center-session/backend/configuration.mjs';
import {createAuthAPI,createActorAuthenticator} from '../game-center-session/backend/service.mjs';
import {createAppHandler} from './handler.ts';
import {AppServiceError} from './contracts.ts';
const config=experimentalConfiguration(cloudEnvironment(Deno.env.toObject()));
const db=postgres(config.databaseURL,{prepare:false,max:3,idle_timeout:15,connect_timeout:8,...(config.local?{}:{ssl:'require'})});
const auth=createAuthAPI(config);
const authenticate=createActorAuthenticator(auth,()=>new AppServiceError('unauthorized','Sign in to continue.',401));
// Only isolated Auth cleanup is enabled. No billing, push or Base44 configuration.
const isolated={GAME_CENTER_ENVIRONMENT:'experimental-000',GAME_CENTER_PROJECT_REF:config.project,
  SUPABASE_URL:config.origin,SUPABASE_ANON_KEY:config.anonKey,SUPABASE_SERVICE_ROLE_KEY:config.serviceRoleKey,SUPABASE_DB_URL:config.databaseURL};
Deno.serve(createAppHandler({db,authenticate,config:isolated}));
