#!/bin/bash
#
# verify-mq-backup.bash - check a backup made by backup-mq.bash.
#
# Checks: the files exist, SHA256SUMS match, the tarball reads cleanly, the mq
# container is running again, and the live queue counts match counts-before.tsv.
# Read-only. Prints one PASS/FAIL line per check.
#
# Usage: verify-mq-backup.bash [BACKUP_DIR]
# BACKUP_DIR defaults to the newest directory under /opt/mq_backups.
#
# Environment: MQ_CONTAINER (default caltechauthors-mq-1), BACKUP_ROOT
# (default /opt/mq_backups).
#
# EXIT STATUS: 0 all checks passed; 1 a check failed; 2 usage; 66 backup
# directory or file missing.
#
set -uo pipefail

MQ_CONTAINER="${MQ_CONTAINER:-caltechauthors-mq-1}"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/mq_backups}"

case "${1:-}" in
  -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  -*) echo "usage: $0 [BACKUP_DIR]" >&2; exit 2 ;;
esac
[ $# -le 1 ] || { echo "usage: $0 [BACKUP_DIR]" >&2; exit 2; }

DEST="${1:-$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -1)}"
DEST="${DEST%/}"
[ -n "$DEST" ] && [ -d "$DEST" ] || { echo "error: no backup directory found" >&2; exit 66; }
echo "verifying $DEST"

FAILS=0
check() { # check "label" command...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS  $label"; else echo "FAIL  $label"; FAILS=$((FAILS + 1)); fi
}

for f in rabbit-defs.json counts-before.tsv rabbitmq-vol.tgz SHA256SUMS; do
  [ -s "$DEST/$f" ] || { echo "error: $DEST/$f missing or empty" >&2; exit 66; }
done

check "checksums match"            bash -c "cd '$DEST' && sha256sum -c SHA256SUMS"
check "tarball reads cleanly"      bash -c "gzip -t '$DEST/rabbitmq-vol.tgz' && tar -tzf '$DEST/rabbitmq-vol.tgz'"
check "definitions are valid JSON" python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$DEST/rabbit-defs.json"
check "$MQ_CONTAINER is running"   test "$(docker inspect -f '{{.State.Running}}' "$MQ_CONTAINER")" = true

LIVE="$(mktemp)"; trap 'rm -f "$LIVE"' EXIT
if docker exec "$MQ_CONTAINER" rabbitmqctl list_queues -q name messages_ready 2>/dev/null \
     | grep -v -E 'celeryev|pidbox' | sort > "$LIVE" && [ -s "$LIVE" ]; then
  if diff -q "$DEST/counts-before.tsv" "$LIVE" >/dev/null; then
    echo "PASS  live queue counts match counts-before.tsv"
  else
    echo "FAIL  live queue counts differ from counts-before.tsv (name, backup vs live):"
    join -t "$(printf '\t')" -a1 -a2 -e MISSING -o 0,1.2,2.2 "$DEST/counts-before.tsv" "$LIVE" \
      | awk -F'\t' '$2 != $3' | head -20
    FAILS=$((FAILS + 1))
  fi
else
  echo "FAIL  could not list live queues"; FAILS=$((FAILS + 1))
fi

echo "$FAILS check(s) failed"
[ "$FAILS" -eq 0 ]
