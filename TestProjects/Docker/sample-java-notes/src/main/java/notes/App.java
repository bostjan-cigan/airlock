package notes;

import redis.clients.jedis.JedisPooled;

public final class App {
    public static void main(String[] args) throws Exception {
        Config config = Config.fromEnv();
        var server = new NotesServer(new Store(config), new JedisPooled(config.redisHost(), config.redisPort()), config.redisPrefix());
        int port = server.start(config.port());
        System.out.println("notes API on http://localhost:" + port);
    }
}
