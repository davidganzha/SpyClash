import postgres from 'postgres';
import { assertIsolatedSupabase } from '../app-services/legacy-provider.ts';
import { createGenerationRewardSSVHandler } from '../app-services/generation-rewards.ts';
import { createRewardedGenerationSSVGateway } from './handler.ts';

const config = Deno.env.toObject();
const origin = assertIsolatedSupabase(config);
const local = new URL(origin).protocol === 'http:';
if (!config.SUPABASE_DB_URL) throw new Error('Missing server database connection.');
const connection = new URL(config.SUPABASE_DB_URL);
if (!local) {
  if (connection.hostname !== 'db.bbkfsgnordtdiblgdzkg.supabase.co' || connection.username !== 'postgres') {
    throw new Error('Unexpected database configuration.');
  }
  connection.hostname = 'aws-0-eu-west-1.pooler.supabase.com';
  connection.port = '6543';
  connection.username = 'postgres.bbkfsgnordtdiblgdzkg';
}
const db = postgres(connection.href, {prepare: false, max: 3, idle_timeout: 15, connect_timeout: 8, ...(local ? {} : {ssl: 'require'})});
// The native handler rechecks Google's signature before its locked transaction.
// Keeping that contract also protects its existing authenticated route.
Deno.serve(createRewardedGenerationSSVGateway({config, native: createGenerationRewardSSVHandler(db)}));
