import { createClient } from 'redis';

export async function connectRedis(redisUrl) {
  const client = createClient({
    url: redisUrl,
    // Fail fast instead of retrying forever when Redis isn't there.
    socket: { connectTimeout: 3000, reconnectStrategy: false },
  });
  client.on('error', () => {}); // surfaced through rejected commands instead
  await client.connect();
  return client;
}

export function createCache(client, prefix, ttlSeconds) {
  const key = (name) => `${prefix}${name}`;
  return {
    async getJSON(name) {
      const raw = await client.get(key(name));
      return raw === null ? null : JSON.parse(raw);
    },
    setJSON: (name, value) => client.set(key(name), JSON.stringify(value), { EX: ttlSeconds }),
    del: (name) => client.del(key(name)),
    incr: (name) => client.incr(key(name)),
    async getInt(name) {
      return Number((await client.get(key(name))) ?? 0);
    },
    ping: () => client.ping(),
  };
}
