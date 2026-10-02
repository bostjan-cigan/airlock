import psycopg
from psycopg.rows import dict_row


def connect(url):
    return psycopg.connect(url, autocommit=True, row_factory=dict_row)


def migrate(conn):
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS notes (
          id         SERIAL PRIMARY KEY,
          text       TEXT NOT NULL,
          created_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        """
    )


def _row(note):
    return {**note, "created_at": note["created_at"].isoformat()}


def list_notes(conn):
    return [_row(n) for n in conn.execute("SELECT id, text, created_at FROM notes ORDER BY id")]


def get_note(conn, note_id):
    note = conn.execute("SELECT id, text, created_at FROM notes WHERE id = %s", (note_id,)).fetchone()
    return _row(note) if note else None


def insert_note(conn, text):
    note = conn.execute("INSERT INTO notes (text) VALUES (%s) RETURNING id, text, created_at", (text,)).fetchone()
    return _row(note)


def count_notes(conn):
    return conn.execute("SELECT count(*)::int AS n FROM notes").fetchone()["n"]
