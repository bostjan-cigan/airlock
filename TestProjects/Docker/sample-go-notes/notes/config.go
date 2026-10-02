package notes

import "os"

// Config comes from the environment. Hostnames are the compose service names: inside
// AIrlock they resolve to 127.0.0.1 (services share the agent's network).
type Config struct {
	Port        string
	DatabaseURL string
	RedisURL    string
	RedisPrefix string
}

func LoadConfig() Config {
	return Config{
		Port:        env("PORT", "3000"),
		DatabaseURL: env("DATABASE_URL", "postgres://app:app@postgres:5432/app"),
		RedisURL:    env("REDIS_URL", "redis://redis:6379"),
		RedisPrefix: env("REDIS_PREFIX", "notes-app:"),
	}
}

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
