"""The notes API: GET /health, GET /notes, POST /notes {"text": "..."}."""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg
import redis

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://app:app@postgres:5432/app")
REDIS_URL = os.environ.get("REDIS_URL", "redis://redis:6379")


def connect():
    conn = psycopg.connect(DATABASE_URL, autocommit=True)
    conn.execute("CREATE TABLE IF NOT EXISTS notes (id SERIAL PRIMARY KEY, text TEXT NOT NULL)")
    return conn, redis.Redis.from_url(REDIS_URL)


def create_server(conn, cache, port=0):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, status, body):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path == "/health":
                conn.execute("SELECT 1")
                cache.ping()
                return self.send(200, {"postgres": "ok", "redis": "ok"})
            if self.path == "/notes":
                rows = conn.execute("SELECT id, text FROM notes ORDER BY id").fetchall()
                return self.send(200, [{"id": i, "text": t} for i, t in rows])
            self.send(404, {"error": "Not found"})

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("content-length", "0"))) or b"{}")
            text = str(body.get("text", "")).strip()
            if self.path != "/notes" or not text:
                return self.send(400, {"error": '"text" is required'})
            note_id = conn.execute("INSERT INTO notes (text) VALUES (%s) RETURNING id", (text,)).fetchone()[0]
            cache.publish("notes:new", note_id)
            self.send(201, {"id": note_id, "text": text})

    return ThreadingHTTPServer(("0.0.0.0", port), Handler)


if __name__ == "__main__":
    create_server(*connect(), int(os.environ.get("PORT", "8000"))).serve_forever()
