import http from 'node:http';
import * as db from './db.js';

const NOTES_KEY = 'notes:all';
const REQUESTS_KEY = 'stats:requests';

function send(res, status, body, headers = {}) {
  res.writeHead(status, { 'content-type': 'application/json', ...headers });
  res.end(JSON.stringify(body));
}

async function readJSON(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  if (chunks.length === 0) return {};
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

/**
 * Notes API.
 *   GET  /health     both databases reachable?
 *   GET  /notes      list (served from Redis when cached; X-Cache: HIT|MISS)
 *   POST /notes      {"text": "..."} → stored in Postgres, cache invalidated
 *   GET  /notes/:id  one note
 *   GET  /stats      request counter (Redis) + note count (Postgres)
 */
export function createApp({ pool, cache }) {
  return http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost');
      if (url.pathname !== '/health') await cache.incr(REQUESTS_KEY);

      if (req.method === 'GET' && url.pathname === '/health') {
        const checks = await Promise.allSettled([pool.query('SELECT 1'), cache.ping()]);
        const [postgres, redis] = checks.map((c) => (c.status === 'fulfilled' ? 'ok' : c.reason.message));
        const ok = postgres === 'ok' && redis === 'ok';
        return send(res, ok ? 200 : 503, { postgres, redis });
      }

      if (req.method === 'GET' && url.pathname === '/notes') {
        const cached = await cache.getJSON(NOTES_KEY);
        if (cached) return send(res, 200, cached, { 'x-cache': 'HIT' });
        const notes = await db.listNotes(pool);
        await cache.setJSON(NOTES_KEY, notes);
        return send(res, 200, notes, { 'x-cache': 'MISS' });
      }

      if (req.method === 'POST' && url.pathname === '/notes') {
        let body;
        try {
          body = await readJSON(req);
        } catch {
          return send(res, 400, { error: 'Body must be JSON' });
        }
        const text = typeof body.text === 'string' ? body.text.trim() : '';
        if (!text) return send(res, 400, { error: '"text" is required' });
        const note = await db.insertNote(pool, text);
        await cache.del(NOTES_KEY);
        return send(res, 201, note);
      }

      const match = url.pathname.match(/^\/notes\/(\d+)$/);
      if (req.method === 'GET' && match) {
        const note = await db.getNote(pool, Number(match[1]));
        return note ? send(res, 200, note) : send(res, 404, { error: 'Not found' });
      }

      if (req.method === 'GET' && url.pathname === '/stats') {
        const [requests, notes] = await Promise.all([cache.getInt(REQUESTS_KEY), db.countNotes(pool)]);
        return send(res, 200, { requests, notes });
      }

      send(res, 404, { error: 'Not found' });
    } catch (err) {
      console.error(err);
      send(res, 500, { error: err.message });
    }
  });
}
