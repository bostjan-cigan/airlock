<?php

use Notes\App;
use Notes\Config;
use PHPUnit\Framework\TestCase;

/** Integration tests against the real Postgres and Redis from compose.yaml. */
final class AppTest extends TestCase
{
    private PDO $db;
    private Predis\Client $redis;
    private string $prefix;
    private App $app;

    protected function setUp(): void
    {
        $this->db = new PDO(Config::dsn());
        $this->redis = new Predis\Client(Config::redis());
        $this->prefix = 'test-' . getmypid() . ':';
        $this->app = new App($this->db, $this->redis, $this->prefix);
        $this->db->exec('TRUNCATE notes RESTART IDENTITY');
    }

    protected function tearDown(): void
    {
        foreach ($this->redis->keys($this->prefix . '*') as $key) {
            $this->redis->del($key);
        }
    }

    public function testNotesFlow(): void
    {
        $this->assertSame(200, $this->app->handle('GET', '/health', '')[0]);
        [$status, $body, $headers] = $this->app->handle('GET', '/notes', '');
        $this->assertSame([200, [], 'MISS'], [$status, $body, $headers['x-cache']]);
        $this->assertSame('HIT', $this->app->handle('GET', '/notes', '')[2]['x-cache']);
        [$status, $note] = $this->app->handle('POST', '/notes', json_encode(['text' => 'hello from postgres']));
        $this->assertSame(201, $status);
        $this->assertSame('MISS', $this->app->handle('GET', '/notes', '')[2]['x-cache']);
        $this->assertNotNull($this->redis->get($this->prefix . 'notes:all'));
        $this->assertSame('hello from postgres', $this->app->handle('GET', '/notes/' . $note['id'], '')[1]['text']);
    }

    public function testMissingAndInvalid(): void
    {
        $this->assertSame(404, $this->app->handle('GET', '/notes/999999', '')[0]);
        $this->assertSame(400, $this->app->handle('POST', '/notes', json_encode(['text' => '  ']))[0]);
        $this->assertSame(400, $this->app->handle('POST', '/notes', 'not json')[0]);
    }
}
