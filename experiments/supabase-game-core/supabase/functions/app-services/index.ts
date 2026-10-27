import postgres from 'postgres';
import { createAppHandler } from './handler.ts';
import { AppServiceError } from './contracts.ts';
import { createMaintenanceHandler } from './maintenance-handler.ts';
import { createNativeAIRelayHandler } from './native-ai-relay.ts';

const origin = Deno.env.get('SUPABASE_URL') || '';
const url = new URL(origin);
const local = ['127.0.0.1', 'localhost', 'kong'].includes(url.hostname);
if (!local && origin !== 'https://bbkfsgnordtdiblgdzkg.supabase.co') throw new Error('Only the isolated staging project is allowed.');
const databaseURL = Deno.env.get('SUPABASE_DB_URL');
if (!databaseURL) throw new Error('Missing server database connection.');
const connection = new URL(databaseURL);
if (!local) {
  if (connection.hostname !== 'db.bbkfsgnordtdiblgdzkg.supabase.co' || connection.username !== 'postgres') throw new Error('Unexpected staging database configuration.');
  connection.hostname = 'aws-0-eu-west-1.pooler.supabase.com';
  connection.port = '6543';
  connection.username = 'postgres.bbkfsgnordtdiblgdzkg';
}
const db = postgres(connection.href, { prepare: false, max: 3, idle_timeout: 15, connect_timeout: 8, ...(local ? {} : { ssl: 'require' }) });
const authenticate = async (token: string) => {
  const key = Deno.env.get('SUPABASE_ANON_KEY');
  if (!key) throw new Error('Missing Auth client configuration.');
  const response = await fetch(origin + '/auth/v1/user', { headers: { Authorization: 'Bearer ' + token, apikey: key }, signal: AbortSignal.timeout(8000) });
  if (response.status === 401 || response.status === 403) throw new AppServiceError('unauthorized', 'Your session has expired.', 401);
  if (!response.ok) throw new Error('Auth unavailable');
  return await response.json();
};
const config = Deno.env.toObject();
const app = createAppHandler({ db, authenticate, config });
const maintenance = createMaintenanceHandler(db, config);
const nativeAIRelay = createNativeAIRelayHandler(db, config);
Deno.serve(request => {
  const path=new URL(request.url).pathname;
  if(path.endsWith('/native-ai-relay/claim')||path.endsWith('/native-ai-relay/complete'))return nativeAIRelay(request);
  return path.endsWith('/maintenance')?maintenance(request):app(request);
});
