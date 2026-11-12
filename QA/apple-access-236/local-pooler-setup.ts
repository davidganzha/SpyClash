import postgres from 'npm:postgres@3.4.9';

const url = new URL(Deno.env.get('SPYCLASH_TEST_DATABASE_URL') || '');
if (url.hostname !== '127.0.0.1' || url.port !== '56322' || url.pathname !== '/postgres') {
  throw new Error('Only the designated local fixture database is allowed');
}
const db = postgres(url.href, { max: 1, connect_timeout: 8 });
const name = 'repair235_pooler_meta';
try {
  if (Deno.args[0] === 'cleanup') {
    await db.unsafe(`DROP DATABASE IF EXISTS ${name} WITH (FORCE)`);
    console.log('Temporary local pooler metadata removed');
  } else {
    if (!(await db`select 1 from pg_database where datname=${name}`).length) await db.unsafe(`CREATE DATABASE ${name}`);
    const metadata = new URL(url);
    metadata.hostname = 'supabase_db_spyclash-game-core-test';
    metadata.port = '5432';
    metadata.pathname = '/' + name;
    metadata.protocol = 'ecto:';
    const random = () => crypto.randomUUID().replaceAll('-', '');
    const environment = {
      PORT: '4000', POSTGRES_HOST: metadata.hostname, POSTGRES_PORT: '5432', POSTGRES_DB: 'postgres',
      POSTGRES_PASSWORD: decodeURIComponent(url.password), DATABASE_URL: metadata.href,
      CLUSTER_POSTGRES: 'true', SECRET_KEY_BASE: random() + random(), VAULT_ENC_KEY: random(),
      API_JWT_SECRET: random(), METRICS_JWT_SECRET: random(), REGION: 'local', ERL_AFLAGS: '-proto_dist inet_tcp',
      POOLER_TENANT_ID: 'repair235', POOLER_DEFAULT_POOL_SIZE: '3', POOLER_MAX_CLIENT_CONN: '100',
      POOLER_POOL_MODE: 'transaction', DB_POOL_SIZE: '3',
    };
    await Deno.mkdir('.local/apple-access-236', { recursive: true });
    await Deno.writeTextFile('.local/apple-access-236/pooler.env', Object.entries(environment).map(([key, value]) => `${key}=${value}`).join('\n') + '\n', { mode: 0o600 });
    console.log('Temporary local pooler metadata and private environment file prepared');
  }
} finally { await db.end({ timeout: 2 }); }
