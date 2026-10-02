"""Settings from the environment. Hostnames are the compose service names: inside
AIrlock they resolve to 127.0.0.1 (services share the agent's network)."""
import os

PORT = int(os.environ.get("PORT", "3000"))
DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://app:app@postgres:5432/app")
REDIS_URL = os.environ.get("REDIS_URL", "redis://redis:6379")
REDIS_PREFIX = os.environ.get("REDIS_PREFIX", "notes-app:")
CACHE_TTL_SECONDS = int(os.environ.get("CACHE_TTL_SECONDS", "60"))
