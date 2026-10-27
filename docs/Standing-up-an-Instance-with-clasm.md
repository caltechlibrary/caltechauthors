# Standing up a CaltechAUTHORS instance with clasm

One straight path to a working CaltechAUTHORS test instance (Invenio RDM under
uv + Granian, repo `caltechauthors`, branch `main`), provisioned with
[clasm](https://github.com/caltechlibrary/clasm). Follow the steps in order.
The choices are already made; the reasons are in the notes at the end.

**Requires clasm v0.0.12.** Check with `clasm -version`.

You need:

- AWS credentials that work (`aws sts get-caller-identity` shows your IAM user).
- The SSH private key for the key pair you launch with, at mode `0600`.
- The branch you are deploying pushed to `origin`. The setup script clones from
  GitHub, so uncommitted local work is invisible to it.
- A DNS name for the instance (a `*.caltechlibrary.dev` name) once you reach Step 7.

Run every `./nginx-deploy.bash` command from `/Sites/caltechauthors` on the
instance; the `./` is needed because the script is in that directory, not on
`PATH`.

## Step 1 — Look up production's launch values

Read them from production rather than trusting numbers written down anywhere:

```bash
aws ec2 describe-instances --region us-west-2 --instance-ids <production-instance-id> \
  --query 'Reservations[].Instances[].{Type:InstanceType,Key:KeyName,SGs:SecurityGroups[].GroupId,Subnet:SubnetId}'
```

Use production's instance type (`m7i-flex.2xlarge`), key pair, and the
`caltech-ssh` security group. Add the `invenio` security group (80 and 443 open)
so you can browse to the instance before it sits behind Cloudflare. Use a
subnet with `MapPublicIpOnLaunch=true`, or the instance gets no public address.

## Step 2 — Create the read-only restore role

A test instance restores from production's backups, so it must not be able to
write to them. Do not use `rdm-backups`. Make a read-only role and profile:

```bash
clasm iam create-role-from-template -json \
  --backup-bucket sql-backups.library.caltech.edu \
  --second-bucket opensearch-backups.library.caltech.edu \
  --key-prefix caltechauthors-v13 \
  rdm-restore-source-read-only restore-source-<instance>
clasm iam create-instance-profile -json restore-source-<instance> restore-source-<instance>
```

`<instance>` is the `Name` tag you pick in Step 3, for example `caltechauthors-v14`.

## Step 3 — Create the launch template

Pick an amd64 Ubuntu 24.04 AMI. The name must contain `amd64`; an `arm64` AMI is
always wrong here.

```bash
clasm compute create-launch-template-from-cloud-init-yaml \
  --name <instance> --ami <ami-name-or-id> \
  --instance-type m7i-flex.2xlarge --key-pair <keypair> \
  --security-group <caltech-ssh-id> --security-group <invenio-id> --subnet <subnet-id> \
  --iam-instance-profile restore-source-<instance> \
  --name-tag <instance> --environment test \
  --root-volume-gb 250 ~/WorkLab/caltechauthors/cloud-init.yaml
```

It refuses a wrong architecture, a missing security group, subnet, key pair or
profile, and creates nothing when it does. The `project` tag is written
lowercase (`caltechauthors`); leave it that way.

## Step 4 — Launch the instance

```bash
clasm compute create-ec2-instance-from-launch-template -json <instance>
```

This launches one billable instance and waits for cloud-init to finish. Expect
several minutes. clasm has no terminate form; end a throwaway instance from the
Compute menu.

## Step 5 — Run the setup script

Cloud-init writes the setup script but does not run it. Open an SSM session,
become `ubuntu`, and run it under `tmux`:

```bash
aws ssm start-session --target <instance-id> --region us-west-2
```

```bash
sudo -u ubuntu -i
tmux new -s setup '/usr/local/bin/setup_caltechauthors_granian.bash main 2>&1 | tee /home/ubuntu/setup.log'
```

The script clones the repo to `/Sites/caltechauthors`, installs the toolchain,
starts the backing containers, and installs the systemd units. It leaves
Postgres and OpenSearch empty on purpose; the next step fills them. It also
leaves file storage unconfigured, so file downloads return 403. Leave it that
way on a test instance: a restored database names production's content buckets.

## Step 6 — Restore SQL and OpenSearch

Take the source name from production: `caltechauthors-v13`. Run each command
without `--confirm` first. It prints the plan and changes nothing.

```bash
# SQL: dry run, then the real run
clasm rdm-backup-and-restore restore-sql-backup-from-s3 \
  <instance> sql-backups.library.caltech.edu caltechauthors-v13 latest
clasm rdm-backup-and-restore restore-sql-backup-from-s3 --confirm <instance> \
  <instance> sql-backups.library.caltech.edu caltechauthors-v13 latest

# OpenSearch: dry run, then the real run
clasm rdm-backup-and-restore restore-opensearch-snapshot-from-s3 \
  <instance> /opt/rdm_opensearch_backups opensearch-backups.library.caltech.edu \
  caltechauthors-v13 latest caltechauthors-
clasm rdm-backup-and-restore restore-opensearch-snapshot-from-s3 --confirm <instance> \
  <instance> /opt/rdm_opensearch_backups opensearch-backups.library.caltech.edu \
  caltechauthors-v13 latest caltechauthors-
```

Typing the source name explicitly matters: left alone, the default is the new
instance's own name, which has no backups yet, and the restore reports nothing
found. The SQL restore takes about 10 minutes and the OpenSearch restore about
5. The OpenSearch restore ends with a health check, and its exit status is that
check's verdict, so a non-zero exit is a real finding.

## Step 7 — Set up HTTPS with Let's Encrypt

Cloud-init starts nginx with a self-signed certificate.[^selfsigned] Replace it
with a Let's Encrypt certificate for the instance's name.

1. **DNS.** Point an `A` record for the name (here `authors.caltechlibrary.dev`)
   at the instance and wait for it to propagate.

2. **Get the certificate.** Use `certonly`, never `certbot --nginx`:

   ```bash
   sudo certbot certonly --standalone -d authors.caltechlibrary.dev \
     --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx"
   ```

3. **Deploy it.** From `/Sites/caltechauthors`:

   ```bash
   cd /Sites/caltechauthors
   sudo ./nginx-deploy.bash diff  --server-name authors.caltechlibrary.dev --tls letsencrypt
   sudo ./nginx-deploy.bash check --server-name authors.caltechlibrary.dev --tls letsencrypt
   sudo ./nginx-deploy.bash apply --server-name authors.caltechlibrary.dev --tls letsencrypt --reload
   ```

   `diff` exits 1 here because the host still has the self-signed
   configuration; that is expected. `check` tests a staged copy and changes
   nothing. `apply` backs up what it replaces and restores the backup if
   `nginx -t` fails. If you need to back out,
   `sudo ./nginx-deploy.bash rollback --reload`.

4. **Look.** `curl -sI http://authors.caltechlibrary.dev/` answers `301` to
   HTTPS, and `curl -sI https://authors.caltechlibrary.dev/` answers from the
   application without redirecting again.

## Step 8 — Verify

On the instance:

```bash
/usr/local/bin/verify_rdm_boot.bash
```

Then check the restore took. Compare these counts with the same query on the
source: `rdm_records_metadata`, `rdm_drafts_metadata`, `rdm_parents_metadata`,
`communities_metadata`, `accounts_user`, `pidstore_pid`, the record index
document count, and the `/api/records` total. Small drift is normal, because the
source keeps moving. An `/api/records` total below the raw record count is the
access filter on restricted records working.

Finally, `sudo reboot`, wait, and run `verify_rdm_boot.bash` again. The instance
must come back without anyone starting anything by hand.

## Step 9 — Set up SQL backups

Cloud-init does not do this. Do it now, not later:

```bash
sudo install -d -o ubuntu -g www-data -m 0770 /opt/rdm_sql_backups
sudo crontab -u ubuntu -e
```

```
0 3,11,15,19,23 * * * /Sites/caltechauthors/invenio-sql-backup.bash <postgres-container-name> /opt/rdm_sql_backups
```

Create `/Sites/caltechauthors/postgres_env.cfg` (`ubuntu:ubuntu`, `0664`). A
restore needs it:

```bash
export DB_NAME="caltechauthors"
export DB_USERNAME="caltechauthors"
```

## Notes

- **Why the read-only role.** `rdm-backups` can overwrite and delete objects in
  production's SQL and OpenSearch backup buckets, which are not versioned. The
  restore role reads one prefix and explicitly denies every write and delete.
  Remove it when the instance no longer needs it (each command takes `--confirm`
  and has a dry run):

  ```bash
  clasm iam remove-role-from-instance-profile --confirm restore-source-<instance> restore-source-<instance> restore-source-<instance>
  clasm iam delete-instance-profile --confirm restore-source-<instance> restore-source-<instance>
  clasm iam delete-role --confirm restore-source-<instance> restore-source-<instance>
  ```

- **After the OpenSearch restore,** delete the `clasm-fix-auditlog-orphan`,
  `clasm-fix-auditlog-plain` and `clasm-fix-job-logs-plain` copies yourself once
  the admin audit-logs page works. clasm never deletes them, and a leftover one
  makes the next conversion refuse.
- **Archiving from a restored instance:** if the first Archive OpenSearch
  Snapshot after a restore fails with `AccessDeniedException`, check that
  `/opt/rdm_opensearch_backups` is `ubuntu:ubuntu 0775` and `chown` it by hand.
- **Commands over SSM** do not have uv on `PATH`; wrap them:
  `sudo -u ubuntu -H bash -lc 'cd /Sites/caltechauthors && uv run --no-sync ...'`.
- **Reboot is unattended.** Docker restarts the containers and `rdm.target`
  brings up the app. After `sudo systemctl restart docker`, also run
  `sudo systemctl restart rdm.target`. Logs are in the journal:
  `journalctl -u rdm -f`.
- **Making this instance production** is a separate, longer procedure
  (security-group swap, Elastic IP, retagging `Environment=production`,
  backups before cutover). It is not covered here. The full earlier version of
  this runbook is in git history.
- **More on nginx and certificates:** [nginx.md](nginx.md) and
  [Adding-a-Certbot-Hostname.md](Adding-a-Certbot-Hostname.md).

[^selfsigned]: `nginx-deploy.bash` also accepts `--tls self-signed`. The cloud-init
    files use it (`--server-name _`) so a fresh instance, including one built by
    the Multipass cloud-init, comes up serving HTTPS before any certificate exists.
    Use `--tls letsencrypt` for everything you deploy by hand.
