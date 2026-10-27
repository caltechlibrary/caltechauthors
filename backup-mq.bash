#!/bin/bash
#
# backup-mq.bash - back up RabbitMQ (the Celery broker) for CaltechAUTHORS.
#
# Writes to /opt/mq_backups/<UTC-stamp>/ :
#   rabbit-defs.json      queue/exchange/binding definitions (no messages)
#   counts-before.tsv     messages_ready per queue, taken just before mq stops
#   rabbitmq-vol.tgz      cold copy of the RabbitMQ data volume (the messages)
#   SHA256SUMS            checksums of the files above
#
# The mq container is stopped for the copy and started again afterward, even
# on failure. Stop the publishers first (granian REST/UI, celery workers); the
# script refuses to run while they are up, since a cold copy needs a quiet broker.
#
# Usage: backup-mq.bash [--help]
# Run as a user who can use docker and sudo (e.g. ubuntu). Verify afterward with
# verify-mq-backup.bash.
#
# Environment: MQ_CONTAINER (default caltechauthors-mq-1), BACKUP_ROOT
# (default /opt/mq_backups).
#
# EXIT STATUS: 0 ok; 1 publishers still running; 2 usage; 66 container not
# found; 73 cannot create backup directory; 74 read/write failed part way.
#
set -euo pipefail

MQ_CONTAINER="${MQ_CONTAINER:-caltechauthors-mq-1}"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/mq_backups}"

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: $0 [--help]" >&2; exit 2 ;;
esac

# Step 0: preconditions -------------------------------------------------------
docker inspect "$MQ_CONTAINER" >/dev/null 2>&1 || {
  echo "error: container $MQ_CONTAINER not found" >&2; exit 66; }

# Bracket the first letter so pgrep does not match this script's own command line.
if pgrep -f '[g]ranian --interface|[c]elery --app invenio_app' >/dev/null; then
  echo "error: granian or celery is still running; stop the publishers first:" >&2
  pgrep -af '[g]ranian --interface|[c]elery --app invenio_app' | cut -c1-120 >&2
  exit 1
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="$BACKUP_ROOT/$STAMP"
sudo mkdir -p "$DEST" || { echo "error: cannot create $DEST" >&2; exit 73; }
sudo chown "$(id -u):$(id -g)" "$BACKUP_ROOT" "$DEST"

VOL="$(docker inspect "$MQ_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/rabbitmq"}}{{.Source}}{{end}}{{end}}')"
[ -n "$VOL" ] || { echo "error: no /var/lib/rabbitmq mount on $MQ_CONTAINER" >&2; exit 66; }

NEED_KB="$(sudo du -sk "$VOL" | cut -f1)"
AVAIL_KB="$(df -Pk "$BACKUP_ROOT" | awk 'NR==2{print $4}')"
if [ "$AVAIL_KB" -lt $((NEED_KB * 2)) ]; then
  echo "error: need about $((NEED_KB * 2 / 1024)) MB free in $BACKUP_ROOT, have $((AVAIL_KB / 1024)) MB" >&2
  exit 74
fi
echo "backup directory: $DEST"

# Step 1: definitions and queue counts (safe while running) ---------------------
docker exec "$MQ_CONTAINER" rabbitmqctl export_definitions /tmp/rabbit-defs.json >/dev/null
docker cp "$MQ_CONTAINER:/tmp/rabbit-defs.json" "$DEST/rabbit-defs.json"
docker exec "$MQ_CONTAINER" rabbitmqctl list_queues -q name messages_ready \
  | grep -v -E 'celeryev|pidbox' | sort > "$DEST/counts-before.tsv"
echo "definitions and counts saved ($(wc -l < "$DEST/counts-before.tsv") queues)"

# Step 2: cold copy of the data volume ------------------------------------------
restart_mq() {
  if [ "$(docker inspect -f '{{.State.Running}}' "$MQ_CONTAINER" 2>/dev/null)" != "true" ]; then
    echo "starting $MQ_CONTAINER" >&2
    docker start "$MQ_CONTAINER" >/dev/null
  fi
}
trap restart_mq EXIT

echo "stopping $MQ_CONTAINER"
docker stop "$MQ_CONTAINER" >/dev/null
echo "copying $VOL (this can take a minute)"
sudo tar -C "$VOL" -czf "$DEST/rabbitmq-vol.tgz.partial" . || { echo "error: tar failed" >&2; exit 74; }
mv "$DEST/rabbitmq-vol.tgz.partial" "$DEST/rabbitmq-vol.tgz"
restart_mq
trap - EXIT

( cd "$DEST" && sha256sum rabbit-defs.json counts-before.tsv rabbitmq-vol.tgz > SHA256SUMS )
echo "done: $(du -sh "$DEST" | cut -f1) in $DEST"
echo "next: verify-mq-backup.bash $DEST"
