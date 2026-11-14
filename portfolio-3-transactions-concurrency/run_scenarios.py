#!/usr/bin/env python3
"""MIT 8103 Portfolio 3: Transactions and Concurrency (KoboTrust Digital Bank)
Usage : PGHOST=localhost PGUSER=postgres python3 run_scenarios.py [scenario ...]"""
import os, shutil, subprocess, sys, threading, time, pathlib, textwrap

HERE = pathlib.Path(__file__).resolve().parent
EVID = HERE / "evidence"
DB = os.environ.get("PGDATABASE", "kobotrust")
SETUP = HERE / "sql" / "00_setup_demo_accounts.sql"
# line-buffered psql output: GNU stdbuf on Linux, gstdbuf on macOS (brew install coreutils)
_sb = shutil.which("stdbuf") or shutil.which("gstdbuf")
LINEBUF = [_sb, "-oL", "-eL"] if _sb else []

A1, A2, B1 = "'8880000001'", "'8880000002'", "'8880000003'"   # Ada SAVINGS, Ada CURRENT, Bayo CURRENT
BAL = ("SELECT account_number, balance FROM account "
       "WHERE account_number IN ('8880000001','8880000002','8880000003') ORDER BY 1;")


class Session:
    def __init__(self, name, log, t0):
        self.name, self.log, self.t0 = name, log, t0
        self.p = subprocess.Popen(
            LINEBUF + ["psql", "-d", DB, "-X", "-q", "-v", "VERBOSITY=terse"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1)
        threading.Thread(target=self._reader, daemon=True).start()
        self.send("SET search_path = bank, public; SET application_name = 'session_%s';" % name, echo=False)

    def _reader(self):
        for line in self.p.stdout:
            line = line.rstrip()
            if line:
                self.log(f"{time.time() - self.t0:6.2f}s  {self.name} | {line}")

    def send(self, sql, echo=True):
        if echo:
            for i, l in enumerate(textwrap.dedent(sql).strip().splitlines()):
                self.log(f"{time.time() - self.t0:6.2f}s  {self.name} {'>>' if i == 0 else '  '} {l}")
        self.p.stdin.write(textwrap.dedent(sql).strip() + "\n")
        self.p.stdin.flush()

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=15)
        except Exception:
            self.p.kill()


def run(name, title, explanation, steps):
    """steps: list of (session_name | 'NOTE', sql_or_text, seconds_to_wait_after)"""
    reset = subprocess.run(["psql", "-d", DB, "-X", "-q", "-f", str(SETUP)], capture_output=True, text=True)
    if reset.returncode:
        print(reset.stderr); sys.exit(1)
    lines, lock = [], threading.Lock()

    def log(s):
        with lock:
            lines.append(s)
    t0 = time.time()
    sessions = {}
    for sess, sql, wait in steps:
        if sess == "NOTE":
            log(f"{time.time() - t0:6.2f}s  -- {sql}")
        else:
            if sess not in sessions:
                sessions[sess] = Session(sess, log, t0)
                time.sleep(0.3)
            sessions[sess].send(sql)
        time.sleep(wait)
    time.sleep(0.5)
    for s in sessions.values():
        s.close()
    header = (f"SCENARIO: {title}\n{'=' * 78}\n{textwrap.fill(explanation, 78)}\n\n"
              "Timeline (seconds since start | session | '>>' = statement sent, otherwise = server output)\n"
              + "-" * 78 + "\n")
    EVID.mkdir(exist_ok=True)
    (EVID / f"{name}.txt").write_text(header + "\n".join(lines) + "\n")
    print(f"--- {name}: {len(lines)} lines -> evidence/{name}.txt")


SCENARIOS = {}


def scenario(fn):
    SCENARIOS[fn.__name__] = fn
    return fn


@scenario
def s1_commit_atomic_transfer():
    run("s1_commit_atomic_transfer", "COMMIT: an atomic transfer becomes visible only after COMMIT",
        "Session A transfers N10,000 from Ada (8880000001) to Bayo (8880000003) inside an explicit "
        "transaction. Session B observes before and after A commits. Atomicity: the debit, the credit, "
        "the txn row and both ledger legs are applied together. Durability: after COMMIT the change is in "
        "the WAL and survives a crash.", [
            ("B", BAL, 0.6),
            ("A", "BEGIN;", 0.3),
            ("A", f"SELECT transfer_funds({A1}, {B1}, 10000, 'MOBILE', 'P3 demo commit') AS txn_id;", 0.6),
            ("A", BAL, 0.6),
            ("NOTE", "A has not committed yet. B must still see the OLD balances (no dirty read):", 0),
            ("B", BAL, 0.6),
            ("A", "COMMIT;", 0.5),
            ("NOTE", "After COMMIT, B sees the new balances:", 0),
            ("B", BAL, 0.6),
            ("B", "SELECT le.direction, le.amount, le.balance_after, a.account_number FROM ledger_entry le "
                  "JOIN account a USING (account_id) WHERE txn_id = (SELECT max(txn_id) FROM txn "
                  "WHERE narration='P3 demo commit') ORDER BY direction DESC;", 0.6),
        ])


@scenario
def s2_rollback_and_savepoint():
    run("s2_rollback_and_savepoint", "ROLLBACK: explicit rollback, automatic rollback on error, and SAVEPOINT",
        "(1) An explicit ROLLBACK undoes a completed transfer. (2) A transfer that breaks a business rule "
        "(insufficient funds) raises an error, the whole transaction is aborted, and nothing can run until ROLLBACK. "
        "(3) A batch of three payments uses SAVEPOINTs, so the one failing payment is rolled back on its own "
        "and the other two still commit.", [
            ("A", BAL, 0.5),
            ("NOTE", "(1) explicit ROLLBACK", 0),
            ("A", "BEGIN;", 0.2),
            ("A", f"SELECT transfer_funds({A1}, {B1}, 7000, 'WEB', 'P3 demo rollback');", 0.4),
            ("A", BAL, 0.4),
            ("A", "ROLLBACK;", 0.3),
            ("A", BAL, 0.5),
            ("NOTE", "(2) error -> the transaction is aborted -> everything in it is rolled back", 0),
            ("A", "BEGIN;", 0.2),
            ("A", f"SELECT transfer_funds({A1}, {B1}, 5000, 'WEB', 'P3 demo ok part');", 0.4),
            ("A", f"SELECT transfer_funds({A1}, {B1}, 900000, 'WEB', 'P3 demo too big');", 0.4),
            ("A", "SELECT 'can I continue?';", 0.4),
            ("A", "ROLLBACK;", 0.3),
            ("A", BAL, 0.5),
            ("NOTE", "(3) SAVEPOINT: a batch of 3 payments where payment #2 fails", 0),
            ("A", "BEGIN;", 0.2),
            ("A", "SAVEPOINT pay1;", 0.1),
            ("A", f"SELECT transfer_funds({A1}, {B1}, 1000, 'WEB', 'P3 demo batch #1');", 0.3),
            ("A", "SAVEPOINT pay2;", 0.1),
            ("A", f"SELECT transfer_funds({A1}, '0000000000', 1000, 'WEB', 'P3 demo batch #2 bad account');", 0.3),
            ("A", "ROLLBACK TO SAVEPOINT pay2;", 0.2),
            ("A", "SAVEPOINT pay3;", 0.1),
            ("A", f"SELECT transfer_funds({A1}, {B1}, 3000, 'WEB', 'P3 demo batch #3');", 0.3),
            ("A", "COMMIT;", 0.3),
            ("A", BAL, 0.5),
        ])


@scenario
def s3_isolation_levels():
    run("s3_isolation_levels", "ISOLATION: READ COMMITTED vs REPEATABLE READ (non-repeatable read)",
        "A branch report (session A) reads Ada's balance twice inside one transaction while session B "
        "commits a transfer in between. Under READ COMMITTED each statement sees a new snapshot, so the "
        "second read differs (non-repeatable read). Under REPEATABLE READ the whole transaction uses one "
        "snapshot, so both reads agree. PostgreSQL never allows dirty reads, even at READ UNCOMMITTED.", [
            ("NOTE", "--- Part 1: READ COMMITTED (PostgreSQL default) ---", 0),
            ("A", "BEGIN ISOLATION LEVEL READ COMMITTED;", 0.2),
            ("A", f"SELECT 'read #1' AS r, balance FROM account WHERE account_number = {A1};", 0.5),
            ("B", f"SELECT transfer_funds({A1}, {B1}, 2000, 'USSD', 'P3 demo iso RC');", 0.5),
            ("A", f"SELECT 'read #2' AS r, balance FROM account WHERE account_number = {A1};", 0.5),
            ("A", "COMMIT;", 0.4),
            ("NOTE", "--- Part 2: REPEATABLE READ ---", 0),
            ("A", "BEGIN ISOLATION LEVEL REPEATABLE READ;", 0.2),
            ("A", f"SELECT 'read #1' AS r, balance FROM account WHERE account_number = {A1};", 0.5),
            ("B", f"SELECT transfer_funds({A1}, {B1}, 2000, 'USSD', 'P3 demo iso RR');", 0.5),
            ("A", f"SELECT 'read #2' AS r, balance FROM account WHERE account_number = {A1};", 0.5),
            ("A", "COMMIT;", 0.3),
            ("A", f"SELECT 'after commit' AS r, balance FROM account WHERE account_number = {A1};", 0.4),
            ("NOTE", "--- Part 3: READ UNCOMMITTED still gives no dirty read in PostgreSQL ---", 0),
            ("B", "BEGIN;", 0.1),
            ("B", f"UPDATE account SET balance = balance + 1000000 WHERE account_number = {A1};", 0.4),
            ("A", "BEGIN ISOLATION LEVEL READ UNCOMMITTED;", 0.1),
            ("A", f"SELECT 'uncommitted?' AS r, balance FROM account WHERE account_number = {A1};", 0.4),
            ("A", "COMMIT;", 0.1),
            ("B", "ROLLBACK;", 0.4),
        ])


@scenario
def s4_lost_update():
    naive_read = f"SELECT balance FROM account WHERE account_number = {A1};"
    run("s4_lost_update", "CONCURRENCY PROBLEM: lost update, and three ways to prevent it",
        "A naive application reads the balance, subtracts in application code, then writes the result back. "
        "Two ATM withdrawals (N10,000 by A and N20,000 by B) run at the same time against Ada's N50,000. "
        "Correct final balance: N20,000. Part 1 shows the anomaly: B overwrites A's update. Part 2 prevents it "
        "with pessimistic locking (SELECT ... FOR UPDATE). Part 3 uses REPEATABLE READ, where PostgreSQL "
        "detects the conflict and aborts B, which must retry. Part 4 uses an atomic UPDATE balance = balance - x.", [
            ("NOTE", "--- Part 1: naive read-modify-write at READ COMMITTED -> LOST UPDATE ---", 0),
            ("A", "BEGIN;", 0.1), ("B", "BEGIN;", 0.2),
            ("A", naive_read, 0.3), ("B", naive_read, 0.3),
            ("NOTE", "both sessions read 50000; the app computes 50000-10000 and 50000-20000", 0),
            ("A", f"UPDATE account SET balance = 40000 WHERE account_number = {A1};", 0.3),
            ("A", "COMMIT;", 0.3),
            ("B", f"UPDATE account SET balance = 30000 WHERE account_number = {A1};", 0.3),
            ("B", "COMMIT;", 0.3),
            ("A", f"SELECT balance AS final_balance_should_be_20000 FROM account WHERE account_number = {A1};", 0.6),
            ("NOTE", "N10,000 withdrawal LOST. The ledger reconciliation in 00_setup detects and repairs this drift.", 0),
            ("A", "SELECT * FROM (SELECT a.balance AS stored, (SELECT balance_after FROM ledger_entry le "
                  "WHERE le.account_id=a.account_id ORDER BY created_at DESC, entry_id DESC LIMIT 1) AS ledger "
                  f"FROM account a WHERE account_number = {A1}) x;", 0.6),
            ("A", f"UPDATE account SET balance = 50000 WHERE account_number = {A1};", 0.5),
            ("NOTE", "--- Part 2: pessimistic locking with SELECT ... FOR UPDATE ---", 0),
            ("A", "BEGIN;", 0.1), ("B", "BEGIN;", 0.2),
            ("A", f"SELECT balance FROM account WHERE account_number = {A1} FOR UPDATE;", 0.4),
            ("B", f"SELECT balance FROM account WHERE account_number = {A1} FOR UPDATE;", 0.8),
            ("C", "SELECT application_name, wait_event_type, wait_event, state FROM pg_stat_activity "
                  "WHERE application_name LIKE 'session_%' ORDER BY 1;", 0.6),
            ("NOTE", "B is BLOCKED (wait_event = transactionid) until A finishes", 0),
            ("A", f"UPDATE account SET balance = 40000 WHERE account_number = {A1};", 0.3),
            ("A", "COMMIT;", 0.6),
            ("NOTE", "B is released and now reads 40000 (the committed value), so it writes 40000-20000", 0),
            ("B", f"UPDATE account SET balance = 20000 WHERE account_number = {A1};", 0.3),
            ("B", "COMMIT;", 0.3),
            ("A", f"SELECT balance AS final_balance FROM account WHERE account_number = {A1};", 0.5),
            ("A", f"UPDATE account SET balance = 50000 WHERE account_number = {A1};", 0.5),
            ("NOTE", "--- Part 3: optimistic approach with REPEATABLE READ (first committer wins) ---", 0),
            ("A", "BEGIN ISOLATION LEVEL REPEATABLE READ;", 0.1),
            ("B", "BEGIN ISOLATION LEVEL REPEATABLE READ;", 0.2),
            ("A", naive_read, 0.3), ("B", naive_read, 0.3),
            ("A", f"UPDATE account SET balance = 40000 WHERE account_number = {A1};", 0.3),
            ("B", f"UPDATE account SET balance = 30000 WHERE account_number = {A1};", 0.6),
            ("A", "COMMIT;", 0.6),
            ("NOTE", "B is aborted with a serialization failure; the application must ROLLBACK and RETRY", 0),
            ("B", "ROLLBACK;", 0.2),
            ("B", "BEGIN ISOLATION LEVEL REPEATABLE READ;", 0.1),
            ("B", naive_read, 0.3),
            ("B", f"UPDATE account SET balance = 20000 WHERE account_number = {A1};", 0.3),
            ("B", "COMMIT;", 0.3),
            ("A", f"SELECT balance AS final_balance FROM account WHERE account_number = {A1};", 0.5),
            ("A", f"UPDATE account SET balance = 50000 WHERE account_number = {A1};", 0.5),
            ("NOTE", "--- Part 4: atomic in-place update (what transfer_funds() does) ---", 0),
            ("A", "BEGIN;", 0.1), ("B", "BEGIN;", 0.2),
            ("A", f"UPDATE account SET balance = balance - 10000 WHERE account_number = {A1};", 0.3),
            ("B", f"UPDATE account SET balance = balance - 20000 WHERE account_number = {A1};", 0.6),
            ("A", "COMMIT;", 0.5),
            ("B", "COMMIT;", 0.3),
            ("A", f"SELECT balance AS final_balance FROM account WHERE account_number = {A1};", 0.6),
        ])


SKEW_CHECK = ("SELECT COALESCE(sum(le.amount),0) AS used_today FROM ledger_entry le JOIN txn t USING (txn_id) "
              "JOIN account a USING (account_id) JOIN customer c USING (customer_id) "
              "WHERE c.bvn='88800000001' AND le.direction='D' AND t.narration LIKE 'P3 skew%' "
              "AND le.created_at >= date_trunc('day', now());")
SKEW_TEXT = ("KYC tier-1 rule (customer level, not account level): Ada may send at most N60,000 per day across ALL "
             "her accounts. Two requests arrive at the same moment: N40,000 from her SAVINGS to Bayo (session A) and "
             "N40,000 from her CURRENT account to a merchant (session B). Each checks the daily total, sees N0 used, "
             "and proceeds. The two transactions read the same data but write DIFFERENT rows, so row locks and "
             "REPEATABLE READ (snapshot isolation) cannot see a conflict. ")


def _skew_steps(level, retry=False):
    retry_steps = [
        ("NOTE", "application RETRY of the aborted transaction (SQLSTATE 40001 => retry):", 0),
        ("B", "BEGIN ISOLATION LEVEL SERIALIZABLE;", 0.1),
        ("B", SKEW_CHECK, 0.4),
        ("NOTE", "40,000 already used + 40,000 requested > 60,000, so the app declines the request", 0),
        ("B", "ROLLBACK;", 0.3),
    ] if retry else []
    return [
        ("A", f"BEGIN ISOLATION LEVEL {level};", 0.1),
        ("B", f"BEGIN ISOLATION LEVEL {level};", 0.2),
        ("A", SKEW_CHECK, 0.4), ("B", SKEW_CHECK, 0.4),
        ("NOTE", "both see used_today = 0, so a N40,000 transfer looks allowed (limit N60,000)", 0),
        ("A", f"SELECT transfer_funds({A1}, {B1}, 40000, 'MOBILE', 'P3 skew via savings');", 0.4),
        ("B", f"SELECT transfer_funds({A2}, '8880001001', 40000, 'MOBILE', 'P3 skew via current');", 0.4),
        ("A", "COMMIT;", 0.4),
        ("B", "COMMIT;", 0.5),
        ("A", SKEW_CHECK.replace("used_today", "total_sent_today__limit_is_60000"), 0.6),
    ] + retry_steps + [
        # clear the marker so the next run starts from zero 'used today'
        ("A", "UPDATE txn SET narration = 'P3 demo skew (cleared)' WHERE narration LIKE 'P3 skew%';", 0.4),
    ]


@scenario
def s5a_write_skew_repeatable_read():
    run("s5a_write_skew_repeatable_read",
        "CONCURRENCY PROBLEM: write skew under REPEATABLE READ (snapshot isolation)",
        SKEW_TEXT + "Result: both commit and Ada sends N80,000, which breaks the N60,000 rule.",
        _skew_steps("REPEATABLE READ"))


@scenario
def s5b_serializable_prevents_write_skew():
    run("s5b_serializable_prevents_write_skew",
        "CONCURRENCY CONTROL: SERIALIZABLE (SSI) prevents the write skew",
        SKEW_TEXT + "Under SERIALIZABLE, PostgreSQL's Serializable Snapshot Isolation tracks the read->write "
        "dependencies between the two transactions (a 'dangerous structure') and aborts one with SQLSTATE 40001. "
        "The application retries it, the re-check now sees N40,000 already used, and the request is declined.",
        _skew_steps("SERIALIZABLE", retry=True))


@scenario
def s6_deadlock_and_lock_ordering():
    run("s6_deadlock_and_lock_ordering", "CONCURRENCY CONTROL: deadlock detection, and prevention by lock ordering",
        "Part 1: naive transfer code debits the source first. A sends Ada->Bayo while B sends Bayo->Ada at the same time. "
        "A locks Ada and waits for Bayo; B locks Bayo and waits for Ada. This is a cycle in the wait-for graph. "
        "PostgreSQL's deadlock detector (after deadlock_timeout = 1s) aborts one victim. Part 2: the same two "
        "transfers through transfer_funds(), which always locks the lower account_id first. B simply waits, "
        "then both succeed, with no deadlock.", [
            ("NOTE", "--- Part 1: naive ordering -> DEADLOCK ---", 0),
            ("A", "BEGIN;", 0.1), ("B", "BEGIN;", 0.2),
            ("A", f"UPDATE account SET balance = balance - 1000 WHERE account_number = {A1};  -- debit Ada", 0.3),
            ("B", f"UPDATE account SET balance = balance - 2000 WHERE account_number = {B1};  -- debit Bayo", 0.3),
            ("A", f"UPDATE account SET balance = balance + 1000 WHERE account_number = {B1};  -- credit Bayo (waits for B)", 0.4),
            ("B", f"UPDATE account SET balance = balance + 2000 WHERE account_number = {A1};  -- credit Ada (cycle!)", 1.8),
            ("A", "COMMIT;", 0.3), ("B", "ROLLBACK;", 0.3),
            ("C", "SELECT datname, deadlocks FROM pg_stat_database WHERE datname = current_database();", 0.4),
            ("NOTE", "--- Part 2: transfer_funds() locks rows in account_id order -> NO deadlock ---", 0),
            ("A", "BEGIN;", 0.1), ("B", "BEGIN;", 0.2),
            ("A", f"SELECT transfer_funds({A1}, {B1}, 1000, 'WEB', 'P3 demo order A');", 0.3),
            ("B", f"SELECT transfer_funds({B1}, {A1}, 2000, 'WEB', 'P3 demo order B');", 0.6),
            ("C", "SELECT application_name, wait_event_type, wait_event FROM pg_stat_activity "
                  "WHERE application_name IN ('session_A','session_B') ORDER BY 1;", 0.5),
            ("A", "COMMIT;", 0.5), ("B", "COMMIT;", 0.4),
            ("C", "SELECT datname, deadlocks FROM pg_stat_database WHERE datname = current_database();", 0.3),
            ("C", BAL, 0.5),
        ])


def stress_test(clients=16, seconds=20):
    """pgbench: many concurrent transfer_funds() calls, then invariant checks."""
    # (a) baseline for comparison: the NAIVE transfer (inconsistent lock order)
    subprocess.run(["psql", "-d", DB, "-X", "-q", "-f", str(SETUP)], capture_output=True)
    naive = subprocess.run(["pgbench", "-n", "-c", str(clients), "-j", "4", "-T", "10",
                            "-f", str(HERE / "sql" / "pgbench_naive_transfer.sql"),
                            "--max-tries=1", "--failures-detailed", DB], capture_output=True, text=True)
    # (b) the real test: transfer_funds() with ordered locking
    subprocess.run(["psql", "-d", DB, "-X", "-q", "-f", str(SETUP)], capture_output=True)
    script = HERE / "sql" / "pgbench_transfer.sql"
    q = lambda s: subprocess.run(["psql", "-d", DB, "-X", "-At", "-c", s], capture_output=True, text=True).stdout.strip()
    total_before = q("SELECT sum(balance) FROM bank.account WHERE account_number LIKE '8880001%'")
    deadlocks_before = q("SELECT deadlocks FROM pg_stat_database WHERE datname=current_database()")
    txn_before = q("SELECT COALESCE(max(txn_id),0) FROM bank.txn")
    pb = subprocess.run(["pgbench", "-n", "-c", str(clients), "-j", "4", "-T", str(seconds),
                         "-f", str(script), "--max-tries=5", "--failures-detailed", "-P", "5", DB],
                        capture_output=True, text=True)
    checks = subprocess.run(["psql", "-d", DB, "-X", "-f", str(HERE / "sql" / "stress_invariants.sql"),
                             "-v", f"total_before={total_before}", "-v", f"deadlocks_before={deadlocks_before}", "-v", f"txn_before={txn_before}"],
                            capture_output=True, text=True)
    (EVID / "s7_stress_test_pgbench.txt").write_text(
        "SCENARIO: STRESS TEST: %d concurrent clients calling transfer_funds() for %ds\n%s\n"
        "Random transfers between 100 accounts. Opposite-direction transfers on the same pair happen\n"
        "constantly, so without lock ordering this would deadlock. The invariants checked afterwards:\n"
        "money is conserved, every txn is balanced, no negative balances, and no new deadlocks.\n\n"
        "=== (a) COMPARISON: naive transfer, inconsistent lock order, 10s ===\n%s\n%s\n"
        "=== (b) transfer_funds() with ordered locking ===\n%s\n%s\n=== invariant checks after (b) ===\n%s\n%s" %
        (clients, seconds, "=" * 78, naive.stdout, naive.stderr, pb.stdout, pb.stderr, checks.stdout, checks.stderr))
    print("--- s7_stress_test_pgbench -> evidence/s7_stress_test_pgbench.txt")


if __name__ == "__main__":
    wanted = sys.argv[1:] or list(SCENARIOS) + ["stress"]
    for w in wanted:
        if w == "stress":
            stress_test()
        else:
            SCENARIOS[w]()
    # leave the demo accounts reconciled and reset
    subprocess.run(["psql", "-d", DB, "-X", "-q", "-f", str(SETUP)], capture_output=True)
