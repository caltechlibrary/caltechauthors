#!/bin/bash
#
# bot-traffic-report.bash - summarize automated traffic in the nginx access log.
#
# Read-only. Reads /var/log/nginx/access.log and the newest rotated logs (plain
# or .gz) and prints, for one user-agent pattern and for traffic as a whole:
#
#   1. requests per day: all, matching, matching share, distinct matching IPs
#   2. matching requests per hour (the last 48 hours seen)
#   3. the matching user-agent strings (a vendor changing its UA shows here)
#   4. matching status mix and path-class mix (iiif, record-api, files, ...)
#   5. self-declared automation user agents across ALL traffic, so the next bot
#      shows up before anyone names it
#   6. per-day 429 / 499 / 502 / 504 counts (did the caps and timeouts fire?)
#   7. upstream (RDM) seconds by path class, all traffic
#   8. client fingerprint, matching vs everything else (new-format lines only):
#      share with no sec-ch-ua, share with no cf_ray (origin hit directly),
#      share claiming Windows, top countries
#
# Usage: bot-traffic-report.bash [-p PATTERN] [-d DAYS]
#   -p PATTERN  case-insensitive extended regex matched against the user agent
#               (default: exasearchbot|crawler\.exa\.ai; a bare "exa" also matches
#               "example.com" in other bots' mailto: addresses)
#   -d DAYS     how many log files to read, newest first (default: 3; the
#               current log counts as one)
#
# Environment: LOG_DIR (default /var/log/nginx), LOG_NAME (default access.log).
#
# The fingerprint section needs the caltechauthors_bots log format
# (nginx/conf.d/caltechauthors_log.conf); older lines are skipped there only.
# Select new-format lines by ' rt=[0-9.]+ urt=', never a bare 'rt=' (that also
# matches 'sort=' in query strings).
#
# Run it on the instance over SSM, for example:
#   sudo bash bot-traffic-report.bash -p 'exa|gptbot' -d 5
#
# EXIT STATUS: 0 report printed; 2 usage; 66 no log file found.
#
set -uo pipefail

LOG_DIR="${LOG_DIR:-/var/log/nginx}"
LOG_NAME="${LOG_NAME:-access.log}"
PATTERN="exasearchbot|crawler\.exa\.ai"
DAYS=3

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -p) [ $# -ge 2 ] || { echo "usage: $0 [-p PATTERN] [-d DAYS]" >&2; exit 2; }
        PATTERN="$2"; shift 2 ;;
    -d) [ $# -ge 2 ] || { echo "usage: $0 [-p PATTERN] [-d DAYS]" >&2; exit 2; }
        DAYS="$2"; shift 2 ;;
    *) echo "usage: $0 [-p PATTERN] [-d DAYS]" >&2; exit 2 ;;
  esac
done
case "$DAYS" in ''|*[!0-9]*|0) echo "error: -d wants a positive integer" >&2; exit 2 ;; esac
[ -n "$PATTERN" ] || { echo "error: -p must not be empty" >&2; exit 2; }

# The newest DAYS files by modification time, then reversed so the oldest is
# read first and the day and hour tables come out in time order.
ORDERED=$(ls -1t "$LOG_DIR/$LOG_NAME" "$LOG_DIR/$LOG_NAME".[0-9]* 2>/dev/null |
  head -n "$DAYS" | awk '{ a[NR] = $0 } END { for (i = NR; i >= 1; i--) print a[i] }')
[ -n "$ORDERED" ] || { echo "error: no $LOG_NAME under $LOG_DIR" >&2; exit 66; }

echo "pattern: $PATTERN"
echo "files:"; echo "$ORDERED" | sed 's/^/  /'
echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# shellcheck disable=SC2086
zcat -f $ORDERED | PATTERN="$PATTERN" awk -F'"' '
function top(arr, n, title,   k, cmd) {
  print ""; print title
  cmd = "sort -rn | head -n " n
  for (k in arr) printf "%8d  %s\n", arr[k], k | cmd
  close(cmd)
}
function pclass(p) {
  sub(/\?.*/, "", p)
  if (p ~ /^\/api\/iiif\//) return "api-iiif"
  if (p ~ /^\/api\/records\/[^\/]+\/(draft\/)?files/) return "api-files"
  if (p ~ /^\/api\/records\/[^\/]+\/versions/) return "api-versions"
  if (p ~ /^\/api\/records\/[^\/]+\/communities/) return "api-communities"
  if (p ~ /^\/api\/records\/[^\/]+$/) return "api-record"
  if (p ~ /^\/api\/records/) return "api-search"
  if (p ~ /^\/api/) return "api-other"
  if (p ~ /^\/records\/[^\/]+\/files/) return "ui-files"
  if (p ~ /^\/records\/[^\/]+$/) return "ui-record"
  if (p ~ /^\/search/) return "ui-search"
  if (p ~ /^\/(static|assets)\//) return "static"
  return "other"
}
function upsec(u,   n, parts, i, t) {
  t = 0; n = split(u, parts, /[ ,:]+/)
  for (i = 1; i <= n; i++) if (parts[i] ~ /^[0-9.]+$/) t += parts[i]
  return t
}
BEGIN { lpat = tolower(ENVIRON["PATTERN"]) }
NF < 6 { next }
{
  if (!match($1, /\[[^]]+\]/)) next
  ts = substr($1, RSTART + 1, RLENGTH - 2)
  day = substr(ts, 1, 11); hour = substr(ts, 1, 14)
  split($1, a, " "); ip = a[1]
  split($2, r, " "); path = r[2]
  split($3, s, " "); st = s[1]
  ua = $6; lua = tolower(ua)
  if (!(day in dseen)) { dseen[day] = 1; dorder[++nd] = day }
  tot[day]++
  if (st == "429" || st == "499" || st == "502" || st == "504") errs[day SUBSEP st]++
  pc = pclass(path)
  newfmt = ($7 ~ /^ rt=[0-9.]+ urt=/)
  if (newfmt) { up[pc] += upsec($8); upn[pc]++ }
  if (lua ~ /bot|crawl|spider|gpt|claude|anthropic|perplex|bytespider|amazon|meta-external|ccbot|scrape|python|curl|go-http|axios|headless|okhttp|java\/|libwww|httpx|wget/)
    decl[ua]++
  m = (lua ~ lpat)
  if (m) {
    hit[day]++
    if (!((day SUBSEP ip) in ipseen)) { ipseen[day SUBSEP ip] = 1; dip[day]++ }
    if (!(hour in hseen)) { hseen[hour] = 1; horder[++nh] = hour }
    hh[hour]++
    uas[ua]++; sts[st]++; pcs[pc]++
  }
  if (newfmt) {
    g = m ? "match" : "other"
    fn[g]++
    if ($16 == "" || $16 == "-") fnoch[g]++
    if ($10 == "") fnoray[g]++
    if ($18 ~ /Windows/) fwin[g]++
    cc[g SUBSEP $12]++
  }
}
END {
  print ""; print "1. requests per day"
  printf "%-12s %9s %9s %7s %9s\n", "day", "all", "match", "pct", "ips"
  for (i = 1; i <= nd; i++) { d = dorder[i]
    printf "%-12s %9d %9d %6.1f%% %9d\n", d, tot[d], hit[d] + 0, tot[d] ? 100 * hit[d] / tot[d] : 0, dip[d] + 0 }

  print ""; print "2. matching requests per hour (last 48 hours seen)"
  from = nh > 48 ? nh - 47 : 1
  for (i = from; i <= nh; i++) printf "%s  %7d\n", horder[i], hh[horder[i]]

  top(uas, 10, "3. matching user-agent strings")
  top(sts, 10, "4a. matching status mix")
  top(pcs, 10, "4b. matching path classes")
  top(decl, 25, "5. self-declared automation user agents, all traffic")

  print ""; print "6. error statuses per day (429 = our caps, 499 = client gave up, 502/504 = upstream)"
  printf "%-12s %8s %8s %8s %8s\n", "day", "429", "499", "502", "504"
  for (i = 1; i <= nd; i++) { d = dorder[i]
    printf "%-12s %8d %8d %8d %8d\n", d, errs[d SUBSEP "429"] + 0, errs[d SUBSEP "499"] + 0, errs[d SUBSEP "502"] + 0, errs[d SUBSEP "504"] + 0 }

  print ""; print "7. upstream seconds by path class (new-format lines)"
  cmd = "sort -rn | head -n 12"
  for (k in up) printf "%10.0f s  %8d req  %s\n", up[k], upn[k], k | cmd
  close(cmd)

  print ""; print "8. fingerprint (new-format lines only)"
  split("match other", gs, " ")
  for (i = 1; i <= 2; i++) { g = gs[i]
    if (!fn[g]) { printf "%-6s no new-format lines\n", g; continue }
    printf "%-6s n=%d  no-sec-ch-ua=%.0f%%  no-cf-ray=%.0f%%  windows=%.0f%%\n", g, fn[g],
      100 * fnoch[g] / fn[g], 100 * fnoray[g] / fn[g], 100 * fwin[g] / fn[g]
    cmd = "sort -rn | head -n 5"
    for (k in cc) { split(k, kk, SUBSEP); if (kk[1] == g) printf "%8d  %s  country %s\n", cc[k], g, kk[2] | cmd }
    close(cmd)
  }
}'
