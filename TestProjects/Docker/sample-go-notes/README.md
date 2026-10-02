# sample-go-notes

The notes API in Go (`net/http`, `pgx`, `go-redis`), with Postgres and Redis from `compose.yaml`.

**What it tests:** Go detection from `go.mod`. Its `toolchain go1.22.5` line wins over
`go 1.22`.

**What AIrlock should detect:**
- Tools: Go 1.22.5, installed with mise
- Allowed hosts: `proxy.golang.org`, `sum.golang.org`
- Caches: `GOMODCACHE` and `GOCACHE` on the project's cache volume
- Size: automatic, 4 GB

**Prompt:**
> Run `go test ./...` and report the output. Then add `DELETE /notes/{id}` (204, or 404 if
> missing; invalidate the cache), with a test. Commit.

**Pass criteria:** `go version` is go1.22.5, modules download without allowing any host,
and `go test ./...` passes.
