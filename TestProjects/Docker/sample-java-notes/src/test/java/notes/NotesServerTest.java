package notes;

import static org.junit.jupiter.api.Assertions.*;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import org.junit.jupiter.api.*;
import redis.clients.jedis.JedisPooled;

/** Integration tests against the real Postgres and Redis from compose.yaml. */
class NotesServerTest {
    static Store store;
    static JedisPooled redis;
    static NotesServer server;
    static String base;
    static final String PREFIX = "test-" + ProcessHandle.current().pid() + ":";
    static final HttpClient http = HttpClient.newHttpClient();

    @BeforeAll
    static void start() throws Exception {
        Config config = Config.fromEnv();
        store = new Store(config);
        store.truncate();
        redis = new JedisPooled(config.redisHost(), config.redisPort());
        server = new NotesServer(store, redis, PREFIX);
        base = "http://127.0.0.1:" + server.start(0);
    }

    @AfterAll
    static void stop() throws Exception {
        server.stop();
        redis.keys(PREFIX + "*").forEach(redis::del);
        store.close();
    }

    static HttpResponse<String> get(String path) throws Exception {
        return http.send(HttpRequest.newBuilder(URI.create(base + path)).build(), HttpResponse.BodyHandlers.ofString());
    }

    static HttpResponse<String> post(String path, String body) throws Exception {
        return http.send(HttpRequest.newBuilder(URI.create(base + path)).POST(HttpRequest.BodyPublishers.ofString(body)).build(),
                         HttpResponse.BodyHandlers.ofString());
    }

    @Test
    void notesFlow() throws Exception {
        assertEquals(200, get("/health").statusCode());
        var first = get("/notes");
        assertEquals("[]", first.body());
        assertEquals("MISS", first.headers().firstValue("x-cache").orElseThrow());
        assertEquals("HIT", get("/notes").headers().firstValue("x-cache").orElseThrow());
        var created = post("/notes", "{\"text\": \"hello from postgres\"}");
        assertEquals(201, created.statusCode());
        assertEquals("MISS", get("/notes").headers().firstValue("x-cache").orElseThrow());
        assertNotNull(redis.get(PREFIX + "notes:all"));
        assertEquals(200, get("/notes/1").statusCode());
    }

    @Test
    void missingAndInvalid() throws Exception {
        assertEquals(404, get("/notes/999999").statusCode());
        assertEquals(400, post("/notes", "{\"text\": \"  \"}").statusCode());
        assertEquals(400, post("/notes", "not json").statusCode());
    }
}
