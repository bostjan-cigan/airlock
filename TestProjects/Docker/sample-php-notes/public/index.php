<?php
// Run with: php -S 0.0.0.0:3000 public/index.php
require __DIR__ . '/../vendor/autoload.php';

use Notes\App;
use Notes\Config;

$app = new App(new PDO(Config::dsn()), new Predis\Client(Config::redis()), Config::get('REDIS_PREFIX', 'notes-app:'));
[$status, $body, $headers] = $app->handle($_SERVER['REQUEST_METHOD'], parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH), file_get_contents('php://input'));
http_response_code($status);
header('content-type: application/json');
foreach ($headers as $name => $value) {
    header("$name: $value");
}
echo json_encode($body);
