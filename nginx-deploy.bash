#!/bin/bash
#
# nginx-deploy.bash - deploy this repository's nginx configuration to a host by copy.
#
# caltechauthors DR-0009. Verbs: check, diff, apply, rollback. The repository's nginx/ tree
# mirrors /etc/nginx; this script renders it for one host, tests the result on a STAGED copy
# of the host's /etc/nginx before it copies anything, backs up what it replaces, and can put
# the backup back. The packaged /etc/nginx/nginx.conf is never edited.
#
# Written for bash 3.2 (macOS) and later.

set -u

VERSION=0.0.2
PROG=nginx-deploy.bash

# Exit codes, workspace DR-0014.
EX_OK=0
EX_NEGATIVE=1
EX_USAGE=2
EX_DATA=65
EX_NOINPUT=66
EX_UNAVAILABLE=69
EX_INTERNAL=70
EX_CANTCREAT=73
EX_IOERR=74
EX_NOPERM=77
EX_CONFIG=78

usage_text() {
  cat <<'EOF'
NAME
  nginx-deploy.bash - deploy the repository's nginx configuration to a host by copy

SYNOPSIS
  nginx-deploy.bash check    [OPTIONS]
  nginx-deploy.bash diff     [OPTIONS]
  nginx-deploy.bash apply    [OPTIONS] [--reload] [--yes]
  nginx-deploy.bash rollback [--etc-dir DIR] [--backup-dir DIR] [--reload] [STAMP]
  nginx-deploy.bash --help | --version

DESCRIPTION
  The repository's nginx/ tree mirrors /etc/nginx. This script renders it for one host
  (replacing the tokens written between @ signs in the site file) and installs it by COPY,
  never by symlink, so a change to the checkout is never a live change to the host. The
  packaged /etc/nginx/nginx.conf is never edited.

VERBS
  check     render, build a STAGED copy of the host's /etc/nginx with the rendered files laid
            over it, and test that copy with `nginx -t -c` and, if installed, `logagent check`;
            changes nothing on the host
  diff      show the installed files against the rendered ones; exit 1 when they differ
  apply     check, then back up what will be replaced, copy the rendered files, run `nginx -t`
            on the installed tree, and restore the backup if that fails. Reloads nginx only
            with --reload. Asks first unless --yes is given.
  rollback  put a backup back (the latest, or the named STAMP), run `nginx -t`, and reload
            only with --reload

OPTIONS
  --server-name NAME     the host's name, for server_name ("_" is a catch-all). Required for
                         check, diff and apply.
  --tls letsencrypt|self-signed
                         which certificate pair the site uses. Required for check, diff, apply.
  --cert-name NAME       the Let's Encrypt lineage under /etc/letsencrypt/live/
                         (default: the server name; used with --tls letsencrypt)
  --site-name NAME       the site file's name under sites-available/ (default: caltechauthors)
  --repo-dir DIR         the checkout holding nginx/ (default: this script's directory); the
                         redirect map and the static files are found under it
  --etc-dir DIR          the nginx configuration directory (default: /etc/nginx)
  --cache-dir DIR        the directory that holds the IIIF cache directory (default: /var/cache/nginx);
                         apply creates it, nginx creates caltechauthors_iiif inside it
  --backup-dir DIR       where apply keeps its backups (default: /var/backups/caltechauthors-nginx)
  --logagent-config FILE logagent's host configuration (default: /etc/logagent/logagent.yaml)
  --require-logagent     a missing logagent is an error, not a skipped step
  --no-logagent          do not run logagent check
  --reload               apply and rollback: reload nginx after a good test
  --yes                  apply: do not ask first (for installers)
  --keep-stage           keep the staged tree and print its path (for debugging)
  --help, --version

ENVIRONMENT
  NGINX      the nginx program (default: nginx)
  LOGAGENT   the logagent program (default: logagent)
  SYSTEMCTL  the systemctl program, used by --reload (default: systemctl)

EXIT STATUS
   0  success, or nothing to do
   1  the answer is no: diff found drift, or apply was declined
   2  usage: unknown verb or option, a missing or surplus argument, a bad value
  65  the configuration was rejected: nginx -t failed or logagent found a gap (before any
      change, or after one that was then restored), or a token was left unreplaced
  66  a needed input is missing: nginx, systemctl with --reload, the repository's nginx/ tree,
      the etc directory, a snippet or dhparam.pem it requires, a backup, or logagent with
      --require-logagent
  69  --reload: systemctl could not reload nginx (the files are installed and nginx -t
      passes; nginx keeps serving the previous configuration)
  70  an error nothing classified (a bug)
  73  the backup directory could not be made (nothing was changed)
  74  a copy failed part way (the backup was restored)
  77  not root, and --etc-dir is /etc/nginx
  78  logagent's configuration file is present and wrong
EOF
}

die() { # die CODE MESSAGE...
  local code=$1; shift
  echo "$PROG: $*" >&2
  exit "$code"
}

usage_error() { # usage_error MESSAGE...
  echo "$PROG: $*" >&2
  echo "try: $PROG --help" >&2
  exit $EX_USAGE
}

WORK=""
KEEP=0
cleanup() {
  if [ -n "$WORK" ] && [ "$KEEP" -ne 1 ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

# ---- arguments ---------------------------------------------------------------

POS=()
SERVER_NAME=""
TLS=""
CERT_NAME=""
SITE_NAME=caltechauthors
REPO_DIR=""
ETC_DIR=/etc/nginx
CACHE_DIR=/var/cache/nginx
BACKUP_ROOT=/var/backups/caltechauthors-nginx
LOGAGENT_CONFIG=/etc/logagent/logagent.yaml
REQUIRE_LOGAGENT=0
NO_LOGAGENT=0
RELOAD=0
YES=0

need_value() { # need_value OPTION COUNT
  [ "$2" -ge 2 ] || usage_error "option $1 needs a value"
}

while [ $# -gt 0 ]; do
  arg=$1
  case "$arg" in
    --*=*) opt=${arg%%=*}; val=${arg#*=}; shift; set -- "$opt" "$val" "$@"; arg=$1 ;;
  esac
  case "$arg" in
    --help|-h) usage_text; exit $EX_OK ;;
    --version) echo "$PROG $VERSION"; exit $EX_OK ;;
    --server-name) need_value "$arg" $#; SERVER_NAME=$2; shift 2 ;;
    --tls) need_value "$arg" $#; TLS=$2; shift 2 ;;
    --cert-name) need_value "$arg" $#; CERT_NAME=$2; shift 2 ;;
    --site-name) need_value "$arg" $#; SITE_NAME=$2; shift 2 ;;
    --repo-dir) need_value "$arg" $#; REPO_DIR=$2; shift 2 ;;
    --etc-dir) need_value "$arg" $#; ETC_DIR=$2; shift 2 ;;
    --cache-dir) need_value "$arg" $#; CACHE_DIR=$2; shift 2 ;;
    --backup-dir) need_value "$arg" $#; BACKUP_ROOT=$2; shift 2 ;;
    --logagent-config) need_value "$arg" $#; LOGAGENT_CONFIG=$2; shift 2 ;;
    --require-logagent) REQUIRE_LOGAGENT=1; shift ;;
    --no-logagent) NO_LOGAGENT=1; shift ;;
    --reload) RELOAD=1; shift ;;
    --yes) YES=1; shift ;;
    --keep-stage) KEEP=1; shift ;;
    --) shift; while [ $# -gt 0 ]; do POS+=("$1"); shift; done; break ;;
    -*) usage_error "unknown option: $arg" ;;
    *) POS+=("$arg"); shift ;;
  esac
done

[ ${#POS[@]} -gt 0 ] || usage_error "no verb given (the verbs are: check, diff, apply, rollback)"
VERB=${POS[0]}
case "$VERB" in
  check|diff|apply|rollback) ;;
  *) usage_error "unknown verb: $VERB (the verbs are: check, diff, apply, rollback)" ;;
esac
STAMP_ARG=""
if [ "$VERB" = rollback ]; then
  [ ${#POS[@]} -le 2 ] || usage_error "surplus argument: ${POS[2]}"
  [ ${#POS[@]} -lt 2 ] || STAMP_ARG=${POS[1]}
else
  [ ${#POS[@]} -le 1 ] || usage_error "surplus argument: ${POS[1]}"
fi
case "$VERB" in
  check|diff) [ "$RELOAD" -eq 0 ] || usage_error "--reload only applies to apply and rollback" ;;
esac
[ "$VERB" = apply ] || [ "$YES" -eq 0 ] || usage_error "--yes only applies to apply"

# ---- validating the values ---------------------------------------------------

name_ok() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]+$'; }
abs_path_ok() { printf '%s' "$1" | grep -Eq '^/[A-Za-z0-9._/-]+$'; }

ETC_DIR=${ETC_DIR%/}
[ -n "$ETC_DIR" ] || usage_error "--etc-dir must not be /"
CACHE_DIR=${CACHE_DIR%/}
BACKUP_ROOT=${BACKUP_ROOT%/}
abs_path_ok "$CACHE_DIR" || usage_error "--cache-dir '$CACHE_DIR' must be an absolute path of letters, digits, . _ - and /"
abs_path_ok "$BACKUP_ROOT" || usage_error "--backup-dir '$BACKUP_ROOT' must be an absolute path of letters, digits, . _ - and /"

if [ "$VERB" != rollback ]; then
  [ -n "$SERVER_NAME" ] || usage_error "--server-name is required"
  name_ok "$SERVER_NAME" || usage_error "--server-name '$SERVER_NAME' may only contain letters, digits, . _ and -"
  [ -n "$TLS" ] || usage_error "--tls is required (letsencrypt or self-signed)"
  case "$TLS" in
    letsencrypt|self-signed) ;;
    *) usage_error "--tls '$TLS' is not one of: letsencrypt, self-signed" ;;
  esac
  [ -n "$CERT_NAME" ] || CERT_NAME=$SERVER_NAME
  name_ok "$CERT_NAME" || usage_error "--cert-name '$CERT_NAME' may only contain letters, digits, . _ and -"
  name_ok "$SITE_NAME" || usage_error "--site-name '$SITE_NAME' may only contain letters, digits, . _ and -"
  if [ -z "$REPO_DIR" ]; then REPO_DIR=$(cd "$(dirname "$0")" && pwd); fi
  abs_path_ok "$REPO_DIR" || usage_error "--repo-dir '$REPO_DIR' must be an absolute path of letters, digits, . _ - and /"
  REPO_DIR=${REPO_DIR%/}
  if [ "$REQUIRE_LOGAGENT" -eq 1 ] && [ "$NO_LOGAGENT" -eq 1 ]; then
    usage_error "--require-logagent and --no-logagent contradict each other"
  fi
fi

# ---- what must exist before anything is built ------------------------------------

# Everything but diff writes to, or reads certificates and logs through, the nginx directory.
if [ "$VERB" != diff ] && [ "$ETC_DIR" = /etc/nginx ] && [ "$(id -u)" != 0 ]; then
  die $EX_NOPERM "run as root: this reads /etc/nginx (certificates, logs) and runs nginx -t"
fi

NGINX_BIN=${NGINX:-nginx}
if [ "$VERB" != diff ]; then
  case "$NGINX_BIN" in
    */*) [ -x "$NGINX_BIN" ] || die $EX_NOINPUT "nginx not found: $NGINX_BIN" ;;
    *) command -v "$NGINX_BIN" >/dev/null 2>&1 || die $EX_NOINPUT "nginx not found on PATH" ;;
  esac
fi

SYSTEMCTL_BIN=${SYSTEMCTL:-systemctl}
if [ "$RELOAD" -eq 1 ]; then
  case "$SYSTEMCTL_BIN" in
    */*) [ -x "$SYSTEMCTL_BIN" ] || die $EX_NOINPUT "systemctl not found: $SYSTEMCTL_BIN (--reload needs it)" ;;
    *) command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1 || die $EX_NOINPUT "systemctl not found on PATH (--reload needs it)" ;;
  esac
fi

[ -d "$ETC_DIR" ] || die $EX_NOINPUT "the nginx configuration directory is missing: $ETC_DIR"

if [ "$VERB" != rollback ]; then
  SRC=$REPO_DIR/nginx
  [ -d "$SRC" ] || die $EX_NOINPUT "the repository's nginx tree is missing: $SRC"
  [ -d "$SRC/conf.d" ] || die $EX_NOINPUT "missing: $SRC/conf.d"
  [ -f "$SRC/sites-available/caltechauthors.conf" ] || die $EX_NOINPUT "missing: $SRC/sites-available/caltechauthors.conf"
  [ -f "$SRC/tls/$TLS.conf" ] || die $EX_NOINPUT "missing: $SRC/tls/$TLS.conf"
fi

if [ "$VERB" = check ] || [ "$VERB" = apply ]; then
  [ -f "$ETC_DIR/nginx.conf" ] || die $EX_NOINPUT "missing: $ETC_DIR/nginx.conf"
  # Written by cloud-init, not by this script; it is required, not created.
  [ -f "$ETC_DIR/snippets/ssl-params.conf" ] || die $EX_NOINPUT "missing: $ETC_DIR/snippets/ssl-params.conf (cloud-init writes it)"
  [ -f "$ETC_DIR/dhparam.pem" ] || die $EX_NOINPUT "missing: $ETC_DIR/dhparam.pem (cloud-init writes it)"
  if [ "$TLS" = self-signed ]; then
    [ -f "$ETC_DIR/snippets/self-signed.conf" ] || die $EX_NOINPUT "missing: $ETC_DIR/snippets/self-signed.conf (cloud-init writes it; --tls self-signed needs it)"
  fi
fi

OWNER=""
if [ "$(id -u)" = 0 ]; then OWNER="-o root -g root"; fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nginx-deploy.XXXXXX") || die $EX_IOERR "could not make a working directory"

# ---- rendering ---------------------------------------------------------------

# render_file SOURCE DEST replaces the closed set of tokens, points the cache path at
# --cache-dir, and fails if a token is left.
render_file() {
  sed -e "s#@SERVER_NAME@#$SERVER_NAME#g" -e "s#@REPO_DIR@#$REPO_DIR#g" -e "s#@CERT_NAME@#$CERT_NAME#g" \
      -e "s#/var/cache/nginx/#$CACHE_DIR/#g" "$1" > "$2" \
    || die $EX_IOERR "could not render $1"
  local left
  left=$(grep -n -o '@[A-Z][A-Z_]*@' "$2" | head -3 | tr '\n' ' ')
  [ -z "$left" ] || die $EX_DATA "a token is left unreplaced in $1: $left"
}

# sed_escape STRING escapes a literal for use in a sed pattern that uses # as its delimiter.
sed_escape() { printf '%s' "$1" | sed 's/[][\.*^$#]/\\&/g'; }

# rewrite_in_tree DIR FROM TO replaces the literal FROM with TO in every text file under DIR.
rewrite_in_tree() {
  local dir=$1 from=$2 to=$3 f pat
  pat=$(sed_escape "$from")
  grep -rlIF -- "$from" "$dir" 2>/dev/null | while read -r f; do
    sed "s#$pat#$to#g" "$f" > "$f.rewrite.tmp" && mv "$f.rewrite.tmp" "$f"
  done
}

RENDER=$WORK/render
MANAGED=()      # the files this script owns, relative to the etc directory
LINK_REL=""
LINK_TARGET=""

# render_all renders every managed file into $RENDER, in the layout of the etc directory.
render_all() {
  mkdir -p "$RENDER/conf.d" "$RENDER/sites-available" "$RENDER/snippets" || die $EX_IOERR "could not make $RENDER"
  local f
  for f in "$SRC"/conf.d/*.conf; do
    [ -f "$f" ] || continue
    render_file "$f" "$RENDER/conf.d/$(basename "$f")"
    MANAGED+=("conf.d/$(basename "$f")")
  done
  render_file "$SRC/sites-available/caltechauthors.conf" "$RENDER/sites-available/$SITE_NAME.conf"
  MANAGED+=("sites-available/$SITE_NAME.conf")
  render_file "$SRC/tls/$TLS.conf" "$RENDER/snippets/caltechauthors-tls.conf"
  MANAGED+=("snippets/caltechauthors-tls.conf")
  LINK_REL="sites-enabled/$SITE_NAME.conf"
  LINK_TARGET="$ETC_DIR/sites-available/$SITE_NAME.conf"
}

# ---- the staged tree and its gates (check, and the start of apply) -------------

STAGE=$WORK/stage
DUMP=$WORK/dump.txt

build_stage() {
  mkdir -p "$STAGE" || die $EX_IOERR "could not make $STAGE"
  # cp -RL cannot dereference a dangling symlink; those are re-created below as dangling links, so
  # the staged nginx -t fails exactly where the host's would. Any other copy error is real.
  if ! cp -RL "$ETC_DIR/." "$STAGE/" 2> "$WORK/cp.err"; then
    if grep -v 'No such file or directory' "$WORK/cp.err" | grep -q .; then
      cat "$WORK/cp.err" >&2
      die $EX_IOERR "could not copy $ETC_DIR into the stage"
    fi
  fi
  local l rel
  find "$ETC_DIR" -type l | while read -r l; do
    [ -e "$l" ] && continue
    rel=${l#"$ETC_DIR"/}
    mkdir -p "$(dirname "$STAGE/$rel")" && ln -sfn "$(readlink "$l")" "$STAGE/$rel"
  done
  mkdir -p "$STAGE/conf.d" "$STAGE/sites-available" "$STAGE/sites-enabled" "$STAGE/snippets"
  for rel in "${MANAGED[@]}"; do
    cp "$RENDER/$rel" "$STAGE/$rel" || die $EX_IOERR "could not stage $rel"
  done
  ln -sfn "$STAGE/sites-available/$SITE_NAME.conf" "$STAGE/$LINK_REL" || die $EX_IOERR "could not link the site into the stage"
  # Point the staged copy at itself. nginx -t CREATES proxy_cache_path directories (and fails
  # when the parent is missing), so the cache path moves inside the stage too, or even a test
  # would change the host.
  rewrite_in_tree "$STAGE" "$ETC_DIR/" "$STAGE/"
  mkdir -p "$STAGE/cache"
  rewrite_in_tree "$STAGE" "$CACHE_DIR/" "$STAGE/cache/"
  if [ "$KEEP" -eq 1 ]; then echo "stage: $STAGE" >&2; fi
}

run_gates() {
  if ! "$NGINX_BIN" -t -c "$STAGE/nginx.conf" > "$WORK/nginx-t.out" 2>&1; then
    cat "$WORK/nginx-t.out" >&2
    die $EX_DATA "nginx -t rejected the staged configuration; nothing was changed on this host"
  fi
  echo "nginx -t on the staged tree: ok"

  if ! "$NGINX_BIN" -T -c "$STAGE/nginx.conf" > "$DUMP" 2> "$WORK/nginx-T.err"; then
    cat "$WORK/nginx-T.err" >&2
    die $EX_DATA "nginx -T could not dump the staged configuration"
  fi

  if [ "$NO_LOGAGENT" -eq 1 ]; then
    echo "logagent check: not run (--no-logagent)"
    return
  fi
  local la=${LOGAGENT:-logagent} found=0 rc
  case "$la" in
    */*) [ -x "$la" ] && found=1 ;;
    *) command -v "$la" >/dev/null 2>&1 && found=1 ;;
  esac
  if [ "$found" -eq 0 ]; then
    if [ "$REQUIRE_LOGAGENT" -eq 1 ]; then die $EX_NOINPUT "logagent not found ($la) and --require-logagent was given"; fi
    echo "$PROG: logagent not found; skipped logagent check (--require-logagent makes this an error)" >&2
    return
  fi
  "$la" check --config "$LOGAGENT_CONFIG" --dump "$DUMP" --sample 0 > "$WORK/logagent.out" 2>&1
  rc=$?
  case "$rc" in
    0) cat "$WORK/logagent.out"; echo "logagent check on the staged tree: ok" ;;
    1) cat "$WORK/logagent.out" >&2; die $EX_DATA "logagent check found a gap in the staged configuration; nothing was changed on this host" ;;
    66) cat "$WORK/logagent.out" >&2; die $EX_NOINPUT "logagent could not find its configuration ($LOGAGENT_CONFIG)" ;;
    78) cat "$WORK/logagent.out" >&2; die $EX_CONFIG "logagent's configuration file is wrong ($LOGAGENT_CONFIG)" ;;
    *) cat "$WORK/logagent.out" >&2; die $EX_INTERNAL "logagent check exited $rc, which this script does not know" ;;
  esac
}

# ---- comparing the installed files with the rendered ones ----------------------

CHG_REL=()     # what apply would change, relative to the etc directory
CHG_KIND=()    # created | replaced | link-created | link-replaced
CHG_OLD=()     # link-replaced: the old link target
REPORT=""      # the lines diff prints

# plan_changes fills CHG_* and REPORT.
plan_changes() {
  local rel dest
  for rel in "${MANAGED[@]}"; do
    dest=$ETC_DIR/$rel
    if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
      CHG_REL+=("$rel"); CHG_KIND+=(created); CHG_OLD+=("")
      REPORT="$REPORT"$'missing  '"$rel"$'\n'
    elif cmp -s "$RENDER/$rel" "$dest"; then
      REPORT="$REPORT"$'identical  '"$rel"$'\n'
    else
      CHG_REL+=("$rel"); CHG_KIND+=(replaced); CHG_OLD+=("")
      REPORT="$REPORT"$'differs  '"$rel"$'\n'
      REPORT="$REPORT$(diff -u -L "installed/$rel" -L "rendered/$rel" "$dest" "$RENDER/$rel" 2>&1)"$'\n'
    fi
  done
  dest=$ETC_DIR/$LINK_REL
  if [ -L "$dest" ]; then
    local cur; cur=$(readlink "$dest")
    if [ "$cur" = "$LINK_TARGET" ]; then
      REPORT="$REPORT"$'identical  '"$LINK_REL"$' -> '"$cur"$'\n'
    else
      CHG_REL+=("$LINK_REL"); CHG_KIND+=(link-replaced); CHG_OLD+=("$cur")
      REPORT="$REPORT"$'differs  '"$LINK_REL"$' (points to '"$cur"$', want '"$LINK_TARGET"$')\n'
    fi
  elif [ -e "$dest" ]; then
    CHG_REL+=("$LINK_REL"); CHG_KIND+=(replaced); CHG_OLD+=("")
    REPORT="$REPORT"$'differs  '"$LINK_REL"$' (a regular file where the link belongs)\n'
  else
    CHG_REL+=("$LINK_REL"); CHG_KIND+=(link-created); CHG_OLD+=("")
    REPORT="$REPORT"$'missing  '"$LINK_REL"$'\n'
  fi
}

# ---- restoring from a backup (apply's failure path, and rollback) ---------------

# restore_backup BACKUP_DIR puts back what its MANIFEST says apply replaced or created.
restore_backup() {
  local bk=$1 kind rel rest bad=0
  while read -r kind rel rest; do
    case "$kind" in
      replaced)
        rm -f "$ETC_DIR/$rel" && cp -p "$bk/files/$rel" "$ETC_DIR/$rel" || { echo "$PROG: could not restore $rel" >&2; bad=1; } ;;
      created|link-created)
        rm -f "$ETC_DIR/$rel" || { echo "$PROG: could not remove $rel" >&2; bad=1; } ;;
      link-replaced)
        ln -sfn "$rest" "$ETC_DIR/$rel" || { echo "$PROG: could not restore the link $rel" >&2; bad=1; } ;;
    esac
  done < "$bk/MANIFEST"
  return $bad
}

# reload_nginx runs the reload; a failure is exit 69 and leaves the files in place.
reload_nginx() {
  if ! "$SYSTEMCTL_BIN" reload nginx > "$WORK/reload.out" 2>&1; then
    cat "$WORK/reload.out" >&2
    die $EX_UNAVAILABLE "systemctl reload nginx failed; the files are installed and nginx -t passes, and nginx keeps serving the previous configuration (fix the cause and reload, or run: $PROG rollback)"
  fi
  echo "nginx reloaded"
}

# ---- the verbs ---------------------------------------------------------------

verb_check() {
  render_all
  build_stage
  run_gates
  echo "check: the staged configuration for $SERVER_NAME passed; nothing was changed on this host"
}

verb_diff() {
  render_all
  plan_changes
  printf '%s' "$REPORT"
  if [ ${#CHG_REL[@]} -eq 0 ]; then
    echo "no drift: the installed files match the repository's"
    exit $EX_OK
  fi
  echo "drift: ${#CHG_REL[@]} of $(( ${#MANAGED[@]} + 1 )) managed items differ or are missing"
  exit $EX_NEGATIVE
}

verb_apply() {
  render_all
  build_stage
  run_gates
  plan_changes
  if [ ${#CHG_REL[@]} -eq 0 ]; then
    echo "apply: no change; the installed files already match the repository's"
    return
  fi
  echo "apply: ${#CHG_REL[@]} item(s) to install for $SERVER_NAME:"
  local i
  for i in "${!CHG_REL[@]}"; do echo "  ${CHG_KIND[$i]}  ${CHG_REL[$i]}"; done
  if [ "$YES" -ne 1 ]; then
    local answer=""
    printf 'Install these? [y/N] '
    read -r answer || answer=""
    case "$answer" in
      y|Y|yes|YES) ;;
      *) echo "apply: declined; nothing was changed"; exit $EX_NEGATIVE ;;
    esac
  fi

  # the backup: made first, and nothing is installed unless it exists
  local stamp bk n=1
  stamp=$(date -u +%Y%m%d-%H%M%S)
  mkdir -p "$BACKUP_ROOT" 2>/dev/null || die $EX_CANTCREAT "could not make the backup directory $BACKUP_ROOT; nothing was changed"
  bk=$BACKUP_ROOT/$stamp
  until mkdir "$bk" 2>/dev/null; do
    [ -e "$bk" ] || die $EX_CANTCREAT "could not make the backup directory $bk; nothing was changed"
    n=$((n+1)); bk=$BACKUP_ROOT/$stamp-$n
  done
  mkdir -p "$bk/files" || die $EX_CANTCREAT "could not make $bk/files; nothing was changed"
  {
    echo "etc_dir=$ETC_DIR"
    echo "created_utc=$stamp"
    echo "script=$PROG $VERSION"
  } > "$bk/MANIFEST" || die $EX_CANTCREAT "could not write $bk/MANIFEST; nothing was changed"
  local rel kind
  for i in "${!CHG_REL[@]}"; do
    rel=${CHG_REL[$i]}; kind=${CHG_KIND[$i]}
    case "$kind" in
      replaced)
        mkdir -p "$(dirname "$bk/files/$rel")" && cp -p "$ETC_DIR/$rel" "$bk/files/$rel" || die $EX_CANTCREAT "could not back up $rel; nothing was changed"
        echo "replaced $rel" >> "$bk/MANIFEST" ;;
      created) echo "created $rel" >> "$bk/MANIFEST" ;;
      link-created) echo "link-created $rel" >> "$bk/MANIFEST" ;;
      link-replaced) echo "link-replaced $rel ${CHG_OLD[$i]}" >> "$bk/MANIFEST" ;;
    esac
  done

  # nginx -t on the installed tree creates the IIIF cache directory, but only inside a parent that exists
  fail_and_restore() { # fail_and_restore CODE MESSAGE...
    local code=$1; shift
    if restore_backup "$bk"; then
      die "$code" "$* The previous files were restored from backup $(basename "$bk")."
    fi
    die "$code" "$* Restoring from backup $bk was incomplete: see the messages above and run: $PROG rollback $(basename "$bk")"
  }
  install -d -m 0755 $OWNER "$CACHE_DIR" 2>/dev/null || fail_and_restore $EX_IOERR "could not create $CACHE_DIR."

  for i in "${!CHG_REL[@]}"; do
    rel=${CHG_REL[$i]}; kind=${CHG_KIND[$i]}
    case "$kind" in
      replaced|created)
        install -d -m 0755 $OWNER "$(dirname "$ETC_DIR/$rel")" 2>/dev/null \
          && install -m 0644 $OWNER "$RENDER/$rel" "$ETC_DIR/$rel.nginx-deploy.new" 2>/dev/null \
          && mv -f "$ETC_DIR/$rel.nginx-deploy.new" "$ETC_DIR/$rel" 2>/dev/null \
          || { rm -f "$ETC_DIR/$rel.nginx-deploy.new"; fail_and_restore $EX_IOERR "could not install $rel."; } ;;
      link-created|link-replaced)
        install -d -m 0755 $OWNER "$(dirname "$ETC_DIR/$rel")" 2>/dev/null \
          && ln -sfn "$LINK_TARGET" "$ETC_DIR/$rel" 2>/dev/null \
          || fail_and_restore $EX_IOERR "could not link $rel." ;;
    esac
  done

  if ! "$NGINX_BIN" -t -c "$ETC_DIR/nginx.conf" > "$WORK/installed-t.out" 2>&1; then
    cat "$WORK/installed-t.out" >&2
    fail_and_restore $EX_DATA "nginx -t rejected the installed tree."
  fi
  echo "nginx -t on the installed tree: ok"
  [ "$RELOAD" -ne 1 ] || reload_nginx
  echo "apply: installed ${#CHG_REL[@]} item(s); backup $(basename "$bk") in $BACKUP_ROOT; undo with: $PROG rollback $(basename "$bk")"
}

verb_rollback() {
  [ -d "$BACKUP_ROOT" ] || die $EX_NOINPUT "no backups: $BACKUP_ROOT does not exist"
  local stamp=$STAMP_ARG bk
  if [ -z "$stamp" ]; then
    stamp=$(ls -1 "$BACKUP_ROOT" | sort | tail -1)
    [ -n "$stamp" ] || die $EX_NOINPUT "no backups under $BACKUP_ROOT"
  fi
  bk=$BACKUP_ROOT/$stamp
  [ -f "$bk/MANIFEST" ] || die $EX_NOINPUT "no backup named $stamp under $BACKUP_ROOT"
  local from
  from=$(sed -n 's/^etc_dir=//p' "$bk/MANIFEST" | head -1)
  [ "$from" = "$ETC_DIR" ] || usage_error "backup $stamp belongs to the nginx directory $from, not $ETC_DIR"
  restore_backup "$bk" || die $EX_IOERR "restoring backup $stamp was incomplete; see the messages above"
  echo "rollback: restored the files of backup $stamp"
  if ! "$NGINX_BIN" -t -c "$ETC_DIR/nginx.conf" > "$WORK/installed-t.out" 2>&1; then
    cat "$WORK/installed-t.out" >&2
    die $EX_DATA "the files of backup $stamp are restored, but nginx -t rejects the tree"
  fi
  echo "nginx -t on the restored tree: ok"
  [ "$RELOAD" -ne 1 ] || reload_nginx
}

case "$VERB" in
  check) verb_check ;;
  diff) verb_diff ;;
  apply) verb_apply ;;
  rollback) verb_rollback ;;
esac
exit $EX_OK
