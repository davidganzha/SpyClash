import test from 'node:test';
import assert from 'node:assert/strict';
import {gameCenterConfiguration,mainProjectReference} from '../../supabase/functions/game-center-session/backend/configuration.mjs';

const local = {GAME_CENTER_ENABLED:'true',GAME_CENTER_ENVIRONMENT:'local-test',SUPABASE_URL:'http://127.0.0.1:56321',
  SUPABASE_DB_URL:'postgres://postgres:test@127.0.0.1:56322/postgres',SUPABASE_ANON_KEY:'public',SUPABASE_SERVICE_ROLE_KEY:'server'};
const cloud = {...local,GAME_CENTER_ENVIRONMENT:'main',SUPABASE_URL:`https://${mainProjectReference}.supabase.co`,
  SUPABASE_DB_URL:`postgres://postgres:test@db.${mainProjectReference}.supabase.co/postgres`};

test('only explicit main feature enable accepts matching main Auth and database',()=>{
  const config=gameCenterConfiguration(cloud);
  assert.equal(config.local,false);assert.equal(config.bundleID,'com.spyclash.ios');
  assert.equal(new URL(config.databaseURL).username,'postgres.'+mainProjectReference);
  assert.equal(gameCenterConfiguration(local).local,true);
  for(const input of [{...cloud,GAME_CENTER_ENABLED:undefined},{...cloud,GAME_CENTER_ENVIRONMENT:undefined},
    {...cloud,GAME_CENTER_ENVIRONMENT:'experimental-000'},{...cloud,GAME_CENTER_PROJECT_REF:'ovowoixuyabccgkxcexp'},
    {...cloud,SUPABASE_URL:'https://ovowoixuyabccgkxcexp.supabase.co'},
    {...cloud,SUPABASE_DB_URL:local.SUPABASE_DB_URL},{...local,SUPABASE_DB_URL:cloud.SUPABASE_DB_URL},
    {...local,SUPABASE_URL:'http://127.0.0.1:56321/path'},{...cloud,SUPABASE_SERVICE_ROLE_KEY:''}]) {
    assert.throws(()=>gameCenterConfiguration(input));
  }
});
