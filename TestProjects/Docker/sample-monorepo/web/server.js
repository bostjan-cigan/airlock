// Serves the notes page and forwards /api/* to the Python API.
import http from 'node:http';

const API = process.env.API_URL ?? 'http://api:8000';
const PORT = Number(process.env.PORT ?? 3000);

export function page(notes) {
  const items = notes.map((n) => `<li>${n.text.replace(/</g, '&lt;')}</li>`).join('');
  return `<!doctype html><title>Notes</title><h1>Notes</h1><ul>${items}</ul>`;
}

export function createServer(apiUrl = API) {
  return http.createServer(async (req, res) => {
    try {
      const notes = await (await fetch(`${apiUrl}/notes`)).json();
      res.writeHead(200, { 'content-type': 'text/html' });
      res.end(page(notes));
    } catch (err) {
      res.writeHead(502, { 'content-type': 'text/plain' });
      res.end(`API unreachable: ${err.message}`);
    }
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  createServer().listen(PORT, () => console.log(`web on http://localhost:${PORT}`));
}
