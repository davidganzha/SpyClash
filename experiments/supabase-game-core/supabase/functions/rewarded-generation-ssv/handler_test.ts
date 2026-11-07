import { createRewardedGenerationSSVGateway } from './handler.ts';

function assert(value: unknown, message = 'assertion failed'): asserts value {
  if (!value) throw new Error(message);
}
const config = {SUPABASE_URL: 'https://bbkfsgnordtdiblgdzkg.supabase.co'};
const attempt = '11111111-1111-4111-8111-111111111111';
const token = (namespace: string) => `${attempt}.${namespace}.${'a'.repeat(64)}`;
const probeUser = 'spyclash_admob_setup_probe';
const probeData = 'spyclash_setup_probe_v1';
const probeUnit = '1234567890';
const ownedUnit = 'ca-app-pub-5081830513960558/6816674766';
const probeConfig = {ADMOB_REWARDED_AD_UNIT_ID: ownedUnit, SPYCLASH_REWARDED_GENERATION_ENABLED: 'false'};
const destination = 'https://spyclash.com/api/apps/69a0e57fa939f578082f8091/functions/generationRewardAction';
const encode = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));
function rawToDER(raw: Uint8Array) {
  const fields = [raw.slice(0, 32), raw.slice(32)].map(value => {
    while (value.length > 1 && value[0] === 0) value = value.slice(1);
    if (value[0] & 128) value = new Uint8Array([0, ...value]);
    return new Uint8Array([2, value.length, ...value]);
  });
  return new Uint8Array([48, fields[0].length + fields[1].length, ...fields[0], ...fields[1]]);
}
async function fixture(customData = token('legacy'), reward = '1', fields: {userID?: string; adUnit?: string; rewardItem?: string} = {}) {
  const pair = await crypto.subtle.generateKey({name: 'ECDSA', namedCurve: 'P-256'}, true, ['sign', 'verify']);
  const publicKey = encode(new Uint8Array(await crypto.subtle.exportKey('spki', pair.publicKey)));
  // Deliberately preserve order, mixed percent escape case and literal plus.
  const query = `user_id=${encodeURIComponent(fields.userID ?? 'legacy+player')}&ad_network=one+two&ad_unit=${encodeURIComponent(fields.adUnit ?? '1234567890')}&custom_data=${customData.replaceAll('.', '%2e')}&reward_item=${encodeURIComponent(fields.rewardItem ?? 'generation')}&reward_amount=${reward}&timestamp=1794074400000&transaction_id=transaction_1`;
  const raw = new Uint8Array(await crypto.subtle.sign({name: 'ECDSA', hash: 'SHA-256'}, pair.privateKey, new TextEncoder().encode(decodeURIComponent(query))));
  const signature = encode(rawToDER(raw)).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
  const url = `https://example.test/functions/v1/rewarded-generation-ssv?${query}&signature=${signature}&key_id=123`;
  const calls: {url: string; init?: RequestInit}[] = [];
  const nativeCalls: Request[] = [];
  const keyCalls: string[] = [];
  let reply: () => Response = () => Response.json({success: true, duplicate: false});
  let keyReply: () => Response = () => Response.json({keys: [{keyId: 123, base64: publicKey}]});
  const fetcher: typeof fetch = (input, init) => {
    if (String(input) === 'https://www.gstatic.com/admob/reward/verifier-keys.json') {
      keyCalls.push(String(input));
      return Promise.resolve(keyReply());
    }
    calls.push({url: String(input), init});
    return Promise.resolve(reply());
  };
  const native = (request: Request) => {nativeCalls.push(request); return Promise.resolve(Response.json({received: true}));};
  return {url, calls, nativeCalls, keyCalls, fetcher, native, setReply: (value: typeof reply) => {reply = value;}, setKeyReply: (value: typeof keyReply) => {keyReply = value;},
    handler: (overrides = {}) => createRewardedGenerationSSVGateway({config: {...config, ...overrides}, fetch: fetcher, native})};
}

Deno.test('legacy SSV verifies first and preserves the entire signed query byte for byte', async () => {
  const f = await fixture();
  const response = await f.handler()(new Request(f.url));
  assert(response.status === 200);
  assert(f.nativeCalls.length === 0 && f.calls.length === 1);
  assert(f.calls[0].url === destination + new URL(f.url).search);
  assert(f.calls[0].init?.redirect === 'error' && f.calls[0].init?.method === 'GET');
  assert(f.calls[0].init?.signal instanceof AbortSignal);
  assert(!new Headers(f.calls[0].init?.headers).has('Authorization'));
  assert((await response.json()).received === true);
});
Deno.test('native SSV reaches only the existing native ledger handler', async () => {
  const f = await fixture(token('native'));
  const request = new Request(f.url);
  assert((await f.handler()(request)).status === 200);
  assert(f.nativeCalls.length === 1 && f.nativeCalls[0] === request && f.calls.length === 0);
});
Deno.test('signature tampering cannot route to either ledger', async () => {
  const f = await fixture();
  for (const url of [f.url.replace('legacy%2e', 'native%2e'), f.url.replace('reward_amount=1', 'reward_amount=9'), f.url + '&namespace=native']) {
    assert((await f.handler()(new Request(url))).status === 400);
  }
  assert(f.calls.length === 0 && f.nativeCalls.length === 0);
});
Deno.test('signed unsupported or old unnamespaced tokens cannot be guessed into a wallet', async () => {
  for (const customData of [token('unknown'), `${attempt}.${'a'.repeat(64)}`, token('legacy').slice(1)]) {
    const f = await fixture(customData);
    assert((await f.handler()(new Request(f.url))).status === 400);
    assert(f.calls.length === 0 && f.nativeCalls.length === 0);
  }
  const f = await fixture(token('legacy'), '2');
  assert((await f.handler()(new Request(f.url))).status === 400 && f.calls.length === 0);
});
Deno.test('legacy destination overrides and wrong project fail closed without forwarding', async () => {
  const f = await fixture();
  for (const overrides of [
    {SUPABASE_URL: 'https://other-project.supabase.co'},
    {BASE44_STAGING_ORIGIN: 'https://other.example', BASE44_STAGING_APP_ID: 'a'.repeat(24), LEGACY_BRIDGE_ENABLED: 'true', APP_ENVIRONMENT: 'staging', BASE44_STAGING_ORIGIN_ALLOWLIST: '["https://other.example"]'},
    {BASE44_STAGING_ORIGIN: 'https://spyclash.com', BASE44_STAGING_APP_ID: 'a'.repeat(24)},
  ]) assert((await f.handler(overrides)(new Request(f.url))).status === 503);
  assert(f.calls.length === 0);
});
Deno.test('disabled new offers do not discard an already issued signed callback', async () => {
  const f = await fixture();
  assert((await f.handler({SPYCLASH_REWARDED_GENERATION_ENABLED: 'false'})(new Request(f.url))).status === 200);
  f.setReply(() => Response.json({success: true, duplicate: true}));
  assert((await f.handler()(new Request(f.url))).status === 200);
  assert(f.calls.length === 2, 'The gateway leaves replay idempotency with the authoritative ledger.');
});
Deno.test('upstream errors, redirects, malformed success and oversized bodies never acknowledge a grant', async () => {
  const f = await fixture();
  for (const status of [301, 401, 404, 409, 429, 500]) {
    f.setReply(() => new Response('', {status, headers: {Location: 'https://other.example'}}));
    assert((await f.handler()(new Request(f.url))).status === 503);
  }
  for (const body of ['', '<html>hosting error</html>', '{"success":false}', ' '.repeat(4_097)]) {
    f.setReply(() => new Response(body));
    assert((await f.handler()(new Request(f.url))).status === 503);
  }
  f.setReply(() => {throw new TypeError('redirect or connection failure');});
  assert((await f.handler()(new Request(f.url))).status === 503);
});
Deno.test('failed key lookup and non-GET requests never touch a ledger', async () => {
  const f = await fixture();
  f.setKeyReply(() => new Response('', {status: 503}));
  assert((await f.handler()(new Request(f.url))).status === 503);
  assert((await f.handler()(new Request(f.url, {method: 'POST'}))).status === 405);
  assert(f.calls.length === 0 && f.nativeCalls.length === 0);
});

Deno.test('signed dashboard probe acknowledges only delivery with offers disabled and never routes a credit', async () => {
  for (const enabled of [undefined, 'false']) {
    const f = await fixture(probeData, '1', {userID: probeUser, adUnit: probeUnit});
    // A disabled/unavailable legacy bridge is irrelevant to a no-credit probe.
    const handler = f.handler({...probeConfig, SPYCLASH_REWARDED_GENERATION_ENABLED: enabled, LEGACY_BRIDGE_ENABLED: 'false'});
    const response = await handler(new Request(f.url));
    assert(response.status === 200 && response.headers.get('Cache-Control') === 'no-store');
    const body = await response.json();
    assert(body.received === true && body.setup_probe === true && body.reward_granted === false);
    assert(f.keyCalls.length === 1 && f.calls.length === 0 && f.nativeCalls.length === 0);
    const repeated = await handler(new Request(f.url));
    assert(repeated.status === 200 && (await repeated.json()).reward_granted === false);
    assert(f.calls.length === 0 && f.nativeCalls.length === 0);
  }
});

Deno.test('dashboard probe cannot bypass the Google signature check', async () => {
  const f = await fixture(probeData, '1', {userID: probeUser, adUnit: probeUnit});
  for (const url of [
    f.url.replace(probeUser, 'someone_else'),
    f.url.replace(probeData, 'different_custom_data'),
    f.url.replace('ad_unit=1234567890', 'ad_unit=1234567891'),
    f.url.replace('reward_amount=1', 'reward_amount=2'),
    f.url.replace(/&signature=.*$/, ''),
    f.url.replace('&signature=', `&user_id=${probeUser}&signature=`),
  ]) assert((await f.handler(probeConfig)(new Request(url))).status === 400);
  assert(f.calls.length === 0 && f.nativeCalls.length === 0);
});

Deno.test('signed mismatched probe markers, unit and reward fail without routing', async () => {
  for (const values of [
    {customData: token('native'), userID: probeUser},
    {customData: token('legacy'), userID: probeUser},
    {customData: probeData, userID: 'another_account'},
    {customData: 'different_custom_data', userID: probeUser},
    {adUnit: '1234567891'},
    {adUnit: ownedUnit},
    {adUnit: ownedUnit.split('/')[1]},
    {reward: '0'},
    {reward: '2'},
    {rewardItem: 'coins'},
  ]) {
    const f = await fixture(values.customData ?? probeData, values.reward ?? '1', {
      userID: values.userID ?? probeUser, adUnit: values.adUnit ?? probeUnit, rewardItem: values.rewardItem,
    });
    assert((await f.handler(probeConfig)(new Request(f.url))).status === 400);
    assert(f.calls.length === 0 && f.nativeCalls.length === 0);
  }
});

Deno.test('dashboard probe requires a configured owned ad unit', async () => {
  const f = await fixture(probeData, '1', {userID: probeUser, adUnit: probeUnit});
  for (const unit of [undefined, '', 'invalid', 'ca-app-pub-3940256099942544/1712485313']) {
    const response = await f.handler({...probeConfig, ADMOB_REWARDED_AD_UNIT_ID: unit})(new Request(f.url));
    assert(response.status === 503 && (await response.json()).code === 'reward_probe_unconfigured');
  }
  assert(f.calls.length === 0 && f.nativeCalls.length === 0);
});

Deno.test('dashboard probe rejects non-GET requests and key outages without routing', async () => {
  const f = await fixture(probeData, '1', {userID: probeUser, adUnit: probeUnit});
  assert((await f.handler(probeConfig)(new Request(f.url, {method: 'POST'}))).status === 405);
  assert(f.keyCalls.length === 0);
  f.setKeyReply(() => new Response('', {status: 503}));
  assert((await f.handler(probeConfig)(new Request(f.url))).status === 503);
  assert(f.calls.length === 0 && f.nativeCalls.length === 0);
});
