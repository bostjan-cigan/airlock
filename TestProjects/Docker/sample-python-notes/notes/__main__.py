from . import cache, config, db
from .app import create_server

conn = db.connect(config.DATABASE_URL)
db.migrate(conn)
store = cache.Cache(cache.connect(config.REDIS_URL), config.REDIS_PREFIX, config.CACHE_TTL_SECONDS)
server = create_server(conn, store, config.PORT)
print(f"notes API on http://localhost:{config.PORT}")
server.serve_forever()
