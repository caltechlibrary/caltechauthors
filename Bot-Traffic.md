# Tracking automated traffic on CaltechAUTHORS

CaltechAUTHORS gets 390,000 to 690,000 requests a day, most of it automated.
This page is the standing procedure for measuring that traffic, and the log of
each bot or wave we have looked at, so a follow-up starts from the last
numbers instead of from scratch. Add a new entry to the incident log at the
bottom whenever a new bot or wave is investigated.

Background: issue #168; the nginx changes (real client IP, extended log format,
concurrency caps) are `nginx-cloudflare-real-ip.conf`,
`nginx-log-format-bot-fingerprint.conf` and `nginx-concurrency-limits.conf`.

## What you need

- Read access to the production instance's nginx logs. We use AWS SSM
  (`caltechauthors-v13`, `i-0effbcc6cfb91097e`) as the management path; the
  commands below are read-only.
- `bot-traffic-report.bash` from this repository. It reads
  `/var/log/nginx/access.log` and the newest rotated logs, prints one report,
  and changes nothing.
- The extended log format
  (`nginx-log-format-bot-fingerprint.conf`) for the fingerprint section.
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
