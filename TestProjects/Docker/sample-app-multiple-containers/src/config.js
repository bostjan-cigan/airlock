// Hostnames are the compose service names. Inside AIrlock they resolve to
// 127.0.0.1 (services share the agent's network); under plain
// `docker compose` they resolve over the compose network.
export const config = {
  port: Number(process.env.PORT ?? 3000),
  databaseUrl: process.env.DATABASE_URL ?? 'postgres://app:app@postgres:5432/app',
  redisUrl: process.env.REDIS_URL ?? 'redis://redis:6379',
  redisPrefix: process.env.REDIS_PREFIX ?? 'notes-app:',
  cacheTtlSeconds: Number(process.env.CACHE_TTL_SECONDS ?? 60),
};
