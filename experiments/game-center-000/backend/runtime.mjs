import postgres from 'npm:postgres@3.4.9';
import {experimentalConfiguration} from './configuration.mjs';
import {createRepository} from './repository.mjs';
import {createAuthAPI, createGameCenterHandler} from './service.mjs';
import {createAssertionVerifier} from './assertion.mjs';

export function createExperimentalRuntime(environment, ensureProfile) {
  const config = experimentalConfiguration(environment);
  const db = postgres(config.databaseURL, {prepare:false,max:3,idle_timeout:15,connect_timeout:8,onnotice:()=>{},...(config.local?{}:{ssl:'require'})});
  const repository = createRepository(db,{ensureProfile});
  const auth = createAuthAPI(config);
  return {config,db,repository,auth,handler:createGameCenterHandler({repository,auth,verify:createAssertionVerifier()})};
}
