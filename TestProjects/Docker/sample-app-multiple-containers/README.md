# sample-app-multiple-containers

A small Node.js notes API that uses two databases. It's an AIrlock test project
for tasks that need several service containers.

- **Postgres** (`postgres:16-alpine`) stores the notes.
- **Redis** (`redis:7-alpine`) caches the note list and counts requests.

There's no framework: the API uses `node:http` with `pg` and `redis` as its only
dependencies. The tests run with `node --test`.

## API

| Method | Path         | What it does                                                                |
| ------ | ------------ | --------------------------------------------------------------------------- |
| GET    | `/health`    | Returns `{"postgres":"ok","redis":"ok"}`, or `503` if either database is down |
| GET    | `/notes`     | Lists the notes, from Redis when cached. The `X-Cache` header says `HIT` or `MISS` |
| POST   | `/notes`     | Takes `{"text":"..."}`, inserts the note into Postgres and clears the cache |
| GET    | `/notes/:id` | Returns one note                                                            |
| GET    | `/stats`     | Returns `{"requests": <Redis counter>, "notes": <Postgres count>}`          |

The app reads its settings from these environment variables:

| Variable       | Default                                 |
| -------------- | --------------------------------------- |
| `DATABASE_URL` | `postgres://app:app@postgres:5432/app`  |
| `REDIS_URL`    | `redis://redis:6379`                    |
| `PORT`         | `3000`                                  |

The defaults use the compose service names as hostnames, so the same code works
inside AIrlock and under plain `docker compose`.

## Use it as an AIrlock test case

1. Make a standalone repository. AIrlock looks for `compose.yaml` at the repository root, so the sample can't stay inside the AIrlock checkout.

   ```sh
   TestProjects/Docker/sample-app-multiple-containers/scripts/make-repo.sh
   ```

   This creates `~/AIrlockSamples/sample-app-multiple-containers`. You can pass a different path as the first argument.

2. Start a task on that repository with **services enabled**.

   **What AIrlock should do:**
   - start `postgres` and `redis` beside the agent container, on the agent's network
   - skip `app`, because it's built from the repository and the agent runs the code itself
   - drop no settings from `postgres` or `redis`
   - keep the data in named volumes, prefixed per task

3. Give the agent a prompt that uses both databases. For example:

   > Run `npm install`, then `npm run check` and `npm test`, and report the output. Then add `DELETE /notes/:id`: remove the row from Postgres, invalidate the Redis cache, and return 204, or 404 if the note doesn't exist. Add a test for it and make sure `npm test` passes. Commit the change.

**Pass criteria:**
- `npm run check` prints `PASS` for both postgres and redis.
- `npm test` passes all tests, including the new one.
- `get_changes` shows the commit.

**Optional extra checks:**
- Expose port 3000 and run `npm start` in the task. Then `curl localhost:<port>/health` from the Mac.
- Restart one service (`restart_service redis`) and confirm `/health` recovers.

## Run without AIrlock

```sh
docker compose up -d --build --wait
docker compose exec app npm run check
docker compose exec app npm test
curl localhost:3000/health
docker compose down -v
```

To run it on the Mac against the compose databases, publish `5432` and `6379` in a
compose override. Then set:

- `DATABASE_URL=postgres://app:app@localhost:5432/app`
- `REDIS_URL=redis://localhost:6379`
