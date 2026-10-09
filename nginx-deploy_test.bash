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
    if [ "${STUB_NGINX_T_RC:-0}" != 0 ]; then echo "${STUB_NGINX_T_MSG:-nginx: [emerg] stub says the configuration is wrong}" >&2; exit "$STUB_NGINX_T_RC"; fi
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
  chmod +x "$CASE_DIR/bin/nginx" "$CASE_DIR/bin/logagent"
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
  OUT=$(env STUB_LOG="$CASE_DIR/stub.log" NGINX="$CASE_DIR/bin/nginx" LOGAGENT="$CASE_DIR/bin/logagent" TMPDIR="$CASE_DIR/tmp" \
    ${envs[@]+"${envs[@]}"} "$SCRIPT" "$@" 2> "$CASE_DIR/err")
  RC=$?
  ERR=$(cat "$CASE_DIR/err")
}

# std prints the arguments most tests share: check with a full, valid set of options.
std() {
  echo "check --repo-dir $CASE_DIR/repo --etc-dir $CASE_DIR/etc --server-name host.example.org --tls self-signed --logagent-config $CASE_DIR/logagent.yaml"
}

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
t_verbs_not_built_yet_are_unknown() { new_case $FUNCNAME; run -- apply --server-name x; eq "$RC" 2 "apply is not a verb yet"; }
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
