-- Portfolio 5: 02_distributed_queries.sql   (coordinator)

\pset footer off
SET enable_partitionwise_aggregate = on;   -- push GROUP BY down to each shard
SET enable_partitionwise_join      = on;

\echo '\n=== SH1. Data distribution across shards (shard key = region) ==='
SELECT tableoid::regclass AS shard_partition, count(*) AS accounts, sum(balance) AS deposits
FROM dist.account GROUP BY 1 ORDER BY 1;
SELECT tableoid::regclass AS shard_partition, count(*) AS ledger_rows
FROM dist.ledger_entry GROUP BY 1 ORDER BY 1;

\echo '\n=== SH2. Single-shard query: the shard key is in WHERE, so the planner prunes the other shard ==='
EXPLAIN (VERBOSE, COSTS OFF)
SELECT account_number, balance FROM dist.account
WHERE region = 'NORTH' AND account_number = '1000000092';
SELECT account_number, region, balance FROM dist.account
WHERE region = 'NORTH' AND account_number = '1000000092';

\echo '\n=== SH3. No shard key: SCATTER-GATHER, both shards are queried ==='
EXPLAIN (VERBOSE, COSTS OFF)
SELECT account_number, balance FROM dist.account WHERE account_number = '1000000092';

\echo '\n=== SH4a. Aggregate PUSHED DOWN: each shard computes its own GROUP BY (partition-wise aggregate) ==='
EXPLAIN (VERBOSE, COSTS OFF)
SELECT region, count(*), sum(amount) FROM dist.ledger_entry WHERE direction = 'C' GROUP BY region;
SELECT region, count(*) AS credits, sum(amount) AS value FROM dist.ledger_entry WHERE direction = 'C' GROUP BY region ORDER BY 1;

\echo '\n=== SH4b. Aggregate NOT pushed down: date_trunc(timestamptz) is only STABLE (depends on TimeZone), ==='
\echo '===       so postgres_fdw will not ship it. Raw rows travel to the coordinator and are grouped there   ==='
EXPLAIN (VERBOSE, COSTS OFF)
SELECT region, date_trunc('month', created_at) AS month, count(*), sum(amount)
FROM dist.ledger_entry WHERE direction = 'C' GROUP BY 1, 2;
SELECT region, to_char(date_trunc('month', created_at), 'YYYY-MM') AS month, count(*) AS credits, sum(amount) AS value
FROM dist.ledger_entry WHERE direction = 'C' AND created_at >= '2026-08-01' GROUP BY 1, 2 ORDER BY 2, 1;

\echo '\n=== SH5. Cost of distribution: same statement, local table vs sharded tables ==='
\timing on
SELECT count(*), sum(le.amount) FROM bank.ledger_entry le WHERE le.created_at >= '2026-01-01' AND le.account_id <> 1;
SELECT count(*), sum(amount)    FROM dist.ledger_entry   WHERE created_at >= '2026-01-01';
\timing off

\echo '\n=== SH6a. Join inside ONE shard, default fdw costing: the coordinator only has LOCAL estimates ==='
\echo '===        for the remote tables, so it may pull far more rows than needed            ==='
EXPLAIN (VERBOSE, COSTS OFF)
SELECT a.account_number, l.created_at, l.direction, l.amount
FROM dist.account a JOIN dist.ledger_entry l
  ON l.account_number = a.account_number AND l.region = a.region
WHERE a.region = 'SOUTH' AND a.customer_id = 2
ORDER BY l.created_at DESC LIMIT 5;
\timing on
SELECT a.account_number, l.created_at, l.direction, l.amount
FROM dist.account a JOIN dist.ledger_entry l
  ON l.account_number = a.account_number AND l.region = a.region
WHERE a.region = 'SOUTH' AND a.customer_id = 2
ORDER BY l.created_at DESC LIMIT 5;
\timing off

\echo '\n=== SH6b. Same join with use_remote_estimate = true: the shard is asked for real row counts, ==='
\echo '===        and the plan becomes a parameterised lookup per account                       ==='
ALTER FOREIGN TABLE dist.ledger_south OPTIONS (ADD use_remote_estimate 'true');
ALTER FOREIGN TABLE dist.account_south OPTIONS (ADD use_remote_estimate 'true');
EXPLAIN (VERBOSE, COSTS OFF)
SELECT a.account_number, l.created_at, l.direction, l.amount
FROM dist.account a JOIN dist.ledger_entry l
  ON l.account_number = a.account_number AND l.region = a.region
WHERE a.region = 'SOUTH' AND a.customer_id = 2
ORDER BY l.created_at DESC LIMIT 5;
\timing on
SELECT a.account_number, l.created_at, l.direction, l.amount
FROM dist.account a JOIN dist.ledger_entry l
  ON l.account_number = a.account_number AND l.region = a.region
WHERE a.region = 'SOUTH' AND a.customer_id = 2
ORDER BY l.created_at DESC LIMIT 5;
\timing off
ALTER FOREIGN TABLE dist.ledger_south OPTIONS (DROP use_remote_estimate);
ALTER FOREIGN TABLE dist.account_south OPTIONS (DROP use_remote_estimate);
