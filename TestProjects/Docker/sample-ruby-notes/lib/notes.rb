# Notes API on WEBrick, with Postgres for storage and Redis for the cache.
#
#   GET  /health     both databases reachable?
#   GET  /notes      list (from Redis when cached; X-Cache: HIT|MISS)
#   POST /notes      {"text": "..."} -> stored in Postgres, cache invalidated
#   GET  /notes/:id  one note
#   GET  /stats      request counter (Redis) + note count (Postgres)
require "json"
require "pg"
require "redis"
require "webrick"

module Notes
  # Hostnames are the compose service names: inside AIrlock they resolve to 127.0.0.1.
  CONFIG = {
    port: Integer(ENV.fetch("PORT", "3000")),
    database_url: ENV.fetch("DATABASE_URL", "postgres://app:app@postgres:5432/app"),
    redis_url: ENV.fetch("REDIS_URL", "redis://redis:6379"),
    redis_prefix: ENV.fetch("REDIS_PREFIX", "notes-app:")
  }.freeze

  def self.connect_db(url = CONFIG[:database_url])
    db = PG.connect(url)
    db.exec("CREATE TABLE IF NOT EXISTS notes (id SERIAL PRIMARY KEY, text TEXT NOT NULL)")
    db
  end

  class App
    def initialize(db, redis, prefix)
      @db, @redis, @prefix, @lock = db, redis, prefix, Mutex.new
    end

    def key(name) = "#{@prefix}#{name}"

    # [status, body, headers]
    def call(method, path, body)
      @lock.synchronize do
        @redis.incr(key("stats:requests")) unless path == "/health"
        case [method, path]
        in ["GET", "/health"]
          checks = { postgres: check { @db.exec("SELECT 1") }, redis: check { @redis.ping } }
          [checks.values.all?("ok") ? 200 : 503, checks, {}]
        in ["GET", "/notes"]
          if (cached = @redis.get(key("notes:all")))
            [200, JSON.parse(cached), { "x-cache" => "HIT" }]
          else
            notes = @db.exec("SELECT id, text FROM notes ORDER BY id").map { { id: _1["id"].to_i, text: _1["text"] } }
            @redis.set(key("notes:all"), notes.to_json, ex: 60)
            [200, notes, { "x-cache" => "MISS" }]
          end
        in ["POST", "/notes"]
          text = begin
            JSON.parse(body.to_s).fetch("text", "").to_s.strip
          rescue JSON::ParserError
            return [400, { error: "Body must be JSON" }, {}]
          end
          return [400, { error: '"text" is required' }, {}] if text.empty?
          row = @db.exec_params("INSERT INTO notes (text) VALUES ($1) RETURNING id, text", [text]).first
          @redis.del(key("notes:all"))
          [201, { id: row["id"].to_i, text: row["text"] }, {}]
        in ["GET", "/stats"]
          [200, { requests: @redis.get(key("stats:requests")).to_i, notes: @db.exec("SELECT count(*) FROM notes").getvalue(0, 0).to_i }, {}]
        in ["GET", %r{\A/notes/(\d+)\z}]
          row = @db.exec_params("SELECT id, text FROM notes WHERE id = $1", [Regexp.last_match(1).to_i]).first
          row ? [200, { id: row["id"].to_i, text: row["text"] }, {}] : [404, { error: "Not found" }, {}]
        else
          [404, { error: "Not found" }, {}]
        end
      end
    end

    def check
      yield
      "ok"
    rescue StandardError => e
      e.message
    end

    def server(port)
      server = WEBrick::HTTPServer.new(Port: port, AccessLog: [], Logger: WEBrick::Log.new(File::NULL))
      server.mount_proc("/") do |req, res|
        status, body, headers = call(req.request_method, req.path, req.body)
        res.status = status
        res["content-type"] = "application/json"
        headers.each { |name, value| res[name] = value }
        res.body = body.to_json
      end
      server
    end
  end
end
