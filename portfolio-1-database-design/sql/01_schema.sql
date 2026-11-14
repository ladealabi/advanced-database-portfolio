-- File       : 01_schema.sql  - DDL: tables, keys, constraints, triggers
-- Run        : psql -d kobotrust -f 01_schema.sql

DROP SCHEMA IF EXISTS bank CASCADE;
CREATE SCHEMA bank;
SET search_path = bank, public;

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()

-- Domains: reusable, self-documenting constraints
CREATE DOMAIN money_ngn AS NUMERIC(18,2);                         -- exact decimal, never FLOAT for money
CREATE DOMAIN positive_amount AS NUMERIC(18,2) CHECK (VALUE > 0);
CREATE DOMAIN nuban AS CHAR(10) CHECK (VALUE ~ '^[0-9]{10}$');    -- Nigerian Uniform Bank Account Number
CREATE DOMAIN bvn_t AS CHAR(11) CHECK (VALUE ~ '^[0-9]{11}$');    -- Bank Verification Number

-- 1. BRANCH
CREATE TABLE branch (
    branch_id     SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    branch_code   CHAR(5)      NOT NULL UNIQUE,
    branch_name   VARCHAR(80)  NOT NULL,
    city          VARCHAR(50)  NOT NULL,
    state         VARCHAR(30)  NOT NULL,
    region        VARCHAR(10)  NOT NULL CHECK (region IN ('SOUTH','NORTH')),  -- used later as shard key (P5)
    opened_on     DATE         NOT NULL DEFAULT CURRENT_DATE
);

-- 2. EMPLOYEE (self-referencing manager hierarchy)
CREATE TABLE employee (
    employee_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    branch_id     SMALLINT     NOT NULL REFERENCES branch(branch_id),
    manager_id    INT          NULL REFERENCES employee(employee_id),
    first_name    VARCHAR(40)  NOT NULL,
    last_name     VARCHAR(40)  NOT NULL,
    email         VARCHAR(120) NOT NULL UNIQUE,
    job_role      VARCHAR(30)  NOT NULL CHECK (job_role IN
                    ('BRANCH_MANAGER','TELLER','RELATIONSHIP_OFFICER','COMPLIANCE_OFFICER','OPERATIONS')),
    hired_on      DATE         NOT NULL,
    CONSTRAINT chk_not_own_manager CHECK (manager_id IS NULL OR manager_id <> employee_id)
);

-- 3. CUSTOMER
CREATE TABLE customer (
    customer_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bvn           bvn_t        NOT NULL UNIQUE,              -- candidate key
    first_name    VARCHAR(40)  NOT NULL,
    last_name     VARCHAR(40)  NOT NULL,
    email         VARCHAR(120) NOT NULL UNIQUE,              -- candidate key
    phone         VARCHAR(14)  NOT NULL UNIQUE CHECK (phone ~ '^\+234[0-9]{10}$'),
    date_of_birth DATE         NOT NULL,
    address_line  VARCHAR(150) NOT NULL,
    city          VARCHAR(50)  NOT NULL,
    state         VARCHAR(30)  NOT NULL,
    kyc_tier      SMALLINT     NOT NULL DEFAULT 1 CHECK (kyc_tier BETWEEN 1 AND 3),
    status        VARCHAR(10)  NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED')),
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT chk_adult CHECK (date_of_birth <= (created_at::date - INTERVAL '18 years'))
);

-- 4. ACCOUNT_TYPE (lookup table)
-- limits/rates on account.type, see normalisation notes)
CREATE TABLE account_type (
    type_code        VARCHAR(10)   PRIMARY KEY,
    description      VARCHAR(60)   NOT NULL,
    min_balance      money_ngn     NOT NULL DEFAULT 0 CHECK (min_balance >= 0),
    daily_debit_limit money_ngn    NOT NULL CHECK (daily_debit_limit > 0),
    annual_interest_pct NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (annual_interest_pct BETWEEN 0 AND 100)
);

-- 5. ACCOUNT
CREATE TABLE account (
    account_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_number nuban        NOT NULL UNIQUE,
    customer_id    INT          NOT NULL REFERENCES customer(customer_id) ON DELETE RESTRICT,
    branch_id      SMALLINT     NOT NULL REFERENCES branch(branch_id),
    type_code      VARCHAR(10)  NOT NULL REFERENCES account_type(type_code),
    currency       CHAR(3)      NOT NULL DEFAULT 'NGN' CHECK (currency IN ('NGN','USD','GBP')),
    balance        money_ngn    NOT NULL DEFAULT 0,
    status         VARCHAR(10)  NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DORMANT','FROZEN','CLOSED')),
    opened_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT chk_no_overdraft CHECK (balance >= 0)          -- business rule: no overdraft product
);

-- 6. BENEFICIARY (M:N-style: customer saves external/internal payees)
-- Composite primary key.
CREATE TABLE beneficiary (
    customer_id          INT         NOT NULL REFERENCES customer(customer_id) ON DELETE CASCADE,
    bank_code            CHAR(3)     NOT NULL,              -- CBN bank code, '999' = KoboTrust itself
    beneficiary_account  nuban       NOT NULL,
    nickname             VARCHAR(40) NOT NULL,
    added_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (customer_id, bank_code, beneficiary_account)
);

-- 7. TXN  (business event: one transfer / deposit / withdrawal)
CREATE TABLE txn (
    txn_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    txn_ref       UUID         NOT NULL UNIQUE DEFAULT gen_random_uuid(),   -- idempotency / external reference
    txn_type      VARCHAR(12)  NOT NULL CHECK (txn_type IN ('DEPOSIT','WITHDRAWAL','TRANSFER','REVERSAL','FEE')),
    channel       VARCHAR(8)   NOT NULL CHECK (channel IN ('MOBILE','USSD','WEB','POS','ATM','BRANCH')),
    status        VARCHAR(10)  NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','SUCCESS','FAILED','REVERSED')),
    amount        positive_amount NOT NULL,
    narration     VARCHAR(140),
    reversal_of   BIGINT       NULL REFERENCES txn(txn_id),
    initiated_by_employee INT  NULL REFERENCES employee(employee_id),       -- NULL = customer self-service
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT clock_timestamp(),  -- time of posting, not txn start (see P3 reflection)
    CONSTRAINT chk_reversal CHECK ((txn_type = 'REVERSAL') = (reversal_of IS NOT NULL))
);

-- 8. LEDGER_ENTRY (double-entry bookkeeping: every txn => balanced legs)
CREATE TABLE ledger_entry (
    entry_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    txn_id        BIGINT       NOT NULL REFERENCES txn(txn_id),
    account_id    INT          NOT NULL REFERENCES account(account_id),
    direction     CHAR(1)      NOT NULL CHECK (direction IN ('D','C')),   -- Debit / Credit
    amount        positive_amount NOT NULL,
    balance_after money_ngn    NOT NULL,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT clock_timestamp()   -- now() = transaction START time; wrong order under concurrency
);

-- Cash and settlement use an internal "GL" account owned by the bank

-- 9. AUDIT_LOG (populated by trigger; JSONB keeps before/after images)
CREATE TABLE audit_log (
    audit_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name   TEXT        NOT NULL,
    operation    CHAR(1)     NOT NULL CHECK (operation IN ('I','U','D')),
    row_pk       TEXT        NOT NULL,
    old_data     JSONB,
    new_data     JSONB,
    changed_by   TEXT        NOT NULL DEFAULT current_user,
    changed_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Foreign-key indexes (PostgreSQL does NOT create these automatically).
CREATE INDEX idx_employee_branch   ON employee(branch_id);
CREATE INDEX idx_account_customer  ON account(customer_id);
CREATE INDEX idx_ledger_txn        ON ledger_entry(txn_id);   -- also used by the double-entry trigger

-- INTEGRITY RULES THAT A CHECK CONSTRAINT CANNOT EXPRESS -> TRIGGERS

-- (a) Double-entry rule: for every txn, SUM(debits) = SUM(credits).
CREATE OR REPLACE FUNCTION trg_check_txn_balanced() RETURNS trigger
LANGUAGE plpgsql
SET search_path = bank, public   -- pinned: works for any caller, and blocks search_path hijacking
AS $$
DECLARE
    v_diff NUMERIC;
BEGIN
    SELECT COALESCE(SUM(CASE direction WHEN 'D' THEN amount ELSE -amount END),0)
      INTO v_diff
      FROM ledger_entry
     WHERE txn_id = NEW.txn_id;
    IF v_diff <> 0 THEN
        RAISE EXCEPTION 'Ledger imbalance for txn %: debits - credits = %', NEW.txn_id, v_diff
              USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER ledger_balanced
    AFTER INSERT ON ledger_entry
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION trg_check_txn_balanced();

-- (b) Audit trail for every change to account (balance, status ...)
CREATE OR REPLACE FUNCTION trg_audit_account() RETURNS trigger
LANGUAGE plpgsql
SET search_path = bank, public   -- pinned: works for any caller, and blocks search_path hijacking
AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW IS NOT DISTINCT FROM OLD THEN
        RETURN NEW;
    END IF;
    INSERT INTO audit_log(table_name, operation, row_pk, old_data, new_data)
    VALUES (TG_TABLE_NAME, left(TG_OP,1),
            COALESCE(NEW.account_id, OLD.account_id)::text,
            CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
            CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END);
    RETURN COALESCE(NEW, OLD);
END $$;

-- Created disabled during bulk load (see 02_seed_data.sql) and enabled afterwards.
CREATE TRIGGER account_audit
    AFTER INSERT OR UPDATE OR DELETE ON account
    FOR EACH ROW EXECUTE FUNCTION trg_audit_account();
