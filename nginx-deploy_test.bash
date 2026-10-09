#!/bin/bash
#
# nginx-deploy_test.bash - tests for nginx-deploy.bash (caltechauthors DR-0009, plan phase 2).
#
# Usage: ./nginx-deploy_test.bash [NAME-PATTERN]
#
# No real nginx or logagent is needed. Every test builds a fixture under a temporary
# directory: a copy of this repository's nginx/ tree, a fake /etc/nginx, and stub
# `nginx` and `logagent` programs. The stub nginx behaves like the real one in the one
# way that matters here: `nginx -t -c FILE` CREATES the directory named by
# proxy_cache_path (its last component only) and fails when the parent is missing, so
# a staged copy that still points at /var/cache/nginx makes it fail.
#
# EXIT STATUS: 0 every test passed; 1 a test failed.
#
# Written for bash 3.2 (macOS) and later: no associative arrays, no mapfile.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/nginx-deploy.bash"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nginx-deploy-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
PASSED=0
FAILED=0
FAILED_NAMES=""
CASE_DIR=""
OUT=""
ERR=""
RC=0

# ---- fixtures ---------------------------------------------------------------

# new_case NAME builds $CASE_DIR with repo/, etc/ and bin/ (the stubs).
new_case() {
  CASE_DIR="$ROOT/$1"
  mkdir -p "$CASE_DIR/repo" "$CASE_DIR/bin" "$CASE_DIR/etc/conf.d" "$CASE_DIR/etc/sites-available" \
    "$CASE_DIR/etc/sites-enabled" "$CASE_DIR/etc/snippets"
  cp -R "$HERE/nginx" "$CASE_DIR/repo/nginx"
  {
    echo "events {}"
    echo "http {"
    echo "  include $CASE_DIR/etc/mime.types;"
    echo "  include $CASE_DIR/etc/conf.d/*.conf;"
    echo "  include $CASE_DIR/etc/sites-enabled/*;"
    echo "}"
  } > "$CASE_DIR/etc/nginx.conf"
  echo "types { text/html html; }" > "$CASE_DIR/etc/mime.types"
  echo "ssl_protocols TLSv1.2;" > "$CASE_DIR/etc/snippets/ssl-params.conf"
  printf 'ssl_certificate /x.crt;\nssl_certificate_key /x.key;\n' > "$CASE_DIR/etc/snippets/self-signed.conf"
  echo "dh" > "$CASE_DIR/etc/dhparam.pem"
  : > "$CASE_DIR/stub.log"
  cat > "$CASE_DIR/bin/nginx" <<'EOS'
#!/bin/bash
echo "nginx $*" >> "$STUB_LOG"
mode=""; conf=""
while [ $# -gt 0 ]; do
  case "$1" in -t) mode=t;; -T) mode=T;; -c) conf=$2; shift;; esac
  shift
done
if [ ! -f "$conf" ]; then echo "nginx: [emerg] open() \"$conf\" failed (2: No such file or directory)" >&2; exit 1; fi
cdir=$(dirname "$conf")
# the real nginx creates proxy_cache_path directories, last component only, even under -t
dir=$(cat "$cdir"/conf.d/*.conf 2>/dev/null | grep -E '^[[:space:]]*proxy_cache_path[[:space:]]' | head -1 | awk '{print $2}')
if [ -n "$dir" ]; then
  [ -d "$dir" ] || mkdir "$dir" 2>/dev/null || { echo "nginx: [emerg] mkdir() \"$dir\" failed (2: No such file or directory)" >&2
    echo "nginx: configuration file $conf test failed" >&2; exit 1; }
fi
case "$mode" in
  t)
    rc=${STUB_NGINX_T_RC:-0}
    if [ "$conf" = "${STUB_ETC:-/nonexistent}/nginx.conf" ] && [ -n "${STUB_NGINX_INSTALLED_RC:-}" ]; then rc=$STUB_NGINX_INSTALLED_RC; fi
    if [ "$rc" != 0 ]; then echo "${STUB_NGINX_T_MSG:-nginx: [emerg] stub says the configuration is wrong}" >&2; exit "$rc"; fi
    echo "nginx: the configuration file $conf syntax is ok" >&2
    echo "nginx: configuration file $conf test is successful" >&2
    ;;
  T)
    echo "# configuration file $conf:"; cat "$conf"
    for f in "$cdir"/conf.d/*.conf "$cdir"/sites-enabled/*; do
      [ -e "$f" ] || continue
      echo "# configuration file $f:"; cat "$f"
    done
    ;;
esac
EOS
  cat > "$CASE_DIR/bin/logagent" <<'EOS'
#!/bin/bash
echo "logagent $*" >> "$STUB_LOG"
echo "${STUB_LOGAGENT_OUT:-No gaps found.}"
exit "${STUB_LOGAGENT_RC:-0}"
EOS
  cat > "$CASE_DIR/bin/systemctl" <<'EOS'
#!/bin/bash
echo "systemctl $*" >> "$STUB_LOG"
if [ "${STUB_SYSTEMCTL_RC:-0}" != 0 ]; then echo "Job for nginx.service failed." >&2; fi
exit "${STUB_SYSTEMCTL_RC:-0}"
EOS
  cat > "$CASE_DIR/bin/install" <<'EOS'
#!/bin/bash
# forwards to the real install, except that a destination matching $STUB_INSTALL_FAIL_ON gets a
# half-written file and a failure, as a full disk would leave
if [ -n "${STUB_INSTALL_FAIL_ON:-}" ]; then
  case "$*" in *"$STUB_INSTALL_FAIL_ON"*)
    last=""; for a in "$@"; do last=$a; done
    [ "$1" = "-d" ] || echo "half written" > "$last"
    echo "install: $last: No space left on device" >&2; exit 1 ;;
  esac
fi
exec "$(PATH=/usr/bin:/bin command -v install)" "$@"
EOS
  cat > "$CASE_DIR/bin/date" <<'EOS'
#!/bin/bash
# prints $STUB_DATE when it is set (a fixed clock), otherwise forwards to the real date
if [ -n "${STUB_DATE:-}" ]; then echo "$STUB_DATE"; exit 0; fi
exec "$(PATH=/usr/bin:/bin command -v date)" "$@"
EOS
  chmod +x "$CASE_DIR/bin/nginx" "$CASE_DIR/bin/logagent" "$CASE_DIR/bin/systemctl" "$CASE_DIR/bin/install" "$CASE_DIR/bin/date"
  echo "version: 1" > "$CASE_DIR/logagent.yaml"
}

# run [VAR=value ...] -- ARGS... runs the script with the stubs and the fixture's
# standard arguments; sets OUT, ERR and RC.
STD_ARGS=""
run() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  # the script's temporary directory is inside the case, so a kept stage is removed with it
  mkdir -p "$CASE_DIR/tmp"
  OUT=$(env STUB_LOG="$CASE_DIR/stub.log" NGINX="$CASE_DIR/bin/nginx" LOGAGENT="$CASE_DIR/bin/logagent" SYSTEMCTL="$CASE_DIR/bin/systemctl" STUB_ETC="$CASE_DIR/etc" TMPDIR="$CASE_DIR/tmp" \
    ${envs[@]+"${envs[@]}"} "$SCRIPT" "$@" 2> "$CASE_DIR/err" <<<"${RUN_STDIN:-}")
  RC=$?
  ERR=$(cat "$CASE_DIR/err")
}

# std prints the arguments most tests share: check with a full, valid set of options.
std() {
  echo "check --repo-dir $CASE_DIR/repo --etc-dir $CASE_DIR/etc --server-name host.example.org --tls self-signed --logagent-config $CASE_DIR/logagent.yaml"
}

# stdv VERB prints the full option set for diff, apply and rollback in the sandbox: the cache
# and backup directories live inside the case, so nothing outside it is touched.
stdv() {
  echo "$1 --repo-dir $CASE_DIR/repo --etc-dir $CASE_DIR/etc --server-name host.example.org --tls self-signed --logagent-config $CASE_DIR/logagent.yaml --cache-dir $CASE_DIR/cache --backup-dir $CASE_DIR/backups"
}
# stdr prints the options rollback takes.
stdr() { echo "rollback --etc-dir $CASE_DIR/etc --backup-dir $CASE_DIR/backups"; }
# mode_of FILE prints the permission string, e.g. -rw-r--r--
mode_of() { ls -ld "$1" | awk '{print $1}'; }
# n_backups prints how many backup directories exist.
n_backups() { ls -1 "$CASE_DIR/backups" 2>/dev/null | wc -l | tr -d ' '; }
# latest_backup prints the path of the newest backup directory.
latest_backup() { ls -1 "$CASE_DIR/backups" | sort | tail -1 | sed "s#^#$CASE_DIR/backups/#"; }
# apply_ok applies with --yes and fails the test if it does not succeed.
apply_ok() { run -- $(stdv apply) --yes --no-logagent "$@"; eq "$RC" 0 "apply (stderr: $ERR)"; }

# tree_sig DIR prints a signature of every file and link under DIR.
tree_sig() {
  (cd "$1" && find . \( -type f -o -type l \) | sort | while read -r f; do
    if [ -L "$f" ]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"; else printf '%s %s\n' "$f" "$(cksum < "$f")"; fi
  done)
}

# ---- assertions -------------------------------------------------------------

fail() { echo "      FAIL: $*"; TEST_OK=0; }
eq()   { [ "$1" = "$2" ] || fail "$3: got '$1', want '$2'"; }
has()  { case "$1" in *"$2"*) ;; *) fail "$3: '$2' not found in: $(printf '%s' "$1" | head -c 300)";; esac; }
hasnt(){ case "$1" in *"$2"*) fail "$3: '$2' was found";; esac; }
exists()  { [ -e "$1" ] || fail "$2: $1 does not exist"; }
absent()  { [ ! -e "$1" ] || fail "$2: $1 exists"; }

# staged_dir finds the stage a --keep-stage run printed ("stage: PATH" on stderr).
staged_dir() { printf '%s\n' "$ERR" | sed -n 's/^stage: //p' | head -1; }

# ---- the tests --------------------------------------------------------------

t_help_lists_the_exit_status() {
  new_case $FUNCNAME; run -- --help
  eq "$RC" 0 "exit"; has "$OUT" "EXIT STATUS" "help"; has "$OUT" "check" "help names the verb"; has "$OUT" "--server-name" "help names the option"
}
t_version() { new_case $FUNCNAME; run -- --version; eq "$RC" 0 "exit"; has "$OUT" "nginx-deploy.bash 0." "version line"; }
t_a_bad_flag_is_a_usage_error() { new_case $FUNCNAME; run -- check --frobnicate; eq "$RC" 2 "exit"; has "$ERR" "--frobnicate" "names the flag"; }
t_a_surplus_argument_is_a_usage_error() { new_case $FUNCNAME; run -- $(std) surplus; eq "$RC" 2 "exit"; has "$ERR" "surplus" "names the argument"; }
t_no_verb_is_a_usage_error() { new_case $FUNCNAME; run --; eq "$RC" 2 "exit"; }
t_an_unknown_verb_is_a_usage_error() { new_case $FUNCNAME; run -- frobnicate; eq "$RC" 2 "exit"; has "$ERR" "frobnicate" "names the verb"; }
t_the_four_verbs_are_known() {
  new_case $FUNCNAME
  for v in diff apply rollback; do run -- $v --frobnicate; has "$ERR" "--frobnicate" "$v reaches option parsing, so it is a verb"; done
  run -- frobnicate; has "$ERR" "check, diff, apply, rollback" "the error lists the verbs"
}
t_a_missing_server_name_is_a_usage_error() {
  new_case $FUNCNAME; run -- check --repo-dir "$CASE_DIR/repo" --etc-dir "$CASE_DIR/etc" --tls self-signed
  eq "$RC" 2 "exit"; has "$ERR" "--server-name is required" "says it is required"
}
t_tls_is_required() {
  new_case $FUNCNAME; run -- check --repo-dir "$CASE_DIR/repo" --etc-dir "$CASE_DIR/etc" --server-name a.example
  eq "$RC" 2 "exit"; has "$ERR" "--tls is required" "says it is required"
}
t_tls_takes_a_closed_vocabulary() {
  new_case $FUNCNAME; run -- check --repo-dir "$CASE_DIR/repo" --etc-dir "$CASE_DIR/etc" --server-name a.example --tls acm
  eq "$RC" 2 "exit"; has "$ERR" "letsencrypt" "lists the values"
}
t_a_server_name_with_odd_characters_is_a_usage_error() {
  new_case $FUNCNAME
  for bad in 'a b' 'x;y' 'a&b' 'a#b' '$(id)'; do
    run -- check --repo-dir "$CASE_DIR/repo" --etc-dir "$CASE_DIR/etc" --server-name "$bad" --tls self-signed
    eq "$RC" 2 "server name '$bad'"
  done
}
t_an_underscore_server_name_is_accepted() {
  new_case $FUNCNAME; run -- check --repo-dir "$CASE_DIR/repo" --etc-dir "$CASE_DIR/etc" --server-name _ --tls self-signed --no-logagent
  eq "$RC" 0 "exit (stderr: $ERR)"
}
t_a_repo_dir_with_odd_characters_is_a_usage_error() {
  new_case $FUNCNAME; run -- check --repo-dir "/tmp/a b" --etc-dir "$CASE_DIR/etc" --server-name a.example --tls self-signed
  eq "$RC" 2 "exit"
}
t_a_missing_repo_nginx_tree_is_no_input() {
  new_case $FUNCNAME; mkdir "$CASE_DIR/empty"; run -- check --repo-dir "$CASE_DIR/empty" --etc-dir "$CASE_DIR/etc" --server-name a.example --tls self-signed
  eq "$RC" 66 "exit"; has "$ERR" "nginx tree is missing: $CASE_DIR/empty/nginx" "names the missing tree itself, not a file inside it"
}
t_a_missing_etc_dir_is_no_input() {
  new_case $FUNCNAME; run -- check --repo-dir "$CASE_DIR/repo" --etc-dir "$CASE_DIR/nowhere" --server-name a.example --tls self-signed
  eq "$RC" 66 "exit"; has "$ERR" "configuration directory is missing: $CASE_DIR/nowhere" "names the directory itself, not a file inside it"
}
t_missing_nginx_is_no_input() {
  new_case $FUNCNAME; run NGINX=/nonexistent/nginx -- $(std) --no-logagent
  eq "$RC" 66 "exit"; has "$ERR" "nginx" "says what is missing"
}
t_the_default_etc_dir_needs_root() {
  new_case $FUNCNAME
  if [ "$(id -u)" = 0 ]; then echo "      (skipped: running as root)"; return; fi
  run -- check --repo-dir "$CASE_DIR/repo" --server-name a.example --tls self-signed --no-logagent
  eq "$RC" 77 "exit"; has "$ERR" "root" "says why"
}
t_a_missing_ssl_params_snippet_is_no_input() {
  new_case $FUNCNAME; rm "$CASE_DIR/etc/snippets/ssl-params.conf"; run -- $(std) --no-logagent
  eq "$RC" 66 "exit"; has "$ERR" "ssl-params.conf" "names the file"
}
t_a_missing_dhparam_is_no_input() {
  new_case $FUNCNAME; rm "$CASE_DIR/etc/dhparam.pem"; run -- $(std) --no-logagent
  eq "$RC" 66 "exit"; has "$ERR" "dhparam.pem" "names the file"
}
t_self_signed_needs_its_snippet_but_letsencrypt_does_not() {
  new_case $FUNCNAME; rm "$CASE_DIR/etc/snippets/self-signed.conf"
  run -- $(std) --no-logagent; eq "$RC" 66 "self-signed without its snippet"; has "$ERR" "self-signed.conf" "names the file"
  run -- check --repo-dir "$CASE_DIR/repo" --etc-dir "$CASE_DIR/etc" --server-name a.example --tls letsencrypt --no-logagent
  eq "$RC" 0 "letsencrypt does not need it (stderr: $ERR)"
}
t_tokens_are_replaced_in_the_staged_site_file() {
  new_case $FUNCNAME; run -- $(std) --no-logagent --keep-stage; eq "$RC" 0 "exit"
  local s; s=$(staged_dir); exists "$s/sites-available/caltechauthors.conf" "site file"
  local site; site=$(cat "$s/sites-available/caltechauthors.conf")
  has "$site" "server_name host.example.org;" "server name"; has "$site" "include $CASE_DIR/repo/redirect-map.conf;" "repo dir in the redirect map include"
  has "$site" "alias $CASE_DIR/repo/.venv/var/instance/static;" "repo dir in the static alias"
  case "$site" in *@[A-Z_]*@*) fail "an @TOKEN@ is left";; esac
}
t_the_cert_name_defaults_to_the_server_name() {
  new_case $FUNCNAME
  run -- check --repo-dir "$CASE_DIR/repo" --etc-dir "$CASE_DIR/etc" --server-name a.example.org --tls letsencrypt --no-logagent --keep-stage; eq "$RC" 0 "exit"
  local s; s=$(staged_dir); has "$(cat "$s/snippets/caltechauthors-tls.conf")" "/etc/letsencrypt/live/a.example.org/fullchain.pem" "default cert name"
  run -- check --repo-dir "$CASE_DIR/repo" --etc-dir "$CASE_DIR/etc" --server-name a.example.org --cert-name other-lineage --tls letsencrypt --no-logagent --keep-stage
  s=$(staged_dir); has "$(cat "$s/snippets/caltechauthors-tls.conf")" "/etc/letsencrypt/live/other-lineage/privkey.pem" "explicit cert name"
}
t_self_signed_uses_the_snippet_cloud_init_writes() {
  new_case $FUNCNAME; run -- $(std) --no-logagent --keep-stage; eq "$RC" 0 "exit"
  local s; s=$(staged_dir); has "$(cat "$s/snippets/caltechauthors-tls.conf")" "include snippets/self-signed.conf;" "self-signed variant"
  hasnt "$(cat "$s/snippets/caltechauthors-tls.conf")" "letsencrypt" "no Let's Encrypt path"
}
t_the_site_name_names_the_file_and_the_link() {
  new_case $FUNCNAME; run -- $(std) --no-logagent --keep-stage --site-name myhost; eq "$RC" 0 "exit"
  local s; s=$(staged_dir); exists "$s/sites-available/myhost.conf" "site file"; [ -L "$s/sites-enabled/myhost.conf" ] || fail "sites-enabled link is missing"
  run -- $(std) --no-logagent --keep-stage; s=$(staged_dir); exists "$s/sites-available/caltechauthors.conf" "default site name"
}
t_the_repository_conf_d_files_are_overlaid() {
  new_case $FUNCNAME; run -- $(std) --no-logagent --keep-stage; eq "$RC" 0 "exit"
  local s; s=$(staged_dir)
  for f in caltechauthors_limits caltechauthors_cache caltechauthors_log cloudflare_real_ip; do exists "$s/conf.d/$f.conf" "conf.d/$f.conf"; done
}
t_a_token_left_unreplaced_is_wrong_data() {
  new_case $FUNCNAME; echo "  # oops @NOPE@" >> "$CASE_DIR/repo/nginx/sites-available/caltechauthors.conf"
  run -- $(std) --no-logagent; eq "$RC" 65 "exit"; has "$ERR" "@NOPE@" "names the token"; has "$ERR" "caltechauthors.conf" "names the file"
  hasnt "$(cat "$CASE_DIR/stub.log")" "nginx -t" "nginx was never asked"
}
t_the_staged_copy_points_the_cache_inside_the_stage() {
  new_case $FUNCNAME; run -- $(std) --no-logagent --keep-stage; eq "$RC" 0 "exit (stderr: $ERR)"
  local s; s=$(staged_dir)
  hasnt "$(cat "$s"/conf.d/*.conf)" "/var/cache/nginx/" "no live cache path in the staged conf.d"
  has "$(cat "$s"/conf.d/caltechauthors_cache.conf)" "$s/cache/caltechauthors_iiif" "the cache path is inside the stage"
}
t_check_changes_nothing() {
  new_case $FUNCNAME
  local before_etc before_repo; before_etc=$(tree_sig "$CASE_DIR/etc"); before_repo=$(tree_sig "$CASE_DIR/repo")
  run -- $(std); eq "$RC" 0 "exit (stderr: $ERR)"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before_etc" "the target tree"; eq "$(tree_sig "$CASE_DIR/repo")" "$before_repo" "the repository"
  if [ ! -e /var/cache/nginx ]; then absent /var/cache/nginx "nothing was created under /var/cache"; fi
}
t_a_missing_cache_parent_does_not_fail_check() {
  new_case $FUNCNAME
  if [ -d /var/cache/nginx ] && [ -w /var/cache/nginx ]; then echo "      (skipped: /var/cache/nginx exists and is writable here)"; return; fi
  run -- $(std) --no-logagent; eq "$RC" 0 "exit (stderr: $ERR)"
}
t_nginx_is_asked_to_test_the_staged_tree_not_the_live_one() {
  new_case $FUNCNAME; run -- $(std) --no-logagent --keep-stage; local s; s=$(staged_dir); local log; log=$(cat "$CASE_DIR/stub.log")
  has "$log" "nginx -t -c $s/nginx.conf" "the test"; has "$log" "nginx -T -c $s/nginx.conf" "the dump"
  hasnt "$log" "-c $CASE_DIR/etc/nginx.conf" "the live tree was not tested"
}
t_a_dangling_symlink_is_copied_as_a_dangling_symlink() {
  new_case $FUNCNAME; ln -s /nowhere/at/all "$CASE_DIR/etc/sites-enabled/default"
  run -- $(std) --no-logagent --keep-stage; eq "$RC" 0 "the copy is not stopped by a stale link (stderr: $ERR)"
  local s; s=$(staged_dir)
  [ -L "$s/sites-enabled/default" ] || fail "the stage has no link at sites-enabled/default"
  [ ! -e "$s/sites-enabled/default" ] || fail "the stage's link is not dangling, so a real nginx -t would not fail where the host would"
  eq "$(readlink "$s/sites-enabled/default")" "/nowhere/at/all" "its target is kept as it is"
}
t_the_stage_paths_are_rewritten() {
  new_case $FUNCNAME; run -- $(std) --no-logagent --keep-stage; local s; s=$(staged_dir)
  has "$(cat "$s/nginx.conf")" "include $s/conf.d/*.conf;" "stock nginx.conf include is rewritten to the stage"
  hasnt "$(cat "$s/nginx.conf")" "$CASE_DIR/etc/" "no live path is left"
}
t_a_failing_nginx_test_is_wrong_data() {
  new_case $FUNCNAME; run STUB_NGINX_T_RC=1 "STUB_NGINX_T_MSG=nginx: [emerg] unknown log format \"x\"" -- $(std) --no-logagent
  eq "$RC" 65 "exit"; has "$ERR" "unknown log format" "shows nginx's complaint"
}
t_the_stage_is_removed_on_exit() {
  new_case $FUNCNAME; run -- $(std) --no-logagent
  local s; s=$(sed -n 's/^nginx -t -c \(.*\)\/nginx.conf$/\1/p' "$CASE_DIR/stub.log" | head -1)
  [ -n "$s" ] || { fail "the stage path was not found in the stub log"; return; }
  absent "$s" "the stage"
  run STUB_NGINX_T_RC=1 -- $(std) --no-logagent
  s=$(sed -n 's/^nginx -t -c \(.*\)\/nginx.conf$/\1/p' "$CASE_DIR/stub.log" | tail -1); absent "$s" "the stage after a failure"
}
t_logagent_gets_the_staged_dump_and_no_sample() {
  new_case $FUNCNAME; run -- $(std) --keep-stage; eq "$RC" 0 "exit (stderr: $ERR)"; local log; log=$(cat "$CASE_DIR/stub.log")
  has "$log" "logagent check --config $CASE_DIR/logagent.yaml --dump " "logagent check with the config and a dump"; has "$log" "--sample 0" "no log sampling"
  local s; s=$(staged_dir); hasnt "$log" "$CASE_DIR/etc/nginx.conf" "the dump is not of the live tree"
}
t_a_logagent_gap_blocks_the_deployment() {
  new_case $FUNCNAME; run STUB_LOGAGENT_RC=1 "STUB_LOGAGENT_OUT=[gap] access-log-off: server a has access_log off" -- $(std)
  eq "$RC" 65 "exit"; has "$ERR$OUT" "access-log-off" "shows logagent's finding"
}
t_a_logagent_warning_does_not_block() {
  new_case $FUNCNAME; run "STUB_LOGAGENT_OUT=[warn] location /static has access_log off" -- $(std)
  eq "$RC" 0 "exit (stderr: $ERR)"; has "$ERR$OUT" "location /static" "the warning is shown"
}
t_a_logagent_config_problem_passes_through() {
  new_case $FUNCNAME; run STUB_LOGAGENT_RC=78 -- $(std); eq "$RC" 78 "a configuration error"
  run STUB_LOGAGENT_RC=66 -- $(std); eq "$RC" 66 "a missing logagent configuration"
}
t_a_logagent_failure_nothing_classified_is_internal() {
  new_case $FUNCNAME; run STUB_LOGAGENT_RC=9 -- $(std); eq "$RC" 70 "exit"
}
t_a_missing_logagent_is_skipped_with_a_message() {
  new_case $FUNCNAME; run LOGAGENT=/nonexistent/logagent -- $(std); eq "$RC" 0 "exit (stderr: $ERR)"; has "$ERR" "skipped" "says it skipped"
}
t_require_logagent_makes_a_missing_one_an_error() {
  new_case $FUNCNAME; run LOGAGENT=/nonexistent/logagent -- $(std) --require-logagent; eq "$RC" 66 "exit"; has "$ERR" "logagent" "names it"
}
t_no_logagent_never_runs_it() {
  new_case $FUNCNAME; run -- $(std) --no-logagent; eq "$RC" 0 "exit"
  eq "$(grep -c '^logagent ' "$CASE_DIR/stub.log")" 0 "logagent was not called"
  run -- $(std); eq "$(grep -c '^logagent ' "$CASE_DIR/stub.log")" 1 "control: without the flag it is called once"
}

# ---- phase 3: usage ----------------------------------------------------------

t_reload_and_yes_apply_only_where_they_make_sense() {
  new_case $FUNCNAME
  run -- $(std) --reload; eq "$RC" 2 "check --reload"; has "$ERR" "--reload only applies to apply and rollback" "says where it applies"
  run -- $(stdv diff) --yes; eq "$RC" 2 "diff --yes"; has "$ERR" "--yes only applies to apply" "says where it applies"
}
t_rollback_takes_one_optional_stamp_and_the_others_none() {
  new_case $FUNCNAME
  run -- $(stdr) one two; eq "$RC" 2 "two stamps"; has "$ERR" "two" "names the surplus argument"
  run -- $(std) somestamp; eq "$RC" 2 "check with a stamp"
}
t_rollback_needs_no_server_name() {
  new_case $FUNCNAME; run -- $(stdr); eq "$RC" 66 "no backups is no input, not a usage error"
}
t_cache_dir_and_backup_dir_must_be_absolute_paths() {
  new_case $FUNCNAME
  run -- $(stdv apply) --yes --cache-dir relative/dir; eq "$RC" 2 "relative --cache-dir"; has "$ERR" "--cache-dir" "names the option"
  run -- $(stdv apply) --yes --backup-dir relative/dir; eq "$RC" 2 "relative --backup-dir"; has "$ERR" "--backup-dir" "names the option"
  run -- $(std) --no-logagent --cache-dir "$CASE_DIR/cache"; eq "$RC" 0 "control: check accepts an absolute --cache-dir (stderr: $ERR)"
}

# ---- phase 3: diff -------------------------------------------------------------

t_diff_on_a_fresh_host_reports_everything_missing() {
  new_case $FUNCNAME; local before; before=$(tree_sig "$CASE_DIR/etc")
  run -- $(stdv diff); eq "$RC" 1 "drift is exit 1"
  for f in conf.d/caltechauthors_limits.conf conf.d/caltechauthors_cache.conf conf.d/caltechauthors_log.conf conf.d/cloudflare_real_ip.conf \
           sites-available/caltechauthors.conf snippets/caltechauthors-tls.conf sites-enabled/caltechauthors.conf; do
    has "$OUT" "missing  $f" "$f is reported missing"
  done
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "diff changed the tree"
}
t_diff_after_apply_reports_no_drift() {
  new_case $FUNCNAME; apply_ok; run -- $(stdv diff); eq "$RC" 0 "exit (out: $OUT)"; has "$OUT" "no drift" "says so"
}
t_diff_shows_a_hand_edit_as_a_diff() {
  new_case $FUNCNAME; apply_ok; echo "# a hand edit" >> "$CASE_DIR/etc/conf.d/caltechauthors_limits.conf"
  run -- $(stdv diff); eq "$RC" 1 "exit"; has "$OUT" "differs  conf.d/caltechauthors_limits.conf" "names the file"; has "$OUT" "-# a hand edit" "the diff shows the host's extra line"
}
t_diff_notices_a_missing_or_a_wrong_link() {
  new_case $FUNCNAME; apply_ok
  rm "$CASE_DIR/etc/sites-enabled/caltechauthors.conf"; run -- $(stdv diff); eq "$RC" 1 "missing link"; has "$OUT" "missing  sites-enabled/caltechauthors.conf" "reports it"
  ln -s /nowhere "$CASE_DIR/etc/sites-enabled/caltechauthors.conf"; run -- $(stdv diff); eq "$RC" 1 "wrong link"; has "$OUT" "differs  sites-enabled/caltechauthors.conf" "reports it"
}
t_diff_changes_nothing_and_does_not_need_nginx() {
  new_case $FUNCNAME; local before; before=$(tree_sig "$CASE_DIR/etc")
  run NGINX=/nonexistent/nginx -- $(stdv diff); eq "$RC" 1 "no nginx is needed (a 66 would mean it looked for one)"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "the tree"; eq "$(n_backups)" 0 "no backup directory"
}
t_diff_does_not_need_root() {
  new_case $FUNCNAME
  if [ "$(id -u)" = 0 ]; then echo "      (skipped: running as root)"; return; fi
  run -- diff --repo-dir "$CASE_DIR/repo" --server-name a.example --tls self-signed
  [ "$RC" != 77 ] || fail "diff refused to run as a normal user (exit 77) although it only reads"
}
t_diff_compares_real_paths_not_the_stage() {
  new_case $FUNCNAME; apply_ok; run -- $(stdv diff); eq "$RC" 0 "a diff that compared stage-rewritten text would report the cache and etc paths as drift"
}

# ---- phase 3: apply ------------------------------------------------------------

t_apply_installs_the_rendered_files() {
  new_case $FUNCNAME; apply_ok; local e=$CASE_DIR/etc
  for f in conf.d/caltechauthors_limits.conf conf.d/caltechauthors_cache.conf conf.d/caltechauthors_log.conf conf.d/cloudflare_real_ip.conf; do exists "$e/$f" "$f"; done
  has "$(cat "$e/sites-available/caltechauthors.conf")" "server_name host.example.org;" "the site file is rendered"
  has "$(cat "$e/snippets/caltechauthors-tls.conf")" "include snippets/self-signed.conf;" "the tls snippet"
  eq "$(readlink "$e/sites-enabled/caltechauthors.conf")" "$e/sites-available/caltechauthors.conf" "the sites-enabled link"
}
t_apply_installs_the_rendered_repository_files_not_the_stage_copies() {
  new_case $FUNCNAME; apply_ok
  eq "$(grep -rl "$CASE_DIR/tmp" "$CASE_DIR/etc" 2>/dev/null | wc -l | tr -d ' ')" 0 "an installed file mentions the stage path"
  has "$(cat "$CASE_DIR/etc/conf.d/caltechauthors_cache.conf")" "$CASE_DIR/cache/caltechauthors_iiif" "the real cache path"
}
t_apply_installs_files_with_mode_0644() {
  new_case $FUNCNAME; apply_ok
  eq "$(mode_of "$CASE_DIR/etc/conf.d/caltechauthors_limits.conf")" "-rw-r--r--" "conf.d file"
  eq "$(mode_of "$CASE_DIR/etc/sites-available/caltechauthors.conf")" "-rw-r--r--" "site file"
  eq "$(mode_of "$CASE_DIR/etc/snippets/caltechauthors-tls.conf")" "-rw-r--r--" "tls snippet"
}
t_apply_leaves_the_packaged_nginx_conf_and_every_other_file_alone() {
  new_case $FUNCNAME; echo "# another site's file" > "$CASE_DIR/etc/conf.d/other.conf"; ln -s /nowhere "$CASE_DIR/etc/sites-enabled/default"
  local sum_conf sum_other; sum_conf=$(cksum < "$CASE_DIR/etc/nginx.conf"); sum_other=$(tree_sig "$CASE_DIR/etc" | grep -E 'other.conf|sites-enabled/default|mime.types|dhparam')
  apply_ok
  eq "$(cksum < "$CASE_DIR/etc/nginx.conf")" "$sum_conf" "the packaged nginx.conf"
  eq "$(tree_sig "$CASE_DIR/etc" | grep -E 'other.conf|sites-enabled/default|mime.types|dhparam')" "$sum_other" "the unmanaged files"
}
t_apply_creates_the_cache_parent_before_the_installed_test() {
  new_case $FUNCNAME; absent "$CASE_DIR/cache" "the cache directory before"
  apply_ok; exists "$CASE_DIR/cache" "the cache parent after (the stub nginx -t on the installed tree fails without it)"
}
t_a_second_apply_changes_nothing() {
  new_case $FUNCNAME; apply_ok; local sig; sig=$(tree_sig "$CASE_DIR/etc"); : > "$CASE_DIR/stub.log"
  run -- $(stdv apply) --yes --no-logagent --reload; eq "$RC" 0 "exit"; has "$OUT" "no change" "says so"
  eq "$(tree_sig "$CASE_DIR/etc")" "$sig" "the tree"; eq "$(n_backups)" 1 "no second backup"
  eq "$(grep -c '^systemctl ' "$CASE_DIR/stub.log")" 0 "nothing to reload"
}
t_apply_asks_first_and_a_no_changes_nothing() {
  new_case $FUNCNAME; local before; before=$(tree_sig "$CASE_DIR/etc")
  RUN_STDIN=n; run -- $(stdv apply) --no-logagent; eq "$RC" 1 "an n declines (exit 1, nothing wrong, the answer is no)"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "the tree"; eq "$(n_backups)" 0 "no backup"
  RUN_STDIN=; run -- $(stdv apply) --no-logagent; eq "$RC" 1 "an empty answer declines"
  RUN_STDIN=y; run -- $(stdv apply) --no-logagent; eq "$RC" 0 "a y proceeds (stderr: $ERR)"; exists "$CASE_DIR/etc/sites-available/caltechauthors.conf" "installed"
}
t_apply_stops_at_the_staged_gates_before_any_change() {
  new_case $FUNCNAME; local before; before=$(tree_sig "$CASE_DIR/etc")
  run STUB_NGINX_T_RC=1 -- $(stdv apply) --yes --no-logagent; eq "$RC" 65 "a failing staged nginx -t"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "the tree"; eq "$(n_backups)" 0 "no backup"
  run STUB_LOGAGENT_RC=1 -- $(stdv apply) --yes; eq "$RC" 65 "a logagent gap"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "the tree after the gap"; eq "$(n_backups)" 0 "no backup after the gap"
}
t_a_failing_installed_test_restores_everything() {
  new_case $FUNCNAME; echo "# the old limits" > "$CASE_DIR/etc/conf.d/caltechauthors_limits.conf"; local before; before=$(tree_sig "$CASE_DIR/etc")
  run STUB_NGINX_INSTALLED_RC=1 -- $(stdv apply) --yes --no-logagent; eq "$RC" 65 "exit"; has "$ERR" "restored" "says it restored"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "the tree is byte-identical to before"
  eq "$(n_backups)" 1 "the backup is kept"; exists "$(latest_backup)/MANIFEST" "its manifest"
}
t_a_stage_that_cannot_be_built_changes_nothing() {
  new_case $FUNCNAME
  if [ "$(id -u)" = 0 ]; then echo "      (skipped: running as root, chmod would not stop the copy)"; return; fi
  local before; before=$(tree_sig "$CASE_DIR/etc"); chmod 555 "$CASE_DIR/etc/sites-available"
  run -- $(stdv apply) --yes --no-logagent; local rc=$RC; chmod 755 "$CASE_DIR/etc/sites-available"
  eq "$rc" 74 "exit"; eq "$(tree_sig "$CASE_DIR/etc")" "$before" "the tree"; eq "$(n_backups)" 0 "no backup was made for a stage that never got built"
}
t_a_copy_that_fails_part_way_is_restored() {
  new_case $FUNCNAME
  echo "# the old limits" > "$CASE_DIR/etc/conf.d/caltechauthors_limits.conf"; local before; before=$(tree_sig "$CASE_DIR/etc")
  run PATH="$CASE_DIR/bin:$PATH" STUB_INSTALL_FAIL_ON=sites-available -- $(stdv apply) --yes --no-logagent
  eq "$RC" 74 "exit (stderr: $ERR)"; has "$ERR" "restored" "says it restored"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "the conf.d files installed before the failure are undone"
  eq "$(n_backups)" 1 "the backup is kept"
}
t_a_half_written_file_from_a_failed_install_is_removed() {
  new_case $FUNCNAME; local before; before=$(tree_sig "$CASE_DIR/etc")
  run PATH="$CASE_DIR/bin:$PATH" STUB_INSTALL_FAIL_ON=sites-available/caltechauthors.conf.nginx-deploy.new -- $(stdv apply) --yes --no-logagent
  eq "$RC" 74 "exit (stderr: $ERR)"
  eq "$(find "$CASE_DIR/etc" -name '*.nginx-deploy.new' | wc -l | tr -d ' ')" 0 "no half-written .new file is left behind"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "the tree is as it was"
}
t_two_backups_in_the_same_second_do_not_overwrite_each_other() {
  new_case $FUNCNAME
  run PATH="$CASE_DIR/bin:$PATH" STUB_DATE=20260101-000000 -- $(stdv apply) --yes --no-logagent; eq "$RC" 0 "first apply (stderr: $ERR)"
  echo "# edited by hand" >> "$CASE_DIR/etc/conf.d/caltechauthors_limits.conf"
  run PATH="$CASE_DIR/bin:$PATH" STUB_DATE=20260101-000000 -- $(stdv apply) --yes --no-logagent; eq "$RC" 0 "second apply (stderr: $ERR)"
  eq "$(n_backups)" 2 "two backup directories"
  exists "$CASE_DIR/backups/20260101-000000/MANIFEST" "the first"; exists "$CASE_DIR/backups/20260101-000000-2/MANIFEST" "the second"
  has "$(cat "$CASE_DIR/backups/20260101-000000/MANIFEST")" "created conf.d/caltechauthors_limits.conf" "the first backup is intact"
  has "$(cat "$CASE_DIR/backups/20260101-000000-2/files/conf.d/caltechauthors_limits.conf")" "# edited by hand" "the second holds the hand edit"
}
t_the_backup_has_a_stamp_name_and_a_manifest() {
  new_case $FUNCNAME; apply_ok; local b; b=$(latest_backup)
  printf '%s' "$(basename "$b")" | grep -Eq '^[0-9]{8}-[0-9]{6}' || fail "the backup name '$(basename "$b")' is not a stamp"
  local m; m=$(cat "$b/MANIFEST")
  has "$m" "etc_dir=$CASE_DIR/etc" "the etc directory"; has "$m" "created conf.d/caltechauthors_limits.conf" "a created file"
  has "$m" "link-created sites-enabled/caltechauthors.conf" "the created link"
}
t_the_backup_holds_only_what_was_replaced() {
  new_case $FUNCNAME; apply_ok; echo "# edited by hand" >> "$CASE_DIR/etc/conf.d/caltechauthors_log.conf"
  apply_ok; local b; b=$(latest_backup)
  eq "$(find "$b/files" -type f | wc -l | tr -d ' ')" 1 "one file backed up"
  has "$(cat "$b/files/conf.d/caltechauthors_log.conf")" "# edited by hand" "it holds the host's version"
  has "$(cat "$b/MANIFEST")" "replaced conf.d/caltechauthors_log.conf" "the manifest says replaced"
}
t_a_backup_directory_that_cannot_be_made_is_cant_create() {
  new_case $FUNCNAME; echo "a file" > "$CASE_DIR/blocker"; local before; before=$(tree_sig "$CASE_DIR/etc")
  run -- $(stdv apply) --yes --no-logagent --backup-dir "$CASE_DIR/blocker/sub"; eq "$RC" 73 "exit"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "nothing is installed without a backup"
}
t_nothing_reloads_without_the_flag() {
  new_case $FUNCNAME; apply_ok; eq "$(grep -c '^systemctl ' "$CASE_DIR/stub.log")" 0 "no systemctl call"
}
t_reload_follows_a_good_installed_test() {
  new_case $FUNCNAME; apply_ok --reload; eq "$(grep -c '^systemctl reload nginx$' "$CASE_DIR/stub.log")" 1 "one reload"
  local last_t last_r; last_t=$(grep -n "^nginx -t -c $CASE_DIR/etc/nginx.conf" "$CASE_DIR/stub.log" | tail -1 | cut -d: -f1); last_r=$(grep -n '^systemctl reload' "$CASE_DIR/stub.log" | cut -d: -f1)
  [ -n "$last_t" ] && [ -n "$last_r" ] && [ "$last_t" -lt "$last_r" ] || fail "the reload must come after the installed-tree test (test line '$last_t', reload line '$last_r')"
}
t_a_failing_reload_is_unavailable_and_keeps_the_files() {
  new_case $FUNCNAME; run STUB_SYSTEMCTL_RC=1 -- $(stdv apply) --yes --no-logagent --reload
  eq "$RC" 69 "exit"; has "$ERR" "previous configuration" "says nginx keeps serving the old one"
  exists "$CASE_DIR/etc/sites-available/caltechauthors.conf" "the files stay installed, since the tree itself is good"
}
t_a_failing_installed_test_never_reloads() {
  new_case $FUNCNAME; run STUB_NGINX_INSTALLED_RC=1 -- $(stdv apply) --yes --no-logagent --reload
  eq "$RC" 65 "exit"; eq "$(grep -c '^systemctl ' "$CASE_DIR/stub.log")" 0 "no reload"
}
t_reload_needs_systemctl_before_anything_changes() {
  new_case $FUNCNAME; local before; before=$(tree_sig "$CASE_DIR/etc")
  run SYSTEMCTL=/nonexistent/systemctl -- $(stdv apply) --yes --no-logagent --reload; eq "$RC" 66 "exit"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "the tree"
}
t_a_new_server_name_replaces_the_site_file_and_backs_up_the_old_one() {
  new_case $FUNCNAME; apply_ok
  run -- $(stdv apply) --yes --no-logagent --server-name other.example.org; eq "$RC" 0 "exit (stderr: $ERR)"
  has "$(cat "$CASE_DIR/etc/sites-available/caltechauthors.conf")" "server_name other.example.org;" "the new name"
  has "$(cat "$(latest_backup)/files/sites-available/caltechauthors.conf")" "server_name host.example.org;" "the backup holds the old one"
}
t_apply_needs_root_for_the_default_etc_dir() {
  new_case $FUNCNAME
  if [ "$(id -u)" = 0 ]; then echo "      (skipped: running as root)"; return; fi
  run -- apply --repo-dir "$CASE_DIR/repo" --server-name a.example --tls self-signed --yes --no-logagent; eq "$RC" 77 "exit"
}

# ---- phase 3: rollback ---------------------------------------------------------

t_rollback_after_a_first_apply_restores_the_original_tree() {
  new_case $FUNCNAME; local before; before=$(tree_sig "$CASE_DIR/etc")
  apply_ok; run -- $(stdr) --no-logagent; run -- $(stdr); eq "$RC" 0 "rollback (stderr: $ERR)"
  eq "$(tree_sig "$CASE_DIR/etc")" "$before" "created files and the link are gone"
}
t_rollback_restores_replaced_content_and_a_replaced_link() {
  new_case $FUNCNAME
  echo "# the old limits" > "$CASE_DIR/etc/conf.d/caltechauthors_limits.conf"
  echo "# an old site" > "$CASE_DIR/etc/sites-available/old.conf"; ln -s "$CASE_DIR/etc/sites-available/old.conf" "$CASE_DIR/etc/sites-enabled/caltechauthors.conf"
  local before; before=$(tree_sig "$CASE_DIR/etc"); apply_ok
  run -- $(stdr); eq "$RC" 0 "rollback (stderr: $ERR)"; eq "$(tree_sig "$CASE_DIR/etc")" "$before" "content and link restored"
}
t_rollback_with_no_backups_is_no_input() {
  new_case $FUNCNAME; run -- $(stdr); eq "$RC" 66 "no backup directory"; has "$ERR" "no backups" "says so"
  mkdir "$CASE_DIR/backups"; run -- $(stdr); eq "$RC" 66 "an empty backup directory"; has "$ERR" "no backups under" "says so, and not that a named backup is missing"
}
t_rollback_takes_the_latest_or_the_named_stamp() {
  new_case $FUNCNAME; apply_ok; local first; first=$(basename "$(latest_backup)")
  echo "# hand edit" >> "$CASE_DIR/etc/conf.d/caltechauthors_limits.conf"; apply_ok
  run -- $(stdr); eq "$RC" 0 "rollback of the latest"; has "$(cat "$CASE_DIR/etc/conf.d/caltechauthors_limits.conf")" "# hand edit" "the latest backup returns the hand-edited file"
  run -- $(stdr) "$first"; eq "$RC" 0 "rollback of the named first backup"; absent "$CASE_DIR/etc/conf.d/caltechauthors_limits.conf" "the first backup returns the host to before anything was installed"
}
t_an_unknown_stamp_is_no_input() {
  new_case $FUNCNAME; apply_ok; run -- $(stdr) 19990101-000000; eq "$RC" 66 "exit"; has "$ERR" "19990101-000000" "names the stamp"
}
t_rollback_tests_the_restored_tree() {
  new_case $FUNCNAME; apply_ok; run STUB_NGINX_INSTALLED_RC=1 -- $(stdr); eq "$RC" 65 "exit"
}
t_rollback_reloads_only_with_the_flag() {
  new_case $FUNCNAME; apply_ok; run -- $(stdr); eq "$(grep -c '^systemctl ' "$CASE_DIR/stub.log")" 0 "no flag, no reload"
  apply_ok; run -- $(stdr) --reload; eq "$(grep -c '^systemctl reload nginx$' "$CASE_DIR/stub.log")" 1 "with the flag, one reload"
}
t_rollback_refuses_another_etc_dir() {
  new_case $FUNCNAME; apply_ok; mkdir "$CASE_DIR/etc2"
  run -- rollback --etc-dir "$CASE_DIR/etc2" --backup-dir "$CASE_DIR/backups"; eq "$RC" 2 "exit"; has "$ERR" "$CASE_DIR/etc" "names the directory the backup belongs to"
}
t_rollback_survives_files_that_are_already_gone() {
  new_case $FUNCNAME; apply_ok; rm "$CASE_DIR/etc/conf.d/caltechauthors_cache.conf"; run -- $(stdr); eq "$RC" 0 "exit (stderr: $ERR)"
}

# ---- the runner -------------------------------------------------------------

PATTERN=${1:-}
TESTS=$(declare -F | awk '{print $3}' | grep '^t_' | sort)
echo "nginx-deploy_test.bash: $(echo "$TESTS" | wc -w | tr -d ' ') tests, script $SCRIPT"
for t in $TESTS; do
  if [ -n "$PATTERN" ]; then case "$t" in *"$PATTERN"*) ;; *) continue;; esac; fi
  TEST_OK=1
  ( "$t" ) > "$ROOT/$t.out" 2>&1
  # a function cannot set the parent's TEST_OK from a subshell, so a failure is a FAIL line in its output
  if grep -q '^      FAIL:' "$ROOT/$t.out" || [ ! -x "$SCRIPT" ]; then
    echo "FAIL  $t"; sed 's/^/      /' "$ROOT/$t.out" | grep -v '^            ' | head -8
    [ -x "$SCRIPT" ] || echo "      (the script $SCRIPT does not exist or is not executable)"
    FAILED=$((FAILED+1)); FAILED_NAMES="$FAILED_NAMES $t"
  else
    echo "PASS  $t"; PASSED=$((PASSED+1))
    grep '(skipped' "$ROOT/$t.out" | head -1
  fi
done
echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
