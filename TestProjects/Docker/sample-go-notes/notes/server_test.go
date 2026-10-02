package notes

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/redis/go-redis/v9"
)

// Integration tests against the real Postgres and Redis from compose.yaml.
func setup(t *testing.T) (*httptest.Server, *redis.Client, string) {
	t.Helper()
	ctx := context.Background()
	cfg := LoadConfig()
	store, err := OpenStore(ctx, cfg.DatabaseURL)
	if err != nil {
		t.Fatalf("postgres: %v", err)
	}
	if err := store.Truncate(ctx); err != nil {
		t.Fatal(err)
	}
	opts, err := redis.ParseURL(cfg.RedisURL)
	if err != nil {
		t.Fatal(err)
	}
	client := redis.NewClient(opts)
	prefix := fmt.Sprintf("test-%d:", os.Getpid())
	server := httptest.NewServer(&Server{Store: store, Redis: client, Prefix: prefix})
	t.Cleanup(func() {
		server.Close()
		keys, _ := client.Keys(ctx, prefix+"*").Result()
		if len(keys) > 0 {
			client.Del(ctx, keys...)
		}
		client.Close()
		store.Close()
	})
	return server, client, prefix
}

func TestNotesFlow(t *testing.T) {
	server, client, prefix := setup(t)
	res, _ := http.Get(server.URL + "/health")
	if res.StatusCode != 200 {
		t.Fatalf("health: %d", res.StatusCode)
	}
	first, _ := http.Get(server.URL + "/notes")
	if first.Header.Get("x-cache") != "MISS" {
		t.Fatal("first read should miss the cache")
	}
	second, _ := http.Get(server.URL + "/notes")
	if second.Header.Get("x-cache") != "HIT" {
		t.Fatal("second read should hit the cache")
	}
	created, _ := http.Post(server.URL+"/notes", "application/json", bytes.NewBufferString(`{"text":"hello from postgres"}`))
	if created.StatusCode != 201 {
		t.Fatalf("create: %d", created.StatusCode)
	}
	var note Note
	json.NewDecoder(created.Body).Decode(&note)
	after, _ := http.Get(server.URL + "/notes")
	if after.Header.Get("x-cache") != "MISS" {
		t.Fatal("writing should invalidate the cache")
	}
	if exists, _ := client.Exists(context.Background(), prefix+"notes:all").Result(); exists != 1 {
		t.Fatal("list should be cached in Redis")
	}
	one, _ := http.Get(fmt.Sprintf("%s/notes/%d", server.URL, note.ID))
	if one.StatusCode != 200 {
		t.Fatalf("get one: %d", one.StatusCode)
	}
}

func TestMissingAndInvalid(t *testing.T) {
	server, _, _ := setup(t)
	if res, _ := http.Get(server.URL + "/notes/999999"); res.StatusCode != 404 {
		t.Fatalf("missing: %d", res.StatusCode)
	}
	if res, _ := http.Post(server.URL+"/notes", "application/json", bytes.NewBufferString(`{"text":"  "}`)); res.StatusCode != 400 {
		t.Fatalf("blank: %d", res.StatusCode)
	}
	if res, _ := http.Post(server.URL+"/notes", "application/json", bytes.NewBufferString(`not json`)); res.StatusCode != 400 {
		t.Fatalf("bad json: %d", res.StatusCode)
	}
}
