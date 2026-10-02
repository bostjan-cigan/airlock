import json

import redis


def connect(url):
    client = redis.Redis.from_url(url, socket_connect_timeout=3)
    client.ping()
    return client


class Cache:
    def __init__(self, client, prefix, ttl):
        self.client, self.prefix, self.ttl = client, prefix, ttl

    def _key(self, name):
        return f"{self.prefix}{name}"

    def get_json(self, name):
        raw = self.client.get(self._key(name))
        return None if raw is None else json.loads(raw)

    def set_json(self, name, value):
        self.client.set(self._key(name), json.dumps(value), ex=self.ttl)

    def delete(self, name):
        self.client.delete(self._key(name))

    def incr(self, name):
        return self.client.incr(self._key(name))

    def get_int(self, name):
        return int(self.client.get(self._key(name)) or 0)

    def ping(self):
        return self.client.ping()
