#!/bin/bash
#
# reboot_scripts_test.bash - tests for admin/safe_to_reboot.bash and admin/caltechauthors_down.bash
# (plan nginx_symlinks_and_host_checks, Phase 4).
#
# Usage: ./admin/reboot_scripts_test.bash [NAME-PATTERN]
#
# The contract these tests pin (the same one admin-shell-scripts documents):
#   safe_to_reboot.bash  only REPORTS. Exit 0 and no output when a reboot is safe; exit 1 and
#                        a description when it is not. It never stops, starts or kills anything.
#                        When units are running it names the script that stops them.
#   caltechauthors_down.bash  stops the RDM units in order: nginx, rdm, rdm_rest, rdm_celery.
#                        It never touches Docker (the units Require docker.service, so systemd
#                        stops the containers at shutdown).
#
# No real systemd is needed: stub `systemctl`, `pgrep` and `sudo` are put first on PATH and log
# every call to $STUB_LOG.
#
# EXIT STATUS: 0 every test passed; 1 a test failed.
# Written for bash 3.2 (macOS) and later.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SAFE="$HERE/safe_to_reboot.bash"
DOWN="$HERE/caltechauthors_down.bash"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/reboot-scripts-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
PASSED=0
FAILED=0
CASE_DIR=""
OUT=""
RC=0

# new_case NAME builds $CASE_DIR/bin with stubs. STUB_ACTIVE is a space-separated list of units
# that report active; STUB_DUMP=1 makes pgrep find a running backup; STUB_STOP_FAIL names a unit
# whose stop fails.
new_case() {
  CASE_DIR="$ROOT/$1"
  mkdir -p "$CASE_DIR/bin"
  : > "$CASE_DIR/stub.log"
  cat > "$CASE_DIR/bin/systemctl" <<'EOS'
#!/bin/bash
echo "systemctl $*" >> "$STUB_LOG"
case "$1" in
  is-active)
    shift; q=0; [ "$1" = "--quiet" ] && { q=1; shift; }
    for u in ${STUB_ACTIVE:-}; do [ "$u" = "$1" ] || [ "$u.service" = "$1" ] && { [ $q = 1 ] || echo active; exit 0; }; done
    [ $q = 1 ] || echo inactive; exit 3;;
  stop)
    [ "${STUB_STOP_FAIL:-}" = "$2" ] && exit 5
    exit 0;;
  *) exit 0;;
esac
EOS
  cat > "$CASE_DIR/bin/pgrep" <<'EOS'
#!/bin/bash
echo "pgrep $*" >> "$STUB_LOG"
[ "${STUB_DUMP:-0}" = 1 ] && { echo 4242; exit 0; }
exit 1
EOS
  cat > "$CASE_DIR/bin/sudo" <<'EOS'
#!/bin/bash
echo "sudo $*" >> "$STUB_LOG"
exec "$@"
EOS
  # docker, kill and pkill must never be called; a call is logged and fails loudly
  for c in docker kill pkill; do
    printf '#!/bin/bash\necho "FORBIDDEN %s $*" >> "$STUB_LOG"\nexit 99\n' "$c" > "$CASE_DIR/bin/$c"
  done
  chmod +x "$CASE_DIR"/bin/*
}

# run_script PATH [ARGS...] runs a script with the stubs first on PATH.
run_script() {
  local script=$1; shift
  OUT=$(STUB_LOG="$CASE_DIR/stub.log" PATH="$CASE_DIR/bin:$PATH" bash "$script" "$@" 2>&1)
  RC=$?
}

fail() { echo "      FAIL: $*"; }
expect_rc() { [ "$RC" -eq "$1" ] || fail "exit $RC, wanted $1 ($2); output: $OUT"; }
expect_out() { case "$OUT" in *"$1"*) ;; *) fail "output lacks '$1': $OUT";; esac; }
expect_no_out() { case "$OUT" in *"$1"*) fail "output has '$1': $OUT";; esac; }
log_has() { grep -q -- "$1" "$CASE_DIR/stub.log" || fail "stub log lacks '$1'"; }
log_lacks() { ! grep -q -- "$1" "$CASE_DIR/stub.log" || fail "stub log has '$1'"; }

# ---- safe_to_reboot.bash ----------------------------------------------------

t_safe_nothing_running_is_silent_and_exit_0() {
  new_case $FUNCNAME; STUB_ACTIVE="" run_script "$SAFE"
  expect_rc 0 "nothing is running"; [ -z "$OUT" ] || fail "expected no output, got: $OUT"
}

t_safe_each_unit_alone_makes_it_unsafe() {
  local u
  for u in nginx rdm rdm_rest rdm_celery; do
    new_case $FUNCNAME-$u; STUB_ACTIVE="$u" run_script "$SAFE"
    expect_rc 1 "$u is running"; expect_out "$u"
  done
}

t_safe_names_every_running_unit_and_not_the_stopped_ones() {
  new_case $FUNCNAME; STUB_ACTIVE="nginx rdm_celery" run_script "$SAFE"
  expect_rc 1 "two units running"; expect_out "nginx"; expect_out "rdm_celery"
  expect_no_out "rdm_rest"
}

t_safe_names_the_down_script() {
  new_case $FUNCNAME; STUB_ACTIVE="rdm" run_script "$SAFE"
  expect_out "caltechauthors_down.bash"
}

t_safe_a_running_backup_is_unsafe_and_says_wait() {
  new_case $FUNCNAME; STUB_ACTIVE="" STUB_DUMP=1 run_script "$SAFE"
  expect_rc 1 "a SQL backup is running"; expect_out "backup"; expect_out "wait"
}

t_safe_a_running_backup_does_not_ask_for_a_stop() {
  new_case $FUNCNAME; STUB_ACTIVE="" STUB_DUMP=1 run_script "$SAFE"
  expect_no_out "caltechauthors_down.bash"
}

t_safe_looks_for_both_backup_programs() {
  # the stub ignores arguments, so pin what the script asks pgrep for
  new_case $FUNCNAME; run_script "$SAFE"
  log_has "pgrep -f .*invenio-sql-backup"; log_has "pgrep -f .*pg_dump"
}

t_safe_has_no_side_effects() {
  new_case $FUNCNAME; STUB_ACTIVE="nginx rdm rdm_rest rdm_celery" STUB_DUMP=1 run_script "$SAFE"
  log_lacks "systemctl stop"; log_lacks "systemctl start"; log_lacks "systemctl restart"
  log_lacks "systemctl disable"; log_lacks "FORBIDDEN"; log_lacks "^sudo "
}

t_safe_help_exits_0_and_describes_the_contract() {
  new_case $FUNCNAME; run_script "$SAFE" --help
  expect_rc 0 "--help"; expect_out "safe_to_reboot.bash"; expect_out "caltechauthors_down.bash"
  log_lacks "systemctl"
}

t_safe_unknown_argument_is_a_usage_error() {
  new_case $FUNCNAME; run_script "$SAFE" --nope
  expect_rc 2 "unknown argument"; log_lacks "systemctl"
}

t_safe_missing_systemctl_is_not_reported_as_safe() {
  # a host where the probe cannot run must not claim a reboot is safe
  new_case $FUNCNAME; rm "$CASE_DIR/bin/systemctl"
  OUT=$(STUB_LOG="$CASE_DIR/stub.log" PATH="$CASE_DIR/bin:/usr/bin:/bin" bash "$SAFE" 2>&1); RC=$?
  [ "$(command -v systemctl >/dev/null 2>&1; echo $?)" -eq 0 ] && { echo "      (skipped: real systemctl present)"; return 0; }
  expect_rc 70 "systemctl missing"
}

# ---- caltechauthors_down.bash -----------------------------------------------

t_down_stops_the_four_units_in_order() {
  new_case $FUNCNAME; STUB_ACTIVE="nginx rdm rdm_rest rdm_celery" run_script "$DOWN"
  expect_rc 0 "all stops succeed"
  local got
  got=$(grep '^systemctl stop' "$CASE_DIR/stub.log" | awk '{print $3}' | tr '\n' ' ')
  [ "$got" = "nginx rdm rdm_rest rdm_celery " ] || fail "stop order was: $got"
}

t_down_uses_sudo() {
  new_case $FUNCNAME; run_script "$DOWN"
  log_has "sudo systemctl stop nginx"
}

t_down_never_touches_docker_or_kills() {
  new_case $FUNCNAME; run_script "$DOWN"
  log_lacks "FORBIDDEN"
}

t_down_a_failed_stop_still_tries_the_rest_and_exits_nonzero() {
  new_case $FUNCNAME; STUB_STOP_FAIL=rdm run_script "$DOWN"
  [ "$RC" -ne 0 ] || fail "exit 0 although a stop failed"
  log_has "systemctl stop rdm_rest"; log_has "systemctl stop rdm_celery"
  expect_out "rdm"
}

t_down_help_exits_0_and_stops_nothing() {
  new_case $FUNCNAME; run_script "$DOWN" --help
  expect_rc 0 "--help"; expect_out "caltechauthors_down.bash"; log_lacks "systemctl stop"
}

t_down_unknown_argument_is_a_usage_error_and_stops_nothing() {
  new_case $FUNCNAME; run_script "$DOWN" --nope
  expect_rc 2 "unknown argument"; log_lacks "systemctl stop"
}

t_down_then_safe_agree() {
  # after the down script reports success the units are inactive, so safe_to_reboot is silent
  new_case $FUNCNAME; STUB_ACTIVE="" run_script "$DOWN"; expect_rc 0 "down"
  run_script "$SAFE"; expect_rc 0 "safe after down"
}

# ---- the runner -------------------------------------------------------------

PATTERN=${1:-}
TESTS=$(declare -F | awk '{print $3}' | grep '^t_' | sort)
echo "reboot_scripts_test.bash: $(echo "$TESTS" | wc -w | tr -d ' ') tests"
for t in $TESTS; do
  if [ -n "$PATTERN" ]; then case "$t" in *"$PATTERN"*) ;; *) continue;; esac; fi
  ( "$t" ) > "$ROOT/$t.out" 2>&1
  if grep -q '^      FAIL:' "$ROOT/$t.out" || [ ! -f "$SAFE" ] || [ ! -f "$DOWN" ]; then
    echo "FAIL  $t"; head -4 "$ROOT/$t.out" | sed 's/^/      /'
    FAILED=$((FAILED+1))
  else
    echo "PASS  $t"; PASSED=$((PASSED+1))
  fi
done
echo; echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
