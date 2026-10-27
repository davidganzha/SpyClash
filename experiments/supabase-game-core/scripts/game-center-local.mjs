import {spawnSync,spawn} from 'node:child_process';
import {readFileSync,existsSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {dirname,resolve} from 'node:path';
import {homedir} from 'node:os';
import postgres from 'postgres';
import {gameCenterConfiguration} from '../supabase/functions/game-center-session/backend/configuration.mjs';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
if(existsSync(resolve(root,'supabase/.temp/project-ref')))throw new Error('Local test directory must not be cloud linked.');
const environment={...process.env,DOCKER_HOST:process.env.DOCKER_HOST||`unix://${homedir()}/.colima/spyclash-supabase/docker.sock`};
if(new URL(environment.DOCKER_HOST).protocol!=='unix:')throw new Error('Local Docker socket required.');
const status=spawnSync(resolve(root,'node_modules/.bin/supabase'),['status','-o','json'],{cwd:root,env:environment,encoding:'utf8'});
if(status.status!==0)throw new Error('Start the dedicated local Supabase stack first.');
const info=JSON.parse(status.stdout);
const env={...environment,GAME_CENTER_ENABLED:'true',GAME_CENTER_ENVIRONMENT:'local-test',SUPABASE_URL:info.API_URL,
  SUPABASE_DB_URL:info.DB_URL,SUPABASE_ANON_KEY:info.ANON_KEY,SUPABASE_SERVICE_ROLE_KEY:info.SERVICE_ROLE_KEY};
if(!gameCenterConfiguration(env).local)throw new Error('Tests refuse cloud environments.');
const db=postgres(info.DB_URL,{max:1,onnotice:()=>{}});
try{
  const [schema]=await db`select to_regclass('app_private.profiles') is not null and to_regclass('app_private.main_account_deletions') is not null as present`;
  if(!schema.present)throw new Error('Existing app schema required; this runner never resets the stack.');
  await db.begin(async tx=>{
    await tx.unsafe(readFileSync(resolve(root,'supabase/functions/game-center-session/schema.sql'),'utf8'));
    await tx.unsafe(readFileSync(resolve(root,'supabase/migrations/20261026234309_native_game_center_ai_relay.sql'),'utf8'));
  });
}finally{await db.end();}
const regression=process.argv[2]==='legacy-regression';
const executable=regression?process.execPath:resolve(root,'node_modules/.bin/deno');
const args=regression?['--experimental-transform-types','--test','--test-concurrency=1',
  'tests/app-services/main-account-deletion.test.mjs','tests/app-services/legacy-billing-push.test.mjs','tests/app-services/legacy-session.test.mjs']
  :['run','--allow-net','--allow-env','--allow-read','--allow-write','--allow-run',
    '--config',resolve(root,'supabase/functions/game-center-session/deno.json'),resolve(root,'tests/game-center/integration-local.ts')];
const child=spawn(executable,args,{cwd:root,env:{...env,DATABASE_URL:info.DB_URL},stdio:'inherit'});
for(const signal of ['SIGINT','SIGTERM'])process.on(signal,()=>child.kill(signal));
child.on('exit',code=>{process.exitCode=code??1;});
