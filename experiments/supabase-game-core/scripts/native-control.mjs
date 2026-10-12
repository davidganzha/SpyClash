import http from 'node:http';
import { randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { requireAllowedTestTarget, requireLoopback, syntheticTestActors } from '../client/game-client.mjs';

export async function startNativeControl({ config, actors, transportURLs = {} }) {
  requireAllowedTestTarget(config.url, config);
  syntheticTestActors({ SUPABASE_TEST_ACTORS: JSON.stringify(Object.values(actors)) }, 1);
  for (const url of Object.values(transportURLs)) requireLoopback(url, 'native transport URL');
  const token = randomBytes(32).toString('hex');
  const queues = new Map(Object.keys(actors).map((id) => [id, []]));
  const histories = new Map(Object.keys(actors).map((id) => [id, []]));
  const results = new Map();
  const waiters = new Map();
  const knownControl = new Map();
  function json(res, status, data) {
    res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(data === undefined ? undefined : JSON.stringify(data));
  }
  const server = http.createServer(async (req, res) => {
    const supplied = Buffer.from(req.headers.authorization ?? '');
    const expected = Buffer.from(`Bearer ${token}`);
    if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) return json(res, 401, { error: 'unauthorized' });
    const path = (req.url ?? '').split('?')[0];
    const match = /^\/clients\/([a-z0-9_-]+)\/(config|next|events)$/.exec(path);
    if (!match || !Object.hasOwn(actors, match[1])) return json(res, 404, { error: 'unknown_client' });
    const [, clientID, operation] = match;
    if (operation === 'config' && req.method === 'GET') {
      const actor = actors[clientID];
      return json(res, 200, { backendURL: config.url, publishableKey: config.anonKey, email: actor.email, password: actor.password, name: actor.name, ...(transportURLs[clientID] ? { transportURL: transportURLs[clientID] } : {}) });
    }
    if (operation === 'next' && req.method === 'GET') {
      const command = queues.get(clientID).shift();
      return json(res, command ? 200 : 204, command);
    }
    if (operation !== 'events' || req.method !== 'POST') return json(res, 405, { error: 'unsupported' });
    try {
      let body = '';
      for await (const chunk of req) {
        body += chunk;
        if (body.length > 128 * 1024) return json(res, 413, { error: 'too_large' });
      }
      const event = JSON.parse(body);
      // Configuration credentials must never enter event histories/checkpoints.
      const serialized = JSON.stringify(event);
      if (/"(?:access_token|refresh_token|password|publishableKey|anonKey|service_role|control_token)"\s*:/i.test(serialized)) return json(res, 400, { error: 'credential_in_event' });
      if (event.client_id && event.client_id !== clientID) return json(res, 400, { error: 'actor_mismatch' });
      if (event.control_id && knownControl.get(event.control_id) !== clientID) return json(res, 400, { error: 'control_mismatch' });
      histories.get(clientID).push({ ...event, received_at: new Date().toISOString() });
      if (histories.get(clientID).length > 1500) histories.get(clientID).shift();
      if (event.event === 'result' && event.control_id) {
        results.set(event.control_id, event);
        const waiting = waiters.get(event.control_id);
        if (waiting) { clearTimeout(waiting.timer); waiters.delete(event.control_id); waiting.resolve(event); }
      }
      return json(res, 200, { accepted: true });
    } catch { return json(res, 400, { error: 'invalid_event' }); }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return {
    url: `http://127.0.0.1:${server.address().port}`, token,
    events(clientID) { return structuredClone(histories.get(clientID) ?? []); },
    enqueue(clientID, command) {
      if (!queues.has(clientID)) throw new Error('Unknown native client');
      const id = randomUUID();
      knownControl.set(id, clientID);
      queues.get(clientID).push({ ...structuredClone(command), id });
      return id;
    },
    waitResult(id, timeout = 60_000) {
      if (results.has(id)) return Promise.resolve(results.get(id));
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { waiters.delete(id); reject(new Error(`Native control request timed out: ${id}`)); }, timeout);
        waiters.set(id, { resolve, reject, timer });
      });
    },
    async close() {
      for (const waiter of waiters.values()) { clearTimeout(waiter.timer); waiter.reject(new Error('Native fixture closed')); }
      waiters.clear();
      const closing = new Promise((resolve) => server.close(resolve));
      server.closeAllConnections();
      await closing;
    },
  };
}
