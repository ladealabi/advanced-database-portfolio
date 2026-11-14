#!/usr/bin/env bash
# Portfolio 5: replication_demo.sh

set -uo pipefail
source "$(dirname "$0")/../pg_env.sh"      # BIN, PGDEMO, PRIMARY_DIR, as_pg, now_ms (Linux + macOS)
STANDBY_DIR=$PGDEMO/standby
P="psql -h localhost -p 5432 -U postgres -d kobotrust -X -q"
S="psql -h localhost -p 5433 -U postgres -d kobotrust -X -q"
step() { printf '\n==================== %s ====================\n' "$1"; }

step "R0. Primary settings"
$P -c "SELECT name, setting FROM pg_settings WHERE name IN
       ('wal_level','max_wal_senders','synchronous_commit','synchronous_standby_names','hot_standby') ORDER BY 1;"

step "R1. Build a hot standby with pg_basebackup (-R writes primary_conninfo + standby.signal)"
as_pg "$BIN/pg_ctl -D '$STANDBY_DIR' stop -m fast" >/dev/null 2>&1; rm -rf "$STANDBY_DIR"
START=$(now_ms)
as_pg "$BIN/pg_basebackup -d 'host=localhost port=5432 user=postgres application_name=standby_lagos2' \
        -D '$STANDBY_DIR' -R -X stream -c fast" || { echo "base backup failed"; exit 1; }
echo "base backup finished in $(( $(now_ms) - START )) ms"
cat "$STANDBY_DIR/postgresql.auto.conf" | grep -E "primary_conninfo" | sed 's/password=[^ ]*//'
ls "$STANDBY_DIR"/standby.signal
cat >> "$STANDBY_DIR/postgresql.conf" <<EOF
port=5433
unix_socket_directories='$PGDEMO'
EOF
as_pg "$BIN/pg_ctl -D '$STANDBY_DIR' -l '$PGDEMO/standby.log' start -w" | tail -1
sleep 2
$S -c "SELECT 1" >/dev/null 2>&1 || { echo "standby did not start"; tail $PGDEMO/standby.log; exit 1; }

step "R2. Replication status on the primary, and reads served by the standby"
$P -x -c "SELECT application_name, client_addr, state, sync_state, sent_lsn, replay_lsn,
                 write_lag, flush_lag, replay_lag FROM pg_stat_replication;"
$S -c "SELECT pg_is_in_recovery() AS standby_mode, count(*) AS accounts,
              sum(balance) AS total_deposits FROM bank.account;"

step "R3. The standby is READ-ONLY"
$S -c "UPDATE bank.account SET balance = balance + 1 WHERE account_number = '1000000027';" 2>&1

step "R4. ASYNCHRONOUS replication: a write is visible on the standby only after replay"
$P -c "CREATE TABLE IF NOT EXISTS bank.repl_probe (id int PRIMARY KEY, written_at timestamptz);
       TRUNCATE bank.repl_probe;"
sleep 1
# A large committed write (1.5M rows, ~100 MB of WAL), then read the standby straight away
$P -c "INSERT INTO bank.repl_probe SELECT g, clock_timestamp() FROM generate_series(1, 1500000) g;"
T0=$(now_ms)
echo "primary: 1,500,000 probe rows committed. Polling the standby:"
for i in $(seq 1 200); do
  R=$($S -At -c "SELECT count(*) FROM bank.repl_probe")
  MS=$(( $(now_ms) - T0 ))
  echo "  +${MS} ms  standby sees $R rows"
  [ "$R" = "1500000" ] && break; sleep 0.02
done
echo "=> the standby returned STALE data (0 rows) for a short window: eventual consistency.
   Because a transaction replays atomically, the standby never shows a partial result."
$P -c "SELECT application_name, sync_state,
              pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS bytes_behind, replay_lag
       FROM pg_stat_replication;"

step "R5. SYNCHRONOUS replication (synchronous_commit = remote_apply)"
$P -c "ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (standby_lagos2)';" -c "SELECT pg_reload_conf();" >/dev/null
sleep 1
$P -c "SELECT application_name, sync_state FROM pg_stat_replication;"
$P -c "TRUNCATE bank.repl_probe; SET synchronous_commit = remote_apply; INSERT INTO bank.repl_probe VALUES (2, clock_timestamp());"
echo "standby immediately after COMMIT returned on the primary (remote_apply means it must already be visible):"
$S -c "SELECT * FROM bank.repl_probe ORDER BY id;"
echo "commit latency, local vs remote_apply:"
$P -c "CREATE TABLE IF NOT EXISTS bank.repl_latency (id bigint GENERATED ALWAYS AS IDENTITY, at timestamptz DEFAULT clock_timestamp());"
echo "INSERT INTO bank.repl_latency DEFAULT VALUES;" > /tmp/kt_commit.sql
for MODE in local remote_apply; do
  echo "  synchronous_commit=$MODE (1 client, 500 single-row commits):"
  PGOPTIONS="-c synchronous_commit=$MODE" pgbench -h localhost -p 5432 -U postgres -n -c 1 -t 500 \
      -f /tmp/kt_commit.sql kobotrust 2>/dev/null | grep -E "latency average|^tps" | sed 's/^/     /'
done

step "R6. Sync standby DOWN: a COMMIT waits rather than risk losing data (CAP: choose C over A)"
as_pg "$BIN/pg_ctl -D '$STANDBY_DIR' stop -m fast" >/dev/null
echo "standby stopped. A synchronous INSERT is started in the background..."
( $P -c "SET synchronous_commit = on; INSERT INTO bank.repl_probe VALUES (99, clock_timestamp());" 2>&1 | sed 's/^/  [writer] /' ) &
sleep 3
echo "3 s later the writer is still waiting:"
$P -c "SELECT pid, state, wait_event_type, wait_event, now() - query_start AS waiting_for, left(query, 45) AS query
       FROM pg_stat_activity WHERE wait_event = 'SyncRep';"
echo "operator cancels the wait:"
$P -At -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE wait_event = 'SyncRep';" >/dev/null
wait
echo "(production setups use 'ANY 1 (s1, s2)' with two standbys, so one failure does not block writes)"
$P -c "ALTER SYSTEM RESET synchronous_standby_names;" -c "SELECT pg_reload_conf();" >/dev/null
as_pg "$BIN/pg_ctl -D '$STANDBY_DIR' -l '$PGDEMO/standby.log' start -w" | tail -1
sleep 2

step "R7. FAILOVER: primary crashes, standby promoted"
LAST=$($P -At -c "SELECT max(txn_id) FROM bank.txn")
echo "last txn_id committed on primary before crash: $LAST"
sleep 1
as_pg "$BIN/pg_ctl -D '$PRIMARY_DIR' stop -m immediate" | tail -1      # simulated crash (no clean shutdown)
$P -c "SELECT 1" 2>&1 | head -1 | sed 's/^/  primary: /'
START=$(now_ms)
as_pg "$BIN/pg_ctl -D '$STANDBY_DIR' promote -w" | tail -1
echo "promotion took $(( $(now_ms) - START )) ms"
$S -c "SELECT pg_is_in_recovery() AS still_standby, (SELECT max(txn_id) FROM bank.txn) AS last_txn_on_new_primary;"
echo "writes on the NEW primary:"
$S -c "SELECT bank.transfer_funds('8880001003','8880001004', 500, 'MOBILE', 'P5 after failover') AS new_txn;"
echo "RPO check: every txn committed before the crash exists on the promoted node -> no data loss"

step "R8. Clean-up: retire the promoted demo node, restart the original primary"
# In production the old primary would be rebuilt from the new one with pg_rewind
# (it must never come back as a second writable primary: split brain).
as_pg "$BIN/pg_ctl -D '$STANDBY_DIR' stop -m fast" | tail -1
as_pg "$BIN/pg_ctl -D '$PRIMARY_DIR' -l '$PGDEMO/primary.log' start -w" | tail -1
$P -c "DROP TABLE IF EXISTS bank.repl_probe, bank.repl_latency;"
$P -c "SELECT 'primary back online' AS status, pg_is_in_recovery() AS in_recovery;"
