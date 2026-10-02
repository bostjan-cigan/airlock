//! Notes API on `tiny_http`, with Postgres for storage and Redis for the cache.
//!
//!   GET  /health     both databases reachable?
//!   GET  /notes      list (from Redis when cached; X-Cache: HIT|MISS)
//!   POST /notes      {"text": "..."} -> stored in Postgres, cache invalidated
//!   GET  /notes/{id} one note
//!   GET  /stats      request counter (Redis) + note count (Postgres)
use postgres::{Client, NoTls};
use redis::Commands;
use serde::{Deserialize, Serialize};
use std::io::Read;
use std::sync::Mutex;
use tiny_http::{Header, Method, Request, Response, Server};

const NOTES_KEY: &str = "notes:all";
const REQUESTS_KEY: &str = "stats:requests";

/// Hostnames are the compose service names: inside AIrlock they resolve to 127.0.0.1.
pub struct Config {
    pub port: u16,
    pub database_url: String,
    pub redis_url: String,
    pub redis_prefix: String,
}

impl Config {
    pub fn from_env() -> Self {
        let var = |key: &str, fallback: &str| std::env::var(key).unwrap_or_else(|_| fallback.to_string());
        Config {
            port: var("PORT", "3000").parse().unwrap_or(3000),
            database_url: var("DATABASE_URL", "postgres://app:app@postgres:5432/app"),
            redis_url: var("REDIS_URL", "redis://redis:6379"),
            redis_prefix: var("REDIS_PREFIX", "notes-app:"),
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Note {
    pub id: i32,
    pub text: String,
}

pub struct App {
    db: Mutex<Client>,
    redis: Mutex<redis::Connection>,
    prefix: String,
}

impl App {
    pub fn connect(config: &Config, prefix: &str) -> Result<Self, Box<dyn std::error::Error>> {
        let mut db = Client::connect(&config.database_url, NoTls)?;
        db.batch_execute("CREATE TABLE IF NOT EXISTS notes (id SERIAL PRIMARY KEY, text TEXT NOT NULL)")?;
        let redis = redis::Client::open(config.redis_url.as_str())?.get_connection()?;
        Ok(App { db: Mutex::new(db), redis: Mutex::new(redis), prefix: prefix.to_string() })
    }

    pub fn truncate(&self) -> Result<(), postgres::Error> {
        self.db.lock().unwrap().batch_execute("TRUNCATE notes RESTART IDENTITY")
    }

    fn key(&self, name: &str) -> String {
        format!("{}{}", self.prefix, name)
    }

    /// Answers one request: (status, body, extra headers).
    pub fn handle(&self, method: &Method, path: &str, body: &str) -> (u16, String, Vec<(String, String)>) {
        let mut redis = self.redis.lock().unwrap();
        let mut db = self.db.lock().unwrap();
        if path != "/health" {
            let _: Result<i64, _> = redis.incr(self.key(REQUESTS_KEY), 1);
        }
        let error = |status: u16, message: &str| (status, serde_json::json!({ "error": message }).to_string(), vec![]);
        match (method, path) {
            (Method::Get, "/health") => {
                let postgres = db.simple_query("SELECT 1").map(|_| "ok".to_string()).unwrap_or_else(|e| e.to_string());
                let redis_ok = redis::cmd("PING").query::<String>(&mut *redis).map(|_| "ok".to_string()).unwrap_or_else(|e| e.to_string());
                let status = if postgres == "ok" && redis_ok == "ok" { 200 } else { 503 };
                (status, serde_json::json!({ "postgres": postgres, "redis": redis_ok }).to_string(), vec![])
            }
            (Method::Get, "/notes") => {
                if let Ok(Some(cached)) = redis.get::<_, Option<String>>(self.key(NOTES_KEY)) {
                    return (200, cached, vec![("x-cache".into(), "HIT".into())]);
                }
                let notes: Vec<Note> = db
                    .query("SELECT id, text FROM notes ORDER BY id", &[])
                    .map(|rows| rows.iter().map(|r| Note { id: r.get(0), text: r.get(1) }).collect())
                    .unwrap_or_default();
                let json = serde_json::to_string(&notes).unwrap();
                let _: Result<(), _> = redis.set_ex(self.key(NOTES_KEY), &json, 60);
                (200, json, vec![("x-cache".into(), "MISS".into())])
            }
            (Method::Post, "/notes") => {
                let Ok(value) = serde_json::from_str::<serde_json::Value>(body) else { return error(400, "Body must be JSON") };
                let text = value.get("text").and_then(|t| t.as_str()).unwrap_or("").trim().to_string();
                if text.is_empty() {
                    return error(400, "\"text\" is required");
                }
                match db.query_one("INSERT INTO notes (text) VALUES ($1) RETURNING id, text", &[&text]) {
                    Ok(row) => {
                        let _: Result<(), _> = redis.del(self.key(NOTES_KEY));
                        (201, serde_json::to_string(&Note { id: row.get(0), text: row.get(1) }).unwrap(), vec![])
                    }
                    Err(e) => error(500, &e.to_string()),
                }
            }
            (Method::Get, "/stats") => {
                let requests: i64 = redis.get(self.key(REQUESTS_KEY)).unwrap_or(0);
                let notes: i64 = db.query_one("SELECT count(*) FROM notes", &[]).map(|r| r.get(0)).unwrap_or(0);
                (200, serde_json::json!({ "requests": requests, "notes": notes }).to_string(), vec![])
            }
            (Method::Get, p) if p.starts_with("/notes/") => {
                let Ok(id) = p["/notes/".len()..].parse::<i32>() else { return error(404, "Not found") };
                match db.query_opt("SELECT id, text FROM notes WHERE id = $1", &[&id]) {
                    Ok(Some(row)) => (200, serde_json::to_string(&Note { id: row.get(0), text: row.get(1) }).unwrap(), vec![]),
                    _ => error(404, "Not found"),
                }
            }
            _ => error(404, "Not found"),
        }
    }

    pub fn respond(&self, mut request: Request) {
        let mut body = String::new();
        let _ = request.as_reader().read_to_string(&mut body);
        let (status, json, headers) = self.handle(request.method(), request.url(), &body);
        let mut response = Response::from_string(json).with_status_code(status)
            .with_header(Header::from_bytes("content-type", "application/json").unwrap());
        for (name, value) in headers {
            response = response.with_header(Header::from_bytes(name.as_bytes(), value.as_bytes()).unwrap());
        }
        let _ = request.respond(response);
    }

    pub fn serve(&self, port: u16) {
        let server = Server::http(("0.0.0.0", port)).expect("listen");
        for request in server.incoming_requests() {
            self.respond(request);
        }
    }
}
