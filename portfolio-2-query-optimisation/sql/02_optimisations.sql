-- Portfolio 2: 02_optimisations.sql

SET search_path = bank, public;

-- Q1, Q5, Q6: composite B-tree. The equality column goes first, then the range/sort column.
CREATE INDEX IF NOT EXISTS idx_ledger_acct_time
    ON ledger_entry (account_id, created_at, entry_id);

-- Q5: partial index containing only debit legs. It is smaller than the full
-- index and exactly matches the predicate direction = 'D'.
CREATE INDEX IF NOT EXISTS idx_ledger_debits_acct_time
    ON ledger_entry (account_id, created_at) WHERE direction = 'D';

-- Q2: expression index, so lower(email) can be searched with an index.
CREATE INDEX IF NOT EXISTS idx_customer_email_lower
    ON customer (lower(email));

-- Q3: partial index. Only about 2% of txns are FAILED, so the index is tiny.
CREATE INDEX IF NOT EXISTS idx_txn_failed_time
    ON txn (created_at) WHERE status = 'FAILED';

-- Q4, Q7: time-range scans on the 1M-row ledger.
CREATE INDEX IF NOT EXISTS idx_ledger_created_brin
    ON ledger_entry USING brin (created_at) WITH (pages_per_range = 32);

-- Q8: covering index (INCLUDE) allows an index-only scan with no heap visit.
CREATE INDEX IF NOT EXISTS idx_account_customer_cover
    ON account (customer_id) INCLUDE (account_number, type_code, balance);

-- Q6: branch filter
CREATE INDEX IF NOT EXISTS idx_account_branch ON account (branch_id);

-- Q7: the monthly report does not need to be real-time. Precompute it once
-- in a materialized view and refresh it nightly (or CONCURRENTLY with a unique index).
DROP MATERIALIZED VIEW IF EXISTS mv_branch_monthly;
CREATE MATERIALIZED VIEW mv_branch_monthly AS
SELECT b.branch_code, date_trunc('month', le.created_at)::date AS month,
       sum(le.amount) FILTER (WHERE le.direction = 'C') AS inflow,
       sum(le.amount) FILTER (WHERE le.direction = 'D') AS outflow,
       count(*) AS postings
FROM ledger_entry le
JOIN account a ON a.account_id = le.account_id
JOIN branch  b ON b.branch_id  = a.branch_id
WHERE a.type_code <> 'GL'
GROUP BY b.branch_code, month;
CREATE UNIQUE INDEX ON mv_branch_monthly (branch_code, month);

VACUUM ANALYZE ledger_entry;   -- refresh statistics and the visibility map (needed for index-only scans)
VACUUM ANALYZE account;
VACUUM ANALYZE customer;
VACUUM ANALYZE txn;
