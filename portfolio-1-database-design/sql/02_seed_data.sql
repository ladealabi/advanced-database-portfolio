-- Portfolio 1 - 02_seed_data.sql

SET search_path = bank, public;
SELECT setseed(0.8103);                       -- same data on every run

-- branches
INSERT INTO branch (branch_code, branch_name, city, state, region, opened_on) VALUES
 ('LAG01','Victoria Island','Lagos','Lagos','SOUTH','2015-03-02'),
 ('LAG02','Ikeja GRA','Lagos','Lagos','SOUTH','2016-07-11'),
 ('LAG03','Lekki Phase 1','Lagos','Lagos','SOUTH','2019-01-14'),
 ('OYO01','Ring Road','Ibadan','Oyo','SOUTH','2017-05-08'),
 ('RIV01','Trans-Amadi','Port Harcourt','Rivers','SOUTH','2017-09-18'),
 ('ENU01','Ogui Road','Enugu','Enugu','SOUTH','2018-02-05'),
 ('EDO01','Ring Road','Benin City','Edo','SOUTH','2020-06-22'),
 ('FCT01','Wuse II','Abuja','FCT','NORTH','2015-10-01'),
 ('FCT02','Garki Area 11','Abuja','FCT','NORTH','2018-11-12'),
 ('KAN01','Bompai','Kano','Kano','NORTH','2016-04-04'),
 ('KAD01','Ahmadu Bello Way','Kaduna','Kaduna','NORTH','2019-08-19'),
 ('PLA01','Rayfield','Jos','Plateau','NORTH','2021-03-15');

-- account types
INSERT INTO account_type VALUES
 ('SAVINGS',  'Regular savings account',          1000.00,  1000000.00, 4.20),
 ('CURRENT',  'Current account (individual)',     5000.00,  5000000.00, 0.00),
 ('KIDDIES',  'Children savings (guardian-run)',     0.00,    50000.00, 5.00),
 ('DOMUSD',   'Domiciliary account (USD)',          0.00,    10000.00, 0.50),
 ('GL',       'Internal general-ledger account',     0.00, 999999999999.00, 0.00);

-- Name pools (Yoruba, Igbo, Hausa, Edo, Ijaw, Tiv ...)
CREATE TEMP TABLE fn(n) AS SELECT unnest(ARRAY[
 'Adebayo','Chinedu','Aisha','Emeka','Funmilayo','Ibrahim','Ngozi','Tunde','Zainab','Olumide',
 'Chiamaka','Musa','Folake','Uche','Halima','Segun','Amaka','Yusuf','Bisola','Ifeanyi',
 'Fatima','Kelechi','Damilola','Abdullahi','Nneka','Kunle','Hauwa','Obinna','Temitope','Sani',
 'Adaeze','Gbenga','Maryam','Chidi','Yetunde','Bello','Ebere','Osaro','Efe','Tamuno',
 'Terver','Nkechi','Rotimi','Usman','Ifeoma','Lanre','Hadiza','Ikenna','Bukola','Ololade']);
CREATE TEMP TABLE ln(n) AS SELECT unnest(ARRAY[
 'Adeyemi','Okafor','Bello','Okonkwo','Abubakar','Adebayo','Eze','Ogunleye','Mohammed','Nwosu',
 'Balogun','Ibrahim','Ojo','Chukwu','Yusuf','Afolabi','Obi','Lawal','Okoro','Danjuma',
 'Akinola','Nwachukwu','Suleiman','Olatunji','Igwe','Aliyu','Oyelaran','Udeh','Garba','Osagie',
 'Ekpo','Iyorchia','Briggs','Akande','Onyekachi','Umar','Fashola','Ezeh','Bakare','Alabi']);

-- employees
-- 1 branch manager per branch, then ~9 staff reporting to that manager
INSERT INTO employee (branch_id, manager_id, first_name, last_name, email, job_role, hired_on)
SELECT b.branch_id, NULL,
       (SELECT n FROM fn ORDER BY random()+b.branch_id*0 LIMIT 1),
       (SELECT n FROM ln ORDER BY random()+b.branch_id*0 LIMIT 1),
       lower(b.branch_code)||'.manager@kobotrust.ng', 'BRANCH_MANAGER', b.opened_on
FROM branch b ORDER BY b.branch_id;

INSERT INTO employee (branch_id, manager_id, first_name, last_name, email, job_role, hired_on)
SELECT m.branch_id, m.employee_id,
       (SELECT n FROM fn ORDER BY random()+g*0 LIMIT 1),
       (SELECT n FROM ln ORDER BY random()+g*0 LIMIT 1),
       lower(b.branch_code)||'.staff'||g||'@kobotrust.ng',
       (ARRAY['TELLER','TELLER','TELLER','RELATIONSHIP_OFFICER','RELATIONSHIP_OFFICER',
              'COMPLIANCE_OFFICER','OPERATIONS','OPERATIONS','TELLER'])[g],
       b.opened_on + (random()*1500)::int
FROM employee m JOIN branch b USING (branch_id)
CROSS JOIN generate_series(1,9) g
WHERE m.job_role = 'BRANCH_MANAGER';

-- customers
-- customer 1 is the bank itself (owner of internal GL accounts)
INSERT INTO customer (bvn, first_name, last_name, email, phone, date_of_birth,
                      address_line, city, state, kyc_tier, created_at)
VALUES ('00000000000','KoboTrust','Treasury','treasury@kobotrust.ng','+2340000000000',
        '1990-01-01','1 Marina','Lagos','Lagos',3,'2015-01-01');

INSERT INTO customer (bvn, first_name, last_name, email, phone, date_of_birth,
                      address_line, city, state, kyc_tier, created_at)
SELECT lpad((22000000000 + g*37)::text, 11, '0'),
       f.n, l.n,
       lower(f.n||'.'||l.n||g)||'@'||(ARRAY['gmail.com','yahoo.com','outlook.com'])[1+(g%3)],
       '+234'||(ARRAY['803','806','813','816','703','706','802','808','805','907'])[1+(g%10)]
             ||lpad(((g*7919) % 10000000)::text,7,'0'),
       DATE '1960-01-01' + (random()*15000)::int,
       (1+(random()*120)::int)||' '||(ARRAY['Allen Avenue','Adeola Odeku St','Ahmadu Bello Way','Aminu Kano Cres',
                                            'Ogui Road','Aba Road','Bodija Estate','Rayfield Road'])[1+(g%8)],
       b.city, b.state,
       (ARRAY[1,1,2,2,2,3])[1+(g%6)],
       TIMESTAMPTZ '2024-01-01' + random()*INTERVAL '540 days'
FROM generate_series(1,20000) g
CROSS JOIN LATERAL (SELECT n FROM fn OFFSET (random()*49)::int + g*0 LIMIT 1) f
CROSS JOIN LATERAL (SELECT n FROM ln OFFSET (random()*39)::int + g*0 LIMIT 1) l
CROSS JOIN LATERAL (SELECT city, state FROM branch OFFSET (g % 12) LIMIT 1) b;

-- accounts
-- internal GL / settlement account (funds deposits & receives withdrawals)
INSERT INTO account (account_number, customer_id, branch_id, type_code, balance, opened_at)
VALUES ('9990000001', 1, 1, 'GL', 0, '2015-01-01');

-- every customer gets 1 account; ~50% get a second one
INSERT INTO account (account_number, customer_id, branch_id, type_code, currency, opened_at)
SELECT lpad((1000000000 + c.customer_id*13 + k)::text,10,'0'),
       c.customer_id,
       1 + (c.customer_id % 12),
       CASE WHEN k = 1 THEN (ARRAY['SAVINGS','SAVINGS','SAVINGS','CURRENT'])[1+(c.customer_id%4)]
            ELSE (ARRAY['CURRENT','KIDDIES','SAVINGS','DOMUSD'])[1+((c.customer_id/2)%4)] END,
       CASE WHEN k = 2 AND (c.customer_id/2) % 4 = 3 THEN 'USD' ELSE 'NGN' END,
       c.created_at + INTERVAL '1 hour' * k
FROM customer c
CROSS JOIN generate_series(1,2) k
WHERE c.customer_id > 1 AND (k = 1 OR c.customer_id % 2 = 0);

-- a few dormant / frozen accounts for realism
UPDATE account SET status = 'DORMANT' WHERE account_id % 97 = 0 AND type_code <> 'GL';
UPDATE account SET status = 'FROZEN'  WHERE account_id % 499 = 0 AND type_code <> 'GL';

-- beneficiaries
INSERT INTO beneficiary (customer_id, bank_code, beneficiary_account, nickname)
SELECT DISTINCT ON (c.customer_id, a.account_number)
       c.customer_id, '999', a.account_number, 'Payee '||a.account_id
FROM customer c
CROSS JOIN generate_series(1,3) g
JOIN LATERAL (SELECT account_id, account_number FROM account
              WHERE account_id = 2 + ((c.customer_id * 7 + g * 101) % 29000)) a ON true
WHERE c.customer_id > 1 AND c.customer_id % 3 = 0;

-- TRANSACTIONS + LEDGER
ALTER TABLE ledger_entry DISABLE TRIGGER ledger_balanced;
ALTER TABLE account      DISABLE TRIGGER account_audit;

-- (1) opening deposits: one per NGN customer account, at branch
INSERT INTO txn (txn_type, channel, status, amount, narration, initiated_by_employee, created_at)
SELECT 'DEPOSIT','BRANCH','SUCCESS',
       round((200000 + random()*4800000)::numeric, 2),
       'Opening deposit acct '||a.account_id,
       (SELECT employee_id FROM employee e WHERE e.branch_id = a.branch_id AND job_role='TELLER' LIMIT 1),
       a.opened_at + INTERVAL '10 minutes'
FROM account a WHERE a.type_code <> 'GL' AND a.currency = 'NGN'
ORDER BY a.account_id;

-- helper: list of NGN customer accounts that can transact, numbered 1..N
CREATE TEMP TABLE live_acct AS
SELECT row_number() OVER (ORDER BY account_id) AS rn, account_id
FROM account WHERE type_code IN ('SAVINGS','CURRENT') AND currency='NGN' AND status='ACTIVE';
CREATE INDEX ON live_acct(rn);
SELECT count(*) AS live_accounts FROM live_acct \gset

-- (2) peer-to-peer transfers (bulk of the volume), 2024-07 .. 2026-10
CREATE TEMP TABLE tmp_transfer AS
SELECT g AS seq,
       1 + floor(random() * :live_accounts)::int AS src_rn,
       1 + floor(random() * :live_accounts)::int AS dst_rn,
       round((100 + power(random(),4) * 150000)::numeric, 2) AS amount,
       (ARRAY['MOBILE','MOBILE','MOBILE','USSD','WEB','POS'])[1+floor(random()*6)::int] AS channel,
       TIMESTAMPTZ '2025-07-01' + random()*INTERVAL '487 days' AS ts,
       CASE WHEN random() < 0.02 THEN 'FAILED'
            WHEN random() < 0.004 THEN 'REVERSED' ELSE 'SUCCESS' END AS status
FROM generate_series(1,420000) g;
DELETE FROM tmp_transfer WHERE src_rn = dst_rn;

-- Planted suspicious patterns for the fraud queries (P2) and graph analysis (P4)
INSERT INTO tmp_transfer
SELECT 1000000 + b*10 + k, 500 + b*37, 900 + b*53 + k, 9500.00, 'MOBILE',
       TIMESTAMPTZ '2026-10-05 02:00' + b*INTERVAL '1 day' + k*INTERVAL '75 seconds', 'SUCCESS'
FROM generate_series(1,12) b, generate_series(1,5) k;
-- (b) round-tripping ring: money cycles 7001 -> 7002 -> 7003 -> 7004 -> 7005 -> 7001, three laps
INSERT INTO tmp_transfer
SELECT 2000000 + lap*10 + k, 7000 + k, 7000 + (k % 5) + 1, 95000.00 - lap*1000, 'WEB',
       TIMESTAMPTZ '2026-09-10 23:00' + lap*INTERVAL '1 day' + k*INTERVAL '20 minutes', 'SUCCESS'
FROM generate_series(1,3) lap, generate_series(1,5) k;

ALTER TABLE txn ADD COLUMN tmp_seq INT;   -- temporary join key for the bulk load
INSERT INTO txn (txn_type, channel, status, amount, narration, created_at, tmp_seq)
SELECT 'TRANSFER', channel, status, amount,
       (ARRAY['Rent','Food stuff','School fees','Transport','Data bundle','Contribution','Salary support','Gift'])
         [1+(seq%8)], ts, seq
FROM tmp_transfer ORDER BY ts;

-- (3) ATM / POS withdrawals
INSERT INTO txn (txn_type, channel, status, amount, narration, created_at, tmp_seq)
SELECT 'WITHDRAWAL', (ARRAY['ATM','ATM','POS','BRANCH'])[1+floor(random()*4)::int], 'SUCCESS',
       round((1000 + power(random(),3)*80000)::numeric, -3), 'Cash withdrawal',
       TIMESTAMPTZ '2025-07-01' + random()*INTERVAL '487 days',
       -(1 + floor(random() * :live_accounts)::int)          -- negative tmp_seq = account rn
FROM generate_series(1,70000);

-- ledger legs
-- opening deposits: Debit GL settlement, Credit customer
INSERT INTO ledger_entry (txn_id, account_id, direction, amount, balance_after, created_at)
SELECT t.txn_id, x.account_id, x.dir, t.amount, 0, t.created_at
FROM txn t
JOIN account a ON a.account_id = substring(t.narration from '[0-9]+$')::int
CROSS JOIN LATERAL (VALUES (1,'D'), (a.account_id,'C')) x(account_id, dir)
WHERE t.txn_type = 'DEPOSIT';

-- transfers (successful or later-reversed): Debit sender, Credit receiver
INSERT INTO ledger_entry (txn_id, account_id, direction, amount, balance_after, created_at)
SELECT t.txn_id, x.account_id, x.dir, t.amount, 0, t.created_at
FROM txn t
JOIN tmp_transfer tt ON tt.seq = t.tmp_seq AND t.txn_type = 'TRANSFER'
JOIN live_acct s ON s.rn = tt.src_rn
JOIN live_acct d ON d.rn = tt.dst_rn
CROSS JOIN LATERAL (VALUES (s.account_id,'D'), (d.account_id,'C')) x(account_id, dir)
WHERE t.status IN ('SUCCESS','REVERSED');

-- withdrawals: Debit customer, Credit GL settlement
INSERT INTO ledger_entry (txn_id, account_id, direction, amount, balance_after, created_at)
SELECT t.txn_id, x.account_id, x.dir, t.amount, 0, t.created_at
FROM txn t
JOIN live_acct s ON s.rn = -t.tmp_seq
CROSS JOIN LATERAL (VALUES (s.account_id,'D'), (1,'C')) x(account_id, dir)
WHERE t.txn_type = 'WITHDRAWAL';

-- reversals: a new REVERSAL txn 2 hours later with the legs swapped
INSERT INTO txn (txn_type, channel, status, amount, narration, reversal_of, initiated_by_employee, created_at)
SELECT 'REVERSAL', 'BRANCH', 'SUCCESS', t.amount, 'Reversal of '||t.txn_ref, t.txn_id,
       (SELECT employee_id FROM employee WHERE job_role='OPERATIONS' ORDER BY employee_id LIMIT 1),
       t.created_at + INTERVAL '2 hours'
FROM txn t WHERE t.status = 'REVERSED';

INSERT INTO ledger_entry (txn_id, account_id, direction, amount, balance_after, created_at)
SELECT r.txn_id, le.account_id, CASE le.direction WHEN 'D' THEN 'C' ELSE 'D' END, le.amount, 0, r.created_at
FROM txn r JOIN ledger_entry le ON le.txn_id = r.reversal_of
WHERE r.txn_type = 'REVERSAL';

ALTER TABLE txn DROP COLUMN tmp_seq;

-- insufficient funds
-- Randomly generated debits can overdraw an account. A real core-banking
DO $$
DECLARE
    v_bad BIGINT[];
    v_iter INT := 0;
BEGIN
    LOOP
        v_iter := v_iter + 1;
        SELECT array_agg(DISTINCT COALESCE(t.reversal_of, t.txn_id)) INTO v_bad
        FROM (SELECT txn_id,
                     CASE WHEN account_id = 1 THEN 200000000000 ELSE 0 END
                   + SUM(CASE direction WHEN 'C' THEN amount ELSE -amount END)
                     OVER (PARTITION BY account_id ORDER BY created_at, entry_id) AS bal
              FROM ledger_entry) r
        JOIN txn t ON t.txn_id = r.txn_id
        WHERE r.bal < 0;
        EXIT WHEN v_bad IS NULL OR v_iter > 25;
        RAISE NOTICE 'pass %: % overdrawing txns declined', v_iter, cardinality(v_bad);
        DELETE FROM ledger_entry WHERE txn_id = ANY(v_bad)
            OR txn_id IN (SELECT txn_id FROM txn WHERE reversal_of = ANY(v_bad));
        DELETE FROM txn WHERE reversal_of = ANY(v_bad);
        UPDATE txn SET status = 'FAILED', narration = left(narration || ' [declined: insufficient funds]', 140)
        WHERE txn_id = ANY(v_bad);
    END LOOP;
END $$;

-- running balances
-- GL account starts with a large seeded float so it never goes negative.
WITH running AS (
    SELECT entry_id,
           CASE WHEN account_id = 1 THEN 200000000000 ELSE 0 END
         + SUM(CASE direction WHEN 'C' THEN amount ELSE -amount END)
           OVER (PARTITION BY account_id ORDER BY created_at, entry_id) AS bal
    FROM ledger_entry)
UPDATE ledger_entry le SET balance_after = r.bal
FROM running r WHERE r.entry_id = le.entry_id;

UPDATE account a SET balance = x.bal
FROM (SELECT DISTINCT ON (account_id) account_id, balance_after AS bal
      FROM ledger_entry ORDER BY account_id, created_at DESC, entry_id DESC) x
WHERE x.account_id = a.account_id;

ALTER TABLE ledger_entry ENABLE TRIGGER ledger_balanced;
ALTER TABLE account      ENABLE TRIGGER account_audit;

ANALYZE;

-- integrity checks
\echo '--- Integrity checks (all should be 0) ---'
SELECT 'unbalanced txns'        AS check, count(*) FROM (
         SELECT txn_id FROM ledger_entry GROUP BY txn_id
         HAVING SUM(CASE direction WHEN 'D' THEN amount ELSE -amount END) <> 0) x
UNION ALL
SELECT 'negative running balances', count(*) FROM ledger_entry WHERE balance_after < 0
UNION ALL
SELECT 'account.balance <> last ledger balance', count(*) FROM account a
  JOIN (SELECT DISTINCT ON (account_id) account_id, balance_after FROM ledger_entry
        ORDER BY account_id, created_at DESC, entry_id DESC) l USING (account_id)
  WHERE a.balance <> l.balance_after;

\echo '--- Row counts ---'
SELECT 'branch' t, count(*) FROM branch UNION ALL
SELECT 'employee', count(*) FROM employee UNION ALL
SELECT 'customer', count(*) FROM customer UNION ALL
SELECT 'account', count(*) FROM account UNION ALL
SELECT 'beneficiary', count(*) FROM beneficiary UNION ALL
SELECT 'txn', count(*) FROM txn UNION ALL
SELECT 'ledger_entry', count(*) FROM ledger_entry;
