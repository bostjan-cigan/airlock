package notes;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.stream.Collectors;
import redis.clients.jedis.JedisPooled;

/**
 * Notes API on the JDK's HTTP server.
 *   GET  /health     both databases reachable?
 *   GET  /notes      list (from Redis when cached; X-Cache: HIT|MISS)
 *   POST /notes      {"text": "..."} -> stored in Postgres, cache invalidated
 *   GET  /notes/{id} one note
 *   GET  /stats      request counter (Redis) + note count (Postgres)
 */
public final class NotesServer {
    private final Store store;
    private final JedisPooled redis;
    private final String prefix;
    private HttpServer server;

    public NotesServer(Store store, JedisPooled redis, String prefix) {
        this.store = store;
        this.redis = redis;
        this.prefix = prefix;
    }

    public int start(int port) throws IOException {
        server = HttpServer.create(new InetSocketAddress(port), 0);
        server.createContext("/", this::handle);
        server.start();
        return server.getAddress().getPort();
    }

    public void stop() { server.stop(0); }

    private void handle(HttpExchange exchange) throws IOException {
        String path = exchange.getRequestURI().getPath();
        String method = exchange.getRequestMethod();
        try {
            if (!path.equals("/health")) redis.incr(prefix + "stats:requests");
            if (method.equals("GET") && path.equals("/health")) {
                boolean db = store.ping();
                boolean cache = "PONG".equals(redis.ping());
                send(exchange, db && cache ? 200 : 503,
                     "{\"postgres\":\"" + (db ? "ok" : "down") + "\",\"redis\":\"" + (cache ? "ok" : "down") + "\"}", null);
            } else if (method.equals("GET") && path.equals("/notes")) {
                String cached = redis.get(prefix + "notes:all");
                if (cached != null) {
                    send(exchange, 200, cached, "HIT");
                } else {
                    String json = store.list().stream().map(Store.Note::json).collect(Collectors.joining(",", "[", "]"));
                    redis.setex(prefix + "notes:all", 60, json);
                    send(exchange, 200, json, "MISS");
                }
            } else if (method.equals("POST") && path.equals("/notes")) {
                String text = Json.text(new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8));
                if (text == null) {
                    send(exchange, 400, "{\"error\":\"Body must be JSON with \\\"text\\\"\"}", null);
                } else if (text.isBlank()) {
                    send(exchange, 400, "{\"error\":\"\\\"text\\\" is required\"}", null);
                } else {
                    Store.Note note = store.insert(text.trim());
                    redis.del(prefix + "notes:all");
                    send(exchange, 201, note.json(), null);
                }
            } else if (method.equals("GET") && path.equals("/stats")) {
                String requests = redis.get(prefix + "stats:requests");
                send(exchange, 200, "{\"requests\":" + (requests == null ? 0 : requests) + ",\"notes\":" + store.count() + "}", null);
            } else if (method.equals("GET") && path.matches("/notes/\\d+")) {
                var note = store.get(Integer.parseInt(path.substring("/notes/".length())));
                if (note.isPresent()) send(exchange, 200, note.get().json(), null);
                else send(exchange, 404, "{\"error\":\"Not found\"}", null);
            } else {
                send(exchange, 404, "{\"error\":\"Not found\"}", null);
            }
        } catch (Exception e) {
            send(exchange, 500, "{\"error\":" + Json.quote(String.valueOf(e.getMessage())) + "}", null);
        }
    }

    private static void send(HttpExchange exchange, int status, String json, String cache) throws IOException {
        byte[] body = json.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("content-type", "application/json");
        if (cache != null) exchange.getResponseHeaders().set("x-cache", cache);
        exchange.sendResponseHeaders(status, body.length);
        exchange.getResponseBody().write(body);
        exchange.close();
    }
}
