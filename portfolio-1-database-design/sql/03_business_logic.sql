-- Portfolio 1 - 03_business_logic.sql

SET search_path = bank, public;

-- transfer_funds: atomic, idempotent, deadlock-safe internal transfer
-- * Idempotent : the caller passes a txn_ref (UUID). A retry with the same
CREATE OR REPLACE FUNCTION transfer_funds(
    p_from_account  nuban,
    p_to_account    nuban,
    p_amount        NUMERIC,
    p_channel       VARCHAR DEFAULT 'MOBILE',
    p_narration     VARCHAR DEFAULT NULL,
    p_txn_ref       UUID    DEFAULT gen_random_uuid()
) RETURNS BIGINT
LANGUAGE plpgsql
SET search_path = bank, public   -- pinned: works for any caller, and blocks search_path hijacking
AS $$
DECLARE
    v_from   account%ROWTYPE;
    v_to     account%ROWTYPE;
    v_type   account_type%ROWTYPE;
    v_txn_id BIGINT;
    v_today  NUMERIC;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be positive' USING ERRCODE = 'check_violation';
    END IF;
    IF p_from_account = p_to_account THEN
        RAISE EXCEPTION 'Cannot transfer to the same account';
    END IF;

    -- idempotency check
    SELECT txn_id INTO v_txn_id FROM txn WHERE txn_ref = p_txn_ref;
    IF FOUND THEN
        RAISE NOTICE 'Duplicate request %, returning existing txn %', p_txn_ref, v_txn_id;
        RETURN v_txn_id;
    END IF;

    -- lock both rows in a deterministic order (lowest account_id first)
    PERFORM 1 FROM account
     WHERE account_number IN (p_from_account, p_to_account)
     ORDER BY account_id
     FOR UPDATE;

    SELECT * INTO v_from FROM account WHERE account_number = p_from_account;
    SELECT * INTO v_to   FROM account WHERE account_number = p_to_account;

    IF v_from.account_id IS NULL OR v_to.account_id IS NULL THEN
        RAISE EXCEPTION 'Unknown account number' USING ERRCODE = 'no_data_found';
    END IF;
    IF v_from.status <> 'ACTIVE' OR v_to.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Account not active (from=%, to=%)', v_from.status, v_to.status;
    END IF;
    IF v_from.currency <> v_to.currency THEN
        RAISE EXCEPTION 'Currency mismatch % -> %', v_from.currency, v_to.currency;
    END IF;

    SELECT * INTO v_type FROM account_type WHERE type_code = v_from.type_code;
    IF v_from.balance - p_amount < v_type.min_balance THEN
        RAISE EXCEPTION 'Insufficient funds: balance %, amount %, minimum balance %',
              v_from.balance, p_amount, v_type.min_balance
              USING ERRCODE = 'P0001', HINT = 'INSUFFICIENT_FUNDS';
    END IF;

    SELECT COALESCE(SUM(le.amount),0) INTO v_today
      FROM ledger_entry le JOIN txn t USING (txn_id)
     WHERE le.account_id = v_from.account_id AND le.direction = 'D'
       AND t.txn_type IN ('TRANSFER','WITHDRAWAL')
       AND le.created_at >= date_trunc('day', now());
    IF v_today + p_amount > v_type.daily_debit_limit THEN
        RAISE EXCEPTION 'Daily limit exceeded: used %, limit %', v_today, v_type.daily_debit_limit;
    END IF;

    INSERT INTO txn (txn_ref, txn_type, channel, status, amount, narration)
    VALUES (p_txn_ref, 'TRANSFER', p_channel, 'SUCCESS', p_amount, p_narration)
    RETURNING txn_id INTO v_txn_id;

    UPDATE account SET balance = balance - p_amount WHERE account_id = v_from.account_id;
    UPDATE account SET balance = balance + p_amount WHERE account_id = v_to.account_id;

    INSERT INTO ledger_entry (txn_id, account_id, direction, amount, balance_after)
    VALUES (v_txn_id, v_from.account_id, 'D', p_amount, v_from.balance - p_amount),
           (v_txn_id, v_to.account_id,   'C', p_amount, v_to.balance   + p_amount);

    RETURN v_txn_id;
END $$;

-- reverse_transaction: compensating transaction for a successful transfer
-- (a committed transaction is never edited or deleted - it is reversed)
CREATE OR REPLACE FUNCTION reverse_transaction(p_txn_ref UUID, p_employee_id INT)
RETURNS BIGINT
LANGUAGE plpgsql
SET search_path = bank, public   -- pinned: works for any caller, and blocks search_path hijacking
AS $$
DECLARE
    v_orig  txn%ROWTYPE;
    v_new   BIGINT;
    r       RECORD;
BEGIN
    SELECT * INTO v_orig FROM txn WHERE txn_ref = p_txn_ref FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Transaction % not found', p_txn_ref; END IF;
    IF v_orig.status <> 'SUCCESS' OR v_orig.txn_type <> 'TRANSFER' THEN
        RAISE EXCEPTION 'Only successful transfers can be reversed (status=%, type=%)',
              v_orig.status, v_orig.txn_type;
    END IF;

    INSERT INTO txn (txn_type, channel, status, amount, narration, reversal_of, initiated_by_employee)
    VALUES ('REVERSAL','BRANCH','SUCCESS', v_orig.amount, 'Reversal of '||p_txn_ref, v_orig.txn_id, p_employee_id)
    RETURNING txn_id INTO v_new;

    -- lock affected accounts in id order, then post the mirror-image legs
    PERFORM 1 FROM account WHERE account_id IN
        (SELECT account_id FROM ledger_entry WHERE txn_id = v_orig.txn_id)
        ORDER BY account_id FOR UPDATE;

    FOR r IN SELECT account_id, direction, amount FROM ledger_entry
             WHERE txn_id = v_orig.txn_id ORDER BY account_id LOOP
        UPDATE account
           SET balance = balance + CASE r.direction WHEN 'D' THEN r.amount ELSE -r.amount END
         WHERE account_id = r.account_id;
        INSERT INTO ledger_entry (txn_id, account_id, direction, amount, balance_after)
        SELECT v_new, r.account_id, CASE r.direction WHEN 'D' THEN 'C' ELSE 'D' END, r.amount, balance
          FROM account WHERE account_id = r.account_id;
    END LOOP;

    UPDATE txn SET status = 'REVERSED' WHERE txn_id = v_orig.txn_id;
    RETURN v_new;
END $$;

-- Convenience view: customer 360 (used by the mobile app home screen)
CREATE OR REPLACE VIEW v_customer_accounts AS
SELECT c.customer_id, c.first_name || ' ' || c.last_name AS customer_name,
       c.kyc_tier, a.account_number, a.type_code, a.currency, a.balance, a.status,
       b.branch_name, b.city
FROM customer c
JOIN account a USING (customer_id)
JOIN branch  b ON b.branch_id = a.branch_id
WHERE c.customer_id > 1;
