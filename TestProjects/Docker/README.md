# AIrlock test projects

Each sample is the same small notes API (Postgres for storage, Redis for the cache) in a
different stack, or a project shape that exercises one part of AIrlock's detection. They
all come with tests that pass against the services in their `compose.yaml`.

| Sample | Stack | What it exercises |
| --- | --- | --- |
| `sample-app-multiple-containers` | Node 22, npm | Compose services next to the agent (the original sample) |
| `sample-python-notes` | Python 3.12 | `.python-version` and `requires-python`; `.venv` kept off the Mac |
| `sample-go-notes` | Go 1.22.5 | `go.mod`'s `toolchain` line wins over `go 1.22` |
| `sample-rust-notes` | Rust 1.90 | `rust-toolchain.toml`; heavy stack (8 GB); build output off the Mac |
| `sample-java-notes` | Java 21, Maven | `pom.xml` release; no Maven wrapper, so Maven is installed; heavy stack |
| `sample-ruby-notes` | Ruby 3.3.6 | `.tool-versions`; Ruby built from source; `airlock-install libpq-dev` learned |
| `sample-php-notes` | PHP 8.2, Composer | PHP from Debian packages; `airlock-install php-pgsql`; a blocked-host prompt |
| `sample-node-pnpm` | Node 20, pnpm 9 | `mise.toml` pins an older Node than the agent image's |
| `sample-monorepo` | Node, Python 3.11, Go 1.23 | Stacks found in subfolders (`services/api`, `workers/indexer`) |
| `sample-airlock-config` | Python 3.13, ffmpeg | `.airlock/compose.yaml`: tools, a Debian package and a size |
| `sample-ios-notes` | Swift (iOS) | The notice that Apple-platform code can't build in Linux |
| `sample-node-malicious` | Node | A harmless decoy for `inspect_repo`: install hooks that probe credentials and phone home |

Each sample's README says what AIrlock should detect, gives a prompt, and lists the pass
criteria. `sample-node-malicious` is the exception: it isn't a notes API, and its README
lists what an inspection should report instead. Inspect it in AIrlock; don't install it on
your Mac.

## Check detection without starting a task

```sh
cd Packages/AirlockKit
swift run airlock-cli detect ../../TestProjects/Docker/*/
```

For each sample this prints the tools, Debian packages, allowed hosts, dependency folders,
settings file, size and notices that a task would get. `swift test` checks the same results
(`TestProjectDetectionTests`).

## Try one as a task

AIrlock tasks need a repository of their own, so copy a sample out of this checkout first:

```sh
TestProjects/Docker/make-repo.sh sample-python-notes   # → ~/AIrlockSamples/sample-python-notes
TestProjects/Docker/make-repo.sh all                   # every sample
```

Then start a task on the copy, with services turned on, and give it the prompt from the
sample's README.

## Run a sample without AIrlock

```sh
docker compose up -d --wait postgres redis
docker compose run --rm --build app <test command>    # see the sample's README
docker compose down -v
```
