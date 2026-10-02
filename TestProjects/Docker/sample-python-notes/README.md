# sample-python-notes

The notes API in Python (standard-library HTTP server, `psycopg`, `redis`, `pytest`),
with Postgres and Redis from `compose.yaml`.

**What it tests:** Python detection from `.python-version` (3.12) and
`pyproject.toml` (`requires-python = "~=3.12"`), with no AIrlock configuration.

**What AIrlock should detect:**
- Tools: Python 3.12, installed with mise
- Allowed hosts: `pypi.org`, `files.pythonhosted.org`
- Dependency folder: `.venv` on a volume, so it stays out of your checkout
- Size: automatic, 4 GB

**Prompt:**
> Create a virtualenv in `.venv`, install `requirements.txt`, and run `pytest`. Then add
> `DELETE /notes/<id>` (204, or 404 if missing; invalidate the cache), with a test. Commit.

**Pass criteria:** `python --version` is 3.12, `pip install` works without allowing any
host, and `pytest` passes. A second task installs from the cache.
