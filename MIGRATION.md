# Migration: pipenv + uWSGI → uv + gunicorn

This document tracks the step-by-step migration of CaltechAUTHORS from
`pipenv` / uWSGI to `uv` / gunicorn for local development on macOS ARM.

**Branch:** `uv-gunicorn-dev`  
**Starting state:** `invenio-cli` 1.7.2, `Pipfile`, uWSGI in main deps  
**Target state:** `invenio-cli` 1.11.0, `pyproject.toml` + `uv.lock`, gunicorn for dev, uWSGI for production Linux

---

## Phase 1 — Upgrade invenio-cli and enable uv support

**Why:** invenio-cli 1.7.2 does not support `python_package_manager = uv`.
Version 1.8+ added a `UV` package manager class that calls `uv sync` /
`uv run` instead of `pipenv sync` / `pipenv run`.

- [ ] Upgrade invenio-cli globally: `pip install --upgrade invenio-cli`
- [ ] Verify version ≥ 1.8: `invenio-cli --version`
- [ ] Add `python_package_manager = uv` to `.invenio` `[cli]` section
- [ ] Commit: *"Enable uv as invenio-cli package manager"*

---

## Phase 2 — Replace Pipfile with pyproject.toml

**Why:** `uv` uses `pyproject.toml` (PEP 517/518) as its project descriptor.
With `python_package_manager = uv` in `.invenio`, `invenio-cli install` calls
`uv sync` which reads `pyproject.toml`, not `Pipfile`.

### 2a — Root pyproject.toml

- [ ] Create `pyproject.toml` at the repo root translating all `Pipfile`
      dependencies:
  - Main `[packages]` → `[project] dependencies`
  - `caltechauthors = {editable, path="./site"}` → `[tool.uv.sources]`
  - Git-sourced packages (`invenio-app-rdm`, `idutils`, etc.) → `[tool.uv.sources]`
  - `uwsgi` and friends → `[dependency-groups] production` (skipped on macOS ARM)
  - `gunicorn` → `[dependency-groups] dev`
  - `lxml` → `[tool.uv] no-binary-package` (must build from source on ARM)
- [ ] Pin Python: `uv python pin 3.12` (creates `.python-version`)
- [ ] Generate lock file: `uv lock` (creates `uv.lock`)

### 2b — site/pyproject.toml

- [ ] Add `[project]` section to `site/pyproject.toml` so uv can identify it
      as an editable install (requires `name`, `version`, `requires-python`)
- [ ] Move entry points from `site/setup.cfg` into
      `[project.entry-points.*]` in `site/pyproject.toml`

### 2c — site/setup.cfg

- [ ] Empty `site/setup.cfg` — modern setuptools ignores `[metadata]` and
      `[options.entry_points]` when `[project]` exists in `pyproject.toml`;
      leaving both causes duplicate entry-point registration

### 2d — Verify the install

- [ ] `invenio-cli install` completes without error
- [ ] `.venv/` exists inside the repo root (not in home directory)
- [ ] `.invenio.private` was created (invenio-cli stores the resolved instance path here)
- [ ] `uv run invenio --version` prints the Invenio version
- [ ] `uv run invenio-cli --version` prints 1.11.0 (or the installed version)
- [ ] `cat .invenio.private` shows `instance_path` pointing to `.venv/var/instance/`
- [ ] `ls .venv/var/instance/invenio.cfg` is a symlink to the repo root's `invenio.cfg`
- [ ] `ls .venv/var/instance/assets/less/theme.config` exists (assets copied/linked)

> **Note on `.venv` timestamps:** `uv sync` updates an existing virtualenv in
> place rather than recreating it. If `.venv/` already exists from a previous
> install (e.g. earlier work on another branch), the directory timestamp will
> reflect its original creation date — this is expected and not a problem.

- [ ] Commit: *"Replace Pipfile with pyproject.toml for uv"*

---

## Phase 3 — Switch local dev server from uWSGI to gunicorn

**Why:** uWSGI does not compile on macOS ARM (Apple Silicon). gunicorn is
the replacement for local development. uWSGI stays in the `production`
dependency group for Linux production servers.

### 3a — gunicorn.conf.py

- [ ] Create `gunicorn.conf.py` at the repo root:
  - Call `load_dotenv()` before the WSGI app is imported so all `.env`
    variables (`INVENIO_*`) are in the process environment
  - Set `bind`, `workers`, `timeout`, `loglevel`

### 3b — invenio.cfg (dev overrides)

- [ ] Set `"force_https": False` in `APP_DEFAULT_SECURE_HEADERS`
      (gunicorn serves plain HTTP; nginx handles TLS in production)
- [ ] Comment out `FILES_REST_STORAGE_FACTORY` (S3) and set local
      filesystem storage for dev testing:
      `FILES_REST_STORAGE_CLASS_LIST = {"L": "Local"}`

### 3c — docker-services.yml

- [ ] Reduce OpenSearch `mem_limit` from 16g to 4g and heap to
      `-Xms256m -Xmx512m` for local dev on a shared Mac

### 3d — Supporting scripts and docs

- [ ] Create `scripts/link-instance-assets.sh` (fallback for manual
      `invenio webpack create` runs without invenio-cli)
- [ ] Create `DEV_SETUP.md` with the full first-time and ongoing checklist

### 3e — Verify

- [ ] `invenio-cli install` completes (assets built, symlinks in place)
- [ ] `uv sync --group dev` adds gunicorn
- [ ] Docker services start: `docker compose -f docker-services.yml up -d cache db mq search`
- [ ] DB and indices initialised (see DEV_SETUP.md §6–7)
- [ ] `uv run gunicorn -c gunicorn.conf.py 'invenio_app.wsgi:application'` serves HTTP 200
- [ ] Login works at http://127.0.0.1:5000
- [ ] Commit: *"Add gunicorn for local dev; uWSGI retained for production"*

---

## Known gotchas

| Issue | Fix |
|---|---|
| `invenio.cfg` not loaded | `invenio-cli install` symlinks it into `.venv/var/instance/`; never set `INVENIO_INSTANCE_PATH` manually |
| `lxml` build fails on ARM | Requires MacPorts `libxml2`/`libxslt`; add to `[tool.uv] no-binary-package` |
| `static/dist/manifest.json` not found | Run `invenio-cli assets build` (not bare `invenio webpack create`) |
| Login fails after user create | Add `--confirm` flag: `invenio users create ... --confirm` |
| `roles create admin` must precede fixtures | `invenio rdm-records fixtures` assigns the admin role; role must exist first |
| Port 5000 in use on macOS | macOS AirPlay Receiver also binds 5000; disable in System Settings → AirDrop & Handoff |
| OpenSearch index prefix mismatch | Indices must be created AFTER `invenio.cfg` loads (`SEARCH_INDEX_PREFIX = "caltechauthors-"`) |
| Bogus self-referential symlinks in `assets/` | Caused by running link script before `.venv/var/instance/assets/` exists; delete `assets/less/site/site` and `assets/templates/templates` |
| Celery SIGSEGV on macOS ARM | Default `prefork` pool forks child processes; C extensions (lxml, psycopg2) are not fork-safe on Apple Silicon. Use `--pool=solo` for local dev. |
| `rdm-records fixtures` completes but vocab data never appears | Fixtures only enqueue Celery tasks — data is written by the worker. Start Celery **before** running fixtures, or drain the queue afterward. |
| `caltech_groups.yaml` missing from branch | CaltechAUTHORS-specific vocabulary file; required by `app_data/vocabularies.yaml`. Restore from git history if missing. |
