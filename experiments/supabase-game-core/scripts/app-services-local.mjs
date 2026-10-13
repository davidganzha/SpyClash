import { spawnSync, spawn } from 'node:child_process';
import { readFileSync, readdirSync, openSync, closeSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import postgres from 'postgres';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const env={...process.env,DOCKER_HOST:process.env.DOCKER_HOST||`unix://${homedir()}/.colima/spyclash-supabase/docker.sock`};
const status=spawnSync(resolve(root,'node_modules/.bin/supabase'),['status','-o','json'],{cwd:root,env,encoding:'utf8'});
if(status.status!==0)throw new Error('Start the existing isolated local Supabase stack.');
const info=JSON.parse(status.stdout);
for(const [key,port] of [['API_URL','56321'],['DB_URL','56322']]) {
  const url=new URL(info[key]);if(url.hostname!=='127.0.0.1'||url.port!==port)throw new Error('Unexpected local endpoint.');
}
const db=postgres(info.DB_URL,{max:1,onnotice:()=>{}});
try {
  await db.begin(async tx=>{
    await tx.unsafe(readFileSync(resolve(root,'supabase/schemas/full_game_core.sql'),'utf8'));
    for(const name of ['foundation','services','billing-push','legacy-session','legacy-import'])await tx.unsafe(readFileSync(resolve(root,`supabase/functions/app-services/${name}-schema.sql`),'utf8'));
    await tx`notify pgrst,'reload schema'`;
  });
}finally{await db.end();}
console.log('Applied full application schema to isolated local PostgreSQL.');
if(process.argv[2]==='apply')process.exit(0);
const runEnv={...env,SUPABASE_URL:info.API_URL,SUPABASE_ANON_KEY:info.ANON_KEY,SUPABASE_SERVICE_ROLE_KEY:info.SERVICE_ROLE_KEY,DATABASE_URL:info.DB_URL,APP_SERVICES_URL:'http://127.0.0.1:56326',FULL_CORE_URL:'http://127.0.0.1:56325'};
const log=openSync(resolve(root,'.local/app-services-server.log'),'w',0o600);
const server=spawn(resolve(root,'node_modules/.bin/deno'),['run','--allow-net=127.0.0.1:56321,127.0.0.1:56322,127.0.0.1:56325,127.0.0.1:56326','--allow-env','--allow-read','scripts/app-services-serve.ts'],{cwd:root,env:runEnv,stdio:['ignore',log,log]});closeSync(log);
try {
  let ready=false;
  for(let i=0;i<100;i++) {
    if(server.exitCode!==null)throw new Error('Local application server stopped; inspect .local/app-services-server.log.');
    try{ready=(await fetch(runEnv.APP_SERVICES_URL)).status===405;}catch{}
    if(ready)break;await new Promise(r=>setTimeout(r,100));
  }
  if(!ready)throw new Error('Local application server did not start.');
  const files=readdirSync(resolve(root,'tests/app-services')).filter(n=>n.endsWith('.test.mjs')).map(n=>'tests/app-services/'+n);
  if(!files.length)throw new Error('No application service tests.');
  const test=spawn(process.execPath,['--experimental-transform-types','--test','--test-concurrency=1',...files],{cwd:root,env:runEnv,stdio:'inherit'});
  process.exitCode=await new Promise(r=>test.once('exit',code=>r(code??1)));
} finally {
  if(server.exitCode===null&&server.signalCode===null){const stopped=new Promise(r=>server.once('exit',r));server.kill('SIGTERM');await stopped;}
}
