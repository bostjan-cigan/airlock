# sample-monorepo

A notes monorepo with three stacks in subfolders, and Postgres and Redis from `compose.yaml`:

| Folder            | Stack       | Version from                      |
| ----------------- | ----------- | --------------------------------- |
| `web/`            | Node        | the root `package.json` workspace |
| `services/api/`   | Python      | `services/api/.python-version` (3.11) |
| `workers/indexer/`| Go          | `workers/indexer/go.mod` (1.23)   |

**What it tests:** detection in subfolders. A monorepo's stacks rarely sit at the root.

**What AIrlock should detect:**
- Tools: Node, Python 3.11 and Go 1.23
- Allowed hosts: npm, pypi and the Go module proxy
- Dependency folders: `node_modules` and `services/api/.venv` on volumes

**Prompt:**
> Run the tests of all three parts: `npm test` at the root, `pytest` in `services/api`
> (in a virtualenv), and `go test ./...` in `workers/indexer`. Report the output. Then make
> the indexer ignore words shorter than three letters, with a test. Commit.

**Pass criteria:** `python --version` is 3.11 and `go version` is 1.23, without any
configuration, and all three test suites pass.
