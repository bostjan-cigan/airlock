# sample-airlock-config

A small Python tool that makes video thumbnails with ffmpeg. It has **no version files**,
so everything AIrlock needs comes from `.airlock/compose.yaml`:

```yaml
x-airlock:
  tools: { python: "3.13" }
  packages: [ffmpeg]
  resources: { cpus: 2, memory: 6g }
```

**What it tests:** the settings file when detection can't know enough. It also checks that
`requirements.txt` alone would give the newest Python, and the file pins 3.13 instead.

**What AIrlock should detect:**
- Tools: Python 3.13 "(with .airlock/compose.yaml)", plus the Debian package `ffmpeg`
- Size: 2 CPU · 6 GB, with the reason `.airlock/compose.yaml`
- Allowed hosts: pypi (from `requirements.txt`)

**Prompt:**
> Install `requirements.txt` in a virtualenv and run `pytest`. Then add a `--at` option to
> choose the thumbnail's timestamp, with a test. Commit.

**Pass criteria:** `python --version` is 3.13, `ffmpeg -version` works without
`airlock-install`, the inspector shows 2 CPU · 6 GB, and `pytest` passes.

To try the fallback flow, delete `.airlock/compose.yaml`. Detection then picks the newest
Python and no ffmpeg, so the thumbnail test fails. Add the file back, from the app's
**Create .airlock/compose.yaml** button or by hand.
