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
