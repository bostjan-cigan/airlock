package notes

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	notesKey    = "notes:all"
	requestsKey = "stats:requests"
)

// Server is the notes API:
//
//	GET  /health     both databases reachable?
//	GET  /notes      list (from Redis when cached; X-Cache: HIT|MISS)
//	POST /notes      {"text": "..."} -> stored in Postgres, cache invalidated
//	GET  /notes/{id} one note
//	GET  /stats      request counter (Redis) + note count (Postgres)
type Server struct {
	Store  *Store
	Redis  *redis.Client
	Prefix string
}

func (s *Server) key(name string) string { return s.Prefix + name }

func send(w http.ResponseWriter, status int, body any) {
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(body)
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	if r.URL.Path != "/health" {
		s.Redis.Incr(ctx, s.key(requestsKey))
	}
	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/health":
		checks := map[string]string{"postgres": "ok", "redis": "ok"}
		status := http.StatusOK
		if err := s.Store.Ping(ctx); err != nil {
			checks["postgres"], status = err.Error(), http.StatusServiceUnavailable
		}
		if err := s.Redis.Ping(ctx).Err(); err != nil {
			checks["redis"], status = err.Error(), http.StatusServiceUnavailable
		}
		send(w, status, checks)
	case r.Method == http.MethodGet && r.URL.Path == "/notes":
		if cached, err := s.Redis.Get(ctx, s.key(notesKey)).Bytes(); err == nil {
			w.Header().Set("x-cache", "HIT")
			w.Header().Set("content-type", "application/json")
			w.Write(cached)
			return
		}
		notes, err := s.Store.List(ctx)
		if err != nil {
			send(w, 500, map[string]string{"error": err.Error()})
			return
		}
		data, _ := json.Marshal(notes)
		s.Redis.Set(ctx, s.key(notesKey), data, time.Minute)
		w.Header().Set("x-cache", "MISS")
		send(w, 200, notes)
	case r.Method == http.MethodPost && r.URL.Path == "/notes":
		var body struct{ Text string `json:"text"` }
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			send(w, 400, map[string]string{"error": "Body must be JSON"})
			return
		}
		text := strings.TrimSpace(body.Text)
		if text == "" {
			send(w, 400, map[string]string{"error": `"text" is required`})
			return
		}
		note, err := s.Store.Insert(ctx, text)
		if err != nil {
			send(w, 500, map[string]string{"error": err.Error()})
			return
		}
		s.Redis.Del(ctx, s.key(notesKey))
		send(w, 201, note)
	case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/notes/"):
		id, err := strconv.Atoi(strings.TrimPrefix(r.URL.Path, "/notes/"))
		if err != nil {
			send(w, 404, map[string]string{"error": "Not found"})
			return
		}
		note, err := s.Store.Get(ctx, id)
		if err != nil || note == nil {
			send(w, 404, map[string]string{"error": "Not found"})
			return
		}
		send(w, 200, note)
	case r.Method == http.MethodGet && r.URL.Path == "/stats":
		requests, _ := s.Redis.Get(ctx, s.key(requestsKey)).Int()
		count, _ := s.Store.Count(ctx)
		send(w, 200, map[string]int{"requests": requests, "notes": count})
	default:
		send(w, 404, map[string]string{"error": "Not found"})
	}
}
