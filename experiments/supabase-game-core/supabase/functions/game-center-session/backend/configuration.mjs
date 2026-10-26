import {gameCenterBundleID} from './assertion.mjs';

export const mainProjectReference = 'bbkfsgnordtdiblgdzkg';
/** Deployment is a separate operation. Even a deployed endpoint stays disabled
 * until the operator explicitly enables this exact main application. */
export function gameCenterConfiguration(environment) {
  if (environment.GAME_CENTER_ENABLED !== 'true') throw new Error('Game Center is not enabled.');
  const origin = environment.SUPABASE_URL || '';
  const url = new URL(origin);
  const local = origin === 'http://127.0.0.1:56321';
  const cloud = origin === 'https://' + mainProjectReference + '.supabase.co';
  if ((!local && !cloud) || origin !== url.origin ||
      environment.GAME_CENTER_ENVIRONMENT !== (local ? 'local-test' : 'main') ||
      (environment.GAME_CENTER_PROJECT_REF && environment.GAME_CENTER_PROJECT_REF !== mainProjectReference)) {
    throw new Error('Game Center requires the exact main application or dedicated loopback test stack.');
  }
  if (!environment.SUPABASE_ANON_KEY || !environment.SUPABASE_SERVICE_ROLE_KEY) throw new Error('Server Auth configuration is missing.');
  const database = new URL(environment.SUPABASE_DB_URL || '');
  const direct = database.hostname === 'db.' + mainProjectReference + '.supabase.co' && database.username === 'postgres' && ['', '5432'].includes(database.port);
  const pooler = database.hostname === 'aws-0-eu-west-1.pooler.supabase.com' && database.username === 'postgres.' + mainProjectReference && ['5432', '6543'].includes(database.port);
  if (!['postgres:', 'postgresql:'].includes(database.protocol) || database.pathname !== '/postgres' ||
      (local ? (database.hostname !== '127.0.0.1' || database.port !== '56322' || database.username !== 'postgres') : (!direct && !pooler))) {
    throw new Error('Auth and database must target the same main application.');
  }
  if (cloud && direct) {
    database.hostname = 'aws-0-eu-west-1.pooler.supabase.com';
    database.username = 'postgres.' + mainProjectReference;
    database.port = '6543';
  }
  return {origin, local, project: mainProjectReference, databaseURL: database.href,
    anonKey: environment.SUPABASE_ANON_KEY, serviceRoleKey: environment.SUPABASE_SERVICE_ROLE_KEY, bundleID: gameCenterBundleID};
}
