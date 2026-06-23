#!/usr/bin/env bash
# Fallback script: manually link instance-level assets into the webpack
# working directory and symlink invenio.cfg into the venv instance path.
#
# Prefer "invenio-cli assets build" — it does all of this automatically.
# Only run this script directly if you ran "uv run invenio webpack create"
# without invenio-cli and need to restore the symlinks before running
# "uv run invenio webpack build".

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTANCE="${REPO_ROOT}/.venv/var/instance"
ASSETS_SRC="${REPO_ROOT}/assets"
ASSETS_DST="${INSTANCE}/assets"

ln -sf "${REPO_ROOT}/invenio.cfg"        "${INSTANCE}/invenio.cfg"
ln -sf "${ASSETS_SRC}/less/theme.config" "${ASSETS_DST}/less/theme.config"
ln -sf "${ASSETS_SRC}/less/site"         "${ASSETS_DST}/less/site"
ln -sf "${ASSETS_SRC}/templates"         "${ASSETS_DST}/templates"

echo "Instance assets linked (invenio.cfg + webpack assets)."
