import {mkdirSync,cpSync,writeFileSync,readFileSync,existsSync,readdirSync} from 'node:fs';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=resolve(root,'../supabase-game-core/supabase');
const out=resolve(root,'.local/isolated-package');
// Preparation only. No auth login, project creation/linking, deployment, database reset, or secrets.
if(existsSync(resolve(out,'supabase/.temp/project-ref')))throw new Error('Refusing to overwrite a cloud-linked package.');
mkdirSync(resolve(out,'supabase/functions/game-center-session'),{recursive:true});
for(const name of ['app-services','full-game-core'])cpSync(resolve(source,'functions',name),resolve(out,'supabase/functions',name),{recursive:true});
cpSync(resolve(source,'migrations'),resolve(out,'supabase/migrations'),{recursive:true});
cpSync(resolve(root,'backend'),resolve(out,'supabase/functions/game-center-session/backend'),{recursive:true});
for(const [name,template] of [['game-center-session','game-center-index.ts'],['app-services','app-services-index.ts'],['full-game-core','full-game-core-index.ts']]){
  cpSync(resolve(root,'templates',template),resolve(out,'supabase/functions',name,'index.ts'));
  cpSync(resolve(root,'deno.json'),resolve(out,'supabase/functions',name,'deno.json'));
  if(existsSync(resolve(root,'deno.lock')))cpSync(resolve(root,'deno.lock'),resolve(out,'supabase/functions',name,'deno.lock'));
}
// The inherited cleanup worker is scoped to the old backend. Replace only its
// origin guard in the generated copy with the same strict experiment guard.
const lifecycle=resolve(out,'supabase/functions/app-services/lifecycle.ts');
let lifecycleSource=readFileSync(lifecycle,'utf8');
const legacyGuard="  if (origin !== 'https://bbkfsgnordtdiblgdzkg.supabase.co' && !/^http:\\/\\/127\\.0\\.0\\.1:56321$/.test(origin)) throw new AppServiceError('unsafe_auth_origin','Unexpected Auth origin.',503);";
if(!lifecycleSource.includes(legacyGuard))throw new Error('Inherited lifecycle guard changed; review the isolated adapter.');
lifecycleSource="import {experimentalConfiguration} from '../game-center-session/backend/configuration.mjs';\n"+lifecycleSource.replace(legacyGuard,'  experimentalConfiguration(config);');
writeFileSync(lifecycle,lifecycleSource);
writeFileSync(resolve(out,'supabase/config.toml'),'project_id = "spyclash-game-center-000"\n\n# Each handler independently verifies its credential.\n[functions.game-center-session]\nverify_jwt = false\n[functions.app-services]\nverify_jwt = false\n[functions.full-game-core]\nverify_jwt = false\n');
const migrations=resolve(out,'supabase/migrations');
let names=readdirSync(migrations).filter(n=>n.endsWith('_game_center_000.sql'));
if(names.length===0){
  const result=spawnSync(resolve(root,'node_modules/.bin/supabase'),['migration','new','game_center_000','--workdir',out],{encoding:'utf8'});
  if(result.status!==0)throw new Error('Could not generate isolated migration filename.');
  names=readdirSync(migrations).filter(n=>n.endsWith('_game_center_000.sql'));
}
if(names.length!==1)throw new Error('Ambiguous generated Game Center migration.');
writeFileSync(resolve(migrations,names[0]),readFileSync(resolve(root,'supabase/schemas/game_center.sql')));
writeFileSync(resolve(out,'SERVER-ENVIRONMENT.example'),'GAME_CENTER_ENVIRONMENT=experimental-000\nGAME_CENTER_PROJECT_REF=ovowoixuyabccgkxcexp\n# The marker and ref above are compiled by cloud-configuration.mjs; conflicting overrides fail.\n# SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY and SUPABASE_DB_URL are server-managed.\n# Never copy the 197/198 production environment or add keys to the iOS app.\n');
console.log(`Prepared isolated package: ${out}`);
