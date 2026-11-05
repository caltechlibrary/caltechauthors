#!/bin/bash
#
# safe_to_reboot.bash - report whether CaltechAUTHORS can be rebooted now.
#
# check-for-reboot.bash (from admin-shell-scripts) runs this when Ubuntu wants a reboot.
# It only REPORTS: exit 0 with no output when a reboot is safe, exit 1 with a description
# when it is not. It never stops, starts or kills anything; stopping is
# caltechauthors_down.bash, run by a person.
#
# EXIT STATUS: 0 safe; 1 not safe; 2 usage; 70 the probe could not run (systemctl missing),
# which is never reported as safe.

UNITS="nginx rdm rdm_rest rdm_celery"
DOWN=caltechauthors_down.bash
INSTANCE_DIR=${CALTECHAUTHORS_DIR:-/Sites/caltechauthors}

usage() {
  cat <<TXT
safe_to_reboot.bash - is it safe to reboot this CaltechAUTHORS host?

Reports only. Exit 0 and no output: safe. Exit 1: not safe, with the reason.
It checks that these units are stopped: $UNITS
and that no SQL backup (invenio-sql-backup.bash, pg_dump) is running.
If units are running it names $DOWN, which stops them in order
(nginx, rdm, rdm_rest, rdm_celery). Docker is left to systemd at shutdown.
This script changes nothing.
TXT
}

case "${1:-}" in
  "") ;;
  -h|--help|help) usage; exit 0;;
  *) echo "safe_to_reboot.bash: unknown argument: $1" >&2; exit 2;;
esac

if ! command -v systemctl >/dev/null 2>&1; then
  echo "safe_to_reboot.bash: systemctl not found; cannot tell whether a reboot is safe" >&2
  exit 70
fi

RUNNING=""
for u in $UNITS; do
  if systemctl is-active --quiet "$u" 2>/dev/null; then RUNNING="$RUNNING $u"; fi
done

UNSAFE=0
if [ -n "$RUNNING" ]; then
  UNSAFE=1
  echo "CaltechAUTHORS is still running. These units are active:$RUNNING"
  echo
  echo "Stop them in order with:"
  echo
  echo "    $DOWN"
  echo
  echo "($INSTANCE_DIR's containers are stopped by systemd at shutdown.)"
fi

# Match the process, not any command line that mentions it: `pgrep -f pg_dump` also matches
# `less invenio-sql-backup.bash` or an SSM wrapper whose script text contains the word. The dump
# is the process named pg_dump (visible from the host even when it runs in the db container);
# the script is a shell whose first operand is invenio-sql-backup*.
BACKUP_SCRIPT='^([^ ]*/)?(ba)?sh( -[A-Za-z]+)* [^ ]*invenio-sql-backup'
if pgrep -x pg_dump >/dev/null 2>&1 || pgrep -f "$BACKUP_SCRIPT" >/dev/null 2>&1; then
  UNSAFE=1
  echo "A SQL backup is running. Do not reboot until it finishes: wait, then run this check again."
fi

exit $UNSAFE
