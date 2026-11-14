-- Portfolio 5: 01_coordinator.sql   (run on the coordinator: kobotrust @ 5432)

CREATE EXTENSION IF NOT EXISTS postgres_fdw;
DROP SCHEMA IF EXISTS dist CASCADE;
CREATE SCHEMA dist;

DROP SERVER IF EXISTS shard_south CASCADE;
DROP SERVER IF EXISTS shard_north CASCADE;
CREATE SERVER shard_south FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'localhost', port '5434', dbname 'kobotrust_south', batch_size '1000', fetch_size '10000');
CREATE SERVER shard_north FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'localhost', port '5435', dbname 'kobotrust_north', batch_size '1000', fetch_size '10000');
CREATE USER MAPPING FOR CURRENT_USER SERVER shard_south OPTIONS (user 'postgres');
CREATE USER MAPPING FOR CURRENT_USER SERVER shard_north OPTIONS (user 'postgres');

-- accounts
CREATE TABLE dist.account (
    account_number CHAR(10), customer_id INT, region VARCHAR(10), branch_code CHAR(5),
    type_code VARCHAR(10), balance NUMERIC(18,2), status VARCHAR(10)
) PARTITION BY LIST (region);
CREATE FOREIGN TABLE dist.account_south PARTITION OF dist.account FOR VALUES IN ('SOUTH')
    SERVER shard_south OPTIONS (schema_name 'bank', table_name 'account');
CREATE FOREIGN TABLE dist.account_north PARTITION OF dist.account FOR VALUES IN ('NORTH')
    SERVER shard_north OPTIONS (schema_name 'bank', table_name 'account');

-- ledger
CREATE TABLE dist.ledger_entry (
    entry_id BIGINT, account_number CHAR(10), region VARCHAR(10), txn_ref UUID,
    direction CHAR(1), amount NUMERIC(18,2), created_at TIMESTAMPTZ
) PARTITION BY LIST (region);
CREATE FOREIGN TABLE dist.ledger_south PARTITION OF dist.ledger_entry FOR VALUES IN ('SOUTH')
    SERVER shard_south OPTIONS (schema_name 'bank', table_name 'ledger_entry');
CREATE FOREIGN TABLE dist.ledger_north PARTITION OF dist.ledger_entry FOR VALUES IN ('NORTH')
    SERVER shard_north OPTIONS (schema_name 'bank', table_name 'ledger_entry');

-- load (rows are ROUTED by region)
\timing on
INSERT INTO dist.account
SELECT a.account_number, a.customer_id, b.region, b.branch_code, a.type_code, a.balance, a.status
FROM bank.account a JOIN bank.branch b USING (branch_id)
WHERE a.type_code <> 'GL';

INSERT INTO dist.ledger_entry
SELECT le.entry_id, a.account_number, b.region, t.txn_ref, le.direction, le.amount, le.created_at
FROM bank.ledger_entry le
JOIN bank.account a USING (account_id)
JOIN bank.branch  b USING (branch_id)
JOIN bank.txn     t USING (txn_id)
WHERE a.type_code <> 'GL' AND le.created_at >= '2026-01-01';
\timing off

ANALYZE dist.account_south; ANALYZE dist.account_north;
ANALYZE dist.ledger_south;  ANALYZE dist.ledger_north;
