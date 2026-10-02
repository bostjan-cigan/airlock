<?php

namespace Notes;

/** Settings from the environment. Hostnames are the compose service names: inside AIrlock
 *  they resolve to 127.0.0.1 (services share the agent's network). */
final class Config
{
    public static function get(string $key, string $fallback): string
    {
        $value = getenv($key);
        return $value === false || $value === '' ? $fallback : $value;
    }

    public static function dsn(): string
    {
        return self::get('DATABASE_DSN', 'pgsql:host=postgres;port=5432;dbname=app;user=app;password=app');
    }

    public static function redis(): string
    {
        return self::get('REDIS_URL', 'tcp://redis:6379');
    }
}
