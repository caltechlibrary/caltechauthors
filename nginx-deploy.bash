#!/bin/bash
#
# nginx-deploy.bash - deploy this repository's nginx configuration to a host by copy.
#
# caltechauthors DR-0009. This is phase 2 of its plan: the `check` verb only. It renders
# the repository's nginx/ tree for the host into a STAGED copy of /etc/nginx and tests
# that copy, so nothing on the host changes unless a later verb installs it.
#
# Written for bash 3.2 (macOS) and later.

set -u

VERSION=0.0.1
PROG=nginx-deploy.bash

# Exit codes, workspace DR-0014.
EX_OK=0
EX_NEGATIVE=1
EX_USAGE=2
EX_DATA=65
EX_NOINPUT=66
EX_INTERNAL=70
EX_NOPERM=77
EX_IOERR=74
EX_CONFIG=78

usage_text() {
  cat <<'EOF'
NAME
  nginx-deploy.bash - deploy the repository's nginx configuration to a host by copy

SYNOPSIS
  nginx-deploy.bash check [OPTIONS]
  nginx-deploy.bash --help | --version

DESCRIPTION
  The repository's nginx/ tree mirrors /etc/nginx. This script renders it for one host
  (replacing the tokens written between @ signs in the site file), builds a STAGED copy of
  the host's /etc/nginx with the rendered files laid over it, and tests the staged copy
  with `nginx -t -c` and, if logagent is installed, `logagent check`. The packaged
  /etc/nginx/nginx.conf is never edited and the host is never changed.

VERBS
  check     render and test; changes nothing on the host

OPTIONS
  --server-name NAME     the host's name, for server_name ("_" is a catch-all). Required.
  --tls letsencrypt|self-signed
                         which certificate pair the site uses. Required.
  --cert-name NAME       the Let's Encrypt lineage under /etc/letsencrypt/live/
                         (default: the server name; used with --tls letsencrypt)
  --site-name NAME       the site file's name under sites-available/ (default: caltechauthors)
  --repo-dir DIR         the checkout holding nginx/ (default: this script's directory); it is
                         also what the redirect map and the static files are found under
  --etc-dir DIR          the nginx configuration directory (default: /etc/nginx)
  --logagent-config FILE logagent's host configuration (default: /etc/logagent/logagent.yaml)
  --require-logagent     a missing logagent is an error, not a skipped step
  --no-logagent          do not run logagent check
  --keep-stage           keep the staged tree and print its path (for debugging)
  --help, --version

ENVIRONMENT
  NGINX     the nginx program (default: nginx)
  LOGAGENT  the logagent program (default: logagent)

EXIT STATUS
   0  success
   1  the command ran correctly and the answer is no (not used by check)
   2  usage: unknown verb or option, a missing or surplus argument, a bad value
  65  the rendered configuration was rejected (nginx -t failed or logagent found a
      gap), or a token was left unreplaced
  66  a needed input is missing: nginx, the repository's nginx/ tree, the etc directory,
      a snippet or dhparam.pem it requires, or logagent with --require-logagent
  70  an error nothing classified (a bug)
  74  a copy into the stage failed
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

VERB=""
SERVER_NAME=""
TLS=""
CERT_NAME=""
SITE_NAME=caltechauthors
REPO_DIR=""
ETC_DIR=/etc/nginx
LOGAGENT_CONFIG=/etc/logagent/logagent.yaml
REQUIRE_LOGAGENT=0
NO_LOGAGENT=0

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
    --logagent-config) need_value "$arg" $#; LOGAGENT_CONFIG=$2; shift 2 ;;
    --require-logagent) REQUIRE_LOGAGENT=1; shift ;;
    --no-logagent) NO_LOGAGENT=1; shift ;;
    --keep-stage) KEEP=1; shift ;;
    --) shift; break ;;
    -*) usage_error "unknown option: $arg" ;;
    *)
      if [ -z "$VERB" ]; then VERB=$arg; else usage_error "surplus argument: $arg"; fi
      shift ;;
  esac
done
if [ $# -gt 0 ]; then
  # anything after -- is a surplus positional argument
  if [ -z "$VERB" ]; then VERB=$1; shift; fi
  [ $# -eq 0 ] || usage_error "surplus argument: $1"
fi

[ -n "$VERB" ] || usage_error "no verb given (the verb is: check)"
case "$VERB" in
  check) ;;
  *) usage_error "unknown verb: $VERB (the verb is: check)" ;;
esac

# ---- validating the values ---------------------------------------------------

name_ok() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]+$'; }

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
printf '%s' "$REPO_DIR" | grep -Eq '^/[A-Za-z0-9._/-]+$' || usage_error "--repo-dir '$REPO_DIR' must be an absolute path of letters, digits, . _ - and /"
REPO_DIR=${REPO_DIR%/}
ETC_DIR=${ETC_DIR%/}
[ -n "$ETC_DIR" ] || usage_error "--etc-dir must not be /"
if [ "$REQUIRE_LOGAGENT" -eq 1 ] && [ "$NO_LOGAGENT" -eq 1 ]; then
  usage_error "--require-logagent and --no-logagent contradict each other"
fi

# ---- what must exist before anything is built ------------------------------------

if [ "$ETC_DIR" = /etc/nginx ] && [ "$(id -u)" != 0 ]; then
  die $EX_NOPERM "run as root: this reads /etc/nginx (certificates, logs) and runs nginx -t"
fi

NGINX_BIN=${NGINX:-nginx}
case "$NGINX_BIN" in
  */*) [ -x "$NGINX_BIN" ] || die $EX_NOINPUT "nginx not found: $NGINX_BIN" ;;
  *) command -v "$NGINX_BIN" >/dev/null 2>&1 || die $EX_NOINPUT "nginx not found on PATH" ;;
esac

SRC=$REPO_DIR/nginx
[ -d "$SRC" ] || die $EX_NOINPUT "the repository's nginx tree is missing: $SRC"
[ -d "$SRC/conf.d" ] || die $EX_NOINPUT "missing: $SRC/conf.d"
[ -f "$SRC/sites-available/caltechauthors.conf" ] || die $EX_NOINPUT "missing: $SRC/sites-available/caltechauthors.conf"
[ -f "$SRC/tls/$TLS.conf" ] || die $EX_NOINPUT "missing: $SRC/tls/$TLS.conf"

[ -d "$ETC_DIR" ] || die $EX_NOINPUT "the nginx configuration directory is missing: $ETC_DIR"
[ -f "$ETC_DIR/nginx.conf" ] || die $EX_NOINPUT "missing: $ETC_DIR/nginx.conf"
# Written by cloud-init, not by this script; it is required, not created.
[ -f "$ETC_DIR/snippets/ssl-params.conf" ] || die $EX_NOINPUT "missing: $ETC_DIR/snippets/ssl-params.conf (cloud-init writes it)"
[ -f "$ETC_DIR/dhparam.pem" ] || die $EX_NOINPUT "missing: $ETC_DIR/dhparam.pem (cloud-init writes it)"
if [ "$TLS" = self-signed ]; then
  [ -f "$ETC_DIR/snippets/self-signed.conf" ] || die $EX_NOINPUT "missing: $ETC_DIR/snippets/self-signed.conf (cloud-init writes it; --tls self-signed needs it)"
fi

# ---- rendering ---------------------------------------------------------------

# render_file SOURCE DEST replaces the closed set of tokens and fails if one is left.
render_file() {
  sed -e "s#@SERVER_NAME@#$SERVER_NAME#g" -e "s#@REPO_DIR@#$REPO_DIR#g" -e "s#@CERT_NAME@#$CERT_NAME#g" "$1" > "$2" \
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

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nginx-deploy.XXXXXX") || die $EX_IOERR "could not make a working directory"
STAGE=$WORK/stage
DUMP=$WORK/dump.txt

mkdir -p "$STAGE" || die $EX_IOERR "could not make $STAGE"
cp -RL "$ETC_DIR/." "$STAGE/" || die $EX_IOERR "could not copy $ETC_DIR into the stage"
mkdir -p "$STAGE/conf.d" "$STAGE/sites-available" "$STAGE/sites-enabled" "$STAGE/snippets"

for f in "$SRC"/conf.d/*.conf; do
  [ -f "$f" ] || continue
  render_file "$f" "$STAGE/conf.d/$(basename "$f")"
done
render_file "$SRC/sites-available/caltechauthors.conf" "$STAGE/sites-available/$SITE_NAME.conf"
render_file "$SRC/tls/$TLS.conf" "$STAGE/snippets/caltechauthors-tls.conf"
ln -sfn "$STAGE/sites-available/$SITE_NAME.conf" "$STAGE/sites-enabled/$SITE_NAME.conf" \
  || die $EX_IOERR "could not link the site into the stage"

# Point the staged copy at itself. nginx -t CREATES proxy_cache_path directories (and fails
# when the parent is missing), so the cache path moves inside the stage too, or even a test
# would change the host.
rewrite_in_tree "$STAGE" "$ETC_DIR/" "$STAGE/"
mkdir -p "$STAGE/cache"
rewrite_in_tree "$STAGE" "/var/cache/nginx/" "$STAGE/cache/"

if [ "$KEEP" -eq 1 ]; then echo "stage: $STAGE" >&2; fi

# ---- the gates ---------------------------------------------------------------

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
else
  LA=${LOGAGENT:-logagent}
  found=0
  case "$LA" in
    */*) [ -x "$LA" ] && found=1 ;;
    *) command -v "$LA" >/dev/null 2>&1 && found=1 ;;
  esac
  if [ "$found" -eq 0 ]; then
    if [ "$REQUIRE_LOGAGENT" -eq 1 ]; then die $EX_NOINPUT "logagent not found ($LA) and --require-logagent was given"; fi
    echo "$PROG: logagent not found; skipped logagent check (--require-logagent makes this an error)" >&2
  else
    "$LA" check --config "$LOGAGENT_CONFIG" --dump "$DUMP" --sample 0 > "$WORK/logagent.out" 2>&1
    rc=$?
    case "$rc" in
      0) cat "$WORK/logagent.out"; echo "logagent check on the staged tree: ok" ;;
      1) cat "$WORK/logagent.out" >&2; die $EX_DATA "logagent check found a gap in the staged configuration; nothing was changed on this host" ;;
      66) cat "$WORK/logagent.out" >&2; die $EX_NOINPUT "logagent could not find its configuration ($LOGAGENT_CONFIG)" ;;
      78) cat "$WORK/logagent.out" >&2; die $EX_CONFIG "logagent's configuration file is wrong ($LOGAGENT_CONFIG)" ;;
      *) cat "$WORK/logagent.out" >&2; die $EX_INTERNAL "logagent check exited $rc, which this script does not know" ;;
    esac
  fi
fi

echo "check: the staged configuration for $SERVER_NAME passed; nothing was changed on this host"
exit $EX_OK
