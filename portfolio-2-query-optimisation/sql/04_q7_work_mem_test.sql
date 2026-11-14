-- Portfolio 2: 04_q7_work_mem_test.sql
-- Run: psql -f sql/04_q7_work_mem_test.sql > evidence/q7_work_mem_test.txt

SET search_path = bank, public;
\echo '===== work_mem = 4MB (default) ====='
SET work_mem = '4MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT b.branch_code, date_trunc('month', le.created_at)::date AS month,
       sum(le.amount) FILTER (WHERE le.direction = 'C') AS inflow,
       sum(le.amount) FILTER (WHERE le.direction = 'D') AS outflow, count(*) AS postings
FROM ledger_entry le JOIN account a ON a.account_id = le.account_id JOIN branch b ON b.branch_id = a.branch_id
WHERE le.created_at >= '2026-01-01' AND le.created_at < '2027-01-01' AND a.type_code <> 'GL'
GROUP BY b.branch_code, month ORDER BY b.branch_code, month;
\echo '===== work_mem = 64MB ====='
SET work_mem = '64MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT b.branch_code, date_trunc('month', le.created_at)::date AS month,
       sum(le.amount) FILTER (WHERE le.direction = 'C') AS inflow,
       sum(le.amount) FILTER (WHERE le.direction = 'D') AS outflow, count(*) AS postings
FROM ledger_entry le JOIN account a ON a.account_id = le.account_id JOIN branch b ON b.branch_id = a.branch_id
WHERE le.created_at >= '2026-01-01' AND le.created_at < '2027-01-01' AND a.type_code <> 'GL'
GROUP BY b.branch_code, month ORDER BY b.branch_code, month;
