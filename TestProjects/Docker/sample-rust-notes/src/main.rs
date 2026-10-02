fn main() {
    let config = notes::Config::from_env();
    let app = notes::App::connect(&config, &config.redis_prefix).expect("connect to the databases");
    println!("notes API on http://localhost:{}", config.port);
    app.serve(config.port);
}
