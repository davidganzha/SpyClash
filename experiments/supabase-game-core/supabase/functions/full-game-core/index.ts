import postgres from 'postgres';
import { createHandler } from './handler.ts';
import { GameServiceError } from './service.ts';

const origin = Deno.env.get('SUPABASE_URL') || '';
const url = new URL(origin);
const local = ['127.0.0.1', 'localhost', 'kong'].includes(url.hostname);
if (!local && origin !== 'https://bbkfsgnordtdiblgdzkg.supabase.co') throw new Error('Only the isolated game-core test project is allowed.');
const databaseURL = Deno.env.get('SUPABASE_DB_URL');
if (!databaseURL) throw new Error('Missing server database connection.');
// The built-in URL is a direct connection. Per-isolate pools exhaust Nano's
// connection budget under concurrent requests; Supavisor transaction pooling
// holds one backend connection only for the complete atomic command.
// Host/port/user verified in this test project's Dashboard Connect dialog.
const connection = new URL(databaseURL);
if (!local) {
  if (connection.hostname !== 'db.bbkfsgnordtdiblgdzkg.supabase.co' || connection.username !== 'postgres') {
    throw new Error('Unexpected test database configuration.');
  }
  connection.hostname = 'aws-0-eu-west-1.pooler.supabase.com';
  connection.port = '6543';
  connection.username = 'postgres.bbkfsgnordtdiblgdzkg';
}
const db = postgres(connection.href, { prepare: false, max: 4, idle_timeout: 15, connect_timeout: 8, ...(local ? {} : { ssl: 'require' }) });
const authenticate = async (token: string) => {
  const key = Deno.env.get('SUPABASE_ANON_KEY');
  if (!key) throw new Error('Missing Auth client configuration.');
  const response = await fetch(origin + '/auth/v1/user', { headers: { Authorization: 'Bearer ' + token, apikey: key }, signal: AbortSignal.timeout(8000) });
  if (response.status === 401 || response.status === 403) throw new GameServiceError('unauthorized', 'Your session has expired.', 401);
  if (!response.ok) throw new Error('Auth unavailable');
  return await response.json();
};
Deno.serve(createHandler({ db, authenticate, config:Deno.env.toObject() }));
