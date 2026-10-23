#!/usr/bin/env python3
"""bot-concurrency.py - how many /api requests were really in flight, second by second.

Read-only. Reads the nginx access logs in LOG_DIR (default /var/log/nginx):
access.log, access.log.1 and the rotated access.log.N.gz files, new format only
(the caltechauthors_bots format, which has rt=). For every /api request that held
a slot (429s are skipped, they are rejected before one) it takes the end time and
rt, derives the start, and counts requests in flight per second. It prints, for
non-campus /api, non-campus /api/iiif/ and campus /api:

  - the percentiles (p50, p90, p99, max) of the per-second concurrency
  - the share of seconds with at least 2, 4, 6, 8, 12, 16, 20 and 24 in flight

Use it to judge the concurrency caps (api_conc and iiif_conc in
nginx/conf.d/caltechauthors_limits.conf). Counts are measured behind the caps, so a value
that sits at a cap means the cap is binding. Only aggregates are printed, never an
address, path or user agent. "Campus" is a client address in 131.215.0.0/16 (the
exempt range); it needs the real-IP change so the client address is the visitor.

Run it on the instance over SSM as bot-traffic-report.bash is run, for example:

    sudo python3 -I bot-concurrency.py

Environment: LOG_DIR (default /var/log/nginx).

Exit status: 0 report printed; 66 no log lines found.
"""
import os
import re, gzip, glob, calendar, sys
from collections import Counter
LOG_DIR = os.environ.get("LOG_DIR", "/var/log/nginx")
pat = re.compile(r'^(\S+) - \S+ \[([^\]]+)\] "(\S+) (\S+)[^"]*" (\d+) \d+ "[^"]*" "[^"]*" rt=([0-9.]+) urt=')
mon = {m:i for i,m in enumerate(["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"],1)}
cache = {}
def epoch(ts):
    e = cache.get(ts)
    if e is None:
        d,rest = ts.split(" ")[0].split(":",1)
        dd,mm,yy = d.split("/"); h,mi,s = rest.split(":")
        e = calendar.timegm((int(yy),mon[mm],int(dd),int(h),int(mi),int(s)))
        cache[ts]=e
    return e
def lines():
    for f in sorted(glob.glob(os.path.join(LOG_DIR, "access.log.*.gz")), reverse=True):
        with gzip.open(f,"rt",errors="replace") as fh:
            for l in fh: yield l
    for f in (os.path.join(LOG_DIR, "access.log.1"), os.path.join(LOG_DIR, "access.log")):
        try:
            with open(f,errors="replace") as fh:
                for l in fh: yield l
        except FileNotFoundError: pass
def campus(ip): return ip.startswith("131.215.")
deltas = {"api":Counter(), "iiif":Counter(), "api_campus":Counter()}
lo, hi, n429, nreq = None, None, 0, 0
for l in lines():
    m = pat.match(l)
    if not m: continue
    ip, ts, meth, path, st, rt = m.groups()
    if not path.startswith("/api"): continue
    end = epoch(ts); start = end - float(rt)
    nreq += 1
    if st == "429": n429 += 1; continue            # rejected before holding a slot
    s, e = int(start), int(end)
    lo = s if lo is None or s < lo else lo; hi = e if hi is None or e > hi else hi
    key = "api_campus" if campus(ip) else "api"
    deltas[key][s] += 1; deltas[key][e+1] -= 1
    if key == "api" and path.startswith("/api/iiif/"):
        deltas["iiif"][s] += 1; deltas["iiif"][e+1] -= 1
def hist(d):
    h = Counter(); cur = 0
    for t in range(lo, hi+1):
        cur += d.get(t,0); h[cur] += 1
    return h
if lo is None:
    print("error: no new-format /api lines found in " + LOG_DIR, file=sys.stderr)
    sys.exit(66)
total = hi - lo + 1
print("seconds analysed: %d (%.1f h), /api requests %d, 429s %d" % (total, total/3600, nreq, n429))
for name, label in (("api","non-campus /api (cap api_conc 24)"),("iiif","non-campus /api/iiif/ (cap iiif_conc 6)"),("api_campus","campus /api (exempt, for scale)")):
    h = hist(deltas[name])
    print("\n%s" % label)
    cum = 0; rows = []
    vals = sorted(h)
    def pct(p):
        c = 0
        for v in vals:
            c += h[v]
            if c >= p*total: return v
    print("  p50=%d p90=%d p99=%d max=%d" % (pct(.5), pct(.9), pct(.99), max(vals)))
    for th in (2,4,6,8,12,16,20,24):
        above = sum(c for v,c in h.items() if v >= th)
        print("  seconds with >= %2d in flight: %6d (%.1f%%)" % (th, above, 100*above/total))
