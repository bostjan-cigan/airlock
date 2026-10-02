# Integration tests against the real Postgres and Redis from compose.yaml.
require "minitest/autorun"
require_relative "../lib/notes"

class NotesTest < Minitest::Test
  def setup
    @db = Notes.connect_db
    @db.exec("TRUNCATE notes RESTART IDENTITY")
    @redis = Redis.new(url: Notes::CONFIG[:redis_url])
    @prefix = "test-#{Process.pid}:"
    @app = Notes::App.new(@db, @redis, @prefix)
  end

  def teardown
    keys = @redis.keys("#{@prefix}*")
    @redis.del(*keys) unless keys.empty?
    @db.close
  end

  def test_notes_flow
    assert_equal 200, @app.call("GET", "/health", nil)[0]
    status, body, headers = @app.call("GET", "/notes", nil)
    assert_equal [200, [], "MISS"], [status, body, headers["x-cache"]]
    assert_equal "HIT", @app.call("GET", "/notes", nil)[2]["x-cache"]
    status, note, = @app.call("POST", "/notes", { text: "hello from postgres" }.to_json)
    assert_equal 201, status
    assert_equal "MISS", @app.call("GET", "/notes", nil)[2]["x-cache"]
    refute_nil @redis.get("#{@prefix}notes:all")
    assert_equal "hello from postgres", @app.call("GET", "/notes/#{note[:id]}", nil)[1][:text]
  end

  def test_missing_and_invalid
    assert_equal 404, @app.call("GET", "/notes/999999", nil)[0]
    assert_equal 400, @app.call("POST", "/notes", { text: "  " }.to_json)[0]
    assert_equal 400, @app.call("POST", "/notes", "not json")[0]
  end
end
