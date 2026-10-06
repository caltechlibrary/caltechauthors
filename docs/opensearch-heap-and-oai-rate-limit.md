# OpenSearch heap exhaustion and OAI-PMH bursts

Written 2026-10-02 after two Sentry alerts, `CALTECHAUTHORS-E9` (regressed, first
seen 2026-08-31, 9 events, 9 users) and `CALTECHAUTHORS-EZ` (new):

```
TransportError invenio_oaiserver.response
TransportError(429, 'circuit_breaking_exception',
  '[parent] Data too large, data for [<http_request>] would be [534361136/509.6mb],
   which is larger than the limit of [510027366/486.3mb] ...')
```

**Status (2026-10-06): the heap change is made in this repository's
`docker-services.yml` (`-Xms4g -Xmx4g`) but is not yet applied on the host.
The OAI-PMH rate limit is still only proposed.** Both are production changes for
the person who runs the host, in a maintenance window.

## Recurrence, 2026-10-06

A third failure of the same kind, reported as a few minutes of the authors indexes
not responding with a "no shard available" error in the docker logs. Read-only
inspection of `caltechauthors-v13` showed:

- At 03:00 UTC the JVM spent 40 to 80% of its time collecting garbage, a G1GC
  attempt freed nothing (517 MB before, 520 MB after), and
  `java.lang.OutOfMemoryError: Java heap space` ended the process. `OOMKilled` is
  false and `dmesg` shows no kernel OOM kill.
- Docker restarted the container at 03:00:32 (`restart: unless-stopped`). The node
  was back by 03:00:39 but the cluster state was not recovered until 03:01:02, and
  health went from RED to YELLOW at 03:01:28. Requests in between failed with
  `ClusterBlockException: SERVICE_UNAVAILABLE/1/state not recovered`. That window
  is the "no shard available" the reporter saw; it is a symptom of the restart,
  not a separate fault.
- Afterwards: 70 primaries started, 66 replicas unassigned
  (`CLUSTER_RECOVERED`, decider `same_shard`). That is expected on a single node
  and is why the cluster is yellow, not a fault.
- Heap was at 63% of 512 MB with the instance otherwise idle, so there is no
  headroom for a burst. The node holds about 18 million documents in 70 shards.
- No snapshot-repository errors (`AccessDeniedException`, snapshot 404) appeared in
  the 02:30 to 03:30 UTC window, so this is not the restore-then-archive
  ownership defect. Whether the migrated indices raised the baseline heap use is
  not established.
- `RestartCount` was 1, not the 281 recorded on 2026-10-02, so the container has
  been recreated since then; when and by whom is not established here.

## What the host showed

Read-only inspection of production `caltechauthors-v13` on 2026-10-02:

- OpenSearch runs with `OPENSEARCH_JAVA_OPTS=-Xms512m -Xmx512m`
  (`docker-services.yml`, the `search` service). The host has 31 GB of RAM and
  the container is capped at 16 GB (`mem_limit: 16g`), so the heap, not the
  machine, is the limit.
- The parent circuit breaker trips at 95% of the heap: 95% of 512 MB is
  510,027,366 bytes, the `486.3mb` in the Sentry message. The alerts are the
  breaker doing its job.
- The container is crash-looping. `RestartCount` is 281 since the container was
  created on 2026-08-27, with 5 to 39 starts a day in the retained log, spread
  across every hour of the day, and `java.lang.OutOfMemoryError: Java heap space`
  in the log. `OOMKilled` is false, so this is the JVM running out of heap rather
  than the kernel killing the container. Today's restarts at 19:23:49 and
  19:59:06 UTC are the two alerts (12:23 PM and 12:59 PM Pacific).
- The trigger today was an OAI-PMH burst: 1,466 `verb=ListRecords` requests to
  `/oai2d` in the 19:00 UTC hour (189 in the same hour on 2026-10-01; other hours
  see fewer than ten), about one request a second without a gap. Browser user
  agents, 1,449 answered 200, 15 answered 500, 3 answered 422.
- CaltechDATA's `new-data` instance has the same 512 MB heap and a `RestartCount`
  of 0, so 512 MB is the shared default and v13's load is what exceeds it.
- It is not caused by backup work. The restarts are flat across the day, with no
  cluster at the nightly snapshot (12:35 UTC) or at the dump times, and the first
  alert is from before the cutover.

## Proposed fix, part 1: a larger heap

`docker-services.yml` ships `-Xms512m -Xmx512m` under a comment that says the
settings are for development only. Raise both values together, for example:

```yaml
      - "OPENSEARCH_JAVA_OPTS=-Xms4g -Xmx4g"
```

4 GB is a starting point, not a measured size. Set minimum and maximum to the
same value, keep it at or below half of the host's RAM, and check it afterwards
rather than assuming. `bootstrap.memory_lock=true` is already set, so the heap
is locked into memory; the 16 GB `mem_limit` leaves room for it.

Applying it needs the `search` service recreated, which interrupts search and
OAI-PMH for a minute or two and ends any harvest in progress. Before doing it,
confirm that the OpenSearch data directory is a bind mount that survives a
recreate (`docker inspect caltechauthors-search-1`, look at `Mounts`), since a
recreate that discards the indices is a rebuild. Then:

```text
docker compose -f docker-services.yml up -d search
```

Verify with the node stats, which show the heap and whether the breaker has
tripped, and with the restart count:

```text
curl -s "localhost:9200/_nodes/stats/jvm,breaker?filter_path=nodes.*.jvm.mem.heap_used_percent,nodes.*.jvm.mem.heap_max_in_bytes,nodes.*.breakers.parent"
docker inspect caltechauthors-search-1 --format '{{.RestartCount}}'
```

`heap_max_in_bytes` should be the new size, `tripped` should stay at 0, and the
restart count should stop climbing. Apply the same value to this repository's
`docker-services.yml` so the next deployment does not put 512 MB back.

## Proposed fix, part 2: limit OAI-PMH, in the right place

A bigger heap makes a burst survivable; it does not stop one. Limit
`/oai2d` as well.

**The origin cannot see who is asking.** `authors.library.caltech.edu` is behind
Cloudflare, and all 112 distinct client addresses in the 19:00 UTC burst fall in
Cloudflare's published ranges. nginx has no `real_ip` configuration, so its
`$remote_addr` is a Cloudflare edge, and an nginx `limit_req` keyed on it would
limit Cloudflare, not the harvester. Two ways to do this properly:

- A Cloudflare rate-limiting rule on the path `/oai2d` (preferred: it acts before
  the traffic reaches the host, and Cloudflare knows the real client).
- Teach nginx the real client address first, then limit at the origin:

  ```nginx
  # http level: trust Cloudflare's published ranges (https://www.cloudflare.com/ips/)
  set_real_ip_from 173.245.48.0/20;   # ... and the rest of the list
  real_ip_header CF-Connecting-IP;
  limit_req_zone $binary_remote_addr zone=oai:10m rate=1r/s;

  # server level, beside "location /": same proxy settings as location /
  location = /oai2d {
    limit_req zone=oai burst=5 nodelay;
    proxy_pass http://127.0.0.1:5000;
    # ... the proxy_set_header lines location / uses
  }
  ```

  This is an untested sketch for `nginx-caltechauthors.conf`; check it with
  `nginx -t`, and keep the Cloudflare list current.

Do not block OAI-PMH wholesale: `ListRecords` is how legitimate aggregators and
repositories harvest the metadata. A limit with a burst allowance slows a flood
and leaves a polite harvester alone. `invenio-oaiserver`'s page size and
resumption-token settings also bear on how heavy one request is; check the
current values before changing them.

## Not established

- Who or what the harvester is. The user agents are ordinary desktop browsers,
  which a legitimate harvester would not send.
- The right heap size. 4 GB is a starting point; watch `heap_used_percent` over a
  few days.
- What the 15 responses with status 500 were.
- Whether the crash-looping began at the cutover. Sentry first saw the error on
  2026-08-31, before production moved to this instance on 2026-09-10, and the
  container is older than that.
