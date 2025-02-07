#! /bin/sh

set -u
set -o pipefail

source ./env.sh

(
  set -e

  function log() {
    echo "$1" 
  }

  function try_backup() {
    log "Creating backup of $POSTGRES_DATABASE database..." 
    pg_dump --format=custom \
            -h $POSTGRES_HOST \
            -p $POSTGRES_PORT \
            -U $POSTGRES_USER \
            -d $POSTGRES_DATABASE \
            $PGDUMP_EXTRA_OPTS \
            > db.dump

    timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
    s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}/${POSTGRES_DATABASE}_${timestamp}.dump"

    if [ -n "$PASSPHRASE" ]; then
      log "Encrypting backup..."
      rm -f db.dump.gpg
      gpg --symmetric --batch --passphrase "$PASSPHRASE" db.dump
      rm db.dump
      local_file="db.dump.gpg"
      s3_uri="${s3_uri_base}.gpg"
    else
      local_file="db.dump"
      s3_uri="$s3_uri_base"
    fi

    log "Uploading backup to $S3_BUCKET..."
    aws $aws_args s3 cp "$local_file" "$s3_uri"
    log "Uploaded dump file to $s3_uri"
    rm "$local_file"

    log "Backup complete."

    if [ -n "$BACKUP_KEEP_DAYS" ]; then
      sec=$((86400*BACKUP_KEEP_DAYS))
      date_from_remove=$(date -d "@$(($(date +%s) - sec))" +%Y-%m-%d)
      backups_query="Contents[?LastModified<='${date_from_remove} 00:00:00'].{Key: Key}"

      log "Removing old backups from $S3_BUCKET..."
      aws $aws_args s3api list-objects \
        --bucket "${S3_BUCKET}" \
        --prefix "${S3_PREFIX}" \
        --query "${backups_query}" \
        --output text \
        | xargs -n1 -t -I 'KEY' aws $aws_args s3 rm s3://"${S3_BUCKET}"/'KEY'
      log "Removal complete."
    fi
  }
  try_backup 

)

if [ -f "log.txt" ]; then
  OUTPUT=$(cat log.txt)
  rm log.txt
else
  OUTPUT="No Log" 
fi


if [ $? -ne 0 ]; then
  RESULT="failed"
else
  RESULT="success"
fi

echo $OUTPUT

if [ -n "$NOTIFICATION_URL" ]; then
  python3 -c "import requests; requests.post('$NOTIFICATION_URL', json={'message': '$OUTPUT', 'result': '$RESULT'})"
fi

