// Integration tests: they talk to the real Postgres and Redis from compose.yaml.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { config } from '../src/config.js';
import { createPool, migrate } from '../src/db.js';
import { connectRedis, createCache } from '../src/cache.js';
import { createApp } from '../src/app.js';

// Own key namespace so the tests never touch a running app's keys.
const prefix = `test-${process.pid}-${Date.now()}:`;
let pool, redis, server, base;

before(async () => {
  pool = createPool(config.databaseUrl);
  await migrate(pool);
  await pool.query('TRUNCATE notes RESTART IDENTITY');
  redis = await connectRedis(config.redisUrl);
  server = createApp({ pool, cache: createCache(redis, prefix, 60) });
  await new Promise((resolve) => server.listen(0, resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  server?.close();
  if (redis) {
    const keys = await redis.keys(`${prefix}*`);
    if (keys.length) await redis.del(keys);
    await redis.quit();
  }
  await pool?.end();
});

const get = (path) => fetch(base + path);
const post = (path, body) =>
  fetch(base + path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });

test('health reports both databases', async () => {
  const res = await get('/health');
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { postgres: 'ok', redis: 'ok' });
});

test('notes are stored in Postgres and cached in Redis', async () => {
  const first = await get('/notes');
  assert.equal(first.headers.get('x-cache'), 'MISS');
  assert.deepEqual(await first.json(), []);

  const cached = await get('/notes');
  assert.equal(cached.headers.get('x-cache'), 'HIT');

  const created = await post('/notes', { text: 'hello from postgres' });
  assert.equal(created.status, 201);
  const note = await created.json();
  assert.equal(note.text, 'hello from postgres');

  // Writing invalidates the cache, so the next read goes to Postgres again.
  const afterWrite = await get('/notes');
  assert.equal(afterWrite.headers.get('x-cache'), 'MISS');
  assert.deepEqual((await afterWrite.json()).map((n) => n.text), ['hello from postgres']);

  // The cached copy really lives in Redis.
  const raw = await redis.get(`${prefix}notes:all`);
  assert.equal(JSON.parse(raw)[0].id, note.id);

  const one = await get(`/notes/${note.id}`);
  assert.equal(one.status, 200);
  assert.equal((await one.json()).text, 'hello from postgres');
});

test('missing note is 404', async () => {
  assert.equal((await get('/notes/999999')).status, 404);
});

test('invalid bodies are rejected', async () => {
  assert.equal((await post('/notes', { text: '   ' })).status, 400);
  assert.equal((await post('/notes', 'not json')).status, 400);
});

test('stats combine a Redis counter with a Postgres count', async () => {
  const before = await (await get('/stats')).json();
  await get('/notes');
  const after = await (await get('/stats')).json();
  assert.equal(after.requests, before.requests + 2);
  const { rows } = await pool.query('SELECT count(*)::int AS n FROM notes');
  assert.equal(after.notes, rows[0].n);
});
