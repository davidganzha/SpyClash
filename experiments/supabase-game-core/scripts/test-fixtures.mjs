import { readFileSync, statSync } from 'node:fs';
import { syntheticTestActors } from '../client/game-client.mjs';

export function testEnvironment(env = process.env) {
  if (!env.SUPABASE_TEST_CONFIG_FILE) return { ...env };
  const path = env.SUPABASE_TEST_CONFIG_FILE;
  if (statSync(path).mode & 0o077) throw new Error('Private test configuration requires owner-only permissions (0600)');
  const values = JSON.parse(readFileSync(path, 'utf8'));
  if (!values || typeof values !== 'object' || Array.isArray(values) || Object.values(values).some((value) => typeof value !== 'string')) throw new Error('Test config must map environment names to string values');
  return { ...values, ...env };
}

export function loadTestFixture(config, path) {
  const stat = statSync(path);
  if (stat.mode & 0o077) throw new Error('Actor fixture must have owner-only permissions (0600)');
  const fixture = JSON.parse(readFileSync(path, 'utf8'));
  if (fixture.backendURL !== config.url || (fixture.projectRef ?? null) !== (config.projectRef ?? null)) {
    throw new Error('Actor fixture belongs to a different backend; refusing to sign in');
  }
  syntheticTestActors({ SUPABASE_TEST_ACTORS: JSON.stringify(fixture.actors) }, 1);
  if (new Set(fixture.actors.map((actor) => actor.id)).size !== fixture.actors.length ||
      fixture.actors.some((actor) => !/^(ios[1-3]|js[1-6])$/.test(actor.id))) {
    throw new Error('Fixture actor IDs must be distinct ios1..ios3 or js1..js6');
  }
  return fixture;
}
