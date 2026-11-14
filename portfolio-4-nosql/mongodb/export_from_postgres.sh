#!/usr/bin/env bash
# Portfolio 4: export_from_postgres.sh
# Usage: PGHOST=localhost PGUSER=postgres ./export_from_postgres.sh [outdir]

set -euo pipefail
OUT="${1:-$(dirname "$0")/data}"
DB="${PGDATABASE:-kobotrust}"
mkdir -p "$OUT"
q() { psql -d "$DB" -X -q -At -c "SET search_path=bank,public;" -c "$1" > "$2"; echo "  $(wc -l < "$2") docs -> $2"; }

echo "Exporting from PostgreSQL database '$DB' ..."

# ---- customers: embed KYC, address, beneficiaries, and a SUMMARY of accounts
# (extended-reference pattern: the app's home screen needs no join)
q "
SELECT jsonb_build_object(
  '_id', c.customer_id,
  'bvn', c.bvn,
  'name', jsonb_build_object('first', c.first_name, 'last', c.last_name),
  'contact', jsonb_build_object('email', c.email, 'phone', c.phone),
  'dateOfBirth', jsonb_build_object('\$date', to_char(c.date_of_birth, 'YYYY-MM-DD\"T00:00:00Z\"')),
  'address', jsonb_build_object('line', c.address_line, 'city', c.city, 'state', c.state),
  'kyc', jsonb_build_object('tier', c.kyc_tier,
         'dailyLimit', (ARRAY[50000, 200000, 5000000])[c.kyc_tier]),
  'status', c.status,
  'createdAt', jsonb_build_object('\$date', to_char(c.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')),
  'accounts', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                 'accountNumber', a.account_number, 'type', a.type_code, 'currency', a.currency)
                 ORDER BY a.account_id) FROM account a WHERE a.customer_id = c.customer_id), '[]'),
  'beneficiaries', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                 'bankCode', b.bank_code, 'accountNumber', b.beneficiary_account, 'nickname', b.nickname))
                 FROM beneficiary b WHERE b.customer_id = c.customer_id), '[]')
)
FROM customer c WHERE c.customer_id > 1 ORDER BY c.customer_id;" "$OUT/customers.ndjson"

# ---- accounts: the balance lives here (hot, frequently-updated field)
q "
SELECT jsonb_build_object(
  '_id', a.account_number,
  'customerId', a.customer_id,
  'type', a.type_code,
  'currency', a.currency,
  'balance', jsonb_build_object('\$numberDecimal', a.balance::text),
  'status', a.status,
  'branch', jsonb_build_object('code', b.branch_code, 'name', b.branch_name, 'city', b.city, 'region', b.region),
  'limits', jsonb_build_object('minBalance', t.min_balance, 'dailyDebit', t.daily_debit_limit),
  'openedAt', jsonb_build_object('\$date', to_char(a.opened_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'))
)
FROM account a JOIN branch b USING (branch_id) JOIN account_type t USING (type_code)
ORDER BY a.account_id;" "$OUT/accounts.ndjson"

# ---- transactions: ONE document per business transaction with its ledger
q "
SELECT jsonb_build_object(
  '_id', t.txn_ref,
  'type', t.txn_type,
  'channel', t.channel,
  'status', t.status,
  'amount', jsonb_build_object('\$numberDecimal', t.amount::text),
  'narration', t.narration,
  'reversalOf', (SELECT o.txn_ref FROM txn o WHERE o.txn_id = t.reversal_of),
  'createdAt', jsonb_build_object('\$date', to_char(t.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"')),
  'legs', COALESCE((SELECT jsonb_agg(jsonb_build_object(
             'account', a.account_number, 'dir', le.direction,
             'amount', jsonb_build_object('\$numberDecimal', le.amount::text),
             'balanceAfter', jsonb_build_object('\$numberDecimal', le.balance_after::text))
             ORDER BY le.direction DESC)
           FROM ledger_entry le JOIN account a USING (account_id) WHERE le.txn_id = t.txn_id), '[]')
)
FROM txn t ORDER BY t.txn_id;" "$OUT/transactions.ndjson"

# ---- statements: bucket pattern, one document per account per month
# so a monthly statement is ONE document read instead of N rows.
q "
SELECT jsonb_build_object(
  '_id', a.account_number || ':' || to_char(m, 'YYYY-MM'),
  'account', a.account_number,
  'month', to_char(m, 'YYYY-MM'),
  'count', count(*),
  'totalDebit',  jsonb_build_object('\$numberDecimal', COALESCE(sum(le.amount) FILTER (WHERE le.direction='D'),0)::text),
  'totalCredit', jsonb_build_object('\$numberDecimal', COALESCE(sum(le.amount) FILTER (WHERE le.direction='C'),0)::text),
  'closingBalance', jsonb_build_object('\$numberDecimal', (array_agg(le.balance_after ORDER BY le.created_at DESC, le.entry_id DESC))[1]::text),
  'entries', jsonb_agg(jsonb_build_object(
      'at', jsonb_build_object('\$date', to_char(le.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')),
      'txn', t.txn_ref, 'dir', le.direction,
      'amount', jsonb_build_object('\$numberDecimal', le.amount::text), 'narration', t.narration,
      'balanceAfter', jsonb_build_object('\$numberDecimal', le.balance_after::text)) ORDER BY le.created_at, le.entry_id)
)
FROM ledger_entry le
JOIN account a USING (account_id)
JOIN txn t USING (txn_id)
CROSS JOIN LATERAL date_trunc('month', le.created_at) m
WHERE a.type_code <> 'GL'
GROUP BY a.account_number, m
ORDER BY a.account_number, m;" "$OUT/statements.ndjson"

echo "Done. Load with: ./load_mongodb.sh $OUT"
