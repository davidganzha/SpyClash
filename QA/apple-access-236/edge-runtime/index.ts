import { runMembershipConcurrency } from '../membership-concurrency.ts';
import { createAppHandler } from '../../../experiments/supabase-game-core/supabase/functions/app-services/handler.ts';

let running = false;
Deno.serve(async request => {
  if (new URL(request.url).pathname !== '/run') return Response.json({ ready: true, runtime: Deno.version });
  if (running) return Response.json({ error: 'busy' }, { status: 409 });
  running = true;
  try {
    return Response.json(await runMembershipConcurrency(Deno.env.get('SPYCLASH_TEST_MODE') || 'transaction', 16, {
      createAppHandler, sourceSHA256: Deno.env.get('SPYCLASH_TEST_HANDLER_SHA256') || 'not-recorded',
    }));
  } catch (error) {
    return Response.json({ ok: false, name: error instanceof Error ? error.name : 'unknown', message: error instanceof Error ? error.message : 'unknown' }, { status: 500 });
  } finally { running = false; }
});
