#!/bin/bash
#
# bot-family-breakdown.bash - cost by bot family, and today's 429s.
#
# Read-only. Reads /var/log/nginx access logs (the three newest rotated .gz
# files, access.log.1 and access.log) and prints aggregates only; no client
# addresses. User agents are grouped into families (named declared bots, then
# undeclared by claimed platform). Prints:
#
#   A.  per family: requests, share on api-* paths, upstream seconds
#   A2. upstream seconds per request by family
#   B.  429s on 2026-10-07 by family, path class, hour, country, platform hint
#
# Upstream seconds use new-format lines only (' rt=N urt=' present); request
# counts use every line, so do not compare the two directly.
# The 429 day is hard-coded (07/Oct/2026) and the family list is in fam(); edit
# both for a new investigation.
#
# Run it over SSM, as bot-traffic-report.bash is run (see Bot-Traffic.md).
# Environment: LOG_DIR (default /var/log/nginx).
# Missing nginx headers are logged as "-", not empty.
#
# EXIT STATUS: 0 report printed.
#
set -uo pipefail
cd "${LOG_DIR:-/var/log/nginx}"
{ for f in access.log.4.gz access.log.3.gz access.log.2.gz; do [ -f $f ] && zcat $f; done; cat access.log.1 access.log; } 2>/dev/null | awk -F'"' '
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
function fam(u,   l) {
  l = tolower(u)
  if (l ~ /exasearchbot/) return "Exa"
  if (l ~ /chatgpt-user/) return "OpenAI ChatGPT-User"
  if (l ~ /oai-searchbot/) return "OpenAI OAI-SearchBot"
  if (l ~ /claude-user/) return "Anthropic Claude-User"
  if (l ~ /googlebot/) return "Google Googlebot-claim"
  if (l ~ /bingbot/) return "Microsoft bingbot"
  if (l ~ /applebot/) return "Apple Applebot"
  if (l ~ /meta-webindexer/) return "Meta webindexer"
  if (l ~ /meta-externalads/) return "Meta externalads"
  if (l ~ /perplexitybot/) return "PerplexityBot"
  if (l ~ /semrushbot/) return "SemrushBot"
  if (l ~ /semanticscholar/) return "SemanticScholarBot"
  if (l ~ /dotbot/) return "DotBot"
  if (l ~ /baiduspider/) return "Baiduspider"
  if (l ~ /keenablebot/) return "KeenableBot"
  if (l ~ /akashicai/) return "AkashicAI"
  if (l ~ /python-requests/) return "python-requests"
  if (l ~ /bot|spider|crawler|slurp|uptime/) return "other-declared"
  if (l ~ /windows nt/) return "undeclared Windows"
  if (l ~ /android|iphone|ipad/) return "undeclared mobile"
  if (l ~ /macintosh/) return "undeclared Mac"
  if (l ~ /linux|x11/) return "undeclared Linux"
  return "undeclared other"
}
function upsec(u,   n, parts, i, t) {
  t = 0; n = split(u, parts, /[ ,:]+/)
  for (i = 1; i <= n; i++) if (parts[i] ~ /^[0-9.]+$/) t += parts[i]
  return t
}
{
  if (!match($1, /\[[^]]+\]/)) next
  ts = substr($1, RSTART + 1, RLENGTH - 2)
  day = substr(ts, 1, 11); hour = substr(ts, 13, 2)
  split($2, r, " "); path = r[2]
  split($3, s, " "); st = s[1]
  f = fam($6); pc = pclass(path)
  # A: all days, per family
  n[f]++
  cls[f SUBSEP pc]++; fams[f]; pcs[pc]
  if ($7 ~ / rt=[0-9.]+ urt=/) {
    nn[f]++; us = upsec($8); up[f] += us
    if (pc ~ /^api-/) apu[f] += us
    if (pc == "api-iiif") iiif[f] += us
  }
  # B: 10-07 only
  if (day == "07/Oct/2026") {
    d7[f]++
    if (st == "429") {
      t429++; f429[f]++; p429[pc]++; h429[hour]++
      cf = ($10 == "" || $10 == "-" ? "no-cf-ray" : "cf-ray"); c429[cf]++
      cc429[$12]++
      plat = ($18 == "" || $18 == "-" ? "no-ch_plat" : $18); pl429[plat]++
      hasua = ($16 == "" || $16 == "-" ? "no-sec-ch-ua" : "sec-ch-ua"); ch429[hasua]++
      if (f ~ /^undeclared/) ua429[$6]++
      if (f !~ /^undeclared/) uan[f]++
      # campus peers: the first field is the (real) client address
      split($1, a, " "); if (a[1] ~ /^131\.215\./) campus429++
    }
  }
}
function top(arr, k, title,   key, cmd) {
  print ""; print title
  cmd = "sort -rn | head -" k
  for (key in arr) printf "%8d  %s\n", arr[key], key | cmd
  close(cmd)
}
END {
  print "A. per family, all five days: requests, share of api-* classes, upstream seconds (new-format lines only)"
  printf "%-26s %9s %9s %8s %9s %9s %9s\n", "family", "requests", "api-share", "ui+other", "up_s", "api_up_s", "iiif_up_s"
  cmd = "sort -k2 -rn"
  for (f in fams) {
    api = 0; for (p in pcs) if (p ~ /^api-/) api += cls[f SUBSEP p]
    printf "%-26s %9d %8.1f%% %8d %9.0f %9.0f %9.0f\n", f, n[f], 100*api/n[f], n[f]-api, up[f], apu[f], iiif[f] | cmd
  }
  close(cmd)
  print ""
  print "A2. upstream seconds per request by family (new-format lines)"
  cmd = "sort -k2 -rn"
  for (f in fams) if (nn[f] > 0) printf "%-26s %8.3f s/req  (%d new-format reqs)\n", f, up[f]/nn[f], nn[f] | cmd
  close(cmd)

  print ""
  print "B. 2026-10-07 (partial day to ~15:52Z): requests and 429s by family"
  printf "%-26s %9s %7s %8s\n", "family", "requests", "429s", "rate"
  cmd = "sort -k3 -rn"
  for (f in d7) printf "%-26s %9d %7d %7.2f%%\n", f, d7[f], f429[f]+0, 100*(f429[f]+0)/d7[f] | cmd
  close(cmd)
  printf "\ntotal 429s on 10-07: %d; from 131.215.0.0/16 clients: %d\n", t429, campus429+0
  top(p429, 12, "429s by path class")
  top(h429, 24, "429s by UTC hour (count hour)")
  top(c429, 5, "429s with / without cf_ray")
  top(cc429, 10, "429s by cf_country")
  top(ch429, 5, "429s with / without sec-ch-ua")
  top(pl429, 6, "429s by sec-ch-ua-platform")
  top(ua429, 6, "top undeclared user agents among 429s")
  top(uan, 12, "declared families among 429s")
}'
