package notes;

/** Settings from the environment. Hostnames are the compose service names: inside AIrlock
 *  they resolve to 127.0.0.1 (services share the agent's network). */
public record Config(int port, String databaseUrl, String databaseUser, String databasePassword,
                     String redisHost, int redisPort, String redisPrefix) {
    public static Config fromEnv() {
        return new Config(
            Integer.parseInt(env("PORT", "3000")),
            env("JDBC_URL", "jdbc:postgresql://postgres:5432/app"),
            env("DATABASE_USER", "app"),
            env("DATABASE_PASSWORD", "app"),
            env("REDIS_HOST", "redis"),
            Integer.parseInt(env("REDIS_PORT", "6379")),
            env("REDIS_PREFIX", "notes-app:"));
    }

    private static String env(String key, String fallback) {
        String value = System.getenv(key);
        return value == null || value.isEmpty() ? fallback : value;
    }
}
