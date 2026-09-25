# Production database backups

Hourly, encrypted, off-host, undeletable before expiry, and restore-tested every day (SPI-5748).

| | |
|---|---|
| **What** | Every database (`pg_dump -Fc`), all roles (`pg_dumpall --globals-only`), a per-table row-count manifest, and `/opt/volleyspike` minus `backups/` and `migrations/`: env files, `setup.sh`, compose files, Caddy config and origin certificate. |
| **When** | Hourly at :05 — `spike-db-backup.timer`. Worst case you lose one hour of writes. |
| **Where** | `s3://spike-prod-db-backups-058264239816` (eu-west-2). `hourly/` keeps 2 days; the first archive of each UTC day is also written to `daily/` and kept 35 days. |
| **Protection** | Encrypted with [age](https://age-encryption.org) before it leaves the box. S3 Object Lock in compliance mode: no credential — not the box's, not the AWS root account — can delete an archive before its retention ends. The box's own IAM user cannot delete anything. |
| **Verified** | Daily at 04:35 — `spike-db-restore-test.timer` restores the newest hourly archive into a throwaway Postgres (the live cluster's image, no network, data on tmpfs) and compares every table's row count with the manifest. |
| **Alerts** | `DatabaseBackupStale` (newest over 2.5 h old, critical), `DatabaseBackupMissing` (no metrics for 3 h, critical), `DatabaseRestoreTestStale` (no pass for 30 h, warning). Rules: monitoring repo, `prometheus/rules/backup-alerts.yml`. |

Code: `scripts/spike-backup.sh`, `systemd/spike-db-*`, `../aws/prod-db-backups.yaml`.

## Keys

Every archive is encrypted to two age keys, listed in `/etc/spike-backup/recipients.txt`:

- **DR key**: kept offline in the password manager, never on a server. It is the only way to read a
  backup once the box is gone. **If it is lost, every backup is unreadable.**
- **Restore-test key**: `/etc/spike-backup/restore-test.key` on the box, readable only by root. The
  daily test uses it, and it dies with the box. That is fine, because the DR key does not.

To rotate a key, add the new public key to `recipients.txt` and remove the old one. Archives
already written stay readable only by the old key, so keep it until they expire (35 days).

## Install (first time, or on a rebuilt box)

1. **AWS**, once per account, with admin credentials. The bucket is kept if the stack is deleted.
   ```bash
   aws cloudformation deploy --region eu-west-2 --stack-name spike-prod-db-backups \
     --template-file aws/prod-db-backups.yaml --capabilities CAPABILITY_NAMED_IAM
   aws iam create-access-key --user-name spike-prod-db-backup   # secret is shown once
   ```
2. **DR key**, on your own machine: `age-keygen`. Put the `AGE-SECRET-KEY-1…` line in the password
   manager and delete the file. Keep the `age1…` public key for the next step.
3. **The box**, as root, from a checkout of this repo:
   ```bash
   apt-get install -y age
   install -d -m 700 /etc/spike-backup
   age-keygen -o /etc/spike-backup/restore-test.key
   { echo "<DR public key age1…>"; age-keygen -y /etc/spike-backup/restore-test.key; } \
     > /etc/spike-backup/recipients.txt
   cat > /etc/spike-backup/backup.env <<'EOF'
   S3_BUCKET=spike-prod-db-backups-058264239816
   AWS_ACCESS_KEY_ID=<from step 1>
   AWS_SECRET_ACCESS_KEY=<from step 1>
   AWS_REGION=eu-west-2
   AGE_RECIPIENTS=/etc/spike-backup/recipients.txt
   AGE_IDENTITY=/etc/spike-backup/restore-test.key
   EOF
   chmod 600 /etc/spike-backup/*
   install -m 0755 provisioning/scripts/spike-backup.sh /usr/local/sbin/spike-backup.sh
   install -m 0644 provisioning/systemd/spike-db-{backup,restore-test}.{service,timer} /etc/systemd/system/
   systemctl daemon-reload
   systemctl start spike-db-backup.service spike-db-restore-test.service   # one real run of each
   journalctl -u spike-db-backup -u spike-db-restore-test -n 5 --no-pager
   systemctl enable --now spike-db-backup.timer spike-db-restore-test.timer
   ```
4. **Monitoring box**: deploy `backup-alerts.yml` like any other rule file (monitoring repo README).

## Checking on it

```bash
systemctl list-timers 'spike-db-*'
journalctl -u spike-db-backup -n 3 --no-pager    # "uploaded hourly/… N databases, N rows, N bytes"
cat /var/lib/node_exporter/spike_backup*.prom
```

`spike_backup_database_rows{database="…"}` in Grafana shows every database's size over time. A
sudden drop is worth a look while the archives from before it still exist.

## Restore

The plaintext is production data, including children's personal data. Work in tmpfs
(`/dev/shm`) and delete the files when you're done.

### 1. Fetch and decrypt an archive

Any machine with AWS read access and the DR key:

```bash
aws s3 ls --region eu-west-2 s3://spike-prod-db-backups-058264239816/hourly/
aws s3 cp --region eu-west-2 s3://spike-prod-db-backups-058264239816/hourly/spike-prod-<ts>.tar.age .
age -d -i <DR key file> spike-prod-<ts>.tar.age | tar -xf -
cd spike-prod-<ts>    # globals.sql  db/<database>.dump  manifest.tsv  meta.txt  config.tar
```

On the prod box itself, the backup user and the restore-test key can do the same:

```bash
set -a; . /etc/spike-backup/backup.env; set +a; cd "$(mktemp -d /dev/shm/restore.XXXXXX)"
docker run --rm --network host -v "$PWD:/work" -w /work -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
  -e AWS_REGION amazon/aws-cli:2.37.3 s3 cp "s3://$S3_BUCKET/hourly/spike-prod-<ts>.tar.age" .
age -d -i "$AGE_IDENTITY" spike-prod-<ts>.tar.age | tar -xf -
```

`meta.txt` records the Postgres image and version the archive came from. Restore into the same
major version.

### 2a. Read old rows without touching production

```bash
docker run -d --name spike-restore --network none -e POSTGRES_USER=volleyer_user \
  -e POSTGRES_PASSWORD=unused postgres:15-alpine
until docker exec spike-restore pg_isready -q -h 127.0.0.1; do sleep 1; done
grep -vx 'CREATE ROLE volleyer_user;' globals.sql |
  docker exec -i spike-restore psql -U volleyer_user -d postgres -v ON_ERROR_STOP=1
docker exec -i spike-restore pg_restore -U volleyer_user --exit-on-error --create -d postgres < db/events.dump
docker exec -it spike-restore psql -U volleyer_user -d events
docker rm -f spike-restore
```

### 2b. Put one database back on production

First take a fresh backup, so the state you are about to replace is kept too:
`systemctl start spike-db-backup.service`.

If only a few rows are wrong, don't replace the database. Restore it next to the live one and copy
the rows across:

```bash
docker exec volleyspike-postgres-1 createdb -U volleyer_user events_restored
docker exec -i volleyspike-postgres-1 pg_restore -U volleyer_user --exit-on-error -d events_restored < db/events.dump
```

To replace a whole database, for example after a bad migration: stop its service, then

```bash
docker exec volleyspike-postgres-1 psql -U volleyer_user -d postgres -c 'DROP DATABASE events WITH (FORCE)'
docker exec -i volleyspike-postgres-1 pg_restore -U volleyer_user --exit-on-error --create -d postgres < db/events.dump
```

and recreate the service with the full compose invocation (`--env-file .env --env-file .env.tags`).
Every write since the archive is lost for that database. Other services keep their own copies of
some of its data (user identities, club membership, event references), which may now be newer than
it. Replay the relevant republish jobs, such as `UserIdentityRepublishJob` for auth, rather than
editing the copies by hand.

### 2c. Rebuild everything on a new box

1. Provision the box per `README.md` up to, but **not** including, `setup.sh`.
2. Extract `config.tar` into `/opt/volleyspike` (`tar -xpf config.tar -C /opt/volleyspike`). It
   replaces `setup.sh`: the env files, compose files and Caddy certificate come back as they were.
   Then `chown -R deploy:deploy /opt/volleyspike`.
3. Start only Postgres: `export GITHUB_REPOSITORY_OWNER=spike-volleyball`, then
   `docker compose -f docker-compose.yml -f docker-compose.production.yml --env-file .env --env-file .env.tags up -d postgres`.
4. Restore roles and databases. The init script has already created empty service databases, and
   the container has created `volleyer_user`, so drop the one and skip the other:
   ```bash
   grep -vx 'CREATE ROLE volleyer_user;' globals.sql |
     docker exec -i volleyspike-postgres-1 psql -U volleyer_user -d postgres -v ON_ERROR_STOP=1
   for dump in db/*.dump; do
     db=$(basename "$dump" .dump)
     [ "$db" = postgres ] && continue
     docker exec volleyspike-postgres-1 psql -U volleyer_user -d postgres -c "DROP DATABASE IF EXISTS \"$db\"" &&
     docker exec -i volleyspike-postgres-1 pg_restore -U volleyer_user --exit-on-error --create -d postgres < "$dump" ||
     { echo "FAILED on $db"; break; }
   done
   ```
5. Start the rest of the stack, check `/<service>/health` through the gateway, and compare a few
   tables with `manifest.tsv`.
6. Install backups again (above). Use a new restore-test key, but keep the same bucket and DR key.

Host-level setup (WireGuard, nftables, the security-sweep crontab) is not in the archive. It comes
from `bootstrap.sh` and this repo.

## Retention and erasure

Hourly archives expire after 2 days and dailies after 35. S3 lifecycle then removes the expired
versions within about two more days. Data a user deletes is therefore gone from every backup within
about five weeks, which is the "limited period" the privacy policy promises. Compliance mode means
nobody can delete an archive earlier, not even to honour an erasure request, so keep retention
short. If an old archive is ever restored, re-apply any account deletions made since it was taken.
