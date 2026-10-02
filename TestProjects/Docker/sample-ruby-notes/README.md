# sample-ruby-notes

The notes API in Ruby (WEBrick, `pg`, `redis`, Minitest), with Postgres and Redis from
`compose.yaml`.

**What it tests:**
- Ruby detection from `.tool-versions` (`ruby 3.3.6`), which mise builds from source with
  the build packages AIrlock adds.
- The `pg` gem compiles against `libpq-dev`, which nothing installs up front. The agent
  installs it with `airlock-install libpq-dev`, and AIrlock bakes it into the project's
  next image.

**What AIrlock should detect:**
- Tools: Ruby 3.3.6, plus build packages (`build-essential`, `libssl-dev`, `libyaml-dev`…)
- Allowed hosts: `rubygems.org`, `index.rubygems.org`
- Caches: gems in `BUNDLE_PATH` on the project's cache volume

**Prompt:**
> Run `bundle install` (install any Debian packages it needs with `airlock-install`), then
> `bundle exec rake test`. Then add `DELETE /notes/:id` (204, or 404 if missing; invalidate
> the cache), with a test. Commit.

**Pass criteria:**
- `ruby -v` is 3.3.6.
- The agent runs `airlock-install libpq-dev` and the gems install.
- The tests pass.
- The project's next task already has `libpq-dev`.
