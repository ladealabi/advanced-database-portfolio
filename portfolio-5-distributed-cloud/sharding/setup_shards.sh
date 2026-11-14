#!/usr/bin/env bash
# Portfolio 5: setup_shards.sh

set -euo pipefail
source "$(dirname "$0")/../pg_env.sh"      # BIN, PGDEMO, as_pg (Linux + macOS)
for spec in "south:5434" "north:5435"; do
  NAME=${spec%%:*}; PORT=${spec##*:}; DIR=$PGDEMO/shard_$NAME
  as_pg "$BIN/pg_ctl -D '$DIR' stop -m fast" >/dev/null 2>&1 || true
  rm -rf "$DIR"
  as_pg "$BIN/initdb -D '$DIR' -A trust -U postgres" >/dev/null
  cat >> "$DIR/postgresql.conf" <<EOF
port=$PORT
listen_addresses='localhost'
unix_socket_directories='$PGDEMO'
max_prepared_transactions=20
cluster_name='shard_$NAME'
EOF
  as_pg "$BIN/pg_ctl -D '$DIR' -l '$PGDEMO/shard_$NAME.log' start -w" >/dev/null
  psql -h localhost -p "$PORT" -U postgres -d postgres -X -q -c "CREATE DATABASE kobotrust_$NAME;"
  psql -h localhost -p "$PORT" -U postgres -X -q -d "kobotrust_$NAME" <<'EOF'
CREATE SCHEMA bank;
-- identical table definitions on every shard; region is the SHARD KEY
CREATE TABLE bank.account (
    account_number CHAR(10) PRIMARY KEY,
    customer_id    INT          NOT NULL,
    region         VARCHAR(10)  NOT NULL,
    branch_code    CHAR(5)      NOT NULL,
    type_code      VARCHAR(10)  NOT NULL,
    balance        NUMERIC(18,2) NOT NULL CHECK (balance >= 0),
    status         VARCHAR(10)  NOT NULL);
CREATE TABLE bank.ledger_entry (
    entry_id       BIGINT       PRIMARY KEY,         -- global id assigned by the coordinator
    account_number CHAR(10)     NOT NULL REFERENCES bank.account,
    region         VARCHAR(10)  NOT NULL,
    txn_ref        UUID         NOT NULL,
    direction      CHAR(1)      NOT NULL,
    amount         NUMERIC(18,2) NOT NULL,
    created_at     TIMESTAMPTZ  NOT NULL);
CREATE INDEX ON bank.ledger_entry (account_number, created_at);
EOF
  echo "shard_$NAME up on port $PORT ($(psql -h localhost -p "$PORT" -U postgres -d postgres -At -c 'show max_prepared_transactions') prepared-xact slots)"
done
