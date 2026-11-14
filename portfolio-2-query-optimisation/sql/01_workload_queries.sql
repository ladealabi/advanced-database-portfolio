-- 01_workload_queries.sql: the KoboTrust query workload

SET search_path = bank, public;

-- name: Q1_account_statement
-- Mobile app "statement" screen: one account, one month, with running balance.
SELECT le.created_at, t.txn_ref, t.txn_type, t.channel, t.narration,
       CASE le.direction WHEN 'D' THEN -le.amount ELSE le.amount END AS signed_amount,
       le.balance_after
FROM ledger_entry le
JOIN txn t ON t.txn_id = le.txn_id
WHERE le.account_id = 2
  AND le.created_at >= '2026-01-01' AND le.created_at < '2026-07-01'
ORDER BY le.created_at, le.entry_id;

-- name: Q2_customer_login_lookup
-- Login / KYC search by e-mail, case-insensitive (users type mixed case).
SELECT customer_id, first_name, last_name, kyc_tier, status
FROM customer
WHERE lower(email) = lower('Chiamaka.Udeh1@Yahoo.com');

-- name: Q3_failed_txn_monitor
-- Operations dashboard: failed transactions in the last 7 days, by channel.
SELECT channel, count(*) AS failed, sum(amount) AS value_ngn
FROM txn
WHERE status = 'FAILED'
  AND created_at >= TIMESTAMPTZ '2026-10-24' AND created_at < TIMESTAMPTZ '2026-11-01'
GROUP BY channel
ORDER BY failed DESC;

-- name: Q4_velocity_fraud_check
-- Fraud rule: accounts that made >= 3 debits within any 10-minute window in October 2026.
WITH debits AS (
    SELECT account_id, created_at,
           lag(created_at, 2) OVER (PARTITION BY account_id ORDER BY created_at) AS two_before
    FROM ledger_entry
    WHERE direction = 'D' AND account_id <> 1
      AND created_at >= '2026-10-01' AND created_at < '2026-11-01')
SELECT account_id, count(*) AS bursts, min(created_at) AS first_burst
FROM debits
WHERE created_at - two_before <= INTERVAL '10 minutes'
GROUP BY account_id
ORDER BY bursts DESC, account_id
LIMIT 20;

-- name: Q5_dormant_accounts
-- Regulatory: ACTIVE customer accounts with NO debit in the last 90 days.
SELECT a.account_number, a.type_code, a.balance
FROM account a
WHERE a.status = 'ACTIVE' AND a.type_code IN ('SAVINGS','CURRENT')
  AND NOT EXISTS (SELECT 1 FROM ledger_entry le
                  WHERE le.account_id = a.account_id AND le.direction = 'D'
                    AND le.created_at >= TIMESTAMPTZ '2026-08-02')
ORDER BY a.balance DESC
LIMIT 50;

-- name: Q6_last_txn_per_account_correlated
SELECT a.account_number,
       (SELECT max(le.created_at) FROM ledger_entry le WHERE le.account_id = a.account_id) AS last_activity
FROM account a
WHERE a.branch_id = 3 AND a.account_id % 50 = 0;

-- name: Q7_branch_monthly_summary
-- Management report: monthly inflow/outflow per branch for 2026 (heavy aggregate).
SELECT b.branch_code, date_trunc('month', le.created_at)::date AS month,
       sum(le.amount) FILTER (WHERE le.direction = 'C') AS inflow,
       sum(le.amount) FILTER (WHERE le.direction = 'D') AS outflow,
       count(*) AS postings
FROM ledger_entry le
JOIN account a ON a.account_id = le.account_id
JOIN branch  b ON b.branch_id  = a.branch_id
WHERE le.created_at >= '2026-01-01' AND le.created_at < '2027-01-01' AND a.type_code <> 'GL'
GROUP BY b.branch_code, month
ORDER BY b.branch_code, month;

-- name: Q8_customer_accounts_home
-- Mobile home screen: balances for a customer's accounts (very frequent query).
SELECT account_number, type_code, balance
FROM account
WHERE customer_id = 4242;
