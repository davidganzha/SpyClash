import postgres from 'postgres';
import { createLegacySessionHandler } from './service.ts';
import { assertIsolatedSupabase } from '../app-services/legacy-provider.ts';
import { ensureProfile } from '../app-services/profile.ts';
import { prepareLegacyImport, applyLegacyImport } from '../app-services/legacy-import.ts';

const config = Deno.env.toObject();
const origin = assertIsolatedSupabase(config);
const local = new URL(origin).protocol === 'http:';
if (!config.SUPABASE_DB_URL) throw new Error('Missing server database connection.');
const connection = new URL(config.SUPABASE_DB_URL);
if (!local) {
  if (connection.hostname !== 'db.bbkfsgnordtdiblgdzkg.supabase.co' || connection.username !== 'postgres') throw new Error('Unexpected staging database configuration.');
  connection.hostname = 'aws-0-eu-west-1.pooler.supabase.com';
  connection.port = '6543';
  connection.username = 'postgres.bbkfsgnordtdiblgdzkg';
}
const db = postgres(connection.href, {prepare: false, max: 3, idle_timeout: 15, connect_timeout: 8, ...(local ? {} : {ssl: 'require'})});
Deno.serve(createLegacySessionHandler({db, config, prepareImport: prepareLegacyImport,
  applyImport: async (ctx, snapshot) => ({complete: (await applyLegacyImport(ctx, snapshot)).complete === true}), ensureProfile}));
