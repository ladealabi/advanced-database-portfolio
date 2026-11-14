#!/usr/bin/env bash
# Portfolio 4: redis_demo.sh   (KEY-VALUE model, Redis 7)
# Usage: PGHOST=localhost PGUSER=postgres ./redis_demo.sh | tee ../evidence/redis_demo_output.txt

set -uo pipefail
R="redis-cli --no-raw"   # formatted output for display
RV="redis-cli"            # raw output when a value is captured into a variable
PSQL="psql -d ${PGDATABASE:-kobotrust} -X -q -At"
say() { printf '\n=== %s ===\n' "$1"; }
run() { echo "redis> $*"; $R "$@"; }

$R FLUSHDB >/dev/null
echo "Redis server: $($R INFO server | grep redis_version | tr -d '\r')"

say "K1. Login session tokens with automatic expiry (SET ... EX)"
# Sessions are short-lived and read on every API call. A TTL removes them
# with no cleanup job, which a relational table would need.
TOKEN=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
run SET "session:$TOKEN" '{"customerId":2,"device":"android","kycTier":1}' EX 900
run GET "session:$TOKEN"
run TTL "session:$TOKEN"

say "K2. Idempotency keys: block duplicate transfer requests (SET NX)"
# The mobile app retries on timeout. SET NX is atomic: only the FIRST request
# with a given reference wins; the retry gets (nil) and is not processed again.
REF="txn-ref-$(date +%s)"
run SET "idem:$REF" processing NX EX 86400
run SET "idem:$REF" processing NX EX 86400
echo "-> second SET returned (nil), so the duplicate is rejected before it reaches PostgreSQL"

say "K3. Per-customer daily transfer limit counter (INCRBYFLOAT + EXPIREAT)"
# Fixes the P3 finding: summing today's ledger rows gets slower with every
# posting. An O(1) counter that expires at midnight replaces that sum.
DAY=$(date +%F)
MIDNIGHT=$(python3 -c "import datetime as d; t=d.date.today()+d.timedelta(1); print(int(d.datetime(t.year,t.month,t.day).timestamp()))")
KEY="limit:cust:88800000001:$DAY"; LIMIT=60000
for AMT in 40000 40000; do
  # Lua script = atomic check-and-increment, so no write skew is possible
  # runs a script without interleaving other commands)
  RES=$($RV EVAL "
    local used = tonumber(redis.call('GET', KEYS[1]) or '0')
    if used + tonumber(ARGV[1]) > tonumber(ARGV[2]) then return {0, tostring(used)} end
    local new = redis.call('INCRBYFLOAT', KEYS[1], ARGV[1])
    redis.call('EXPIREAT', KEYS[1], ARGV[3])
    return {1, new}" 1 "$KEY" "$AMT" "$LIMIT" "$MIDNIGHT" | tr '\n' ' ')
  echo "request N$AMT -> allowed(1=yes,0=no) used_today: $RES"
done
run TTL "$KEY"

say "K4. OTP brute-force protection / rate limiting (INCR + EXPIRE)"
for i in 1 2 3 4; do
  N=$($RV INCR "otp_fail:+2348060007919"); [ "$N" -eq 1 ] && $RV EXPIRE "otp_fail:+2348060007919" 300 >/dev/null
  if [ "$N" -gt 3 ]; then echo "attempt $i: BLOCKED (failures=$N in 5 min)"; else echo "attempt $i: wrong OTP, failures=$N"; fi
done

say "K5. Cache-aside for the balance screen (HASH) loaded from PostgreSQL"
ROW=$($PSQL -c "SELECT account_number, type_code, balance, status FROM bank.account WHERE account_number='1000000027'")
IFS='|' read -r NUM TYP BALANCE STATUS <<< "$ROW"
run HSET "acct:$NUM" type "$TYP" balance "$BALANCE" status "$STATUS"
run EXPIRE "acct:$NUM" 30
run HGETALL "acct:$NUM"
echo "-> on every successful transfer the app runs DEL acct:<number> (invalidate), so the cache is never stale for long"

say "K6. Real-time leaderboard: top receiving accounts in Oct 2026 (SORTED SET)"
# Scores are IEEE doubles, so amounts are stored in KOBO (integer x100) to keep them exact.
# Load October 2026 credits from PostgreSQL as ZINCRBY commands, piped in bulk
$PSQL -c "
  SELECT 'ZINCRBY lb:credits:2026-10 ' || (le.amount*100)::bigint || ' ' || a.account_number
  FROM bank.ledger_entry le JOIN bank.account a USING (account_id) JOIN bank.txn t USING (txn_id)
  WHERE le.direction='C' AND t.txn_type='TRANSFER' AND a.type_code <> 'GL'
    AND le.created_at >= '2026-10-01' AND le.created_at < '2026-11-01'" | $RV > /dev/null
run ZCARD lb:credits:2026-10
run ZREVRANGE lb:credits:2026-10 0 4 WITHSCORES
run ZREVRANK lb:credits:2026-10 1000000027
echo "-> each new credit is ONE ZINCRBY (O(log N)); the ranking is always current with no GROUP BY"

say "K7. Transaction notifications with a Stream + consumer group (XADD / XREADGROUP)"
run XADD txn:events '*' ref "$REF" account 1000000027 dir D amount 2500 channel MOBILE
run XADD txn:events '*' ref "$REF-2" account 1000000040 dir C amount 2500 channel MOBILE
run XGROUP CREATE txn:events sms-service 0
run XREADGROUP GROUP sms-service worker-1 COUNT 10 STREAMS txn:events '>'
run XPENDING txn:events sms-service

say "K8. Latency: Redis GET vs PostgreSQL primary-key lookup"
echo "redis-benchmark (20 clients, 100k requests):"
redis-benchmark -q -n 100000 -c 20 -t get,set 2>/dev/null | tr '\r' '\n' | grep "requests per second"
echo "pgbench: PostgreSQL lookup by account_number (unique B-tree), 20 clients, 100k queries:"
echo "SELECT balance FROM bank.account WHERE account_number = '1000000027';" > /tmp/kt_pk.sql
pgbench -n -c 20 -j 4 -t 5000 -f /tmp/kt_pk.sql "${PGDATABASE:-kobotrust}" 2>/dev/null | grep -E "^(tps|latency average)"

say "Keyspace summary"
run INFO keyspace
run DBSIZE
