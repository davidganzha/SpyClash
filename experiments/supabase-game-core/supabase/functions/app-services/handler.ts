import { AppServiceError, requireUUID } from './contracts.ts';
import { accountGate, sessionGate, verifiedSessionID } from './account-gate.ts';
import { executeApp, validateCommand, replayAppReceipt } from './dispatcher.ts';
import { prepareMembershipExternal } from './membership.ts';
import { prepareLegacyExternal } from './legacy.ts';
import { processAccountDeletionJobs } from './lifecycle.ts';
import { prepareMainAccountDeletion } from './main-account-deletion.ts';

export function createAppHandler({ db, authenticate, config = {}, fetch: fetcher = fetch }: {
  db: any; authenticate: (token: string) => Promise<any>;
  config?: Record<string, string | undefined>; fetch?: typeof fetch;
}) {
  return async (request: Request): Promise<Response> => {
    if (request.method !== 'POST') return Response.json({ code: 'method_not_allowed', message: 'POST required', retryable: false }, { status: 405 });
    try {
      const bearer = request.headers.get('authorization') || '';
      if (!bearer.startsWith('Bearer ')) throw new AppServiceError('unauthorized', 'Sign in to continue.', 401);
      const token = bearer.slice(7);
      const user = await authenticate(token);
      const id = requireUUID(user?.id, 'actor');
      await sessionGate(db, id, verifiedSessionID(token));
      const raw = await request.text();
      if (new TextEncoder().encode(raw).byteLength > 131072) throw new AppServiceError('request_too_large', 'Request too large.', 413);
      let body: any;
      try { body = JSON.parse(raw); } catch { throw new AppServiceError('invalid_json', 'Invalid request.'); }
      validateCommand(body);
      const actor = { id, email: id + '@example.test', contactEmail: String(user.email || ''),
        full_name: String(user.user_metadata?.full_name || user.user_metadata?.name || 'Operative').slice(0, 80),
        metadata: user.user_metadata || {} };
      // Avoid provider requests from already tombstoned accounts. executeApp
      // rechecks under the write lock after any external verification.
      if (!(body.service === 'profile' && body.action === 'delete')) {
        await db.begin(async (tx: any) => { await accountGate(tx, id); });
        const replay = await replayAppReceipt(db, actor, body);
        if (replay) return Response.json(replay.body, { status: replay.status, headers: { 'Cache-Control': 'no-store' } });
      }
      let evidence;
      if (body.service === 'membership') evidence = await prepareMembershipExternal({ actor, body, config }, { db, fetch: fetcher });
      if (body.service === 'legacy') evidence = await prepareLegacyExternal({ actor, body, config }, { db, fetch: fetcher });
      if (body.service === 'profile' && body.action === 'delete') evidence = await prepareMainAccountDeletion({ actor, body, config }, { db, fetch: fetcher });
      const result = await executeApp(db, actor, body, config, evidence);
      if (body.service === 'profile' && body.action === 'delete' && result.status === 200) {
        // The tombstone already committed. Auth cleanup is safe to retry after
        // a lost response; the durable job remains if Auth is unavailable.
        try { await processAccountDeletionJobs(db, config, fetcher, actor.id); } catch { /* worker retries */ }
      }
      return Response.json(result.body, { status: result.status, headers: { 'Cache-Control': 'no-store' } });
    } catch (error: any) {
      if (error instanceof AppServiceError) {
        return Response.json({ code: error.code, message: error.message, retryable: error.retryable }, { status: error.status, headers: { 'Cache-Control': 'no-store' } });
      }
      console.error('app-services request failed', String(error?.code || error?.name || 'internal'));
      return Response.json({ code: 'app_service_unavailable', message: 'The action could not be confirmed. Retry the saved request.', retryable: true }, { status: 503, headers: { 'Cache-Control': 'no-store' } });
    }
  };
}
