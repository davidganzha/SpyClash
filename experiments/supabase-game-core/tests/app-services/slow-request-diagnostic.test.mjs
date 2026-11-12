import assert from 'node:assert/strict';
import test from 'node:test';
import { watchAppRequest } from '../../supabase/functions/app-services/slow-request-diagnostic.ts';
import { createAppHandler } from '../../supabase/functions/app-services/handler.ts';
import { AppServiceError } from '../../supabase/functions/app-services/contracts.ts';
import { commandHash } from '../../supabase/functions/full-game-core/service.ts';

function clock() {
  const timers = [], events = [];
  const dependencies = {
    schedule(callback, delay) {
      const timer = { callback, delay, cancellations: 0 };
      timers.push(timer);
      return () => { timer.cancellations++; };
    },
    diagnose(event) { events.push(event); },
  };
  return { timers, events, dependencies, fire(index = 0) { timers[index].callback(); } };
}
function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}
const actorID = '11111111-1111-4111-8111-111111111111';
const sessionID = '22222222-2222-4222-8222-222222222222';
const token = 'private-header.' + Buffer.from(JSON.stringify({ session_id: sessionID })).toString('base64url') + '.private-signature';
const request = (body = '{}') => new Request('https://example.test/app-services', {
  method: 'POST', headers: { authorization: 'Bearer ' + token }, body,
});

test('one warning snapshots the current stage after exactly 12 seconds without retaining command data', () => {
  const time = clock(), progress = watchAppRequest(time.dependencies);
  assert.equal(time.timers.length, 1);
  assert.equal(time.timers[0].delay, 12_000);
  assert.deepEqual(time.events, []);
  const command = { service: 'membership', action: 'sync_transaction', signed_transaction: 'PRIVATE_JWS', user: actorID };
  progress.command(command);
  command.action = 'PRIVATE_CHANGED_ACTION';
  progress.stage('prepare_external');
  time.fire();
  progress.stage('execute');
  time.fire();
  assert.deepEqual(time.events, [{ stage: 'prepare_external', operation: 'membership.sync_transaction' }]);
  progress.finish();
  progress.finish();
  assert.equal(time.timers[0].cancellations, 1);
});

test('finished requests suppress even an already queued timer callback', () => {
  const time = clock(), progress = watchAppRequest(time.dependencies);
  progress.finish();
  time.fire();
  assert.deepEqual(time.events, []);
  assert.equal(time.timers[0].cancellations, 1);
});

test('unknown stage/action and private request fields cannot enter diagnostic labels', () => {
  for (const [command, operation] of [
    [{ service: 'PRIVATE_SERVICE', action: 'PRIVATE_ACTION' }, 'unclassified'],
    [{ service: 'membership', action: 'PRIVATE_ACTION' }, 'membership'],
    [{ service: 'membership', action: 'check_subscription' }, 'membership.check_subscription'],
    [{ service: 'membership', action: 'prepare_purchase' }, 'membership.prepare_purchase'],
    [{ service: 'profile', action: 'delete' }, 'profile.delete'],
    [{ service: 'profile', action: 'PRIVATE_ACTION' }, 'profile'],
    [{ service: 'legacy', action: 'PRIVATE_ACTION' }, 'legacy'],
  ]) {
    const time = clock(), progress = watchAppRequest(time.dependencies);
    progress.command({ ...command, token, actorID, signed_transaction: 'PRIVATE_SIGNED_TRANSACTION' });
    progress.stage('PRIVATE_STAGE');
    time.fire();
    assert.deepEqual(time.events, [{ stage: 'authenticate', operation }]);
    for (const secret of ['PRIVATE', token, actorID]) assert.equal(JSON.stringify(time.events).includes(secret), false);
    progress.finish();
  }
});

test('diagnostic scheduling, logger, and cancellation failures do not escape', () => {
  assert.doesNotThrow(() => watchAppRequest({ schedule() { throw Error('PRIVATE_TIMER_FAILURE'); } }).finish());
  const time = clock();
  const progress = watchAppRequest({ ...time.dependencies, diagnose() { throw Error('PRIVATE_LOG_FAILURE'); } });
  assert.doesNotThrow(() => time.fire());
  assert.doesNotThrow(() => progress.finish());
  const badCancel = watchAppRequest({ schedule() { return () => { throw Error('PRIVATE_CANCEL_FAILURE'); }; } });
  assert.doesNotThrow(() => badCancel.finish());
});

test('concurrent requests retain independent stage and completion state', () => {
  const time = clock(), first = watchAppRequest(time.dependencies), second = watchAppRequest(time.dependencies);
  first.stage('session_gate');
  second.stage('execute');
  second.command({ service: 'membership', action: 'check' });
  first.finish();
  time.fire(0);
  time.fire(1);
  assert.deepEqual(time.events, [{ stage: 'execute', operation: 'membership.check' }]);
  second.finish();
});

test('handler clears diagnostics on authentication rejection and does not watch rejected methods', async () => {
  const time = clock();
  const handler = createAppHandler({ db: null, slowRequestDiagnostics: time.dependencies,
    authenticate: async () => { throw new AppServiceError('unauthorized', 'Sign in.', 401); } });
  const method = await handler(new Request('https://example.test/app-services'));
  assert.equal(method.status, 405);
  assert.equal(time.timers.length, 0);
  const response = await handler(request());
  assert.equal(response.status, 401);
  assert.deepEqual(await response.json(), { code: 'unauthorized', message: 'Sign in.', retryable: false });
  assert.equal(time.timers[0].cancellations, 1);
  time.fire();
  assert.deepEqual(time.events, []);
});

test('handler clears diagnostics after an unexpected failure without changing the retryable response', async t => {
  const time = clock();
  t.mock.method(console, 'error', () => {});
  const handler = createAppHandler({ db: null, slowRequestDiagnostics: time.dependencies,
    authenticate: async () => { throw new Error('PRIVATE_INTERNAL_FAILURE'); } });
  const response = await handler(request());
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {
    code: 'app_service_unavailable', message: 'The action could not be confirmed. Retry the saved request.', retryable: true,
  });
  assert.equal(time.timers[0].cancellations, 1);
  time.fire();
  assert.deepEqual(time.events, []);
});

test('slow authentication is observed without cancelling or retrying authentication', async () => {
  const time = clock(), pendingAuth = deferred();
  let calls = 0, settled = false;
  const handler = createAppHandler({ db: async () => [], slowRequestDiagnostics: time.dependencies,
    authenticate: async () => { calls++; return await pendingAuth.promise; } });
  const pendingResponse = handler(request()).then(response => { settled = true; return response; });
  time.fire();
  assert.equal(settled, false);
  assert.equal(calls, 1);
  assert.deepEqual(time.events, [{ stage: 'authenticate', operation: 'unclassified' }]);
  pendingAuth.resolve({ id: actorID });
  assert.equal((await pendingResponse).status, 401);
  assert.equal(calls, 1);
  assert.equal(time.timers[0].cancellations, 1);
});

test('slow session and command reads have distinct safe labels and retain their rejection response', async () => {
  for (const stage of ['session_gate', 'read_command']) {
    const time = clock(), entered = deferred(), pending = deferred();
    const input = request();
    const db = async () => {
      if (stage === 'session_gate') { entered.resolve(); return await pending.promise; }
      return [{ recent: true }];
    };
    if (stage === 'read_command') input.text = async () => { entered.resolve(); return await pending.promise; };
    const handler = createAppHandler({ db, slowRequestDiagnostics: time.dependencies, authenticate: async () => ({ id: actorID }) });
    const response = handler(input);
    await entered.promise;
    time.fire();
    assert.deepEqual(time.events, [{ stage, operation: 'unclassified' }]);
    pending.resolve(stage === 'session_gate' ? [] : 'invalid-json');
    assert.equal((await response).status, stage === 'session_gate' ? 401 : 400);
    assert.equal(time.timers[0].cancellations, 1);
  }
});

test('slow receipt replay logs the allowlisted operation and returns the original success response', async () => {
  const time = clock(), entered = deferred(), receipt = deferred();
  const body = { service: 'membership', action: 'prepare_purchase', request_id: '33333333-3333-4333-8333-333333333333' };
  const db = async (strings) => {
    const query = strings.join('?');
    if (query.includes('from auth.sessions')) return [{ recent: true }];
    if (query.includes('pg_advisory_xact_lock_shared')) return [];
    if (query.includes('from app_private.profiles')) return [{ state: 'active', data: {} }];
    if (query.includes('to_regclass')) return [{ available: false }];
    if (query.includes('from app_private.receipts')) { entered.resolve(); return await receipt.promise; }
    assert.fail('Unexpected database operation');
  };
  db.begin = async callback => await callback(db);
  const handler = createAppHandler({ db, slowRequestDiagnostics: time.dependencies, authenticate: async () => ({ id: actorID }) });
  const response = handler(request(JSON.stringify(body)));
  await entered.promise;
  time.fire();
  assert.deepEqual(time.events, [{ stage: 'receipt', operation: 'membership.prepare_purchase' }]);
  const saved = { product_id: 'saved-product', app_account_token: 'saved-token' };
  receipt.resolve([{ request_hash: await commandHash(body), status: 200, response: saved }]);
  const result = await response;
  assert.equal(result.status, 200);
  assert.deepEqual(await result.json(), saved);
  assert.equal(time.timers[0].cancellations, 1);
  time.fire();
  assert.equal(time.events.length, 1);
});
