package main

import (
	"context"
	"log"
	"net/http"

	"example.com/notes/notes"
	"github.com/redis/go-redis/v9"
)

func main() {
	cfg := notes.LoadConfig()
	store, err := notes.OpenStore(context.Background(), cfg.DatabaseURL)
	if err != nil {
		log.Fatal(err)
	}
	opts, err := redis.ParseURL(cfg.RedisURL)
	if err != nil {
		log.Fatal(err)
	}
	server := &notes.Server{Store: store, Redis: redis.NewClient(opts), Prefix: cfg.RedisPrefix}
	log.Printf("notes API on http://localhost:%s", cfg.Port)
	log.Fatal(http.ListenAndServe(":"+cfg.Port, server))
}
