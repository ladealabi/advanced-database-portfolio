-- Invariants that must hold after the concurrent stress test.

SET search_path = bank, public;
\echo 'Total money across the 100 stress accounts (must equal the value before the test):'
SELECT :total_before::numeric AS total_before, sum(balance) AS total_after,
       sum(balance) = :total_before::numeric AS money_conserved
FROM account WHERE account_number LIKE '8880001%';
\echo 'Transfers committed during the test:'
SELECT count(*) AS stress_txns, sum(amount) AS value_moved FROM txn WHERE narration = 'P3 stress' AND txn_id > :txn_before;
\echo 'Unbalanced txns (must be 0):'
SELECT count(*) AS unbalanced FROM (SELECT txn_id FROM ledger_entry le JOIN txn t USING (txn_id)
  WHERE t.narration = 'P3 stress' GROUP BY txn_id
  HAVING sum(CASE direction WHEN 'D' THEN le.amount ELSE -le.amount END) <> 0) x;
\echo 'Stored balance vs ledger (must be 0 mismatches):'
SELECT count(*) AS mismatches FROM account a
JOIN LATERAL (SELECT balance_after FROM ledger_entry le WHERE le.account_id = a.account_id
              ORDER BY created_at DESC, entry_id DESC LIMIT 1) l ON true
WHERE a.account_number LIKE '8880001%' AND a.balance <> l.balance_after;
\echo 'New deadlocks during the test (must be 0):'
SELECT deadlocks - :deadlocks_before AS new_deadlocks FROM pg_stat_database WHERE datname = current_database();
