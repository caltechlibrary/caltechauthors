# nginx on a CaltechAUTHORS host

The nginx configuration for CaltechAUTHORS lives in this repository's `nginx/` tree and is installed on a
host by `nginx-deploy.bash`. This page is for whoever has to deploy it, check it, change it, or put it
back, and assumes you were not there when it was written.

## What is in the repository

`nginx/` mirrors `/etc/nginx`:

| File | Installed as | What it is |
|---|---|---|
| `sites-available/caltechauthors.conf` | `/etc/nginx/sites-available/<site-name>.conf`, linked from `sites-enabled/` | The site: ports 80 and 443, the proxy locations, the IIIF cache and `Cache-Control` rule, the legacy redirects. A **template**: the script replaces `@SERVER_NAME@` and `@REPO_DIR@`. |
| `tls/letsencrypt.conf` or `tls/self-signed.conf` | `snippets/caltechauthors-tls.conf` | The certificate pair, chosen by `--tls`. |
| `conf.d/caltechauthors_log.conf` | `conf.d/` | The `caltechauthors_bots` log format. |
| `conf.d/caltechauthors_limits.conf` | `conf.d/` | The concurrency caps for `/api` and `/api/iiif/`. |
| `conf.d/caltechauthors_cache.conf` | `conf.d/` | The cache zone for anonymous IIIF renders. |
| `conf.d/cloudflare_real_ip.conf` | `conf.d/` | Trusts the client address from Cloudflare's published ranges only. |

The redirect map for the legacy EPrints URLs is `nginx/redirect-map.conf`. It is not installed under `/etc/nginx`;
the site file includes it from the checkout by absolute path (`@REPO_DIR@/nginx/redirect-map.conf`).

The script installs by **copy**, never by symlink, so editing the checkout is never a live change to a
host. It never edits the packaged `/etc/nginx/nginx.conf`.

## The verbs

All of them need `--server-name` and `--tls`; `nginx-deploy.bash --help` is the full manual.

```shell
sudo ./nginx-deploy.bash check  --server-name authors.library.caltech.edu --tls letsencrypt
sudo ./nginx-deploy.bash diff   --server-name authors.library.caltech.edu --tls letsencrypt
sudo ./nginx-deploy.bash apply  --server-name authors.library.caltech.edu --tls letsencrypt --reload
sudo ./nginx-deploy.bash rollback --reload
```

- **check** renders the files, builds a *staged* copy of the host's `/etc/nginx` with them laid over it, and
  tests that copy with `nginx -t -c`, and with `logagent check` when `logagent` is installed. It changes nothing
  on the host.
- **diff** compares what is installed with what would be rendered. Exit 1 means drift.
- **apply** runs check, backs up what it will replace, copies, runs `nginx -t` on the installed tree, and
  **restores the backup if that fails**. It reloads nginx only with `--reload`, and asks first unless `--yes`.
- **rollback** puts back the latest backup (or the one named by its stamp), tests it, and reloads only with
  `--reload`. Backups are in `/var/backups/caltechauthors-nginx`.

Use `--cert-name` when the Let's Encrypt lineage is not named after the server name, and `--site-name` to
change the file's name under `sites-available/` (default `caltechauthors`). A new instance's `cloud-init`
calls `apply --yes --reload --tls self-signed --server-name _`, so a fresh instance runs what production runs.

### Exit status

The script uses the workspace's exit codes. The ones that matter in practice: **1** drift (`diff`) or a
declined `apply`; **2** a bad command line; **65** the configuration was rejected (`nginx -t` failed or
`logagent` found a gap, before any change or after one that was then restored), a token was left
unreplaced, or the host has legacy configuration and `--migrate-legacy` was not given; **66** something
the command needs is missing; **69** `--reload` could not reload nginx (the files are installed and
`nginx -t` passes, nginx keeps serving the old configuration); **74** a copy failed part way (the backup was
restored); **77** not root. `--help` lists all of them under EXIT STATUS.

## Reloading

`--reload` runs `systemctl reload nginx`, which only *signals* the master process and returns at once. The
new listening sockets can take a moment to open, so a check made in the same instant can still see the old
ones. After a reload, wait a second or two and try again before concluding anything is wrong.

## Certificates

The script needs only the certificate pair. With `--tls letsencrypt` it is
`/etc/letsencrypt/live/<cert-name>/fullchain.pem` and `privkey.pem`; with `--tls self-signed` (test instances)
it is the pair and `snippets/self-signed.conf` that `cloud-init` writes, and the script stops if that file is
missing. How the pair got there is up to the host. The `--tls` vocabulary is closed on purpose
(caltechauthors DR-0009).

Certbot is a convenience for developers and for other institutions adapting this code, and
`Adding-a-Certbot-Hostname.md` is its how-to. The one rule is `certbot certonly`, **never `certbot --nginx`**, on
a host this script manages: `certbot --nginx` inserts certificate lines into the site file, and the next
deployment would remove or duplicate them. Renewals replace the files under `/etc/letsencrypt/live/` and do not
touch the repository's files.

## A host that was configured by hand

A host set up before this layout (production, until it is migrated) has an `/etc/nginx/nginx.conf` edited away
from the nginx-common package's, and/or the old top-level `/etc/nginx/caltechauthors_log.conf`, which would
define the `caltechauthors_bots` log format a second time. `check` and `apply` refuse such a host with exit 65
and change nothing. Rerun with `--migrate-legacy`: it backs up both files, puts back the package's own
`nginx.conf` (taken from the nginx-common `.deb`, and accepted only if its checksum is the one `dpkg` recorded),
removes the old log file, and installs. `rollback` undoes all of it. Do this in a quiet window, with `--reload`.

## The IIIF cache and how to clear it

Anonymous IIIF renders (each one spawns a Ghostscript process) are cached in
`/var/cache/nginx/caltechauthors_iiif`; the zone is defined in `conf.d/caltechauthors_cache.conf`. Unused
entries go after an hour and the directory is capped at 2 GB. To clear the cache, for example after a
takedown, delete the files under that directory; no reload is needed.

A response the application marked as authenticated (it sends `X-User-ID`, which nginx hides from clients) is
never stored, and a request carrying an `Authorization` header or a token argument bypasses the cache. A
cookie is *not* a bypass: every anonymous visitor to a page is given a `session` cookie.

### Why the IIIF location rewrites `Cache-Control`

RDM sends `Cache-Control: public, max-age=...` on IIIF images whether or not the record is restricted, so a
shared cache (a CDN) may keep a permitted reader's response and serve it to anyone who asks for the same URL.
The site file sends `private, no-store` on `/api/iiif/` responses that carry `X-User-ID`, and leaves anonymous
responses as the application sent them. This is our deployment's answer; IIIF handling is also being reworked
upstream. Two details to keep if you change the block:

- The `map` that chooses the header is placed **after** the `redirect-map.conf` include. That file sets
  `map_hash_max_size` and `map_hash_bucket_size`, and nginx rejects them as duplicates if any `map` was parsed
  before them. (The files in `conf.d/` load before the site file, which is why the concurrency caps use `geo`
  and not `map`.)
- A `add_header` in a location **replaces** every inherited one, so the IIIF location restates
  `Strict-Transport-Security` and `X-Request-ID`. So does `/static`.

## Refreshing the Cloudflare address list

`conf.d/cloudflare_real_ip.conf` lists Cloudflare's published ranges (`https://www.cloudflare.com/ips-v4` and
`/ips-v6`). When they change, edit the file in the repository, then `check`, `diff` and `apply --reload`.
Where there is no Cloudflare in front, as on a test instance, the list is inert: only connections from those
ranges are trusted to say who the client is.

## Changing the hostname

The site file is one `server` block, plus the redirect map and the IIIF `Cache-Control` map at http level. To
put a host under a different name, get its certificate pair in place (`Adding-a-Certbot-Hostname.md` for a
Let's Encrypt one), then run `apply` with the new `--server-name` and, if needed, `--cert-name`.

What this layout does **not** do is serve two hostnames from two rendered site files on one host: each file
includes the same `redirect-map.conf` and defines the same http-level maps, and nginx rejects the second one
(`"map_hash_max_size" directive is duplicate`; `check` exits 65 and changes nothing). Verified on nginx 1.24.0.

The failure that `Adding-a-Certbot-Hostname.md` describes (a bare redirect stub that certbot appended its
certificate lines to, so that HTTPS redirected to itself) cannot happen with this layout, because
certbot is never allowed to edit a site file.

## Where to look when it is wrong

- `sudo ./nginx-deploy.bash diff ...` says what differs from the repository.
- `/var/log/nginx/access.log` carries the `caltechauthors_bots` format, including `rt=` and `cache=`;
  `/var/log/nginx/error.log` carries `limiting connections` lines when a cap trips.
- `sudo nginx -t` tests the installed tree. nginx creates the cache directory when it tests, and fails if its
  parent is missing, which `apply` creates for you.
- The reasons for each choice are in the workspace's decision records for this repository (DR-0009 and
  DR-0010).
