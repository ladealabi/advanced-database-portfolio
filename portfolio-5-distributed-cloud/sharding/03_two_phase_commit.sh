#!/usr/bin/env bash
# Portfolio 5: 03_two_phase_commit.sh
# Usage: ./03_two_phase_commit.sh | tee ../evidence/two_phase_commit_output.txt

set -uo pipefail
SOUTH="psql -h localhost -p 5434 -U postgres -d kobotrust_south -X -q -v ON_ERROR_STOP=1"
NORTH="psql -h localhost -p 5435 -U postgres -d kobotrust_north -X -q -v ON_ERROR_STOP=1"
SRC=$($SOUTH -At -c "SELECT account_number FROM bank.account WHERE status='ACTIVE' ORDER BY account_number LIMIT 1")
DST=$($NORTH -At -c "SELECT account_number FROM bank.account WHERE status='ACTIVE' ORDER BY account_number LIMIT 1")
bal() { echo "  SOUTH $SRC = $($SOUTH -At -c "SELECT balance FROM bank.account WHERE account_number='$SRC'")   |   NORTH $DST = $($NORTH -At -c "SELECT balance FROM bank.account WHERE account_number='$DST'")"; }
hdr() { printf '\n==================== %s ====================\n' "$1"; }

# phase-1 helpers: each shard does its local work and then PREPAREs (votes)
prepare_debit()  { $SOUTH -c "BEGIN;
   UPDATE bank.account SET balance = balance - $2 WHERE account_number = '$SRC';
   INSERT INTO bank.ledger_entry VALUES (nextval('xid_seq'), '$SRC', 'SOUTH', '$1', 'D', $2, clock_timestamp());
   PREPARE TRANSACTION '$1';" 2>&1; }
prepare_credit() { $NORTH -c "BEGIN;
   UPDATE bank.account SET balance = balance + $2 WHERE account_number = '$DST';
   INSERT INTO bank.ledger_entry VALUES (nextval('xid_seq'), '$DST', 'NORTH', '$1', 'C', $2, clock_timestamp());
   PREPARE TRANSACTION '$1';" 2>&1; }
# distinct global id ranges per shard for the demo postings
$SOUTH -c "CREATE SEQUENCE IF NOT EXISTS xid_seq START 9000000000;" 2>/dev/null
$NORTH -c "CREATE SEQUENCE IF NOT EXISTS xid_seq START 9500000000;" 2>/dev/null

hdr "Before"
bal

hdr "A. Happy path: both shards vote YES, then COMMIT PREPARED"
G=$(python3 -c "import uuid; print(uuid.uuid4())")
echo "global transaction id: $G"
echo "phase 1 / SOUTH:"; prepare_debit  "$G" 5000 | sed 's/^/  /'
echo "phase 1 / NORTH:"; prepare_credit "$G" 5000 | sed 's/^/  /'
echo "in-doubt transactions waiting for the decision:"
$SOUTH -c "SELECT gid, prepared, database FROM pg_prepared_xacts;"
$NORTH -c "SELECT gid, prepared, database FROM pg_prepared_xacts;"
echo "both voted YES, so phase 2: COMMIT PREPARED on both"
$SOUTH -c "COMMIT PREPARED '$G';"; $NORTH -c "COMMIT PREPARED '$G';"
bal

hdr "B. A shard votes NO: the debit would overdraw, so PREPARE never happens and the global txn is ROLLED BACK"
G=$(python3 -c "import uuid; print(uuid.uuid4())")
echo "phase 1 / NORTH (credit first this time):"; prepare_credit "$G" 999999999 | sed 's/^/  /'
echo "phase 1 / SOUTH:"; prepare_debit "$G" 999999999 | sed 's/^/  /'
echo "SOUTH voted NO, so the coordinator sends ROLLBACK PREPARED to every shard that voted YES"
$NORTH -c "ROLLBACK PREPARED '$G';"
bal
echo "  (balances unchanged on BOTH shards: atomicity across servers)"

hdr "C. Coordinator crashes AFTER phase 1 (the blocking weakness of 2PC)"
G=$(python3 -c "import uuid; print(uuid.uuid4())")
prepare_debit "$G" 1000 >/dev/null; prepare_credit "$G" 1000 >/dev/null
echo "both shards PREPARED... coordinator crashes before sending COMMIT. Some time later:"
$SOUTH -c "SELECT gid, prepared FROM pg_prepared_xacts;"
echo "the prepared txn still holds its row lock. A customer's normal debit on SOUTH now waits:"
$SOUTH -c "SET lock_timeout = '2s'; UPDATE bank.account SET balance = balance - 1 WHERE account_number = '$SRC';" 2>&1 | sed 's/^/  /'
echo "recovery: the coordinator restarts, reads its decision log (it had decided COMMIT), and finishes phase 2:"
$SOUTH -c "COMMIT PREPARED '$G';"; $NORTH -c "COMMIT PREPARED '$G';"
$SOUTH -c "SELECT count(*) AS in_doubt_left FROM pg_prepared_xacts;"
bal

hdr "Global invariant: SOUTH debits = NORTH credits for every 2PC transaction"
$SOUTH -At -c "SELECT txn_ref, amount FROM bank.ledger_entry WHERE entry_id >= 9000000000 ORDER BY 1" > /tmp/kt_s.txt
$NORTH -At -c "SELECT txn_ref, amount FROM bank.ledger_entry WHERE entry_id >= 9500000000 ORDER BY 1" > /tmp/kt_n.txt
echo "SOUTH debit legs: $(wc -l < /tmp/kt_s.txt), NORTH credit legs: $(wc -l < /tmp/kt_n.txt)"
diff /tmp/kt_s.txt /tmp/kt_n.txt >/dev/null && echo "MATCH: every cross-shard transfer is on both shards with the same amount"
