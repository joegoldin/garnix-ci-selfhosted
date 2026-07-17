{ pkgs
, migrate
, postgres
}:
with pkgs;
writeShellScriptBin "db" ''
  set -eu
  set -o pipefail

  usage () {
    echo " db [new|copy|backup|clear]"
  }

  clear-db () {
    echo "Stopping postgres"
    ${postgres}/bin/pg_ctl stop
    echo "Clearing db"
    rm -rf "$PGDATA"
  }

  create-db () {
    echo "Creating DB"
    if ! [[ -d $PGDATA ]]; then
      ${postgres}/bin/pg_ctl initdb
      echo "unix_socket_directories = '$PGHOST'" >> "$PGDATA/postgresql.conf"
      echo "logging_collector = on" >> "$PGDATA/postgresql.conf"
      echo "log_statement = all" >> "$PGDATA/postgresql.conf"
      echo "listen_addresses = '''" >> "$PGDATA/postgresql.conf"
      # postgresql-typed only speaks md5 auth (not scram), so store role
      # passwords as md5. Must be set before the ALTER ROLE below hashes the
      # garnix password.
      echo "password_encryption = md5" >> "$PGDATA/postgresql.conf"
    fi

    ${postgres}/bin/pg_ctl stop || echo "Starting pg_ctl"

    ${postgres}/bin/pg_ctl \
      -o "-F -p $PGPORT" \
      start

    PGUSER= PGPASSWORD= ${postgres}/bin/createuser \
      "$PGUSER" \
      --createdb \
      -p $PGPORT || echo "Not creating user"

    PGUSER= PGPASSWORD= ${postgres}/bin/createuser \
      "monitoring" \
      -p $PGPORT || echo "Not creating user"

    PGUSER= PGPASSWORD= ${postgres}/bin/createdb \
      --owner="$PGUSER" \
      "$PGDATABASE" \
      -p $PGPORT || echo "Not creating DB"

    PGUSER= PGPASSWORD= ${postgres}/bin/psql \
      "$PGDATABASE" \
      -c "ALTER ROLE \"$PGUSER\" WITH LOGIN PASSWORD '$PGPASSWORD'" \
      -p $PGPORT || echo "Not adding password"

    # Require a password for the garnix role. initdb defaults local connections
    # to trust, which accepts any password and defeats getDBConnection's
    # auth-failure handling (and hides real password bugs). Other roles keep
    # trust so the passwordless bootstrap superuser and the monitoring role
    # still connect.
    printf 'local all %s md5\n%s\n' "$PGUSER" "$(cat "$PGDATA/pg_hba.conf")" > "$PGDATA/pg_hba.conf.tmp"
    mv "$PGDATA/pg_hba.conf.tmp" "$PGDATA/pg_hba.conf"
    ${postgres}/bin/pg_ctl reload

    export PATH=${postgres}/bin:$PATH
  }

  apply-migrations () {
    echo "Applying migrations"
    SQITCH_USERNAME=$PGUSER ${migrate}/bin/sqitch deploy --verify "db:pg:$PGDATABASE"
  }

  copy-db () {
    TMP_FILE=$(mktemp --tmpdir garnix-dump.sql.XXXXXX)
    ssh root@db.garnix.io "sudo -u garnix pg_dump garnix --port 9178 | bzip2" > $TMP_FILE
    bzcat $TMP_FILE | psql
  }

  backup () {
    FILE="backup-$(date +"%Y-%m-%d-%H:%M").sql"
    ssh root@db.garnix.io "sudo -u garnix pg_dump garnix --port 9178 | bzip2" > $FILE
  }

  new () {
    create-db
    apply-migrations
  }

  copy () {
    clear-db
    create-db
    copy-db
  }

  command=$1; shift

  case "$command" in
    create) create-db ;;
    new) new ;;
    clear) clear-db ;;
    copy) copy ;;
    backup) backup ;;
    *) usage ;;
  esac
''
