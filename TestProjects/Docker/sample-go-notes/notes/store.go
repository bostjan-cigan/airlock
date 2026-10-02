package notes

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Note struct {
	ID        int       `json:"id"`
	Text      string    `json:"text"`
	CreatedAt time.Time `json:"created_at"`
}

type Store struct{ pool *pgxpool.Pool }

func OpenStore(ctx context.Context, url string) (*Store, error) {
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, err
	}
	_, err = pool.Exec(ctx, `CREATE TABLE IF NOT EXISTS notes (
		id         SERIAL PRIMARY KEY,
		text       TEXT NOT NULL,
		created_at TIMESTAMPTZ NOT NULL DEFAULT now())`)
	return &Store{pool}, err
}

func (s *Store) Close()                              { s.pool.Close() }
func (s *Store) Ping(ctx context.Context) error      { return s.pool.Ping(ctx) }
func (s *Store) Truncate(ctx context.Context) error {
	_, err := s.pool.Exec(ctx, "TRUNCATE notes RESTART IDENTITY")
	return err
}

func (s *Store) List(ctx context.Context) ([]Note, error) {
	rows, err := s.pool.Query(ctx, "SELECT id, text, created_at FROM notes ORDER BY id")
	if err != nil {
		return nil, err
	}
	notes, err := pgx.CollectRows(rows, pgx.RowToStructByPos[Note])
	if notes == nil {
		notes = []Note{}
	}
	return notes, err
}

func (s *Store) Get(ctx context.Context, id int) (*Note, error) {
	var n Note
	err := s.pool.QueryRow(ctx, "SELECT id, text, created_at FROM notes WHERE id = $1", id).Scan(&n.ID, &n.Text, &n.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return &n, err
}

func (s *Store) Insert(ctx context.Context, text string) (Note, error) {
	var n Note
	err := s.pool.QueryRow(ctx, "INSERT INTO notes (text) VALUES ($1) RETURNING id, text, created_at", text).Scan(&n.ID, &n.Text, &n.CreatedAt)
	return n, err
}

func (s *Store) Count(ctx context.Context) (int, error) {
	var n int
	err := s.pool.QueryRow(ctx, "SELECT count(*)::int FROM notes").Scan(&n)
	return n, err
}
