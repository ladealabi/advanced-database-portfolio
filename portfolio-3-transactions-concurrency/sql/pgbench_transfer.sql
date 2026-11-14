-- pgbench script: one random transfer between two of the 100 stress accounts.

\set src random(1, 100)
\set dst random(1, 100)
\set amt random(1, 500)
SELECT bank.transfer_funds((8880001000 + :src)::text, (8880001000 + CASE WHEN :dst = :src THEN (:src % 100) + 1 ELSE :dst END)::text, :amt, 'MOBILE', 'P3 stress');
