import { experimentalBundleID } from './assertion.mjs';
export const productionProject = 'bbkfsgnordtdiblgdzkg';
export function experimentalConfiguration(environment) {
  if (environment.GAME_CENTER_ENVIRONMENT !== 'experimental-000') throw new Error('Experimental backend marker is required.');
  const origin = environment.SUPABASE_URL || '';
  const url = new URL(origin);
  const local = ['127.0.0.1', 'localhost', 'kong'].includes(url.hostname);
  const project = environment.GAME_CENTER_PROJECT_REF || '';
  if (origin !== url.origin || url.username || url.password || url.hostname.includes(productionProject) || project === productionProject ||
      (local ? url.protocol !== 'http:' : (url.protocol !== 'https:' || !/^[a-z]{20}$/.test(project) || url.hostname !== project + '.supabase.co' || url.port))) {
    throw new Error('Only an explicit nonproduction Game Center project is allowed.');
  }
  if (!environment.SUPABASE_ANON_KEY || !environment.SUPABASE_SERVICE_ROLE_KEY) throw new Error('Server Auth configuration is missing.');
  const database = new URL(environment.SUPABASE_DB_URL || '');
  const localDB = ['127.0.0.1', 'localhost', 'db'].includes(database.hostname);
  const direct = database.hostname === 'db.' + project + '.supabase.co' && database.username === 'postgres' && ['', '5432'].includes(database.port);
  const pooler = /^aws-[0-9]+-[a-z0-9-]+\.pooler\.supabase\.com$/.test(database.hostname) && database.username === 'postgres.' + project && ['5432', '6543'].includes(database.port);
  if (!['postgres:', 'postgresql:'].includes(database.protocol) || database.href.includes(productionProject) ||
      (local ? (!localDB || database.username !== 'postgres') : (!direct && !pooler))) {
    throw new Error('Auth and database must target the same isolated environment.');
  }
  return {origin, local, project, databaseURL: database.href, anonKey: environment.SUPABASE_ANON_KEY,
    serviceRoleKey: environment.SUPABASE_SERVICE_ROLE_KEY, bundleID: experimentalBundleID};
}
