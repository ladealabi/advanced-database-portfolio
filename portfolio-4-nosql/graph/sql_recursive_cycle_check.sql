-- Portfolio 4: sql_recursive_cycle_check.sql
-- Run: psql -d kobotrust -f sql_recursive_cycle_check.sql

SET search_path = bank, public;
\timing on

CREATE TEMP TABLE edge AS                    -- account-level SENT_TO edges, Sep-Oct 2026
SELECT ls.account_id AS src, ld.account_id AS dst, count(*) AS n, sum(t.amount) AS amount
FROM txn t
JOIN ledger_entry ls ON ls.txn_id = t.txn_id AND ls.direction = 'D'
JOIN ledger_entry ld ON ld.txn_id = t.txn_id AND ld.direction = 'C'
WHERE t.txn_type = 'TRANSFER' AND t.status = 'SUCCESS'
  AND t.created_at >= '2026-09-01' AND t.created_at < '2026-11-01'
  AND ls.account_id <> 1 AND ld.account_id <> 1
GROUP BY 1, 2;
CREATE INDEX ON edge (src);
ANALYZE edge;

\echo '--- Paths that start and end at account 1000092171 (<= 5 hops) ---'
WITH RECURSIVE walk(origin, last, path, hops, min_laps, total) AS (
    SELECT e.src, e.dst, ARRAY[e.src, e.dst], 1, e.n, e.amount
    FROM edge e JOIN account a ON a.account_id = e.src
    WHERE a.account_number = '1000092171'
  UNION ALL
    SELECT w.origin, e.dst, w.path || e.dst, w.hops + 1, LEAST(w.min_laps, e.n), w.total + e.amount
    FROM walk w JOIN edge e ON e.src = w.last
    WHERE w.hops < 5
      AND w.last <> w.origin                       -- stop once we are back home
      AND (e.dst = w.origin OR NOT e.dst = ANY(w.path))   -- no revisits except closing the loop
)
SELECT hops, min_laps AS laps, total AS value_moved,
       (SELECT string_agg(a.account_number, ' -> ' ORDER BY ord)
        FROM unnest(path) WITH ORDINALITY p(id, ord) JOIN account a ON a.account_id = p.id) AS cycle
FROM walk
WHERE last = origin
ORDER BY laps DESC, value_moved DESC;
