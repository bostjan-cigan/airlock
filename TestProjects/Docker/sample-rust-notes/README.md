# sample-rust-notes

The notes API in Rust (`tiny_http`, `postgres`, `redis`), with Postgres and Redis from
`compose.yaml`. The tests share one database, so run them with `--test-threads=1`.

**What it tests:** Rust detection from `rust-toolchain.toml` (`channel = "1.90"`), plus a
heavy stack.

**What AIrlock should detect:**
- Tools: Rust 1.90, installed with mise
- Allowed hosts: `crates.io`, `static.crates.io`, `index.crates.io`
- Build output: `CARGO_TARGET_DIR` on the cache volume, never in your checkout
- Size: automatic, 8 GB ("auto, Rust")

**Prompt:**
> Run `cargo test -- --test-threads=1` and report the output. Then add `DELETE /notes/{id}`
> (204, or 404 if missing; invalidate the cache), with a test. Commit.

**Pass criteria:** `rustc --version` is 1.90, crates download without allowing any host,
the tests pass, and no `target/` folder appears in the checkout on your Mac.
