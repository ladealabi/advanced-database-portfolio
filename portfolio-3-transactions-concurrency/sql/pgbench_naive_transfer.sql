-- pgbench script: NAIVE transfer (for comparison only). It debits the source

\set src random(1, 100)
\set dst random(1, 100)
\set amt random(1, 500)
BEGIN;
UPDATE bank.account SET balance = balance - :amt WHERE account_number = (8880001000 + :src)::text::bank.nuban;
UPDATE bank.account SET balance = balance + :amt WHERE account_number = (8880001000 + CASE WHEN :dst = :src THEN (:src % 100) + 1 ELSE :dst END)::text::bank.nuban;
END;
