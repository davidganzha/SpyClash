import {ensureProfile} from '../app-services/profile.ts';
import {createGameCenterRuntime} from './backend/runtime.mjs';

// No Auth/DB/network work happens while the feature is disabled. Enabling this
// is a separately approved deployment/configuration operation, never a client flag.
const environment = Deno.env.toObject();
if (environment.GAME_CENTER_ENABLED !== 'true') {
  Deno.serve(() => Response.json({code:'game_center_disabled',message:'Use another sign-in method.',retryable:false},
    {status:503,headers:{'Cache-Control':'no-store'}}));
} else {
  const runtime = createGameCenterRuntime(environment,ensureProfile);
  Deno.serve(runtime.handler);
}
