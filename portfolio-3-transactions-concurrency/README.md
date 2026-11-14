# Portfolio 3: Transactions and Concurrency

**Case study:** KoboTrust Digital Bank. Money must never be created, lost or double-spent, even when thousands of mobile, USSD and POS requests hit the same accounts at once.
**DBMS:** PostgreSQL 16 (MVCC, row-level locks, Serializable Snapshot Isolation)

## How the evidence was produced
`run_scenarios.py` opens **two or three real, concurrent `psql` sessions** (A, B, C) and sends statements to each one in a controlled interleaving. Each line of server output is timestamped as it arrives, so the timelines in `evidence/` show *who waited, who blocked and who got an error*. You can reproduce every scenario by hand: open two terminals with `psql -d kobotrust` and paste each session's `>>` lines in timeline order.

```bash
python3 run_scenarios.py                    # all scenarios plus the stress test
python3 run_scenarios.py s4_lost_update     # just one
```
`sql/00_setup_demo_accounts.sql` runs before each scenario. It **reconciles** demo balances against the ledger, then resets them to N50,000 with *ledgered* transfers, so the double-entry books stay balanced.

## Results summary

| # | Scenario (evidence file) | Concept | What the evidence shows |
|---|---|---|---|
| S1 | `s1_commit_atomic_transfer.txt` | Atomicity, COMMIT, durability | A sees its own uncommitted transfer (40,000 / 60,000). **B still sees 50,000 / 50,000** until A commits. The debit leg, credit leg and txn row appear together. |
| S2 | `s2_rollback_and_savepoint.txt` | ROLLBACK, abort on error, SAVEPOINT | (1) Explicit ROLLBACK restores 50,000. (2) An "insufficient funds" error aborts the transaction, even the earlier successful transfer in it (`current transaction is aborted`). (3) In a batch of 3 payments, #2 (bad account) is rolled back to its savepoint, and #1 and #3 commit (Ada 46,000, Bayo 54,000). |
| S3 | `s3_isolation_levels.txt` | Isolation levels, non-repeatable read, no dirty read | READ COMMITTED: read #1 = 50,000, read #2 = 48,000 (**non-repeatable read**). REPEATABLE READ: both reads = 48,000 (one snapshot). READ UNCOMMITTED: B's uncommitted +1,000,000 is **not** visible, because PostgreSQL never allows dirty reads. |
| S4 | `s4_lost_update.txt` | **Lost update** anomaly and 3 fixes | Naive read-modify-write: final balance **30,000 instead of 20,000** (N10,000 lost). The stored balance (30,000) ≠ the ledger (50,000), so reconciliation detects the drift. Fixes: `SELECT … FOR UPDATE` (B blocked on `transactionid`, final 20,000); REPEATABLE READ (B gets `could not serialize access due to concurrent update`, retries, final 20,000); atomic `balance = balance - x` (final 20,000). |
| S5a | `s5a_write_skew_repeatable_read.txt` | **Write skew** | Customer-level daily limit is N60,000. Two N40,000 transfers from *different* accounts both pass the check, so **N80,000 is sent**. No row conflict exists, so snapshot isolation does not catch it. |
| S5b | `s5b_serializable_prevents_write_skew.txt` | SERIALIZABLE (SSI) | Same workload: B's COMMIT fails with `could not serialize access due to read/write dependencies among transactions`. The retry re-checks, sees N40,000 used, and declines. Total = **N40,000**, so the rule holds. |
| S6 | `s6_deadlock_and_lock_ordering.txt` | Deadlock detection and prevention | Naive opposite-order updates → `ERROR: deadlock detected` after `deadlock_timeout` (1 s); the `pg_stat_database.deadlocks` counter goes to 1. With `transfer_funds()` (locks the lower `account_id` first), B just **waits** on `transactionid`, then both commit; the deadlock counter stays at 1. |
| S7 | `s7_stress_test_pgbench.txt` | Correctness under load | 16 concurrent clients. **Naive** transfer (inconsistent lock order): **9 deadlock failures** in 10 s. **`transfer_funds()`**: **60,422 transfers in 20 s (≈3,030 tps), 0 failures, 0 deadlocks**. Money conserved (N100,000,000 before = after), 0 unbalanced txns, 0 balance/ledger mismatches. |

## Concurrency-control design used in `transfer_funds()`

| Mechanism | Where | Protects against |
|---|---|---|
| Single DB transaction around debit + credit + txn + 2 ledger legs | the whole function | Partial transfers (atomicity) |
| `SELECT … FOR UPDATE` on both accounts **ordered by `account_id`** | start of the function | Lost updates; deadlocks (no cycle is possible in the wait-for graph) |
| Atomic `UPDATE … SET balance = balance ± x` | balance update | Lost update even without explicit locks |
| `CHECK (balance >= 0)` + deferred double-entry trigger | schema | Bugs that bypass the function |
| Idempotency key `txn_ref UUID UNIQUE` | first statement | Double debit when the mobile app retries after a network timeout |
| SERIALIZABLE for multi-row rules (customer daily limit) | caller chooses the isolation level | Write skew |
| Retry on SQLSTATE `40001` / `40P01` | application layer (pgbench `--max-tries`) | Serialization failures and deadlock victims |

## Choosing the isolation level for each operation

| Operation | Level | Reason |
|---|---|---|
| Single transfer (`transfer_funds`) | READ COMMITTED + row locks | Rows are locked explicitly. Highest throughput. |
| Customer-level limits / rules over several rows | SERIALIZABLE + retry | Only SSI prevents write skew without hand-written locks |
| End-of-day reports, statements | REPEATABLE READ (read-only) | Consistent snapshot of all accounts at one instant, and no blocking of writers (MVCC) |

## Findings worth noting
1. **`now()` is the transaction start time.** In the first stress run, 2 accounts showed a stored balance different from the "last" ledger row. The cause: `created_at DEFAULT now()` stamps each posting with its transaction's *start* time. A transaction that started earlier but obtained the lock later therefore got an *earlier* timestamp, so "ORDER BY created_at" did not match the real posting order. Fix: `DEFAULT clock_timestamp()` (time of the actual insert, taken after the lock is held). After the fix: 0 mismatches.
2. **Functions must pin `search_path`.** pgbench sessions did not have `search_path = bank`, so `transfer_funds()` failed with `relation "account" does not exist`. All functions now declare `SET search_path = bank, public`, which also prevents search-path hijacking (a security best practice).
3. **Throughput decays as the day's postings grow.** tps drops during the run because the daily-limit check sums *today's* debits for the account. That sum grows with every transfer. A production fix is a per-account daily counter, for example the Redis `INCRBY` + `EXPIRE` counter in Portfolio 4.
