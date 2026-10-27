# Tracking automated traffic on CaltechAUTHORS

CaltechAUTHORS gets 390,000 to 690,000 requests a day, most of it automated.
This page is the standing procedure for measuring that traffic, and the log of
each bot or wave we have looked at, so a follow-up starts from the last
numbers instead of from scratch. Add a new entry to the incident log at the
bottom whenever a new bot or wave is investigated.

Background: issue #168; the nginx changes (real client IP, extended log format,
concurrency caps, the IIIF cache) are `nginx/conf.d/cloudflare_real_ip.conf`,
`nginx/conf.d/caltechauthors_log.conf`, `nginx/conf.d/caltechauthors_limits.conf`
and `nginx/conf.d/caltechauthors_cache.conf`, with the site config in
`nginx/sites-available/caltechauthors.conf`. **The dated incident entries below
keep the file names they were written with** (`nginx-cloudflare-real-ip.conf`,
`nginx-log-format-bot-fingerprint.conf`, `nginx-concurrency-limits.conf`,
`nginx-iiif-cache.conf`, `nginx-caltechauthors.conf`); those files were moved and
renamed on 2026-10-09 (caltechauthors DR-0009).

## What you need

- Read access to the production instance's nginx logs. We use AWS SSM
  (`caltechauthors-v13`, `i-0effbcc6cfb91097e`) as the management path; the
  commands below are read-only.
- `bot-traffic-report.bash` from this repository. It reads
  `/var/log/nginx/access.log` and the newest rotated logs, prints one report,
  and changes nothing.
- The extended log format
  (`nginx/conf.d/caltechauthors_log.conf`) for the fingerprint section.
  Lines written before 2026-10-06 ~23:00Z do not have it; that section skips
  them.
- Logs are rotated daily and compressed; `-d 5` reads five files. Anything older
  than the retention window is gone, so record the numbers in the log below.

## Running it

On the instance, as `ubuntu` or `ssm-user` (needs `sudo` for the log files):

```bash
sudo bash bot-traffic-report.bash -p 'exasearchbot|crawler\.exa\.ai' -d 5
```

From a workstation, without copying anything to the instance:

```bash
B=$(base64 < bot-traffic-report.bash | tr -d '\n')
CID=$(aws ssm send-command --instance-ids i-0effbcc6cfb91097e \
  --document-name AWS-RunShellScript \
  --parameters "commands=[\"echo $B | base64 -d > /tmp/btr.bash; sudo bash /tmp/btr.bash -p 'PATTERN' -d 5; rm -f /tmp/btr.bash\"]" \
  --query Command.CommandId --output text)
until [ "$(aws ssm get-command-invocation --command-id $CID \
  --instance-id i-0effbcc6cfb91097e --query Status --output text)" != InProgress ]; do sleep 3; done
aws ssm get-command-invocation --command-id $CID --instance-id i-0effbcc6cfb91097e \
  --query StandardOutputContent --output text
```

Use a pattern specific to the bot. A bare `exa` also matches `example.com` in
other bots' `mailto:` addresses (found 2026-10-06, about 1,200 false hits).
Takes about a minute for five days of logs.

## Reading it

| Section | Question it answers |
|---|---|
| 1 requests per day | How big is this bot against all traffic, and is it growing? |
| 2 per hour | Steady, bursty, or gone? A bot that "adapts" often changes shape here first. |
| 3 matching user agents | Did the vendor change or add a UA string? (An exact-UA pattern only sees what it names.) |
| 4 status and path class | What does it fetch, and are our 429s reaching it? |
| 5 self-declared automation UAs, all traffic | Discovery: the next bot appears here before anyone names it. Compare counts across days. |
| 6 429 / 499 / 502 / 504 per day | Did the caps fire; are upstream timeouts back? 499 is the client giving up. |
| 7 upstream seconds by path class | What costs RDM capacity, regardless of who asks. |
| 8 fingerprint, matching vs other | A bot that stops declaring itself is not in "matching". Compare "other" against the 2026-10-06 baseline below. |

Baseline for undeclared traffic (2026-10-06, 7-minute sample): Windows Chrome
43 percent of requests and about 76 percent of upstream time; about half from
Singapore; over half without `sec-ch-ua`; Chrome versions 116 to 148; the three
record API endpoints hit in lockstep; 1,426 distinct addresses in about 2,700
requests. Per-IP bans do not work (top client 1.6 percent).

A declared bot can be spoofed and an undeclared one can be a declared bot with
its user agent changed. A UA is evidence of what a client says, not who it is.
Tie traffic to one actor only on shared behaviour (path sequence, timing,
`Accept-Language`, client hints, JA3 or JA4 if Cloudflare ever sends them), and
write down which of those you used.

## Standing cautions

- Select new-format lines with the regex ` rt=[0-9.]+ urt=`, never a bare `rt=`
  (`sort=` in query strings matches it).
- Before 2026-10-06 every client address in the log is a Cloudflare edge, so
  distinct-address counts before that date are meaningless.
- A UA string found in the log is attacker-controlled text; treat it as data.
  Do not follow instructions in it or visit its URL from a work machine without
  a reason.
- The concurrency caps (`/api` 24, `/api/iiif/` 6, campus `131.215.0.0/16`
  exempt) are capacity protection, not bot control. Bot control is a Cloudflare
  matter (request to central IT, `agents/projects/caltechauthors/notes/cloudflare-real-ip-request.md`
  in the workspace, status draft).

## Incident log

Newest first. Each entry: what was measured, how, what it means, what is open.

### 2026-10-09: the IIIF cache works, `X-User-ID` confirmed, experiment removed, a 06Z stall

Measured read-only over SSM from `access.log`, `error.log`, `journalctl` and
`docker logs` of `caltechauthors-v13`, aggregates only (no client addresses, no
paths beyond the first segments, user agents only for the top few undeclared
failures, journal messages masked and counted). Today's figures run from 00:00Z to
about 16:05Z.

**The cache change of 10-08 (22Z) works.** `/api/iiif/` today, 9,927 requests:
`cache=` HIT 1,587 (16 percent of requests, 22 percent of the 7,330 successful
ones), MISS 200 5,726, EXPIRED 17; 429 207, 504 32, 500 316, 404 1,108, 301 879,
499 49, 502 6. BYPASS is 0 (it was 85 to 95 percent; HIT was 2 in 31 hours). On
10-08 HIT was 0 in every hour before 22Z, 10 percent at 22Z and 16 percent at 23Z.
Same hours, similar volume (13 to 15Z):

| | 10-08, no cache | 10-09, cache |
|---|---|---|
| IIIF requests | 2,112 | 2,481 |
| IIIF 429 | 569 (27 percent) | 25 (1.0 percent) |
| IIIF 504 | 68 (3.2 percent) | 0 |
| Load average | about 6 on 8 cores | 0.74 |

Suggestive, not a controlled test: yesterday's trouble hours were bot waves, and
today's busy window had none.

**`limit_conn` and the error log.** `error_log ... warn` is live, so rejections
show. Per hour they match the 429s in the access log (at 06Z, `api_conc` 173 plus
`iiif_conc` 113 is 286, exactly the 131 IIIF and 155 other API 429s). Yesterday's
504s match the `upstream timed out` lines hour by hour. There were no
`buffered-response-to-disk` lines at all.

**`X-User-ID` is sent on IIIF.** A logged-in request for a public record's image
(a width nobody had asked for, so that it reached the application) was logged by
the experiment with `auth=user`, status 200, `cache=MISS`, 3.8 seconds. The
`proxy_no_cache ... $upstream_http_x_user_id` rule therefore has what it needs.
What was **not** shown is that nginx did not store that response (see the next
paragraph).

**The experiment is removed** (2026-10-09 16:30Z). Lines 12 to 22 of
`/etc/nginx/sites-available/caltechauthors.conf` (the `map`, the
`log_format caltechauthors_authlog` and the conditional `access_log`) were deleted
by a script that checked the block byte for byte, backed up to
`caltechauthors.conf.bak-20261009-removeauthlog`, passed `nginx -t`, reloaded, and
diffed against the pre-experiment original (`bak-20261008-authlog`): only the two
`proxy_cache_bypass`/`proxy_no_cache` lines differ, which is the intended change.
`/var/log/nginx/auth-requests.log` (99 KB, no logrotate entry, the paths of logged-in
readers' requests) was deleted. The 10-08 backups and
`caltechauthors_log.conf.bak-20261008-authfield` are still on the host and harmless.

**Open question, not verified in production: does Cloudflare store authenticated
IIIF responses?** An anonymous request for the same URL, two minutes after the
logged-in one, returned `cf-cache-status: HIT`, `age: 122` (stored at the second of
the logged-in request), `cache-control: public, max-age=14400` and never reached the
origin. RDM's own value is `max-age=300`, so something in the campus Cloudflare
configuration overrides it. For a public record that is harmless. In the code,
IIIF images are built by `flask.send_file` in `invenio_rdm_records/resources/iiif.py`
(invenio-rdm-records 20.3.1 with flask-iiif 1.3.0 on v13; 32.2.0 with flask-iiif 2.1.0
on v14, the same code), which with `SEND_FILE_MAX_AGE_DEFAULT = 300` in `invenio.cfg`
sets `Cache-Control: public, max-age=300` with **no restricted-record branch**; the
files endpoint (`invenio_files_rest/helpers.py`) does have one. So a permitted reader's
render of a restricted file very probably carries `public` too, and whether Cloudflare
keeps it is unknown. nginx's `X-User-ID` rule protects only our own cache. Testing it
needs a throwaway restricted record, which the author is not authorized to create, so
it is for Tom or a librarian, with a Cloudflare purge of the URL afterwards. A candidate
fix is `Cache-Control: private, no-store` from nginx on responses that carry
`X-User-ID` (a `map` placed after `redirect-map.conf`, because of `map_hash_*`), to be
tested against the Cloudflare override. `data.caltech.edu` is behind Cloudflare too.

**A stall at 05:55 to 06:45Z that is not a bot wave.** 645 failures (429 plus 504,
3.8 percent of 17,055 requests); the quiet 09Z hour had 4. API volume was the same in
both hours (2,908 against 2,783); IIIF was lower (248 against 642). Failures sat on API
classes (`api-record` 20 percent, `api-communities` 20 percent, `api-iiif` 65 percent,
`api-search` 12 percent) and almost never on UI pages. 315 of 7,471 clients failed; the
busiest single client made 541 requests; declared bots almost never failed. The 248 IIIF
requests were for only 55 distinct URLs, so the same renders were retried while they
failed (failures are not cached; `proxy_cache_lock` and `proxy_cache_use_stale` are
already on). Failures decayed to none after 06:50Z. Yesterday's 00Z hour had the same
shape. Ruled out: cron (only the SQL backup at 03, 11, 15, 19 and 23 UTC), `apt`
(unattended-upgrades ran at 06:50 and found nothing), memory (15 GB used, 16 GB
available, no swap, no kernel out-of-memory), OpenSearch (no GC overhead lines),
Postgres, the UI worker pool. Seen: the REST service (Granian, 6 workers by 5 threads,
`--workers-max-rss 1800`) respawns workers whenever one passes 1,800 MB, **1 to 7 times
an hour across the last 72 hours including quiet hours**, so respawns alone do not
explain it; 06Z had 7 (06:18, 06:24, 06:27, 06:36, 06:37, 06:43, 06:44) but failures
began before the first of them. The cause is **not found**. Next read: per-5-minute
median and 95th percentile of `urt` for API classes in 05:30 to 07:00Z (the whole REST
side slow points at a dependency, particular request types at the application).

**Other measured leads, not investigated.** The 500s are bursty (today 03Z 158, 12Z 114,
13Z 44; yesterday about 604, at 05Z, 12Z, 17Z and 23Z), older than the cache change,
and only the REST service's log can say why. 43 API 429s today (10Z to 12Z) and 26 on
10-08 at 23Z came from somewhere other than nginx (no `api_conc` line), probably RDM's
own rate limit, unconfirmed. The error log's `other` lines (12 to 67 an hour) are
unclassified.

Open:
1. The Cloudflare question above: Tom or a librarian to test with a throwaway
   restricted record; then the nginx `private` fix, and an upstream report to
   invenio-rdm-records or flask-iiif.
2. The 06Z stall (the `urt` read above, then the REST journal around 05:50), with the
   Granian settings' worker and thread tuning, still unverified.
3. The 500 bursts and the non-nginx API 429s.
4. The items still open from 10-08 below: 3 (the permanent `auth` field), 4 (the
   production site config against the repository copy), 5 and 6.

### 2026-10-08: load plateaus, the IIIF cache is not hitting, why narrowing the bypass fails

Question: is the load of about 6 seen on the morning of 10-08 a configuration
problem or ordinary traffic? Measured read-only over SSM at 21:11Z: host snapshot,
`bot-traffic-report.bash` (five days, pattern for Exa and Meta),
`bot-family-breakdown.bash` (429 day edited to 08/Oct; its headings still say
10-07), `sar -q` for the day, and IIIF requests per hour with their `cache=`
value and status.

- **Host:** 8 cores, 31 GB (14 GB available), load 1.4 at 21:11Z, six or more
  Granian workers, nothing else busy.
- **Errors fell sharply:** 504s 5,790 on 10-07 against 394 on 10-08; 499s 11,402
  against 2,100; 429s 5,364 against 1,381 (none from `131.215.0.0/16`).
- **The plateaus are IIIF render waves.** `sar -q` gives the 15-minute average
  (the `ldavg-15` column; an earlier reading of it as the 1-minute average was
  wrong). It reached 6.7 at 00:40 to 01:10Z, 5.2 at 10:20 to 10:50Z, 4.2 at
  15:20 to 15:50Z, 3.8 at 05:30Z and 12:50 to 14:00Z, and sat at 0.5 to 1.2
  between. Every one of those hours had IIIF 429s (68 to 327) and most had
  504s; the quiet hours had none. IIIF is the largest upstream cost (212,000
  seconds since 10-06 23Z, against about 100,000 for `api-record`), and undeclared
  mobile UAs cost 2.8 s a request and send two thirds of the IIIF time. The
  02 to 04Z Exa burst (up to 4,700 requests an hour) left load near 1.2: Exa is
  not the cause. Load 6 on 8 cores is busy, not overloaded; the caps keep it
  there instead of at 8 to 9 with 504s.
- **The IIIF cache does not help.** From 18Z on 10-07 through 21Z on 10-08, HIT
  was 2 in total, MISS about 600, and BYPASS 85 to 95 percent of IIIF requests
  every hour. Nearly every anonymous reader carries a cookie, so the "any
  cookie" bypass rule (open item 2 of the 10-07 evening entry) excludes them.
  The few stored renders were not asked for again inside RDM's five minutes.
- **Narrowing the bypass to RDM's session cookie would not fix it.** Tested with
  `curl` from the instance: an anonymous GET of `/`, `/search` and `/records/1`
  each returns `Set-Cookie: session=...`; only `/api/records` does not. Any reader
  who has loaded a page therefore carries `session`, and nginx cannot tell an
  anonymous `session` from a logged-in one. Caching without a cookie bypass risks
  serving a logged-in reader's render of a restricted file to an anonymous one
  for five minutes. That is why the cookie bypass was not simply narrowed.
- **A signal that does tell them apart: `X-User-ID`.** Single sign-on (Shibboleth)
  happens inside RDM, not at nginx: there is no `shibd`, Apache or `/etc/shibboleth`
  on the instance and the only sign-in traffic is `POST /login/`. The site config
  already hides Invenio's `X-Session-ID` and `X-User-ID` response headers from
  clients (`proxy_hide_header`), so the application sends them, and nginx reads
  them as `$upstream_http_x_user_id`. **Experiment, 21:55Z** (`map` plus a
  second, conditional `access_log` written only when the header is present,
  holding time, status, method and path with no query string, and `auth=user`;
  never the user id): 114 lines from one logged-in staff session, all 200 or 302,
  on `/api/*`, record pages, `/me/uploads` and one `/preview/` request. The header
  is sent on every authenticated route tested. **It was not seen on a `/api/iiif/`
  request:** the author's PDF viewing went through pdf.js (`/preview/` then
  `/records/<id>/files/<name>.pdf`, a 302), which does not use IIIF at all, so no
  logged-in IIIF request was ever made. Logged-in readers rarely if ever use IIIF;
  the IIIF load is the undeclared automated traffic fetching render links.
- **First attempt failed safely.** A `map` in `caltechauthors_log.conf` (to put
  `anon` or `user` in the main log) was rejected by `nginx -t`:
  `redirect-map.conf` sets `map_hash_max_size` and `map_hash_bucket_size`, and nginx
  reports them as a duplicate once any `map` has been parsed earlier. The backup was
  restored; nothing changed. A permanent `auth` field in the main log needs those two
  directives moved, or the log configuration loaded after `redirect-map.conf`; that
  is undecided.

**Change applied to production, 2026-10-08 after 22:00Z** (backup
`caltechauthors.conf.bak-20261008-cachecookie`, `nginx -t`, graceful reload;
repository copies updated to match): in `location ^~ /api/iiif/`, the cookie is no
longer a bypass or a reason not to store, and a response is never stored when the
application marked it authenticated:

```
proxy_cache_bypass $http_authorization $arg_token $arg_access_token;
proxy_no_cache     $http_authorization $arg_token $arg_access_token $upstream_http_x_user_id;
```

Anonymous readers now reach the cache; a logged-in reader's response is not
stored. Also in place: the 21:55Z experiment (`auth-requests.log`, backup
`caltechauthors.conf.bak-20261008-authlog`), to be removed once a logged-in IIIF
request has been checked.

**Not verified.** (1) That `/api/iiif/` responses carry `X-User-ID` for a logged-in
reader; if they do not, a logged-in render of a restricted file could be stored and
served to anonymous readers for up to five minutes. One logged-in request to
`/api/iiif/record:<id>:<file>/full/300,/0/default.png` and a look at
`auth-requests.log` would settle it. (2) That an anonymous request for a
restricted record returns a response nginx will not store (a 403 without cache
headers should not be). (3) The effect: HIT was 2 in 31 hours before.
- **Other findings:** `citation-weekend-agent/2.0` is a self-described agent not in
  any declared pattern (227 of the day's 429s); Exa sends no 429s today and
  costs 0.23 s a request; meta-webindexer is still the costliest declared bot
  (9,976 upstream seconds in the window); `ja3`, `ja4` and `bot_score` are still
  empty; undeclared clients are about 1.5 million of about 2 million requests.
- **The production site config does not match the repository copy.** SHA-256 of
  `/etc/nginx/sites-enabled/caltechauthors.conf` differs from
  `nginx-caltechauthors.conf` (and the cache file likewise); the difference
  has not been read yet.

Open:
1. ~~Measure the cache after a few hours of weekday traffic.~~ **Done 2026-10-09**,
   see the entry above: HIT 16 percent, BYPASS 0, load about 1.
2. ~~Confirm that IIIF sends `X-User-ID`, then remove the experiment.~~ **Done
   2026-10-09**, see the entry above: it is sent; the experiment and
   `auth-requests.log` are gone. The question of whether nginx stored the logged-in
   response was not answered (Cloudflare answered the repeat request), and a new one
   about Cloudflare's own cache is open there.
3. Decide the permanent `auth` field in the main log (move `map_hash_*`, or load
   the log configuration after `redirect-map.conf`).
4. Diff the production site config against the repository copy and bring the
   repository back in line (their hashes differed on 10-08 before any change of
   mine; the IIIF cache lines now match).
5. Rerun `bot-family-breakdown.bash` with its labels made date-neutral.
6. `GET /login/` returned 200 about 5,579 times on 10-08, about 13 a minute, almost
   certainly automated; not yet looked at.

### 2026-10-07 evening: load 8 again, IIIF repeat rate, IIIF cache

Question: why was load above 8 at 18:12Z, and can a cache for IIIF renders
help? Measured read-only over SSM (host snapshot, then the last 15 minutes of
`access.log`, new-format lines only). All figures are from that 15-minute
sample (17:58 to 18:12Z, 3,631 requests, 14,220 upstream seconds) unless stated.

- **Host:** load 8.4, 9.1 and 8.9 (1, 5, 15 minutes) on 8 cores. Six REST
  Granian workers at 40 to 80 percent CPU each, one Ghostscript render running.
  OpenSearch calm (2 percent CPU, up 20 hours, no restart): the heap fix holds.
  Statuses in the window: 504 on 193 requests, 499 on 183, 429 on 150.
- **Who:** undeclared clients used 13,400 of the 14,220 upstream seconds (94
  percent): Windows UAs 6,336, mobile 3,993, Mac 1,823, Linux 1,261, nearly all on
  the API paths. Exa 362 seconds (2.5 percent, 43 of the 150 429s); every other
  declared bot under 210. A burst at 18:08 to 18:11 doubled the request rate
  (405 a minute against about 200). Singapore sent 408 requests (11 percent),
  China 286, Hong Kong 126, Brazil 117. No fingerprinting of the burst was done,
  so one actor is not established.
- **IIIF repeat rate (the open measurement from 10-06):** 104 IIIF requests for
  **21 distinct URLs**, about 5 per URL, 99 of them PDF renders. 88 percent failed
  (46 504, 42 429, 12 200). IIIF cost 3,126 upstream seconds, about 30 s a request,
  the most expensive path class.
- **Renders are slow:** one PDF render took 54.7 s upstream under that load.
  nginx's default `proxy_read_timeout` is 60 s, so a render finishing after it is
  cut off, returns 504 and cannot be cached.
- **RDM's headers on a render:** `Cache-Control: public, max-age=300`, an
  `Expires`, no `Set-Cookie`, no `Vary`. nginx would honour that without any
  `proxy_cache_valid`.

**Change applied to production, 18:21Z (backups `*.bak-20261007-iiifcache`,
gated by `nginx -t`, graceful reload):** a new
`/etc/nginx/conf.d/caltechauthors_cache.conf` (`proxy_cache_path`, 2 GB, 1 h
inactive); in `location ^~ /api/iiif/` a `proxy_cache` with `proxy_cache_lock` (120
s timeouts), `proxy_cache_use_stale`, `proxy_read_timeout 120s`, and bypass and no-store
for any request with a cookie, an `Authorization` header or a `token` argument
(so only anonymous responses are ever stored); and an appended
`cache="$upstream_cache_status"` log field.

**First attempt did not cache.** The cookie request logged `cache=BYPASS` as
intended, but plain requests logged `MISS` twice for one URL and the cache
directory stayed empty. The cause was `proxy_buffering off;` at server level
(site config line 395), inherited by the IIIF location; nginx does not store an
unbuffered response, so the lock could not collapse requests either.

**Second change, applied at about 18:34Z (reconstructed from the run time; no timestamp was logged) with the author's go-ahead (backup
`caltechauthors.conf.bak-20261007-iiifbuf`, `nginx -t`, graceful reload):**
`proxy_buffering on;` inside `location ^~ /api/iiif/` only. The lifetime stays at
RDM's five minutes; a longer one waits for the log.

**Verified once, with one URL:** the first request (a MISS) took 78 s to render and
was stored (one 156 KB file); the next two came back in 0.03 s (HIT); a request
with a cookie logged BYPASS and went to RDM. **No real traffic has exercised it
yet:** only 5 IIIF requests were logged in the 8 minutes afterwards, 3 of them
mine, and load was 4.0 and falling as the burst eased (3.3 at 18:26Z, 4.0 at 18:38Z),
so the fall is not evidence for or against the cache.

- **Side effect to watch:** `proxy_read_timeout 120s` keeps a stalled upstream
  request for twice as long, holding an `iiif_conc` slot (cap 6) longer and
  possibly raising 429s for others. The 78 s first render shows the longer
  timeout was needed: the 60 s default would have cut it off, uncached.
- **My test requests** each caused a render; the 120 s 504s in them are RDM
  stalling under load, not the cache.
- The bypass is "any cookie", stricter than "logged in": anonymous readers who
  carry a cookie (an RDM session or CSRF cookie, a consent cookie) are not served
  from the cache. The log does not record cookies, so the share is unknown.

**Cap analysis (read-only, 18:42Z; 19.6 hours, 70,657 seconds, non-campus `/api`,
429s excluded because they never held a slot).** Concurrency is computed from each
request's end time and `rt`, so it is the real in-flight count, not an estimate.

- `/api` (cap `api_conc` 24): median 7 in flight, p90 21. At 4 or more in flight 66
  percent of seconds, 8 or more 46 percent, 12 or more 34 percent, 24 or more 5.7
  percent. The cap already binds; sustained overload is the problem, not a loose
  cap at the extreme. (A maximum of 142 is from before the caps were applied at
  23:21Z on 10-06.)
- `/api/iiif/` (cap `iiif_conc` 6): median 2, p90 6; at the cap in 14.8 percent of
  seconds, 2 or more renders running in 53 percent.
- Campus `/api` (exempt): p99 of 3 in flight, maximum 11, 1.8 percent of seconds at
  2 or more. The exemption costs almost nothing.
- Per-minute view (in-flight estimated as upstream seconds over 60, so slowness
  inflates it): below about 4 in flight the API averaged 0.79 s a request with 0.1
  percent 504s; at 4 to 8, 5 s and 4 percent; above 8, 11 to 25 s with 13 to 33
  percent 504s and 25 to 42 percent 499s. The request rate stayed flat at about 50
  to 70 a minute across the buckets, so the damage comes from what is asked for,
  not how much. IIIF success fell from 67 percent at 0 to 4 in flight to 7 to 19
  percent above 8. This gives no threshold for a cap, because slowness raises the
  estimate.
- **Interaction with the cache:** a request waiting on the cache lock still counts
  against `iiif_conc`. Lowering the IIIF cap could let a few waiters on one hot URL
  use every slot and 429 other URLs while one render runs. Do not lower it before the
  hit rate is known.
- **Recommendation recorded 10-07, no cap changed:** let the cache run, re-measure
  with this method, then decide. The candidate is `api_conc` 24 to 12 or 16, which
  turns 20 to 60 s timeouts into immediate 429s, at the price of more 429s for
  off-campus readers (already 6.6 percent of API requests). Treat it as an
  experiment with a rollback.

Open:
1. Tally the `cache=` field for `/api/iiif/` (HIT, MISS, EXPIRED, BYPASS) over a
   few hours of real traffic, with the 504 and 429 counts, to see whether it
   helps, and decide on a longer lifetime (a candidate is 6 h with
   `proxy_ignore_headers Cache-Control Expires` and `proxy_cache_valid 200 6h`;
   the exposure is a record made restricted or taken down staying visible to
   anonymous visitors for that long; deleting the cache files clears it).
2. Narrow the bypass from any cookie to the RDM session cookie and `Authorization`
   once the share of cookie-bearing readers is known.
3. Re-run the cap analysis after a few hours with the cache, then decide on
   `api_conc` (and the IIIF cap), with the author's go-ahead (production change).
4. Rollback if needed: restore the `*.bak-20261007-iiifcache` files (site config and
   `caltechauthors_log.conf`), remove `caltechauthors_cache.conf`, `nginx -t`, reload.
   The repo copies of the nginx files now match production; `/etc/nginx` is not
   under git.

### 2026-10-07: survey of declared bots, cost by family, 10-07 429s

Question: which other declared bots (Anthropic, OpenAI, Google, Meta and so on)
are in the log, what do they cost, and who is being limited by the caps?
Measured at 15:52Z over logs 2026-10-03 through 2026-10-07 (the 7th is
partial), read-only over SSM. First pass: `bot-traffic-report.bash` with a
pattern naming about 50 known crawlers. Second pass: `bot-family-breakdown.bash`,
which groups user agents into families (the version run here had the
missing-header bug below; the repository copy is fixed). The
upstream-seconds figures use only new-format lines, which cover about 17 hours
(from 10-06 23:00Z), while request counts cover all five days. Do not compare
the two directly.

Declared bots, requests over five days (about 1.99 million in all; the named
set is 18 to 23 percent of each day):

| Requests | Bot | Operator |
|---|---|---|
| 117,499 | ExaSearchBot/1.0 | Exa |
| 36,143 | bingbot/2.0 | Microsoft |
| 36,140 | Applebot/0.1 | Apple |
| 35,840 | SemrushBot/7 | Semrush |
| 35,636 | Googlebot/2.1 (a phone UA, Chrome/153; unverified) | Google |
| 35,210 | ChatGPT-User/1.0 | OpenAI |
| 28,302 / 14,285 | meta-webindexer/1.1 / meta-externalads/1.1 | Meta |
| 24,473 | SemanticScholarBot | Allen Institute |
| 24,141 | DotBot/1.2 | Moz |
| 23,868 | Baiduspider (with `-render`) | Baidu |
| 13,751 | OAI-SearchBot/1.4 | OpenAI |
| 13,034 | Claude-User/1.0 | Anthropic |
| 10,106 | PerplexityBot/1.0 | Perplexity |
| 8,363 | KeenableBot/1.0 | Keenable |
| 19,711 | `python-requests/2.34.2` | unnamed |

Also seen: Sogou, SentryUptimeBot, DataForSeoBot, YandexBot, DuckDuckBot,
HaloBot. **Not seen at all:** ClaudeBot, GPTBot, Google-Extended, CCBot,
Bytespider, Amazonbot. Whether `robots.txt` or something upstream explains
that was not checked. OpenAI sends about 49,000 over five days against
Anthropic's 13,000, and Anthropic sends only the user-initiated fetcher.

What each family costs (the `api-*` paths are what load RDM):

- **The declared bots are cheap, with two exceptions.** Almost all crawl the
  HTML pages and static files: `api-*` share is 0 to 0.3 percent for Applebot,
  bingbot, Googlebot, OpenAI, Claude-User, Semrush, Perplexity, DotBot,
  Baiduspider and SemanticScholar, and they cost 0.08 to 0.45 s of upstream
  time per request.
- **Exa** sends 39.5 percent of its requests to `api-*` (the record, versions,
  communities lockstep) at 0.47 s a request, and about 1,500 of the 1,800
  upstream seconds it used in the window were on the API.
- **meta-webindexer** is the other declared exception: 39.7 percent `api-*`,
  0.93 s a request, 9,283 upstream seconds in the window (about five times Exa's
  1,824 and the most of any declared bot, about 8,300 of it on the API). It is the declared
  bot with the highest load on RDM and was not on the earlier list as a concern.
  Its UA is a Chrome-looking string with `meta-webindexer/1.1` appended.
- **`python-requests`** is the most expensive per request, 3.1 s, 92.6 percent
  `api-*`, but only 260 requests in the window.
- **The undeclared traffic is the load.** Upstream seconds in the window: mobile
  UAs 168,000 (3.6 s a request; 103,000 s of it IIIF), Windows 172,000
  (2.1 s a request), Mac 43,000, Linux 26,000. All declared bots together are
  about 26,000. This corrects the 10-06 baseline, which described a Windows
  Chrome wave: the expensive IIIF load is as much Android and Firefox mobile
  UAs as Windows Chrome.

429s on 10-07 (3,830 by 15:52Z, against 683 on 10-06):

- **None from campus** (`131.215.0.0/16`: 0), so no sign yet of real readers
  being limited.
- 93 percent went to undeclared clients. Rate by family: mobile 4.6 percent of
  its requests, Exa 2.5 percent (96 limited), Windows 1.4, meta-webindexer 1.3
  (131), Mac 0.6. No 429s for Applebot, bingbot, OpenAI, Claude-User, Semrush,
  Perplexity or DotBot; Googlebot's UA got 2.
- **Exa now sees 429s**, which it did not before 10-06. Whether its volume
  falls as a result is not yet known.
- By path: 2,026 (53 percent) were `/api/iiif/` (the `iiif_conc` cap of 6), then
  the record API endpoints. By hour, peaks at 14Z (676), 05Z (483), 13Z (453).
- Countries: US 492, BR 428, SG 424, AR 247, CN 179, HK 149. 65 percent sent no
  platform client hint. The top user agents are Windows Chrome/148 and /154
  and Android Firefox 152 to 155, none above 134 requests, so the spread is wide
  and no single client dominates.
- The `cf_ray` and `sec-ch-ua` presence counts from this breakdown are not
  valid (the log writes `-`, not an empty string, for a missing header, and the
  script tested for empty). Only the platform-hint figure above is sound. Fixed
  in `bot-family-breakdown.bash` and checked on a synthetic log.

What this means: none of the declared AI or search bots is the capacity
problem. The caps are hitting the undeclared mobile and desktop wave and, now
and then, Exa and Meta. `Googlebot`, `bingbot` and the others are claims
that were not verified against the vendors' address ranges.

Open:
1. Verify the claims for Googlebot, bingbot, ChatGPT-User, Claude-User and Meta
   against published ranges, using only log lines from 10-06 22:00Z on (earlier
   addresses are Cloudflare edges).
2. Decide the policy for meta-webindexer and Exa (both reach the API paths);
   checking `robots.txt` first.
3. Rerun `bot-family-breakdown.bash` on 10-08 or 10-09 (edit its hard-coded 429
   day first).

### 2026-10-06: ExaSearchBot (check after the first report)

Question: did ExaSearchBot adapt after the earlier attack? Measured with
`bot-traffic-report.bash -p 'exasearchbot|crawler\.exa\.ai' -d 5` at
23:52Z, logs 2026-10-02 through 2026-10-06 (the 6th is partial).

| Day | All requests | Exa | Share | Exa addresses |
|---|---|---|---|---|
| 10-02 | 468,556 | 5,609 | 1.2% | 1,119 |
| 10-03 | 450,059 | 19,676 | 4.4% | 2,346 |
| 10-04 | 390,865 | 36,747 | 9.4% | 3,388 |
| 10-05 | 462,771 | 39,984 | 8.6% | 3,787 |
| 10-06 | 425,890 | 17,316 | 4.1% | 2,804 |

(Address counts before the real-IP change at about 22:00Z on 10-06 are
Cloudflare edges, not clients.)

- **User agent did not change.** One string only:
  `Mozilla/5.0 (compatible; ExaSearchBot/1.0; +https://crawler.exa.ai/)`,
  119,332 requests over five days. No browser-looking or renamed variant under
  that pattern.
- **Volume did not stop; its shape changed.** About 2,000 an hour until 18:00Z
  on 10-05, then 100 to 500 an hour overnight, then bursts on 10-06 at
  03 to 06Z (1,100 to 1,700 an hour), 12Z (1,100) and 16 to 19Z (up to 1,840).
  It is still active and now arrives in bursts, a change from the flat profile.
  Whether that is deliberate, a rate-limit response to our 499/504s, or the
  vendor's own scheduling is not known.
- **What it fetches:** static files, the record page, and the record API
  endpoints `/api/records/<id>`, `/versions` and `/communities` in lockstep
  (about 11,700 each), plus `/files` pages. Only about 60 IIIF requests. 78
  percent of its responses were 200, 17 percent 302. No 429s (the caps started
  at 23:21Z, after nearly all of this).
- **It is not the IIIF and Ghostscript load** that took the host to load 12 on
  10-06. That traffic is the undeclared Windows-Chrome wave in the baseline
  above. Exa is the largest single declared bot, about three times the next
  (bingbot, ChatGPT-User, SemrushBot and Applebot are each about 38,000 over five
  days), but 4 to 9 percent of all traffic.
- **Fingerprint:** only 161 Exa lines are in the new format so far (151 US, 9
  CN, 1 IQ), none without a `cf_ray`, all without `sec-ch-ua`. Too few to
  compare. Rerun in two or three days.
- **Leads, unverified:** about 1,200 requests across a handful of user agents
  claiming research use with `@example.org` or `@example.com` mailto addresses
  (for example `kb-research/1.0`, `CorrespondingAuthorEnricher/2.0`,
  `OvernightLiteratureHarvest/1.0`), and nine requests from
  `access511.py (hole-research swarm, Exa; research use)`. They share a style but
  nothing ties them to Exa or to each other. They are not in the Exa counts above.

Also seen in section 5 (declared automation over five days): ChatGPT-User,
OAI-SearchBot, PerplexityBot, Claude-User, KeenableBot, meta-webindexer and
meta-externalads, SemanticScholarBot, DataForSeoBot, DotBot, Baiduspider,
Sogou, YandexBot, python-requests (29,455) and `Googlebot` strings with
unusual Chrome versions (35,534, not verified as Google's). 499 responses ran
15,000 to 38,000 a day and 504s 534 to 5,178 a day, worst on 10-06 before the
caps.

Open:
1. Rerun on 10-08 or 10-09 with the new log format and compare Exa, the
   declared set and the undeclared fingerprint.
2. Decide the response to Exa. Options, none taken: `robots.txt` (not checked
   whether it names Exa or whether Exa honours it), a Cloudflare rule by UA,
   a rate rule on the three record API endpoints, or nothing since it is 4 to 9
   percent.
3. Send the Cloudflare request to central IT (still a draft).
