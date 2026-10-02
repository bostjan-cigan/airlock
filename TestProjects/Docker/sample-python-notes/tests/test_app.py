"""Integration tests against the real Postgres and Redis from compose.yaml."""
import json
import os
import threading
import urllib.error
import urllib.request

import pytest

from notes import cache, config, db
from notes.app import create_server


@pytest.fixture(scope="module")
def api():
    conn = db.connect(config.DATABASE_URL)
    db.migrate(conn)
    conn.execute("TRUNCATE notes RESTART IDENTITY")
    client = cache.connect(config.REDIS_URL)
    prefix = f"test-{os.getpid()}:"
    server = create_server(conn, cache.Cache(client, prefix, 60))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{server.server_address[1]}", client, prefix
    server.shutdown()
    for key in client.scan_iter(f"{prefix}*"):
        client.delete(key)
    conn.close()


def request(base, path, body=None):
    data = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
    req = urllib.request.Request(base + path, data=data, method="POST" if data is not None else "GET")
    try:
        with urllib.request.urlopen(req) as res:
            return res.status, dict(res.headers), json.loads(res.read())
    except urllib.error.HTTPError as err:
        return err.code, dict(err.headers), json.loads(err.read())


def test_health(api):
    base, _, _ = api
    assert request(base, "/health")[0::2] == (200, {"postgres": "ok", "redis": "ok"})


def test_notes_are_stored_and_cached(api):
    base, client, prefix = api
    status, headers, body = request(base, "/notes")
    assert (status, headers["x-cache"], body) == (200, "MISS", [])
    assert request(base, "/notes")[1]["x-cache"] == "HIT"
    status, _, note = request(base, "/notes", {"text": "hello from postgres"})
    assert status == 201 and note["text"] == "hello from postgres"
    assert request(base, "/notes")[1]["x-cache"] == "MISS"
    assert json.loads(client.get(f"{prefix}notes:all"))[0]["id"] == note["id"]
    assert request(base, f"/notes/{note['id']}")[2]["text"] == "hello from postgres"


def test_missing_and_invalid(api):
    base, _, _ = api
    assert request(base, "/notes/999999")[0] == 404
    assert request(base, "/notes", {"text": "   "})[0] == 400
    assert request(base, "/notes", b"not json")[0] == 400
