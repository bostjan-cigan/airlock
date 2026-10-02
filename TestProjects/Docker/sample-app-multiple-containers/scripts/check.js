// Connectivity probe: can this container reach both databases?
// Exit 0 when both answer, 1 otherwise. Run with `npm run check`.
import { config } from '../src/config.js';
import { createPool } from '../src/db.js';
import { connectRedis } from '../src/cache.js';

async function probe(name, url, fn) {
  const started = Date.now();
  try {
    const detail = await fn();
    console.log(`PASS ${name} (${url}) ${Date.now() - started}ms — ${detail}`);
    return true;
  } catch (err) {
    console.log(`FAIL ${name} (${url}) — ${err.message || err.code || err}`);
    return false;
  }
}

const redact = (url) => url.replace(/\/\/([^:@/]+):[^@/]+@/, '//$1:***@');

const results = await Promise.all([
  probe('postgres', redact(config.databaseUrl), async () => {
    const pool = createPool(config.databaseUrl);
    try {
      const { rows } = await pool.query('SHOW server_version');
      return `server ${rows[0].server_version}`;
    } finally {
      await pool.end();
    }
  }),
  probe('redis', config.redisUrl, async () => {
    const client = await connectRedis(config.redisUrl);
    try {
      const info = await client.info('server');
      return `server ${info.match(/redis_version:(\S+)/)?.[1] ?? '?'}`;
    } finally {
      await client.quit();
    }
  }),
]);

process.exit(results.every(Boolean) ? 0 : 1);
