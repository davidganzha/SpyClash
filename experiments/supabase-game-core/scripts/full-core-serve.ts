// Loopback-only test host for the exact cloud handler and PostgreSQL service.
import postgres from '../node_modules/postgres/src/index.js';
import { createHandler } from '../supabase/functions/full-game-core/handler.ts';
import { GameServiceError } from '../supabase/functions/full-game-core/service.ts';
const origin = Deno.env.get('SUPABASE_URL') || '';
const databaseURL = Deno.env.get('DATABASE_URL') || '';
if (new URL(origin).hostname !== '127.0.0.1' || new URL(databaseURL).hostname !== '127.0.0.1') throw new Error('Loopback test stack required.');
const db = postgres(databaseURL, { prepare: false, max: 4, idle_timeout: 15, connect_timeout: 8 });
const authenticate = async (token: string) => {
  const response = await fetch(origin + '/auth/v1/user', { headers: { Authorization: 'Bearer ' + token, apikey: Deno.env.get('SUPABASE_ANON_KEY') || '' } });
  if (response.status === 401 || response.status === 403) throw new GameServiceError('unauthorized', 'Session expired.', 401);
  if (!response.ok) throw new Error('Auth unavailable');
  return response.json();
};
Deno.serve({ hostname: '127.0.0.1', port: 56325 }, createHandler({ db, authenticate }));
