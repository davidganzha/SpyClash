import assert from 'node:assert/strict';
import test from 'node:test';
import { cloudTestConfig, GameClient, localConfig, requireAllowedTestTarget, syntheticTestActors } from '../client/game-client.mjs';
import { faultProxy } from './fault-proxy.mjs';

const projectRef = 'bbkfsgnordtdiblgdzkg';
const env = { SUPABASE_TEST_MODE: 'cloud-staging', SUPABASE_TEST_PROJECT_REF: projectRef, SUPABASE_URL: `https://${projectRef}.supabase.co`, SUPABASE_ANON_KEY: 'sb_publishable_synthetic_test_only' };

test('cloud opt-in cannot weaken the default local guard or accept a different project', async () => {
  assert.throws(() => localConfig(env), /loopback/);
  assert.throws(() => new GameClient({ url: env.SUPABASE_URL, anonKey: env.SUPABASE_ANON_KEY }), /loopback/);
  assert.throws(() => cloudTestConfig({ ...env, SUPABASE_TEST_MODE: undefined }), /explicit/);
  assert.throws(() => cloudTestConfig({ ...env, SUPABASE_TEST_PROJECT_REF: 'abcdefghijklmnopqrst', SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co' }), /committed synthetic/);
  for (const url of ['http://abcdefghijklmnopqrst.supabase.co', 'https://otherprojectrefabcde.supabase.co', `${env.SUPABASE_URL}/`, `${env.SUPABASE_URL}?redirect=other`]) {
    assert.throws(() => cloudTestConfig({ ...env, SUPABASE_URL: url }), /exactly match/);
  }
  const config = cloudTestConfig(env);
  assert.equal(requireAllowedTestTarget(`${config.url}/rest/v1/rpc/game_command`, config).origin, config.url);
  assert.throws(() => requireAllowedTestTarget('https://unapproved.supabase.co/rest/v1', config), /allowlist/);
  assert.throws(() => requireAllowedTestTarget(config.url, { ...config }), /loopback/);
  await assert.rejects(faultProxy(config.url), /loopback/);
  const client = new GameClient(config);
  await assert.rejects(client.signUp(), /never sign up/);
  await client.close();
});

test('cloud clients reject privileged keys and non-synthetic credentials', () => {
  assert.throws(() => cloudTestConfig({ ...env, SUPABASE_ANON_KEY: 'sb_secret_forbidden' }), /secret/);
  const serviceJWT = `header.${Buffer.from(JSON.stringify({ role: 'service_role' })).toString('base64url')}.signature`;
  assert.throws(() => cloudTestConfig({ ...env, SUPABASE_ANON_KEY: serviceJWT }), /privileged/);
  assert.throws(() => cloudTestConfig({ ...env, SUPABASE_ANON_KEY: 'sbp_management_personal_access_token' }), /public keys/);
  const userJWT = `header.${Buffer.from(JSON.stringify({ role: 'authenticated' })).toString('base64url')}.signature`;
  assert.throws(() => cloudTestConfig({ ...env, SUPABASE_ANON_KEY: userJWT }), /privileged/);
  assert.throws(() => syntheticTestActors({ SUPABASE_TEST_ACTORS: JSON.stringify([{ email: 'real@example.com', password: 'sufficiently-long-password' }]) }, 1), /synthetic/);
  assert.throws(() => syntheticTestActors({ SUPABASE_TEST_ACTORS: 'not-json' }, 1), /valid JSON/);
});
