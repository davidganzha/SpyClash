import assert from 'node:assert/strict';
import http from 'node:http';
import test from 'node:test';
import { startNativeControl } from '../scripts/native-control.mjs';
import { faultProxy } from './fault-proxy.mjs';

test('native fixture requires bearer auth, binds results to the actor and rejects credential events', async (t) => {
  const control = await startNativeControl({
    config: { url: 'http://127.0.0.1:56321', anonKey: 'synthetic-public-key' },
    actors: { ios1: { email: 'fixture@example.test', password: 'synthetic-password-not-used', name: 'Fixture' } },
  });
  t.after(() => control.close());
  assert.equal((await fetch(`${control.url}/clients/ios1/config`)).status, 401);
  const headers = { Authorization: `Bearer ${control.token}`, 'Content-Type': 'application/json' };
  const config = await (await fetch(`${control.url}/clients/ios1/config`, { headers })).json();
  assert.equal(config.backendURL, 'http://127.0.0.1:56321');
  const credentialEvent = await fetch(`${control.url}/clients/ios1/events`, { method: 'POST', headers, body: JSON.stringify({ event: 'state', password: 'must-not-enter-history' }) });
  assert.equal(credentialEvent.status, 400);
  assert.equal(control.events('ios1').length, 0);
  const id = control.enqueue('ios1', { op: 'state' });
  const next = await (await fetch(`${control.url}/clients/ios1/next`, { headers })).json();
  assert.equal(next.id, id);
  assert.equal(next.op, 'state');
  const result = { event: 'result', client_id: 'ios1', control_id: id, ok: true, state: { native: true, revision: 7 } };
  const waiting = control.waitResult(id);
  const accepted = await fetch(`${control.url}/clients/ios1/events`, { method: 'POST', headers, body: JSON.stringify(result) });
  assert.equal(accepted.status, 200);
  assert.deepEqual(await waiting, result);
});

test('fault proxy rejects a backslash-normalized alternate origin without forwarding', async (t) => {
  let forwarded = 0;
  const upstream = http.createServer((_req, res) => { forwarded += 1; res.end('unexpected'); });
  await new Promise((resolve) => upstream.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve) => upstream.close(resolve)));
  const proxy = await faultProxy(`http://127.0.0.1:${upstream.address().port}`);
  t.after(() => proxy.close());
  const status = await new Promise((resolve, reject) => {
    const request = http.request(proxy.url, { path: String.raw`/\unapproved.invalid/path` }, (response) => { response.resume(); response.on('end', () => resolve(response.statusCode)); });
    request.on('error', reject);
    request.end();
  });
  assert.equal(status, 400);
  assert.equal(forwarded, 0);
});
