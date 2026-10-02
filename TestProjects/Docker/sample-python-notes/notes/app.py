"""Notes API on the standard library's HTTP server.

  GET  /health     both databases reachable?
  GET  /notes      list (from Redis when cached; X-Cache: HIT|MISS)
  POST /notes      {"text": "..."} -> stored in Postgres, cache invalidated
  GET  /notes/<id> one note
  GET  /stats      request counter (Redis) + note count (Postgres)
"""
import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import db

NOTES_KEY = "notes:all"
REQUESTS_KEY = "stats:requests"


def create_server(conn, cache, port=0):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, status, body, headers=None):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json")
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path != "/health":
                cache.incr(REQUESTS_KEY)
            if self.path == "/health":
                checks = {}
                for name, check in (("postgres", lambda: conn.execute("SELECT 1")), ("redis", cache.ping)):
                    try:
                        check()
                        checks[name] = "ok"
                    except Exception as err:  # noqa: BLE001
                        checks[name] = str(err)
                ok = all(v == "ok" for v in checks.values())
                return self.send(200 if ok else 503, checks)
            if self.path == "/notes":
                cached = cache.get_json(NOTES_KEY)
                if cached is not None:
                    return self.send(200, cached, {"x-cache": "HIT"})
                notes = db.list_notes(conn)
                cache.set_json(NOTES_KEY, notes)
                return self.send(200, notes, {"x-cache": "MISS"})
            match = re.fullmatch(r"/notes/(\d+)", self.path)
            if match:
                note = db.get_note(conn, int(match.group(1)))
                return self.send(200, note) if note else self.send(404, {"error": "Not found"})
            if self.path == "/stats":
                return self.send(200, {"requests": cache.get_int(REQUESTS_KEY), "notes": db.count_notes(conn)})
            self.send(404, {"error": "Not found"})

        def do_POST(self):
            cache.incr(REQUESTS_KEY)
            if self.path != "/notes":
                return self.send(404, {"error": "Not found"})
            length = int(self.headers.get("content-length", "0"))
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
            except json.JSONDecodeError:
                return self.send(400, {"error": "Body must be JSON"})
            text = body.get("text", "").strip() if isinstance(body.get("text"), str) else ""
            if not text:
                return self.send(400, {"error": '"text" is required'})
            note = db.insert_note(conn, text)
            cache.delete(NOTES_KEY)
            self.send(201, note)

    return ThreadingHTTPServer(("0.0.0.0", port), Handler)
