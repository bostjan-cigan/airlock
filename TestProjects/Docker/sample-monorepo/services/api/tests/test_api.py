"""Integration tests against the real Postgres and Redis from compose.yaml."""
import json
import threading
import urllib.request

from api.main import connect, create_server


def test_health_and_notes():
    conn, cache = connect()
    server = create_server(conn, cache)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    with urllib.request.urlopen(base + "/health") as res:
        assert json.loads(res.read()) == {"postgres": "ok", "redis": "ok"}
    req = urllib.request.Request(base + "/notes", data=json.dumps({"text": "from the api"}).encode(), method="POST")
    with urllib.request.urlopen(req) as res:
        assert res.status == 201
    server.shutdown()
