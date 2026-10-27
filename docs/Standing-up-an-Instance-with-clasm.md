# Standing up a CaltechAUTHORS instance with clasm

A reusable bring-up procedure for a CaltechAUTHORS EC2 instance running
Invenio RDM under **uv + Granian** (repo `caltechauthors`, branch
`granian`), provisioned with [clasm](https://github.com/caltechlibrary/clasm).

Use this whenever a new instance is needed — a throwaway test instance, a
long-lived pre-cutover instance (`caltechauthors-v13` was one; a `-v14` will
follow for the RDM v14 migration), or a from-scratch rebuild of production
itself.

Originally written 2026-08-27 as a one-off procedure for `caltechauthors-v13`;
generalized 2026-09-23 after v13 went to production (cutover 2026-09-10) and
several bugs it hit along the way were fixed in clasm.

**Requires clasm v0.0.12** (released 2026-10-20). It carries the read-only
restore role, the profile swap, the restore's file-location guard and the index
repair that a restore now runs. Check with `clasm -version`. If you are on a
newer clasm, read its [release notes and user
manual](https://github.com/caltechlibrary/clasm) before trusting the specifics
below.

**What was verified how.** The 2026-10-16 material (restore role, profile swap,
location guard) was verified end to end on real AWS. The v0.0.12 index repair's
four parts (health check, template install, log conversion, the restore's
post-load steps) were each run live against a test
instance on 2026-10-20, and production received one read-only
health check (healthy). Its refusal and failure paths, exit classes 65/66/69,
any instance other than that one, and the production-confirmation branch of
`convert-log-indices` against a real production tag were **not** exercised live (see
[Known open risks](#known-open-risks)). **Revised 2026-10-23** by reading
clasm's [user manual](https://github.com/caltechlibrary/clasm/blob/main/docs/user_manual.md)
for v0.0.12, not by re-running a bring-up: command-line forms below are as the
manual documents them.

## Contents

- [Prerequisites](#prerequisites)
- [Decisions to make before you start](#decisions-to-make-before-you-start)
- [Step 1 — Create the launch template](#step-1--create-the-launch-template)
- [Step 2 — Launch the instance](#step-2--launch-the-instance)
- [Step 3 — Run the setup script](#step-3--run-the-setup-script)
- [Step 4 — Restore SQL and OpenSearch](#step-4--restore-sql-and-opensearch)
- [Step 5 — Verify](#step-5--verify)
- [Administering the instance](#administering-the-instance)
- [SQL backups — not provisioned by cloud-init](#sql-backups--not-provisioned-by-cloud-init)
- [Archiving, rotation, and the S3 prefix](#archiving-rotation-and-the-s3-prefix)
- [If this instance is becoming production](#if-this-instance-is-becoming-production)
- [Known open risks](#known-open-risks)
- [References](#references)

## Prerequisites

- clasm v0.0.12. Confirm with `clasm -version`. Install it from
  [github.com/caltechlibrary/clasm](https://github.com/caltechlibrary/clasm);
  if it is not on `PATH`, run the binary from your build of the repository
  (`./bin/clasm -version`).

  Every step below is available in the menu and, for most, as a
  non-interactive `clasm <domain> <action> ...` form (see clasm's user manual,
  "Non-interactive (CLI) Usage"). The forms shown are the ones that exist at
  v0.0.12; where a step has none, it says so.

- AWS credentials resolvable (`aws sts get-caller-identity` should return
  your own IAM user in the right account).
- The SSH private key for whichever key pair you launch with, present
  locally at mode `0600`.
- **The target branch is pushed to `origin`.** The setup script does
  `git clone --branch <branch>` against the public repository, so
  uncommitted local work is invisible to it — commit and push first.

### User-data size

`caltechauthors/cloud-init.yaml` is comfortably over AWS's 16,384-byte
user-data limit on its own (it was 26,715 raw bytes as of the `granian`
branch). clasm gzip-compresses before base64 encoding
(`internal/workflow/userdata_gzip.go`), which brought it well under the
limit. Re-check after any substantial edit to the YAML:

```bash
gzip -c cloud-init.yaml | base64 | tr -d '\n' | wc -c
```

## Decisions to make before you start

Unless you're deliberately deviating, read current production's live
configuration rather than trusting any values written down here — they
drift:

```bash
aws ec2 describe-instances --region us-west-2 --instance-ids <production-instance-id> \
  --query 'Reservations[].Instances[].{Type:InstanceType,Profile:IamInstanceProfile.Arn,Key:KeyName,SGs:SecurityGroups[].GroupId,Subnet:SubnetId}'
```

- **Instance type and key pair.** Normally match production exactly.

- **IAM instance profile — decide by what the instance is for.** Every
  profile needs `AmazonSSMManagedInstanceCore`, which is what lets clasm
  drive the instance over SSM.

  - **A test instance that restores from production's backups: do not use
    `rdm-backups`.** That profile can overwrite and delete objects in
    production's SQL and OpenSearch backup buckets, and neither bucket is
    versioned. Use a read-only restore role instead, made with clasm (see
    [The read-only restore role](#the-read-only-restore-role)). It reads one
    source prefix and has an explicit `Deny` of every write and delete on the
    backup buckets, so a policy attached later cannot reopen them. The profile
    must exist *before* the launch template names it.
  - **A production-track instance** archives its own backups, so it needs
    the write access `rdm-backups` grants and should match production's
    profile. Match production exactly, and know that its restores are
    guarded (see [The location guard](#the-location-guard)).

- **Root volume size.** The team's target is 250 GB (decided 2026-07-21).
  A SQL dump runs roughly 5.4 GB uncompressed and an OpenSearch snapshot
  roughly 6.6 GB, so 250 GB leaves ample headroom. Not a one-way door:
  clasm's Compute domain has a *resize instance's root volume* action that
  grows the volume and automates the OS-level partition/filesystem growth
  over SSM.

- **Subnet and public IP.** clasm's launch-template builder sets
  `NetworkInterfaces` without `AssociatePublicIpAddress`
  (`internal/workflow/launch_template_create.go:35`), so the subnet's own
  `MapPublicIpOnLaunch` setting decides whether the instance gets a public
  IP at all. A test/dev instance that needs direct browser access
  generally wants a subnet with `MapPublicIpOnLaunch=true`. A
  production-track instance can use the same subnet as current production
  (typically `MapPublicIpOnLaunch=false`) because it will get its public
  reachability from an Elastic IP at cutover instead — launching into that
  subnet *without* an Elastic IP produces an instance with no outbound
  route, and cloud-init fails at its first `apt` call.

- **Security groups.** `caltech-ssh` (22 from the Caltech network) is
  **required regardless of purpose** — `cold`'s report runners reach this
  VM over SSH to retrieve data, and that dependency is invisible until a
  report silently stops producing data. Pair it with either an `invenio`-
  style group (22 from Caltech plus 80/443 open, for direct browser
  testing before the instance sits behind Cloudflare) or production's
  Cloudflare-only group (once the instance is meant to serve real
  traffic).

- **Tags.**

  | Key | Value |
  |---|---|
  | `Name` | unique per instance, e.g. `caltechauthors-vNN` |
  | `project` | `caltechauthors` — **must be lowercase** |
  | `Environment` | `test` while iterating, `production` once live |
  | `origin` | `dld` (per `~/.clasm`'s `origin_tag` convention) |

  clasm matches `Name`, `project`, and `Environment` by exact key
  (`internal/inventory/instances.go:138`), and `RDMPostgresConfigFor` falls
  back to the `project` tag for `db_name`/`db_user` when
  `rdm_postgres_config` doesn't have an explicit entry — a capitalized
  `Project` resolves to empty and a restore targets a database that
  doesn't exist (the 2026-07-29 incident the code comment documents).
  clasm's own launch and AMI-creation flows now write this tag correctly
  lowercased, so this is a residual caution for hand-edited tags,
  not an active bug. `Environment=test` matters because clasm shows an
  extra warning before destructive actions on anything tagged
  `Environment=production` — leave it at `test` for as long as the
  instance will be wiped and reloaded repeatedly, and retag it deliberately
  when that stops being true (see
  [If this instance is becoming production](#if-this-instance-is-becoming-production)).

## Step 1 — Create the launch template

**Compute → Create launch template from cloud-init YAML**

Preferred over *create EC2 instance from cloud-init YAML* directly because
the resulting template is reproducible, versioned, and can be updated in
place later via *sync cloud-init YAML to a launch template* as the YAML
evolves.

Answer the prompts with the cloud-init YAML path, the base AMI, the
instance type, root volume size, key pair, security groups, subnet, IAM
instance profile, and a template name — using the decisions above.

The same step has a non-interactive form, which is the one to script
or repeat:

```bash
clasm compute create-launch-template-from-cloud-init-yaml \
  --name caltechauthors-v14 --ami <ami-name-or-id> \
  --instance-type m7i-flex.2xlarge --key-pair <keypair> \
  --security-group <sg-id> --security-group <sg-id> --subnet <subnet-id> \
  --iam-instance-profile <profile> \
  --name-tag caltechauthors-v14 --environment test \
  --root-volume-gb 250 cloud-init.yaml
```

It runs every check the wizard does and **refuses instead of offering a fix**:
a wrong-architecture instance type, a missing security group, subnet, key pair
or profile, a profile that is not SSM-capable, or an empty cloud-init file is
exit 2 with the reason, and nothing is created. It never creates the key pair,
instance profile or role; they must already exist (the read-only restore role
below is made first). Instances launched from the template are tagged `Name`,
`project`, `Environment` and `templateName`, so the template's name follows the
instance (clasm issue #1).

If the instance type you need isn't in clasm's curated shortlist
(`internal/workflow/launch_prompts.go:174` — this is true of
`m7i-flex.2xlarge`, production's own type), use the **Other** free-text
escape hatch. Read the architecture trap below before doing that.

### The AMI architecture trap — read before picking

**In the menu, using "Other" for the instance type disables clasm's only
architecture guard.** (The non-interactive form above checks the architecture
itself and refuses a mismatch, so this trap is the menu's.) clasm's AMI picker offers both amd64 and arm64 official Ubuntu
images, differing only by `amd64`/`arm64` in the middle of an otherwise
identical name. Its protection against a mismatch is that
`promptInstanceType` filters the *curated* list by the AMI's architecture —
there is deliberately no pre-flight check. But
"Other" is offered regardless of architecture, so typing an instance type
walks straight past the filter and AWS is the first thing to object, with:

```
AWS error [InvalidParameterValue]: The architecture 'x86_64' of the
specified instance type does not match the architecture 'arm64' of the
specified AMI.
```

Two ways to stay out of it:

- **Read the architecture in the AMI name**, not just the release. The
  string is `.../ubuntu-noble-24.04-amd64-server-YYYYMMDD` or `...-arm64-...`.
- **Use the curated instance-type list as a tell.** After picking the AMI,
  the list should show `t3`/`m5`/`c5`/`r5` entries for amd64. If it shows
  `t4g`/`m6g`/`c6g`/`r6g`, an arm64 AMI was selected — back out before
  reaching for "Other".

CaltechAUTHORS is x86_64 and its `cloud-init.yaml` says so explicitly, so
arm64 is always wrong here.

### If the architecture is already wrong

*Modify launch template's instance type / EBS root volume size* handles
precisely this case — it prompts for a new AMI when the chosen instance
type's architecture doesn't match the current one. No need to delete and
rebuild the template.

1. Pick the template, the current source version, the correct instance
   type (**Other** again — this picker is unfiltered by architecture), and the root volume size. It then flags the mismatch and
   prompts for a replacement AMI; pick the correctly-architected build.
   `UserData` is inherited via `SourceVersion`, so the gzipped cloud-init
   carries over untouched and doesn't need re-syncing.
2. **Promote the corrected launch template version to default.** Modify
   deliberately never promotes on its own (matching Sync's own precedent),
   and Step 2 below launches from `$Default` — skip the promotion and
   you'll reproduce the original failure exactly.
3. Re-run Step 2.

## Step 2 — Launch the instance

**Compute → Create EC2 instance from launch template**

Pick the template and accept the pre-filled `$Default` version. This flow
collects nothing else — the template supplies every launch parameter by
design. The non-interactive form is
`clasm compute create-ec2-instance-from-launch-template -json <template> [version]`
(it launches one billable instance and waits for `running`; progress goes to
stderr). **clasm has no terminate form**: end a throwaway instance from the
Compute menu, or with the AWS CLI after checking the id.

clasm then polls until the instance reaches `running`, waits for SSM to
report `Online`, runs `cloud-init status --wait` under a bounded timeout,
and reports `done` or `error`. Expect several minutes.
`install_rdm_toolchain.bash` runs from `runcmd` and installs uv, a
uv-managed Python 3.12, `invenio-cli` as a uv tool, and nvm + Node — all as
the `ubuntu` user, into `/home/ubuntu/.local/bin`.

## Step 3 — Run the setup script

Cloud-init writes `setup_caltechauthors_granian.bash` to
`/usr/local/bin/` but **does not run it** — `runcmd` only invokes
`install_rdm_toolchain.bash`.

The instance is managed through SSM sessions, not just SSH:

```bash
aws ssm start-session --target <instance-id> --region us-west-2
```

The session lands as `ssm-user`, not `ubuntu`, and everything the script
needs is under `/home/ubuntu`. Become `ubuntu` first, then run the script
under `tmux` (installed by cloud-init) so a dropped session doesn't kill
it:

```bash
sudo -u ubuntu -i
tmux new -s setup '/usr/local/bin/setup_caltechauthors_granian.bash granian 2>&1 | tee /home/ubuntu/setup.log'
```

SSH also works, via the `caltech-ssh` group and the instance's key pair —
and is not merely a fallback, since `cold`'s report runners retrieve data
from this VM over SSH:

```bash
ssh -i ~/.ssh/<keypair>.pem ubuntu@<public-ip> /usr/local/bin/setup_caltechauthors_granian.bash granian
```

The script clones the repo to `/Sites/caltechauthors`, runs `uv sync` and
`invenio-cli install`, creates the OpenSearch host directories, generates
`.env` (including a fresh `INVENIO_SECRET_KEY`), starts the seven backing
containers, and installs the three systemd units plus `rdm.target`. The
committed unit files on the `granian` branch already specify `User=ubuntu`
and `/home/ubuntu/.local/bin/uv` (fixes already committed) — a
fresh clone gets the right service user without any runtime rewrite.

It deliberately skips `invenio-cli services setup`, leaving Postgres and
OpenSearch empty — demo data would only be discarded by the restore in the
next step.

### File storage

`.env` deliberately omits `INVENIO_S3_*` and `FILES_REST_STORAGE_FACTORY`.
Records restore with their metadata intact, but file downloads return 403
until this is configured — replicate whatever is currently live on
production rather than any placeholder in this document, since production
now serves files normally in practice.

**Keep it that way on a test instance.** A restored database carries
production's *file locations* (on 2026-10-16 the real dump held
`s3://default` and `s3://caltechauthors`, the content bucket), so an
instance whose `.env` holds a writable `INVENIO_S3_*` key would write to
production's content bucket. Omitting the keys is the safe default, and the
restore's [location guard](#the-location-guard) checks the key as well as the
instance role before it replaces anything.

## Step 4 — Restore SQL and OpenSearch

Before restoring, check what is actually freshest. The daily S3 object's
*filename* lags its upload by about two days — each file is named for the
dump's own date and synced later — and a hand-run dump may be sitting on
the source instance's disk, unarchived. Check `/opt/rdm_sql_backups` on
the source instance over SSM before assuming the newest S3 object is the
newest dump.

**RDM Backup & Restore → Restore SQL Backup from S3**

clasm discovers the Postgres container via `docker ps` on each run and
offers to save the reconciled rule into `~/.clasm`, so hand-editing
`rdm_postgres_config` beforehand isn't required. Postgres-target discovery
now runs *before* any S3 transfer starts, so a misconfiguration fails fast
rather than after a multi-GB download. Hyphenated database names are
SQL-identifier-quoted, and the download/decompress step no longer assumes
a `.gz` extension — both were real bugs, now fixed, so they're not
something to watch for. The restore's own timeout was widened to 2 hours
(real loads run roughly 45 minutes).

Blank `db_name`/`db_user` in a reconciled rule fall back to the `project`
tag, which is exactly what `docker-services.yml` sets `POSTGRES_DB` and
`POSTGRES_USER` to — this is why the `project` tag casing matters (see
above). A pattern written for one instance's `Name` tag will not match a
different one; patterns are matched with `path.Match` semantics, first
match wins, so check `~/.clasm` if a restore resolves against the wrong
rule.

**RDM Backup & Restore → Restore OpenSearch Snapshot from S3**
(non-interactive: `clasm rdm-backup-and-restore restore-opensearch-snapshot-from-s3
[--confirm <instance-id-or-name>] <instance> <directory> <bucket> <source>
<snapshot-name-or-latest> <index-prefix>`; with no `--confirm` it prints the plan
and changes nothing.)

Snapshots live under
`s3://opensearch-backups.library.caltech.edu/<source-instance-name>/opensearch-snapshots/`.
Generate a fresh one from the source first (*Archive OpenSearch Snapshot
to S3*) if the newest available snapshot isn't close in time to the SQL
dump — the two need to be roughly consistent with each other, or the index
will disagree with the database. Conflicting-index deletion (when restoring
over an existing index) also now runs before the S3 transfer, same
fail-fast improvement as above.

This workflow prompts separately for **(a)** the S3 source-instance-name
(the prefix to restore from) and **(b)** the index prefix to restore under
— these are independent, and both matter whenever the source and
target instances don't share the same `Name`/`project` tag. If unsure what
index prefix production expects, check this repo's
`docker-services.yml`/OpenSearch config for the existing index naming
before answering that prompt. See
[Known open risks](#known-open-risks) for a real bug in this workflow that
may still bite on the very next archive.

### What the OpenSearch restore does after the load (v0.0.12)

A restore uses `include_global_state:false`, which carries neither **index
templates** nor **data-stream definitions**. Without them the app's first write
creates a plain, `text`-mapped audit-log and job-logs index, and the admin
audit-logs page silently stops updating: every layer answers HTTP 200 and only
`_shards.failed` in the page's own query body gives it away ([caltechauthors issue
#185](https://github.com/caltechlibrary/caltechauthors/issues/185), fixed live on
production 2026-10-19). So **Restore OpenSearch
Snapshot from S3** now finishes with three steps on every instance, in order:

1. install the index templates the instance's app would install and lacks
   (the app's own routine, so they match the installed RDM version);
2. convert an audit log or job logs that came back as an orphaned `.ds-` index
   or a plain index into a real data stream, **copy first**;
3. run the index health check and print its report.

**The health check's verdict is the restore's exit status.** A restore that
leaves the admin page broken exits 1, after printing its own table. There is no
second confirmation; the one the restore already takes names these steps. A
snapshot taken before 2026-10-19 holds the audit log as exactly that orphan, so
older snapshots are converted too.

Things to know:

- **The conversion keeps its copies.** `clasm-fix-auditlog-orphan`,
  `clasm-fix-auditlog-plain` and `clasm-fix-job-logs-plain` are named in the
  output and **never deleted by clasm**; they roughly double the space those two
  indices take. Remove them yourself once the admin audit-logs page is
  confirmed working. A leftover copy of the same name from an earlier run makes
  the next conversion refuse, with the reason and nothing changed.
- **Time.** On CaltechAUTHORS the audit log is about 306,000 documents, so the
  conversion adds minutes to the restore. It runs as polled tasks, one SSM call
  each.
- **Each step is also a form of its own**, for an instance already in the state
  or a restore that stopped part way (all take `-wait`, default 5m, because
  OpenSearch takes about three minutes to answer after a boot):

```bash
clasm rdm-backup-and-restore rdm-index-health <instance>            # read-only; safe on production
clasm rdm-backup-and-restore install-index-templates <instance>     # additive; no confirmation
clasm rdm-backup-and-restore convert-log-indices <instance>         # run install-index-templates first
```

  `convert-log-indices` on an instance whose **live** `Environment` tag is
  `production` is a dry run unless `--confirm <instance-id-or-name>` is given.
- **Use the health check as the first thing to run on any instance you inherit
  from a restore**, and again after one. It queries exact names only, so a kept
  `clasm-fix-*` copy cannot fail a healthy instance.

Not yet checked live, so do not assume them: the production-tag branch of
`convert-log-indices`, the refusal and failure paths, and exit classes 65, 66
and 69 from a real instance.

The restore also moves any `index-N` file and `index.latest` already in the
repository directory aside to `/var/tmp/clasm-stale-repo-<timestamp>/` before it
downloads (deleting nothing), and deletes every existing index matching the
prefix, including an audit-log backing index a previous restore left without a
data stream.

### The location guard

A restored database names the S3 buckets its files live in, and an instance
that can write to one of them would write to production's content after the
restore. **Restore SQL Backup from S3** therefore reads the backup's file
locations first (a `pg_dump --column-inserts` file, so each is one
`INSERT INTO public.files_location` line) and judges every S3 bucket they name
can this instance write to it, through the role of its instance
profile or the `INVENIO_S3_*` key in `/Sites/.env`? Both are put to IAM's policy
simulator; anything that cannot be told is treated as writable, with the reason.

- **Always do the dry run first.** From the command line,
  `clasm rdm-backup-and-restore restore-sql-backup-from-s3 <instance> <bucket>
  <source> latest` with no `--confirm` prints the plan, including each file
  location and `read-only` or `WRITABLE` beside each bucket, and changes
  nothing. It streams the dump through the instance to read the locations (about
  a minute for a 1 GB dump). The menu flow shows the same and asks to continue.
- **A read-only instance is never blocked.** The restore role and no key in
  `.env` give `read-only` for both buckets, and `--confirm <instance>` alone
  runs it.
- **A writable bucket must be named.** `--confirm <instance> --confirm
  <bucket>`; with only the instance named the command refuses (exit 1) and
  prints the flag to add. A `--confirm` that is neither the instance nor a
  writable bucket is a usage error (exit 2). From a terminal with no
  `--confirm` you are asked to type the instance, then each writable bucket.
- **Permissions.** The person running clasm needs `iam:SimulatePrincipalPolicy`,
  `iam:GetAccessKeyLastUsed` and `iam:GetUser`; without them the guard cannot
  tell and treats every bucket as writable. It does not see bucket policies.

Measured 2026-10-16 on a test instance (m7i-flex.2xlarge, restore
role): a 1002.9 MiB dump restored in about 10 minutes (80 tables), and the
6.4 GiB OpenSearch snapshot in about 5 minutes (61 indices, 147,955 records) —
well under the 45 minutes written above, which predates the faster load setting.

### The read-only restore role

Create it once per test instance, from the machine that runs clasm, with the
credentials that can create IAM resources. Each form is scriptable and prints
`-json`; the template and every resource it makes carry the configured `Origin`
tag, so clasm can find and delete them later.

~~~shell
# 1. The role: SSM, plus read of one source prefix in each backup bucket and an
#    explicit Deny of every write and delete there.
clasm iam create-role-from-template -json \
  --backup-bucket sql-backups.library.caltech.edu \
  --second-bucket opensearch-backups.library.caltech.edu \
  --key-prefix caltechauthors-v13 \
  rdm-restore-source-read-only restore-source-<instance>
# 2. An instance profile holding it (the launch template names the profile).
clasm iam create-instance-profile -json restore-source-<instance> restore-source-<instance>
~~~

Name `restore-source-<instance>` in the launch template (Step 1), or, on an
instance that is already running, swap it on for the restore window and back:

~~~shell
clasm compute associate-replace-iam-instance-profile -json <instance> restore-source-<instance>
# ... restore ...
clasm compute associate-replace-iam-instance-profile -json <instance> <its normal profile>
~~~

The swap replaces the association in place (no reboot, no relaunch) and is safe
to repeat: asking for the profile the instance already has changes nothing. The
profile must be SSM-capable. Before relying on a new role, check it with
`aws iam simulate-principal-policy` (one resource per call): `GetObject` allowed
under the prefix and implicitly denied under any other, `PutObject` and
`DeleteObject` explicitly denied.

Remove it when the instance no longer needs it — each step has a dry run, and
`delete-role` refuses while the role is still in a profile:

~~~shell
clasm iam remove-role-from-instance-profile --confirm restore-source-<instance> restore-source-<instance> restore-source-<instance>
clasm iam delete-instance-profile --confirm restore-source-<instance> restore-source-<instance>
clasm iam delete-role --confirm restore-source-<instance> restore-source-<instance>
~~~

## Step 5 — Verify

On the instance:

```bash
/usr/local/bin/verify_rdm_boot.bash
```

All three of its checks are S3-independent, so they pass even with file
storage unconfigured.

Then compare counts against the source you restored from, taken over SSM.
Useful checks:

| Check | Source |
|---|---|
| `rdm_records_metadata` | Postgres |
| `rdm_drafts_metadata` | Postgres |
| `rdm_parents_metadata` | Postgres |
| `communities_metadata` | Postgres |
| `accounts_user` | Postgres |
| `pidstore_pid` | Postgres |
| record index doc count | OpenSearch |
| `/api/records` total | HTTP |

Small drifts are expected and are not failures — the source may keep
moving while the restore runs. Watch the *direction*: if a draft was
published between the dump and the comparison, the source's draft count
falls by one as its record count rises, and the restored copy should show
the mirror image. An `/api/records` total noticeably below the raw record
count is the anonymous-access filter over restricted/embargoed records
working correctly; agreement between the two sides is itself evidence
access control restored properly.

**Static content pages** (`/help`, `/policies`, `/about`, `/year`,
`/metadata_searching`) are registered on the site blueprint in code, but
their actual *content* lives only in production's Postgres database — no
fixture file in the repo supplies it. An instance stood up without this
step's SQL restore will show these pages as empty, not broken; that's
expected until the restore runs.

Finally, reboot the instance once and re-run `verify_rdm_boot.bash`.
Self-healing across a reboot is the check that caught real problems during
this branch's development, and it's the one that matters most for an
instance headed to production.

## Administering the instance

The old manual bring-up sequence — log in, `cd /Sites/caltechauthors`,
`invenio-cli services start`, then start each service and finally nginx by
hand — still works, but is **no longer required after a reboot**.

### Reboot is unattended

All eight services in `docker-services.yml` carry
`restart: "unless-stopped"`, so Docker brings the containers back on its
own. `rdm`, `rdm_rest` and `rdm_celery` are `systemctl enable`d by the
setup script, and each is gated by
`ExecStartPre=/usr/local/bin/wait_for_rdm_services.bash`, which blocks
until Postgres (5432), Redis (6379), RabbitMQ (5672) and OpenSearch (9200)
actually accept connections — a container reporting "started" is not the
same as the service inside it being ready. The gate is bounded at 180
seconds and exits non-zero on timeout, so `Restart=on-failure` retries the
whole unit rather than racing ahead. nginx carries a drop-in ordering it
`After=rdm.service rdm_rest.service`.

`verify_rdm_boot.bash` exists specifically to confirm this: run it right
after a `sudo reboot`, not just after a manual start sequence.

### Operating notes

- Over SSM, uv and the project venv aren't on `PATH` — wrap commands:

  ```bash
  sudo -u ubuntu -H bash -lc 'cd /Sites/caltechauthors && uv run --no-sync celery --app invenio_app.celery inspect ping'
  ```

- `rdm.target` is a single control point for all four services together:

  ```bash
  sudo systemctl start rdm.target
  ```

  Starting units individually still works and is the right thing when
  debugging one of them.

- `invenio-cli services start` / `status` / `stop` still work and are
  still the right way to drive the containers by hand. One thing to keep
  in mind: because the containers are `restart: unless-stopped`, an
  explicit `invenio-cli services stop` keeps them down across a subsequent
  reboot — the one case where the old manual sequence becomes necessary
  again.

- Restarting Docker does not restart the app units — `Requires=` +
  `After=docker.service` propagates *stop* but not *restart*, so after
  `sudo systemctl restart docker` you must also
  `sudo systemctl restart rdm.target`.

- Logs go to the journal, not `dmesg` — the units set
  `StandardOutput=journal`, so use `journalctl -u rdm -f`.

- Starting and stopping the instance itself has forms:
  `clasm compute start-ec2-instance <instance>` and
  `clasm compute stop-ec2-instance [--confirm <instance>] <instance>`. Both read
  the live state, are safe to repeat, and wait for the state to settle (`-no-wait`
  to return at once). A stop on an instance whose live `Environment` tag is
  `production` is a dry run without `--confirm`. After a start the public
  address may change unless the instance has an Elastic IP.

## SQL backups — not provisioned by cloud-init

Neither `cloud-init.yaml` nor `setup_caltechauthors_granian.bash` creates
the backup directory, installs a cron entry, or writes
`postgres_env.cfg`. All three are hand-installed per instance — and this
is not a theoretical gap: `caltechauthors-v13` ran from its 2026-09-10
cutover to 2026-09-15 with **no SQL backup provisioning at all**, found
only when a routine Archive run had nothing to archive. **Do this
immediately after Step 3, not as an afterthought.**

The arrangement (settled 2026-10-02) is directory `ubuntu:www-data 0770`,
and the dump cron runs **as `ubuntu`**, which is in both `docker` and `www-data`.
That is how `caltechauthors-v13` and `new-data` run since 2026-10-02. clasm creates
the directory if it is missing, with exactly that owner, group and mode, and
**never changes an existing one**; **Generate SQL Backup** hands over only the
dump it wrote (`ubuntu`, the directory's group, `0664`). So the directory can be
left to clasm's first run, or made by hand:

```bash
sudo install -d -o ubuntu -g www-data -m 0770 /opt/rdm_sql_backups
```

```bash
# ubuntu's own crontab -- not root's, and not a personal login's
sudo crontab -u ubuntu -e
```

```
0 3,11,15,19,23 * * * /Sites/caltechauthors/invenio-sql-backup.bash <postgres-container-name> /opt/rdm_sql_backups
```

Why `ubuntu` and not a person's login: on 2026-09-30 production's nightly dumps
stopped because the directory had been left `ubuntu:ubuntu 0750` while the cron
still ran as a personal account outside `ubuntu`'s group; it was found two days
later from a consumer's error mail, since the instance has no local mail. A cron
and the directory's group must agree. Readers of the dumps that still log in as
another user (datawork's legacy copy jobs, `feeds_v1.6`'s `fetch_db_records.bash`)
read through the `www-data` group or, once switched, as `ubuntu` with their key in
`~ubuntu/.ssh/authorized_keys`.

Whichever users need to run the dump without `sudo` must be in both
`docker` and `www-data`. A dump takes about 3 minutes and produces roughly
1 GB gzipped from about 5.4 GB raw, so a 4-hour interval has ample
headroom.

For a one-off dump, `clasm rdm-backup-and-restore generate-sql-backup <instance>
/opt/rdm_sql_backups` writes `<container>-<database>-<date>.sql.gz` there with no
confirmation (a second run the same day replaces that day's dump, as the
instance's own script does).

### `postgres_env.cfg` is gitignored, and a restore needs it

`/Sites/caltechauthors/postgres_env.cfg` (`ubuntu:ubuntu`, `0664`):

```bash
export DB_NAME="caltechauthors"
export DB_USERNAME="caltechauthors"
```

Values match `POSTGRES_DB`/`POSTGRES_USER` in `docker-services.yml`. The
file carries no credentials.

It's easy to miss because **its absence does not break backups** — only
`invenio-sql-backup.bash` hardcodes `DB_NAME`/`DB_USERNAME` as a fallback;
`invenio-sql-restore.bash` and `invenio-sql-command.bash` have no defaults
and fail with "The environment variable DB_NAME is not set." Without the
file, the first symptom appears during a *restore*.

## Archiving, rotation, and the S3 prefix

Nothing on the instance trims old dumps on its own — left unmanaged, a
backup directory accumulates without bound. Rotation happens only when
clasm's own archive workflows run:

- **Generate SQL Backup** (renamed from "Run SQL Backup" — it no longer
  auto-chains into archiving) produces the dump.
- **Archive SQL Backups to S3 (and trim local copies)** copies every local
  file up, and deletes local copies only once they're both aged past a
  configurable threshold *and* confirmed present in S3 (tri-state retention
  prompt; a per-file upload failure now warns and continues rather than
  aborting the whole run).
- **Archive OpenSearch Snapshot to S3** likewise only removes what it has
  confirmed archived.

clasm derives the S3 prefix from the instance's `Name` tag
(`internal/workflow/backup_archive.go:200`), so a differently-named
instance's archives land under a different prefix rather than continuing
an old one — this is intended, and it means a migration leaves two
histories per subsystem (SQL and OpenSearch), neither of which is wrong.
`rdm-backups-policy`-style IAM grants are normally scoped to the whole
bucket rather than a prefix, so a new prefix needs no IAM change.

### Restoring across a name change

Restore SQL Backup from S3 and Restore OpenSearch Snapshot from S3 both
prompt for a **"source instance name"** and default it to the *target's
own* `Name` tag. On a brand-new instance that default resolves to a prefix
nothing has ever written to, and the workflow reports "no backups found
under `s3://.../<name>/...`" and returns cleanly — nothing has failed.
**Type the actual source instance's name instead** — whichever instance
was last taking backups. The prompt is editable precisely for this case.
For OpenSearch, also check the separate index-prefix prompt described in
[Step 4](#step-4--restore-sql-and-opensearch) — it is not automatically
derived from the source-instance-name answer.

## If this instance is becoming production

Known mechanical steps, not yet exhaustive — treat this as a checklist to
refine per cutover, not a script to run blind:

1. Wipe and reload SQL and OpenSearch from a final snapshot taken as close
   to cutover as practical. The OpenSearch restore repairs the log indices and
   runs the health check itself (see
   [Step 4](#what-the-opensearch-restore-does-after-the-load-v0012)); its exit
   status is that check's, so a non-zero exit is a finding, not noise. Run
   `rdm-index-health` once more on the new instance just before the Elastic IP
   moves.
2. Confirm file storage (`INVENIO_S3_*` / `FILES_REST_STORAGE_FACTORY`) is
   configured to match what's currently live — don't rely on this
   document's Step 3 placeholder.
3. Swap security groups: replace the browser-testing group with
   production's Cloudflare-only group. **Keep `caltech-ssh` and the key
   pair** — dropping either breaks `cold`'s SSH-based report runners
   silently.
4. Move the Elastic IP association (`aws ec2 associate-address`, not a
   clasm action; the clasm manual documents no form for Elastic IPs or for changing an
   instance's security groups, so step 3 is also the AWS console or CLI) — this is the actual cutover moment. Confirm the new
   instance's networking (subnet, auto-assigned public IP) behaves the way
   you want once the EIP lands on it.
5. Retag `Environment=test` → `Environment=production` so clasm's
   destructive-action guard applies. clasm has a form for this:
   `clasm tag-management tag-resource --replace instance <name-or-id> --tag Environment=production`
   (`--replace` is needed because the key already has another value; the value
   must be `production`, `development` or `test`). From then on `stop-ec2-instance`
   and `convert-log-indices` on it are dry runs unless given `--confirm`.
6. **Provision SQL backups before or immediately at cutover, not after** —
   see [SQL backups](#sql-backups--not-provisioned-by-cloud-init). This is
   the step that was missed for five days on `caltechauthors-v13`.
7. Decide what happens to the outgoing instance — keep it stopped as a
   rollback path for an agreed window rather than terminating it
   immediately. `clasm compute stop-ec2-instance --confirm <instance> <instance>`
   stops it (the `--confirm` is required while it is still tagged
   `production`); clasm has no terminate form.
8. When restoring onto the new instance, override the source-instance-name
   (and OpenSearch index-prefix) prompts with the *outgoing* instance's
   values, per [Restoring across a name change](#restoring-across-a-name-change).

## Known open risks

- **OpenSearch restore used to leave the synced snapshot repository
  root-owned**, which made the *next* Archive OpenSearch Snapshot run off that
  instance fail with an S3 `AccessDeniedException` (`caltechauthors-v13`, first
  post-restore archive, 2026-09-16). The fix (clasm v0.0.8) was
  **verified against real AWS on 2026-10-16**: after a confirmed restore of a
  6.4 GiB snapshot onto a test instance, `/opt/rdm_opensearch_backups`
  was `ubuntu:ubuntu 0775` and nothing in it root-owned. What is *not* yet
  checked is the archive that follows such a restore; if one fails with
  `AccessDeniedException`, check the directory's ownership first, and fix it by
  hand (`chown`) before retrying.
- **v0.0.12's index repair has not been exercised on everything.** Unrun live:
  the production-confirmation branch of `convert-log-indices` against a real
  production tag (unit-tested on a fake), the refusal and failure paths of the
  three forms, exit classes 65, 66 and 69 from a real instance, and any instance
  other than the test instance. Production has had one read-only health check
  (healthy). Treat a failing health check on a new instance as real until shown
  otherwise, and read the report, not just the exit code.
- **Index templates are not registered before the first write.** Neither
  `cloud-init.yaml` nor the setup script installs the app's index templates, so
  an instance that is stood up and then written to *without* a restore creates
  plain, `text`-mapped log indices exactly as production did (#185). A restore
  now puts that right (and `install-index-templates` plus `convert-log-indices`
  do it by hand), but the cutover runbook and cloud-init should register the
  templates before the first app write; that is a caltechauthors/caltechthesis
  change, not a clasm one, and **has not been made**.
- **Kept `clasm-fix-*` copies accumulate.** clasm never deletes them and has no
  form to; a name left from an earlier conversion makes the next one refuse. Remove
  them by hand once the audit-logs page is confirmed.
- **The `pg_dump --column-inserts` format is load-bearing.** The restore's
  location guard reads each file location from one `INSERT INTO
  public.files_location` line, and the load is one statement per row (made
  fast by `synchronous_commit=off` for that session). If
  `invenio-sql-backup.bash` or CaltechDATA's equivalent stops using
  `--column-inserts`, both break; they must change together with clasm.
- **No automated "verify backup readiness" check exists yet.** Confirming that
  a new instance's SQL backup cron and directory are actually in place is
  still a manual check against [SQL backups](#sql-backups--not-provisioned-by-cloud-init).
- **Granian worker tuning (`--workers 6 --blocking-threads 5`,
  `--workers-max-rss 1800`, `--respawn-failed-workers`) was ported 1:1 from
  production's uWSGI settings and has not been treated as a deliberately
  validated tuning exercise**, even though it has been running in
  production since the 2026-09-10 cutover without a reported capacity
  incident. Don't read "no incident" as "confirmed optimal."

## References

- [clasm](https://github.com/caltechlibrary/clasm) — its
  [user manual](https://github.com/caltechlibrary/clasm/blob/main/docs/user_manual.md)
  ("Non-interactive (CLI) Usage") documents every form used above, and its
  [TODO.md](https://github.com/caltechlibrary/clasm/blob/main/TODO.md) lists
  what is open.
- [caltechauthors issue #185](https://github.com/caltechlibrary/caltechauthors/issues/185)
  — the audit-log defect the v0.0.12 index repair answers.
- [nginx.md](nginx.md) and [Adding-a-Certbot-Hostname.md](Adding-a-Certbot-Hostname.md)
  — the web server on the new instance.
- [DB-dump-and-restore.md](DB-dump-and-restore.md) — the dump and restore
  scripts in this repository.
