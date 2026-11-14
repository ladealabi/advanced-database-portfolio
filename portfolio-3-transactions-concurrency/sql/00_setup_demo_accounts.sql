-- Portfolio 3: 00_setup_demo_accounts.sql

SET search_path = bank, public;

INSERT INTO customer (bvn, first_name, last_name, email, phone, date_of_birth, address_line, city, state, kyc_tier)
VALUES ('88800000001','Ada','Demo','p3.demo1@kobotrust.ng','+2348880000001','1994-05-05','12 Demo St','Lagos','Lagos',1),
       ('88800000002','Bayo','Demo','p3.demo2@kobotrust.ng','+2348880000002','1991-02-02','14 Demo St','Lagos','Lagos',2),
       ('88800000003','Stress','Tester','p3.stress@kobotrust.ng','+2348880000003','1988-08-08','1 Load Rd','Lagos','Lagos',3)
ON CONFLICT (bvn) DO NOTHING;

INSERT INTO account (account_number, customer_id, branch_id, type_code)
SELECT v.num, c.customer_id, 1, v.typ
FROM (VALUES ('8880000001','88800000001','SAVINGS'),
             ('8880000002','88800000001','CURRENT'),
             ('8880000003','88800000002','CURRENT')) v(num,bvn,typ)
JOIN customer c ON c.bvn = v.bvn
ON CONFLICT (account_number) DO NOTHING;

INSERT INTO account (account_number, customer_id, branch_id, type_code)
SELECT (8880001000 + g)::text, c.customer_id, 1, 'CURRENT'
FROM generate_series(1,100) g, customer c WHERE c.bvn = '88800000003'
ON CONFLICT (account_number) DO NOTHING;

-- Step 1: reconcile balances against the ledger (the source of truth)
SELECT a.account_number, a.balance AS stored_balance,
       COALESCE(l.balance_after,0) AS ledger_balance,
       a.balance - COALESCE(l.balance_after,0) AS drift
FROM account a
LEFT JOIN LATERAL (SELECT balance_after FROM ledger_entry le WHERE le.account_id = a.account_id
                   ORDER BY created_at DESC, entry_id DESC LIMIT 1) l ON true
WHERE a.account_number LIKE '888%' AND a.balance <> COALESCE(l.balance_after,0);

UPDATE account a SET balance = COALESCE(l.balance_after,0)
FROM account a2
LEFT JOIN LATERAL (SELECT balance_after FROM ledger_entry le WHERE le.account_id = a2.account_id
                   ORDER BY created_at DESC, entry_id DESC LIMIT 1) l ON true
WHERE a.account_id = a2.account_id AND a.account_number LIKE '888%'
  AND a.balance <> COALESCE(l.balance_after,0);

-- Step 2: REBALANCE each demo account to its target with ledgered transfers.
DO $$
DECLARE r RECORD; v_diff NUMERIC;
BEGIN
  FOR r IN SELECT account_number, balance,
                  CASE WHEN account_number LIKE '8880001%' THEN 1000000 ELSE 50000 END AS target
           FROM account WHERE account_number LIKE '888%' ORDER BY account_number LOOP
    v_diff := r.target - r.balance;
    IF v_diff > 0 THEN
      PERFORM transfer_funds('9990000001', r.account_number, v_diff, 'BRANCH', 'P3 reset top-up');
    ELSIF v_diff < 0 THEN
      PERFORM transfer_funds(r.account_number, '9990000001', -v_diff, 'BRANCH', 'P3 reset sweep');
    END IF;
  END LOOP;
END $$;

SELECT account_number, type_code, balance FROM account
WHERE account_number LIKE '88800000%' ORDER BY account_number;
