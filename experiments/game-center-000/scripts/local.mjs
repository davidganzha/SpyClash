import {spawnSync,spawn} from 'node:child_process';
import {readFileSync,existsSync,mkdirSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {dirname,resolve} from 'node:path';
import {homedir} from 'node:os';
import postgres from 'postgres';
import {experimentalConfiguration} from '../backend/configuration.mjs';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const prior=resolve(root,'../supabase-game-core');
const socket=resolve(homedir(),'.colima/spyclash-supabase/docker.sock');
const environment={...process.env,DOCKER_HOST:process.env.DOCKER_HOST||`unix://${socket}`};
const dockerURL=new URL(environment.DOCKER_HOST);
if(dockerURL.protocol!=='unix:')throw new Error('Local runner requires a local Docker socket.');
if(existsSync(resolve(prior,'supabase/.temp/project-ref')))throw new Error('The local reference directory must not be cloud linked.');
const result=spawnSync(resolve(root,'node_modules/.bin/supabase'),['status','-o','json'],{cwd:prior,env:environment,encoding:'utf8'});
if(result.status!==0)throw new Error('Start the dedicated local Supabase stack before running the experiment.');
const info=JSON.parse(result.stdout);
for(const [field,port] of [['API_URL','56321'],['DB_URL','56322']]){
  const url=new URL(info[field]);if(!['127.0.0.1','localhost'].includes(url.hostname)||url.port!==port)throw new Error('Unexpected local stack.');
}
const env={...environment,GAME_CENTER_ENVIRONMENT:'experimental-000',SUPABASE_URL:info.API_URL,SUPABASE_DB_URL:info.DB_URL,
  SUPABASE_ANON_KEY:info.ANON_KEY,SUPABASE_SERVICE_ROLE_KEY:info.SERVICE_ROLE_KEY};
experimentalConfiguration(env);
const db=postgres(info.DB_URL,{max:1,onnotice:()=>{}});
try{
  const [{present}]=await db`select to_regclass('app_private.profiles') is not null as present`;
  if(!present)throw new Error('The local stack needs the existing SpyClash app-services schema. This runner never resets it.');
  await db.begin(async tx=>{await tx.unsafe(readFileSync(resolve(root,'supabase/schemas/game_center.sql'),'utf8'));});
}finally{await db.end();}
mkdirSync(resolve(root,'.local'),{recursive:true,mode:0o700});
const action=process.argv[2];
if(action==='client-config'){
  // The anon key is intentionally public. Never emit Auth admin keys or DB credentials.
  console.log(JSON.stringify({backendURL:'http://127.0.0.1:56330',publishableKey:info.ANON_KEY},null,2));
}else if(action==='test'||action==='serve'){
  const file=action==='test'?'tests/integration-local.ts':'scripts/serve-local.ts';
  const child=spawn(resolve(root,'node_modules/.bin/deno'),['run','--allow-net','--allow-env','--allow-read','--allow-write','--allow-run','--config',resolve(root,'deno.json'),resolve(root,file)],{cwd:root,env,stdio:'inherit'});
  for(const signal of ['SIGINT','SIGTERM'])process.on(signal,()=>child.kill(signal));
  child.on('exit',code=>{process.exitCode=code??1;});
}else throw new Error('Use test, serve, or client-config.');
