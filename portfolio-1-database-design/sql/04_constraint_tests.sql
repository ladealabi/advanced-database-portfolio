-- Portfolio 1 - 04_constraint_tests.sql
-- Run: psql -d kobotrust -f 04_constraint_tests.sql

SET search_path = bank, public;
\set ON_ERROR_STOP off
\set VERBOSITY terse

\echo '\n[T1] PRIMARY KEY / UNIQUE: duplicate BVN (candidate key)'
INSERT INTO customer (bvn, first_name, last_name, email, phone, date_of_birth, address_line, city, state)
SELECT bvn, 'Dup','Licate','dup@x.ng','+2348000000001','1990-01-01','x','Lagos','Lagos' FROM customer WHERE customer_id = 2;

\echo '\n[T2] DOMAIN CHECK: NUBAN must be exactly 10 digits'
INSERT INTO account (account_number, customer_id, branch_id, type_code) VALUES ('12345', 2, 1, 'SAVINGS');

\echo '\n[T3] FOREIGN KEY: account for a customer that does not exist'
INSERT INTO account (account_number, customer_id, branch_id, type_code) VALUES ('5555555555', 999999, 1, 'SAVINGS');

\echo '\n[T4] CHECK: no overdraft (balance >= 0)'
UPDATE account SET balance = -1 WHERE account_id = 2;

\echo '\n[T5] CHECK: customer must be an adult'
INSERT INTO customer (bvn, first_name, last_name, email, phone, date_of_birth, address_line, city, state)
VALUES ('11111111111','Young','Child','kid@x.ng','+2348000000002', CURRENT_DATE - 3650,'x','Lagos','Lagos');

\echo '\n[T6] CHECK: phone must be +234 followed by 10 digits'
INSERT INTO customer (bvn, first_name, last_name, email, phone, date_of_birth, address_line, city, state)
VALUES ('11111111112','Bad','Phone','bad@x.ng','08031234567','1990-01-01','x','Lagos','Lagos');

\echo '\n[T7] CHECK: REVERSAL txn must reference the original (and only reversals may)'
INSERT INTO txn (txn_type, channel, amount) VALUES ('REVERSAL','BRANCH',100);

\echo '\n[T8] FK ON DELETE RESTRICT: cannot delete a customer who still has accounts'
DELETE FROM customer WHERE customer_id = 2;

\echo '\n[T9] DEFERRED CONSTRAINT TRIGGER: unbalanced double-entry is rejected at COMMIT'
BEGIN;
  INSERT INTO txn (txn_type, channel, status, amount) VALUES ('TRANSFER','WEB','SUCCESS',500) ;
  INSERT INTO ledger_entry (txn_id, account_id, direction, amount, balance_after)
  VALUES (currval(pg_get_serial_sequence('bank.txn','txn_id')), 2, 'D', 500, 0);   -- debit with no matching credit
  \echo '   ...insert accepted so far (check is deferred); now COMMIT:'
COMMIT;

\echo '\n[T10] Business rule in transfer_funds(): insufficient funds'
SELECT transfer_funds('1000000027','1000000040', 999999999, 'MOBILE', 'too much');

\echo '\n[T11] Valid transfer succeeds and is audited'
BEGIN;
SELECT transfer_funds('1000000027','1000000040', 2500, 'MOBILE', 'Constraint test - valid') AS new_txn_id;
SELECT audit_id, table_name, operation, row_pk,
       old_data->>'balance' AS old_balance, new_data->>'balance' AS new_balance
FROM audit_log ORDER BY audit_id DESC LIMIT 2;
ROLLBACK;   -- keep the data set unchanged for later portfolios
