<?php

namespace Notes;

use PDO;
use Predis\Client;

/**
 * Notes API.
 *   GET  /health     both databases reachable?
 *   GET  /notes      list (from Redis when cached; X-Cache: HIT|MISS)
 *   POST /notes      {"text": "..."} -> stored in Postgres, cache invalidated
 *   GET  /notes/{id} one note
 *   GET  /stats      request counter (Redis) + note count (Postgres)
 */
final class App
{
    public function __construct(private PDO $db, private Client $redis, private string $prefix)
    {
        $this->db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $this->db->exec('CREATE TABLE IF NOT EXISTS notes (id SERIAL PRIMARY KEY, text TEXT NOT NULL)');
    }

    private function key(string $name): string
    {
        return $this->prefix . $name;
    }

    /** @return array{0: int, 1: mixed, 2: array<string, string>} status, body, headers */
    public function handle(string $method, string $path, string $body): array
    {
        if ($path !== '/health') {
            $this->redis->incr($this->key('stats:requests'));
        }
        if ($method === 'GET' && $path === '/health') {
            $postgres = $this->check(fn () => $this->db->query('SELECT 1'));
            $redis = $this->check(fn () => $this->redis->ping());
            return [$postgres === 'ok' && $redis === 'ok' ? 200 : 503, ['postgres' => $postgres, 'redis' => $redis], []];
        }
        if ($method === 'GET' && $path === '/notes') {
            $cached = $this->redis->get($this->key('notes:all'));
            if ($cached !== null) {
                return [200, json_decode($cached, true), ['x-cache' => 'HIT']];
            }
            $notes = array_map(
                fn ($row) => ['id' => (int) $row['id'], 'text' => $row['text']],
                $this->db->query('SELECT id, text FROM notes ORDER BY id')->fetchAll(PDO::FETCH_ASSOC),
            );
            $this->redis->setex($this->key('notes:all'), 60, json_encode($notes));
            return [200, $notes, ['x-cache' => 'MISS']];
        }
        if ($method === 'POST' && $path === '/notes') {
            $data = json_decode($body, true);
            if (!is_array($data)) {
                return [400, ['error' => 'Body must be JSON'], []];
            }
            $text = trim((string) ($data['text'] ?? ''));
            if ($text === '') {
                return [400, ['error' => '"text" is required'], []];
            }
            $insert = $this->db->prepare('INSERT INTO notes (text) VALUES (?) RETURNING id, text');
            $insert->execute([$text]);
            $row = $insert->fetch(PDO::FETCH_ASSOC);
            $this->redis->del($this->key('notes:all'));
            return [201, ['id' => (int) $row['id'], 'text' => $row['text']], []];
        }
        if ($method === 'GET' && $path === '/stats') {
            $count = (int) $this->db->query('SELECT count(*) FROM notes')->fetchColumn();
            return [200, ['requests' => (int) $this->redis->get($this->key('stats:requests')), 'notes' => $count], []];
        }
        if ($method === 'GET' && preg_match('#^/notes/(\d+)$#', $path, $m)) {
            $select = $this->db->prepare('SELECT id, text FROM notes WHERE id = ?');
            $select->execute([(int) $m[1]]);
            $row = $select->fetch(PDO::FETCH_ASSOC);
            return $row ? [200, ['id' => (int) $row['id'], 'text' => $row['text']], []] : [404, ['error' => 'Not found'], []];
        }
        return [404, ['error' => 'Not found'], []];
    }

    private function check(callable $probe): string
    {
        try {
            $probe();
            return 'ok';
        } catch (\Throwable $e) {
            return $e->getMessage();
        }
    }
}
