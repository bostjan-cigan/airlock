import { config } from './config.js';
import { createPool, migrate } from './db.js';
import { connectRedis, createCache } from './cache.js';
import { createApp } from './app.js';

const pool = createPool(config.databaseUrl);
await migrate(pool);
const redis = await connectRedis(config.redisUrl);
const cache = createCache(redis, config.redisPrefix, config.cacheTtlSeconds);

const server = createApp({ pool, cache });
server.listen(config.port, () => {
  console.log(`notes API on http://localhost:${config.port}`);
});

async function shutdown() {
  server.close();
  await Promise.allSettled([pool.end(), redis.quit()]);
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
