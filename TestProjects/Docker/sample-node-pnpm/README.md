# sample-node-pnpm

The original notes API (`node:http`, `pg`, `redis`, `node --test`), but on Node 20 with
pnpm, both pinned in `mise.toml`. Postgres and Redis come from `compose.yaml`.

**What it tests:** version pins from `mise.toml`, which win over `package.json`.
The agent image ships Node 22, so this checks that a pinned older Node really replaces it
(Claude Code itself doesn't depend on it).

**What AIrlock should detect:**
- Tools: Node 20 and pnpm 9, installed with mise
- Allowed hosts: `registry.npmjs.org`, `registry.yarnpkg.com`
- Dependency folder: `node_modules` on a volume, so it stays out of your checkout
- Caches: the pnpm store on the project's cache volume

**Prompt:**
> Run `pnpm install`, `pnpm run check` and `pnpm test`, and report the output. Then add
> `DELETE /notes/:id` (204, or 404 if missing; invalidate the cache), with a test. Commit.

**Pass criteria:** `node -v` is v20.x, `pnpm -v` is 9.x, the tests pass, and
`node_modules` doesn't appear in the checkout on your Mac.
