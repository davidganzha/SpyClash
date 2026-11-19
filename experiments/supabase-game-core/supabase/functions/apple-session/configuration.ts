import {type AppleConfig, clientID} from './contracts.ts';
export function appleConfiguration(env: Record<string,string>): AppleConfig {
  const fail = () => {throw new Error('Apple session server configuration is unavailable.');};
  if (env.APPLE_SESSION_ENABLED !== 'true' || env.APPLE_NATIVE_CLIENT_ID !== clientID) fail();
  const project = 'bbkfsgnordtdiblgdzkg', origin = env.SUPABASE_URL;
  const local = origin === 'http://127.0.0.1:56321';
  if ((!local && origin !== 'https://' + project + '.supabase.co') || env.APPLE_SESSION_ENVIRONMENT !== (local ? 'local-test' : 'main')) fail();
  const database = new URL(env.SUPABASE_DB_URL || '');
  const direct = database.hostname === 'db.' + project + '.supabase.co' && database.username === 'postgres' && ['', '5432'].includes(database.port);
  const pooler = database.hostname === 'aws-0-eu-west-1.pooler.supabase.com' && database.username === 'postgres.' + project && ['5432','6543'].includes(database.port);
  if (!['postgres:','postgresql:'].includes(database.protocol) || database.pathname !== '/postgres' || (local ? database.hostname !== '127.0.0.1' || database.port !== '56322' || database.username !== 'postgres' : !direct && !pooler)) fail();
  if (!local && direct) {database.hostname='aws-0-eu-west-1.pooler.supabase.com';database.username='postgres.'+project;database.port='6543';}
  for (const key of ['SUPABASE_ANON_KEY','SUPABASE_SERVICE_ROLE_KEY','SPYCLASH_PSEUDONYM_KEY','APPLE_TEAM_ID','APPLE_KEY_ID','APPLE_PRIVATE_KEY_P8_B64']) if (!env[key]) fail();
  let privateKeyPEM = ''; try {privateKeyPEM=atob(env.APPLE_PRIVATE_KEY_P8_B64);} catch {fail();}
  if (!privateKeyPEM.includes('-----BEGIN PRIVATE KEY-----') || !/^[A-Z0-9]{10}$/.test(env.APPLE_TEAM_ID) || !/^[A-Z0-9]{10}$/.test(env.APPLE_KEY_ID)) fail();
  const encryptionKey = env.APPLE_GRANT_ENCRYPTION_KEY || env.PUSH_TOKEN_ENCRYPTION_KEY || '';
  if (!encryptionKey || new TextEncoder().encode(env.SPYCLASH_PSEUDONYM_KEY.trim()).length < 32) fail();
  return {origin,databaseURL:database.href,local,anonKey:env.SUPABASE_ANON_KEY,serviceRoleKey:env.SUPABASE_SERVICE_ROLE_KEY,
    pseudonymKey:env.SPYCLASH_PSEUDONYM_KEY,encryptionKey,teamID:env.APPLE_TEAM_ID,keyID:env.APPLE_KEY_ID,privateKeyPEM,
    newAccountsEnabled:env.APPLE_NEW_ACCOUNTS_ENABLED==='true',migrationCoverageVerified:env.APPLE_MIGRATION_COVERAGE_VERIFIED==='true'};
}
