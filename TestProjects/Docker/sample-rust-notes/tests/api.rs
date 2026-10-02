//! Integration tests against the real Postgres and Redis from compose.yaml.
use notes::{App, Config};
use tiny_http::Method;

fn app() -> App {
    let config = Config::from_env();
    let app = App::connect(&config, &format!("test-{}:", std::process::id())).expect("databases reachable");
    app.truncate().unwrap();
    app
}

#[test]
fn notes_flow() {
    let app = app();
    assert_eq!(app.handle(&Method::Get, "/health", "").0, 200);
    let (status, body, headers) = app.handle(&Method::Get, "/notes", "");
    assert_eq!((status, body.as_str()), (200, "[]"));
    assert_eq!(headers[0].1, "MISS");
    assert_eq!(app.handle(&Method::Get, "/notes", "").2[0].1, "HIT");
    let (status, created, _) = app.handle(&Method::Post, "/notes", r#"{"text":"hello from postgres"}"#);
    assert_eq!(status, 201);
    assert_eq!(app.handle(&Method::Get, "/notes", "").2[0].1, "MISS");
    let id = serde_json::from_str::<serde_json::Value>(&created).unwrap()["id"].as_i64().unwrap();
    assert_eq!(app.handle(&Method::Get, &format!("/notes/{id}"), "").0, 200);
}

#[test]
fn missing_and_invalid() {
    let app = app();
    assert_eq!(app.handle(&Method::Get, "/notes/999999", "").0, 404);
    assert_eq!(app.handle(&Method::Post, "/notes", r#"{"text":"  "}"#).0, 400);
    assert_eq!(app.handle(&Method::Post, "/notes", "not json").0, 400);
}
