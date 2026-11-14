-- Portfolio 2: 00_reset_baseline.sql

SET search_path = bank, public;
DROP INDEX IF EXISTS idx_ledger_acct_time, idx_ledger_debits_acct_time, idx_customer_email_lower,
     idx_txn_failed_time, idx_ledger_created_brin, idx_account_customer_cover, idx_account_branch;
DROP MATERIALIZED VIEW IF EXISTS mv_branch_monthly;
VACUUM ANALYZE;
