#!/usr/bin/env bash
# Production database backups (SPI-5748). Design and restore runbook: provisioning/BACKUPS.md.
#
#   spike-backup.sh backup                   dump every database, encrypt, upload to S3
#   spike-backup.sh restore-test [archive]   restore the newest hourly backup (or a local
#                                            .tar.age) into a throwaway Postgres and check
#                                            every table's row count against the manifest
#
# Plaintext only ever exists on tmpfs: the archive is encrypted before it touches disk or S3.
set -euo pipefail
umask 077

# Exported so the aws-cli container can inherit the AWS_* values by name.
set -a
# shellcheck source=/dev/null
. "${SPIKE_BACKUP_CONFIG:-/etc/spike-backup/backup.env}"
set +a
: "${S3_BUCKET:?}" "${AWS_ACCESS_KEY_ID:?}" "${AWS_SECRET_ACCESS_KEY:?}" "${AWS_REGION:?}"
: "${AGE_RECIPIENTS:?}" "${AGE_IDENTITY:?}"
PG_CONTAINER=${PG_CONTAINER:-volleyspike-postgres-1}
DEPLOY_PATH=${DEPLOY_PATH:-/opt/volleyspike}
TEXTFILE_DIR=${TEXTFILE_DIR:-/var/lib/node_exporter}
STATE_DIR=${STATE_DIRECTORY:-/var/lib/spike-backup}
AWS_CLI_IMAGE=amazon/aws-cli:2.37.3@sha256:83f8ffe939569070c5b66d22231862ab78718766d9d8e4c44ca84dd0be5569a5

# Hourly archives fall under the bucket's default Object Lock retention (2 days); the first
# archive of each UTC day is also written under daily/ and locked for this long.
DAILY_RETENTION_DAYS=35

# Every ordinary table with its exact row count, named the way pg_dump names it in COPY lines.
ROW_COUNTS_SQL="SELECT format('%I.%I', n.nspname, c.relname),
  (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname), false, true, '')))[1]::text
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY 1"

WORK=""
CONTAINER=""
cleanup() {
  [ -z "$CONTAINER" ] || docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
  [ -z "$WORK" ] || rm -rf -- "$WORK"
}
trap cleanup EXIT
WORK=$(mktemp -d "${RUNTIME_DIRECTORY:-/dev/shm}/spike-backup.XXXXXX")

aws_cli() {
  docker run --rm --network host -v "$WORK:/work" -w /work \
    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_REGION -e AWS_ENDPOINT_URL \
    "$AWS_CLI_IMAGE" "$@"
}

# Rows per table as stored in a custom-format dump: each table's data is one COPY block with
# one line per row (COPY text format escapes embedded newlines), ended by a "\." line.
dump_row_counts() {
  docker exec -i "$PG_CONTAINER" pg_restore --data-only -f - < "$1" |
    awk 't == "" && /^COPY /{ t = $2; n = 0; next }
         t != "" && /^\\\.$/{ print t "\t" n; t = ""; next }
         t != ""{ n++ }'
}

# node-exporter's textfile collector only reads *.prom, so the temp name is never half-read.
# It runs as nobody, and this script's umask would leave the file unreadable to it.
write_metrics() {
  cat > "$TEXTFILE_DIR/.$1.tmp"
  chmod 644 "$TEXTFILE_DIR/.$1.tmp"
  mv "$TEXTFILE_DIR/.$1.tmp" "$TEXTFILE_DIR/$1"
}

backup() {
  local started name dir pg_user db daily_key
  started=$(date +%s)
  name=spike-prod-$(date -u -d "@$started" +%Y%m%dT%H%M%SZ)
  dir=$WORK/$name
  mkdir -p "$dir/db"

  pg_user=$(docker exec "$PG_CONTAINER" printenv POSTGRES_USER)
  local -a dbs
  mapfile -t dbs < <(docker exec "$PG_CONTAINER" psql -U "$pg_user" -X -At -d postgres \
    -c "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY 1")
  [ "${#dbs[@]}" -gt 0 ] || { echo "no databases found in $PG_CONTAINER" >&2; exit 1; }

  # Per-database dumps never include roles, and several exist only in the live cluster.
  docker exec "$PG_CONTAINER" pg_dumpall -U "$pg_user" --globals-only > "$dir/globals.sql"
  for db in "${dbs[@]}"; do
    docker exec "$PG_CONTAINER" pg_dump -U "$pg_user" -Fc --lock-wait-timeout=60s -d "$db" \
      > "$dir/db/$db.dump"
  done

  for db in "${dbs[@]}"; do
    dump_row_counts "$dir/db/$db.dump" | awk -v db="$db" '{ print db "\t" $0 }'
  done | LC_ALL=C sort > "$dir/manifest.tsv"

  # A restored database cannot be booted without the host-local env files and setup.sh.
  tar -C "$DEPLOY_PATH" --exclude=./backups --exclude=./migrations -cf "$dir/config.tar" .

  {
    echo "created_at=$started"
    echo "host=$(hostname)"
    echo "postgres_image=$(docker inspect -f '{{.Config.Image}}' "$PG_CONTAINER")"
    echo "server_version=$(docker exec "$PG_CONTAINER" psql -U "$pg_user" -X -At -d postgres -c 'SHOW server_version')"
  } > "$dir/meta.txt"

  tar -C "$WORK" -cf - "$name" | age -R "$AGE_RECIPIENTS" -o "$WORK/$name.tar.age"

  aws_cli s3api put-object --bucket "$S3_BUCKET" --key "hourly/$name.tar.age" \
    --body "$name.tar.age" --checksum-algorithm SHA256 > /dev/null
  daily_key=""
  mkdir -p "$STATE_DIR"
  if [ "$(cat "$STATE_DIR/last-daily" 2> /dev/null)" != "$(date -u -d "@$started" +%F)" ]; then
    daily_key="daily/$name.tar.age"
    aws_cli s3api put-object --bucket "$S3_BUCKET" --key "$daily_key" \
      --body "$name.tar.age" --checksum-algorithm SHA256 \
      --object-lock-mode COMPLIANCE \
      --object-lock-retain-until-date "$(date -u -d "+$DAILY_RETENTION_DAYS days" +%Y-%m-%dT%H:%M:%SZ)" \
      > /dev/null
    date -u -d "@$started" +%F > "$STATE_DIR/last-daily"
  fi

  local size finished
  size=$(stat -c %s "$WORK/$name.tar.age")
  finished=$(date +%s)
  {
    echo "# HELP spike_backup_last_success_timestamp_seconds When the newest backup reached S3."
    echo "# TYPE spike_backup_last_success_timestamp_seconds gauge"
    echo "spike_backup_last_success_timestamp_seconds $finished"
    echo "# HELP spike_backup_last_size_bytes Size of the newest encrypted archive."
    echo "# TYPE spike_backup_last_size_bytes gauge"
    echo "spike_backup_last_size_bytes $size"
    echo "# HELP spike_backup_last_duration_seconds How long the newest backup took."
    echo "# TYPE spike_backup_last_duration_seconds gauge"
    echo "spike_backup_last_duration_seconds $((finished - started))"
    echo "# HELP spike_backup_database_rows Rows per database in the newest backup."
    echo "# TYPE spike_backup_database_rows gauge"
    awk -F '\t' '{ rows[$1] += $3 } END { for (db in rows) printf "spike_backup_database_rows{database=\"%s\"} %d\n", db, rows[db] }' \
      "$dir/manifest.tsv" | LC_ALL=C sort
  } | write_metrics spike_backup.prom

  echo "uploaded hourly/$name.tar.age${daily_key:+ and $daily_key}: ${#dbs[@]} databases," \
    "$(awk -F '\t' '{ n += $3 } END { print n }' "$dir/manifest.tsv") rows, $size bytes"
}

restore_test() {
  local archive=${1:-} key="" started dir db
  started=$(date +%s)
  if [ -z "$archive" ]; then
    key=$(aws_cli s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix hourly/ \
      --query 'sort_by(Contents, &Key)[-1].Key' --output text)
    case "$key" in hourly/*) ;; *) echo "no hourly backups in s3://$S3_BUCKET" >&2; exit 1 ;; esac
    aws_cli s3api get-object --bucket "$S3_BUCKET" --key "$key" archive.tar.age > /dev/null
    archive=$WORK/archive.tar.age
  fi
  age -d -i "$AGE_IDENTITY" "$archive" | tar -C "$WORK" -xf -
  dir=$(find "$WORK" -mindepth 1 -maxdepth 1 -type d -name 'spike-prod-*')
  [ -n "$dir" ] || { echo "archive holds no spike-prod-* directory" >&2; exit 1; }
  tar -tf "$dir/config.tar" | grep -x './.env.common' > /dev/null ||
    { echo "config.tar has no .env.common" >&2; exit 1; }

  # Same image the live cluster runs, no network, data on tmpfs.
  CONTAINER=spike-restore-test-$$
  docker run -d --name "$CONTAINER" --network none \
    --tmpfs /var/lib/postgresql/data:rw,size=2g \
    -e POSTGRES_USER=restore_admin -e POSTGRES_HOST_AUTH_METHOD=trust \
    "$(docker inspect -f '{{.Image}}' "$PG_CONTAINER")" > /dev/null
  # Over TCP: the entrypoint's temporary init server listens on the socket only, so a
  # socket probe can succeed just before that server shuts down for the real start.
  local tries=0
  until docker exec "$CONTAINER" pg_isready -q -h 127.0.0.1 -U restore_admin; do
    tries=$((tries + 1))
    [ "$tries" -lt 60 ] || { echo "throwaway Postgres never became ready" >&2; exit 1; }
    sleep 1
  done

  docker exec -i "$CONTAINER" psql -U restore_admin -X -q -v ON_ERROR_STOP=1 -d postgres \
    < "$dir/globals.sql" > /dev/null
  for dump in "$dir"/db/*.dump; do
    db=$(basename "$dump" .dump)
    # "postgres" already exists in a fresh cluster; every other database is created from the dump.
    if [ "$db" = postgres ]; then
      docker exec -i "$CONTAINER" pg_restore -U restore_admin --exit-on-error -d postgres < "$dump"
    else
      docker exec -i "$CONTAINER" pg_restore -U restore_admin --exit-on-error --create -d postgres < "$dump"
    fi
  done

  for dump in "$dir"/db/*.dump; do
    db=$(basename "$dump" .dump)
    docker exec "$CONTAINER" psql -U restore_admin -X -At -F $'\t' -d "$db" -c "$ROW_COUNTS_SQL" |
      awk -v db="$db" '{ print db "\t" $0 }'
  done | LC_ALL=C sort > "$WORK/restored.tsv"
  if ! diff -u "$dir/manifest.tsv" "$WORK/restored.tsv"; then
    echo "restored row counts differ from the manifest" >&2
    exit 1
  fi

  local created rows finished
  created=$(sed -n 's/^created_at=//p' "$dir/meta.txt")
  rows=$(awk -F '\t' '{ n += $3 } END { print n }' "$WORK/restored.tsv")
  finished=$(date +%s)
  echo "restored $(basename "$dir") (${key:-$archive}): $(find "$dir/db" -name '*.dump' | wc -l) databases," \
    "$rows rows, all counts match; backup was $(((finished - created) / 60)) min old"

  # Only the scheduled check of the newest S3 backup speaks for the pipeline.
  [ -n "$key" ] || return 0
  {
    echo "# HELP spike_backup_restore_test_last_success_timestamp_seconds When a restore of the newest S3 backup last passed."
    echo "# TYPE spike_backup_restore_test_last_success_timestamp_seconds gauge"
    echo "spike_backup_restore_test_last_success_timestamp_seconds $finished"
    echo "# HELP spike_backup_restore_test_backup_age_seconds Age of the backup that restore last passed on, at test time."
    echo "# TYPE spike_backup_restore_test_backup_age_seconds gauge"
    echo "spike_backup_restore_test_backup_age_seconds $((finished - created))"
    echo "# HELP spike_backup_restore_test_rows Rows restored by the last passing restore test."
    echo "# TYPE spike_backup_restore_test_rows gauge"
    echo "spike_backup_restore_test_rows $rows"
    echo "# HELP spike_backup_restore_test_duration_seconds How long the last passing restore test took."
    echo "# TYPE spike_backup_restore_test_duration_seconds gauge"
    echo "spike_backup_restore_test_duration_seconds $((finished - started))"
  } | write_metrics spike_backup_restore_test.prom
}

case "${1:-}" in
  backup) backup ;;
  restore-test) restore_test "${2:-}" ;;
  *) echo "usage: $0 backup | restore-test [archive.tar.age]" >&2; exit 64 ;;
esac
