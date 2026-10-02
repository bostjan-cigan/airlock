import pg from 'pg';

export function createPool(databaseUrl) {
  return new pg.Pool({ connectionString: databaseUrl, max: 5 });
}

export async function migrate(pool) {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS notes (
      id         SERIAL PRIMARY KEY,
      text       TEXT NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
  `);
}

export async function listNotes(pool) {
  const { rows } = await pool.query('SELECT id, text, created_at FROM notes ORDER BY id');
  return rows;
}

export async function getNote(pool, id) {
  const { rows } = await pool.query('SELECT id, text, created_at FROM notes WHERE id = $1', [id]);
  return rows[0] ?? null;
}

export async function insertNote(pool, text) {
  const { rows } = await pool.query(
    'INSERT INTO notes (text) VALUES ($1) RETURNING id, text, created_at',
    [text],
  );
  return rows[0];
}

export async function countNotes(pool) {
  const { rows } = await pool.query('SELECT count(*)::int AS n FROM notes');
  return rows[0].n;
}
