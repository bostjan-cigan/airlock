# Test projects

Small repositories for trying AIrlock on real code and checking that it behaves. They aren't
part of the app and nothing here ships in a release.

They're meant for three things:

- **Trying AIrlock.** Copy a sample out as its own repository, hand it to an agent with the
  prompt from its README, and watch a task go from start to handoff on code that's known to work.
- **Checking detection.** Each sample is shaped to exercise one part of how AIrlock sets up a
  task: which tools and versions it installs, which hosts it allows, which folders it keeps off
  the Mac, how big the container is, and which notices it shows. Their READMEs say what AIrlock
  should find, and `swift test` checks it (`TestProjectDetectionTests`).
- **Checking inspections.** `sample-node-malicious` is a harmless decoy shaped like an npm
  supply-chain attack, for seeing what an inspection reports.

Most samples are the same notes API (Postgres for storage, Redis for the cache) written in a
different stack, so a task on any of them looks alike: run the tests against the compose
services, add a small feature, commit.

| Folder | What's in it |
| --- | --- |
| [`Docker/`](Docker/README.md) | One sample per stack (Node, Python, Go, Rust, Java, Ruby, PHP), plus a monorepo, an `.airlock/compose.yaml` settings file, an iOS package and the inspection decoy. The table, how to check detection and how to run a task are in its README. |

## Quick start

```sh
TestProjects/Docker/make-repo.sh sample-python-notes   # → ~/AIrlockSamples/sample-python-notes
```

AIrlock tasks need a repository of their own, so `make-repo.sh` copies a sample outside this
checkout and commits it on `main`. Point a task at the copy, turn services on, and give it the
prompt from the sample's README. `make-repo.sh all` copies every sample.

Each sample has a `.gitignore` for the packages and build output its stack creates
(`node_modules/`, `.venv/`, `target/`, `vendor/`…), so a copy stays clean after you run it.
