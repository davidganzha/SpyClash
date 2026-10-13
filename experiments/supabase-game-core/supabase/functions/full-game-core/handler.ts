import { executeGame, GameServiceError } from './service.ts';
import { sessionGate, verifiedSessionID } from '../app-services/account-gate.ts';
import { AppServiceError } from '../app-services/contracts.ts';

export function createHandler({ db, authenticate }: { db: any; authenticate: (token: string) => Promise<any> }) {
  return async (request: Request): Promise<Response> => {
    if (request.method !== 'POST') return Response.json({ code: 'method_not_allowed', message: 'POST required', retryable: false }, { status: 405 });
    try {
      const bearer = request.headers.get('authorization') || '';
      if (!bearer.startsWith('Bearer ')) throw new GameServiceError('unauthorized', 'Sign in to play.', 401);
      // Always verify with Auth; decoding an unsigned JWT is never authority.
      const user = await authenticate(bearer.slice(7));
      if (!user?.id) throw new GameServiceError('unauthorized', 'Sign in to play.', 401);
      await sessionGate(db, user.id, verifiedSessionID(bearer.slice(7)));
      const raw = await request.text();
      if (raw.length > 131072) throw new GameServiceError('request_too_large', 'Request too large.', 413);
      let body;
      try { body = JSON.parse(raw); } catch { throw new GameServiceError('invalid_json', 'Invalid request.'); }
      if (!body || typeof body !== 'object' || Array.isArray(body)) throw new GameServiceError('invalid_json', 'Invalid request.');
      const actor = { id: user.id.toLowerCase(), email: user.id.toLowerCase() + '@example.test', full_name: String(user.user_metadata?.full_name || user.user_metadata?.name || 'Operative').slice(0, 80) };
      const result = await executeGame(db, actor, body);
      return Response.json(result.body, { status: result.status, headers: { 'Cache-Control': 'no-store' } });
    } catch (error: any) {
      if (error instanceof GameServiceError || error instanceof AppServiceError || (error.status >= 400 && error.status < 500)) {
        return Response.json({ code: error.code || 'action_rejected', message: error.message, retryable: error.retryable === true }, { status: error.status || 400 });
      }
      // Do not expose SQL text, raw records, credentials or room secrets.
      console.error('full-game-core request failed', String(error?.code || error?.name || 'internal'));
      return Response.json({ code: 'game_service_unavailable', message: 'The action could not be confirmed. Retry the saved request.', retryable: true }, { status: 503 });
    }
  };
}
