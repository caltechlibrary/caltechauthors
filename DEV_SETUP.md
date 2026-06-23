# CaltechAUTHORS Local Development Setup

This checklist brings up a local development instance from a clean checkout.
It uses **uv** for Python package management (via `invenio-cli`), **gunicorn**
as the app server, and **Docker** for backing services (PostgreSQL, Redis,
RabbitMQ, OpenSearch).

## Prerequisites (one-time, not per-checkout)

- [ ] Docker Desktop installed and running
- [ ] Node 18 via nvm: `nvm install 18`
- [ ] uv installed: `curl -LsSf https://astral.sh/uv/install.sh | sh`
- [ ] invenio-cli ≥ 1.8 installed globally: `pip install invenio-cli`
- [ ] Add invenio-cli to PATH (user install):
      `export PATH="$HOME/Library/Python/3.9/bin:$PATH"` (add to `~/.zshrc` or `~/.bash_profile`)
- [ ] libxml2 and libxslt installed (Mac Ports: `sudo port install libxml2 libxslt`)

---

## First-time setup (new checkout)

### 1 — Clone and switch to the working branch

```bash
git clone https://github.com/caltechlibrary/caltechauthors.git
cd caltechauthors
git checkout uv-gunicorn-dev   # or main once merged
```

### 2 — Install Python dependencies, symlink instance files, and build assets

```bash
nvm use 18
invenio-cli install
```

This single command does everything:
- `uv sync` — installs all Python packages into `.venv/` inside the repo
- Determines the Flask instance path (`.venv/var/instance/`) and symlinks
  `invenio.cfg`, `templates`, and `app_data` from the repo root into it
- Copies and symlinks `assets/` into the webpack working directory
- Runs `invenio collect`, `webpack create`, `npm install`, `webpack build`

Then add gunicorn (macOS dev only):

```bash
uv sync --group dev
```

> **uWSGI note:** uWSGI is in `[dependency-groups] production` and is skipped
> on macOS. On Linux production servers use `uv sync --group production` instead.

### 3 — Create `.env` with local secrets

Create `caltechauthors/.env` (never commit this file):

```
INVENIO_SECRET_KEY=<output of: python3 -c "import secrets; print(secrets.token_hex(32))">

INVENIO_SQLALCHEMY_DATABASE_URI=postgresql+psycopg2://caltechauthors:caltechauthors@localhost/caltechauthors
INVENIO_CACHE_TYPE=redis
INVENIO_CACHE_REDIS_URL=redis://localhost:6379/0
INVENIO_ACCOUNTS_SESSION_REDIS_URL=redis://localhost:6379/1
INVENIO_CELERY_RESULT_BACKEND=redis://localhost:6379/2
INVENIO_RATELIMIT_STORAGE_URL=redis://localhost:6379/3
INVENIO_COMMUNITIES_IDENTITIES_CACHE_REDIS_URL=redis://localhost:6379/4
INVENIO_BROKER_URL=amqp://guest:guest@localhost:5672/
INVENIO_CELERY_BROKER_URL=amqp://guest:guest@localhost:5672/
INVENIO_SEARCH_HOSTS=['localhost:9200']

# Disable HTTPS redirect — gunicorn serves plain HTTP locally
INVENIO_FORCE_HTTPS=false
```

### 4 — Start Docker backing services

```bash
docker compose -f docker-services.yml up -d cache db mq search
```

Wait for OpenSearch to be ready:

```bash
until curl -s http://localhost:9200/_cluster/health | \
  python3 -c "import sys,json; h=json.load(sys.stdin); print(h['status']); \
  sys.exit(0 if h['status'] in ('green','yellow') else 1)"; \
do echo "waiting..."; sleep 3; done
```

### 5 — Set vm.max_map_count for OpenSearch (macOS only)

Required once per Docker Desktop restart:

```bash
docker run --privileged --rm --pid=host docker/desktop-linux \
  sh -c "sysctl -w vm.max_map_count=262144"
```

### 6 — Initialise the database and search indices

Run these only on a **fresh database** (first time, or after `db destroy`):

```bash
uv run invenio db create
uv run invenio files location create --default local-storage \
    "$(pwd)/.venv/var/instance/data"
uv run invenio index init
uv run invenio roles create admin
uv run invenio rdm-records fixtures
```

> `roles create admin` must run before `rdm-records fixtures`. The fixture
> assigns a user to the `admin` role; if the role doesn't exist first,
> SQLAlchemy throws a `FlushError`.

### 7 — Create a local admin user

```bash
uv run invenio users create admin@library.caltech.edu \
    --password admin123 --active --confirm
uv run invenio roles add admin@library.caltech.edu admin
uv run invenio access allow superuser-access role admin
```

---

## Running the app

Open **three terminals** in the project directory:

**Terminal 1 — UI server:**
```bash
uv run gunicorn -c gunicorn.conf.py 'invenio_app.wsgi:application'
```

> `gunicorn.conf.py` calls `load_dotenv()` before the WSGI app is imported so
> all `.env` variables reach gunicorn workers.

**Terminal 2 — Celery worker:**
```bash
uv run celery -A invenio_app.celery worker --loglevel=info
```

**Terminal 3 — Celery beat scheduler (optional):**
```bash
uv run celery -A invenio_app.celery beat --loglevel=info
```

Browse to **http://127.0.0.1:5000** and log in with the admin credentials above.

> **Port 5000 conflict:** macOS AirPlay Receiver also binds port 5000.
> Disable it in System Settings → General → AirDrop & Handoff → AirPlay Receiver,
> or change `bind` in `gunicorn.conf.py` to `127.0.0.1:5001`.

---

## Stopping the app

Stop gunicorn and celery with `Ctrl-C` in their terminals, then:

```bash
docker compose -f docker-services.yml stop
```

---

## Updating after a git pull

After a `git pull` that changes `pyproject.toml` or `uv.lock`:

```bash
invenio-cli install
uv sync --group dev
uv run invenio db upgrade    # if migrations were added
uv run invenio index init    # if new index mappings were added
```

If only assets changed (LESS/JS/templates):

```bash
nvm use 18
invenio-cli assets build
```

---

## Rebuilding assets manually (fallback)

If you run `uv run invenio webpack create` directly without `invenio-cli`,
restore the symlinks before building:

```bash
./scripts/link-instance-assets.sh
uv run invenio webpack build
```

---

## Production deployment (Ubuntu, not macOS)

Production runs on Ubuntu with nginx, uWSGI, PostgreSQL, and OpenSearch
installed natively (not Docker).

### Install

```bash
git clone https://github.com/caltechlibrary/caltechauthors.git /Sites/caltechauthors
cd /Sites/caltechauthors
invenio-cli install
uv sync --group production
```

### Configure

- Copy `.env` from the production secrets store.
- Restore `invenio.cfg` S3 block: uncomment `FILES_REST_STORAGE_FACTORY` and
  `S3_ENDPOINT_URL` / `S3_REGION_NAME`; remove `FILES_REST_STORAGE_CLASS_LIST`.
- Run `uv run invenio files location s3-default s3://caltechauthors --default`
  instead of the local-storage location command.

### Build and start

Same as steps 6–7 above, then start via systemd service files
(`rdm.service`, `rdm_rest.service`, `rdm_celery.service`).
