-- Portfolio 2: 03_rewritten_queries.sql

SET search_path = bank, public;

-- name: Q6_last_txn_per_account_rewritten
-- Rewrite of Q6: aggregate once and join, instead of running a subquery per account.
SELECT a.account_number, x.last_activity
FROM account a
LEFT JOIN (SELECT le.account_id, max(le.created_at) AS last_activity
           FROM ledger_entry le
           JOIN account a2 ON a2.account_id = le.account_id
                          AND a2.branch_id = 3 AND a2.account_id % 50 = 0
           GROUP BY le.account_id) x ON x.account_id = a.account_id
WHERE a.branch_id = 3 AND a.account_id % 50 = 0;

-- name: Q7_branch_monthly_from_mv
-- Rewrite of Q7: read the precomputed materialized view.
SELECT branch_code, month, inflow, outflow, postings
FROM mv_branch_monthly
WHERE month >= '2026-01-01' AND month < '2027-01-01'
ORDER BY branch_code, month;
