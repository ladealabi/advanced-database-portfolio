# How to test the portfolio on your Mac

Each step lists the command to run, what you should see, and what to screenshot for the LMS. Run everything from the project folder:

```bash
cd ~/Documents/advanced-database-portfolio
```

---

## Step 0: One-time setup (about 10 minutes)

```bash
# 1. Tools (Homebrew)
brew install postgresql@16 redis coreutils
echo 'export PATH="$(brew --prefix postgresql@16)/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
pip3 install matplotlib networkx

# 2. Start the servers
brew services start postgresql@16
brew services start redis

# 3. The scripts connect as user "postgres" (Homebrew creates only your Mac user)
createuser -s postgres

# 4. Tell every script where the database is (add these to ~/.zshrc so they persist)
export PGHOST=localhost PGUSER=postgres PGDATABASE=kobotrust

# 5. Check
psql -d postgres -c "select version();"     # should say PostgreSQL 16.x
redis-cli ping                              # should say PONG
chmod +x run_all.sh portfolio-*/*.sh portfolio-*/*/*.sh
```
For MongoDB (Portfolio 4 and 5) you also need **Docker Desktop**: https://www.docker.com/products/docker-desktop/

---

## Option A: test everything in one go (about 15 minutes)
```bash
./run_all.sh
```
This rebuilds the database and overwrites every `evidence/` file with **your own** run. The numbers will be slightly different from mine because your machine is different, which is expected and shows the work was run independently. Afterwards, update any README figure that changed.

## Option B: test one portfolio at a time (recommended: commit each to GitHub after it passes)

### Portfolio 1: design
```bash
createdb kobotrust
psql -f portfolio-1-database-design/sql/01_schema.sql
psql -f portfolio-1-database-design/sql/02_seed_data.sql      # about 1 minute
psql -f portfolio-1-database-design/sql/03_business_logic.sql
psql -f portfolio-1-database-design/sql/04_constraint_tests.sql
```
**Expect:** the seed ends with three integrity checks that are all **0** and about 1,011,000 ledger rows. The constraint tests show **10 ERROR lines (T1–T10)**, which are the expected rejections, then a successful transfer (T11).
**Screenshot:** the integrity checks + the constraint test errors. Also open `diagrams/erd.png`.

### Portfolio 2: optimisation
```bash
cd portfolio-2-query-optimisation && python3 run_benchmark.py --runs 5 && cd ..
```
**Expect:** a "before" and an "after" time for each query. Q1, Q2, Q3 and Q6 become hundreds to thousands of times faster.
**Screenshot:** the terminal table + `evidence/benchmark_chart.png` + one before/after plan pair, for example `evidence/plans/before/Q1_account_statement.txt` vs `after/…`.

### Portfolio 3: transactions and concurrency
```bash
cd portfolio-3-transactions-concurrency && python3 run_scenarios.py && cd ..
```
**Expect** (open the files in `evidence/`):

| File | Look for |
|---|---|
| `s4_lost_update.txt` | `final_balance_should_be_20000` shows **30000.00**, which is the lost update |
| `s5a_write_skew_repeatable_read.txt` | total sent **80000.00** with a limit of 60000 |
| `s5b_serializable_prevents_write_skew.txt` | `could not serialize access due to read/write dependencies` |
| `s6_deadlock_and_lock_ordering.txt` | `ERROR: deadlock detected` in Part 1, none in Part 2 |
| `s7_stress_test_pgbench.txt` | (a) some deadlock failures; (b) **0 failed**, `money_conserved = t` |

**Screenshot:** s4, s5b, s6 and the s7 summary. **Optional, but strong for verification:** reproduce s4 by hand in **two Terminal windows** (`psql`) and screenshot them side by side.

### Portfolio 4: NoSQL
```bash
cd portfolio-4-nosql
./redis/redis_demo.sh | tee evidence/redis_demo_output.txt
python3 graph/fraud_graph_analysis.py                  # about 4 minutes; prints 1 HIGH RISK ring
psql -f graph/sql_recursive_cycle_check.sql

# MongoDB (needs Docker Desktop running)
brew install mongosh mongodb-database-tools   # if needed: brew tap mongodb/brew first
docker run -d --name kt-mongo -p 27017:27017 mongo:7.0 --replSet rs0
sleep 5 && docker exec kt-mongo mongosh --quiet --eval 'rs.initiate()'
./mongodb/export_from_postgres.sh ./mongodb/data       # about 1 minute, ~600 MB
MONGO_URI="mongodb://localhost:27017/kobotrust?directConnection=true" ./mongodb/load_mongodb.sh ./mongodb/data
mongosh "mongodb://localhost:27017/kobotrust?directConnection=true" mongodb/03_queries_and_aggregations.js | tee evidence/mongodb_queries_output.txt
mongosh "mongodb://localhost:27017/kobotrust?directConnection=true" mongodb/04_transfer_transaction.js     | tee evidence/mongodb_transaction_output.txt
cd ..
```
**Expect:** Redis K3 shows the second N40,000 **refused** (allowed = 0). The graph shows `[HIGH RISK] laps=3`. MongoDB D9 shows `Document failed validation`, and the transfer script shows COMMITTED, then ROLLED BACK, then a duplicate debited only once.
**Screenshot:** Redis K3, the graph ring (`evidence/graph_fraud_ring.png`), and the MongoDB D7/D8/D9 output plus the transaction output. **These MongoDB screenshots are evidence I could not produce, so they matter.**

### Portfolio 5: distributed and cloud
```bash
cd portfolio-5-distributed-cloud
./replication/replication_demo.sh | tee evidence/replication_demo_output.txt
./sharding/setup_shards.sh
psql -f sharding/01_coordinator.sql
psql -f sharding/02_distributed_queries.sql | tee evidence/sharding_queries_output.txt
./sharding/03_two_phase_commit.sh | tee evidence/two_phase_commit_output.txt
# MongoDB replica set
cd mongodb-cluster && docker compose up -d && ./init-replica-set.sh && ./failover-test.sh && cd ..
cd ..
```
**Expect:** the standby is read-only; stale reads followed by 1,500,000 rows; promotion in about 0.1 s; partition pruning (one `Foreign Scan`); 2PC ending with `MATCH`; MongoDB electing a new primary.
**Notes:**
- The replication demo **deliberately crashes and restarts your main PostgreSQL** (that is the failover test). If the server doesn't come back, run `brew services restart postgresql@16`.
- The extra demo servers live in `~/pgdemo` (ports 5433–5435). Stop them afterwards with `pg_ctl -D ~/pgdemo/shard_south stop` and `pg_ctl -D ~/pgdemo/shard_north stop`.
- Stop the single MongoDB container first (`docker stop kt-mongo`) because it uses port 27017 too.

---

## Troubleshooting
| Problem | Fix |
|---|---|
| `role "postgres" does not exist` | `createuser -s postgres` |
| `psql: command not found` | the `export PATH=…postgresql@16/bin…` line in Step 0, then open a new Terminal |
| `database "kobotrust" does not exist` | run Portfolio 1 first (every other portfolio uses its data) |
| `ModuleNotFoundError: matplotlib` / `networkx` | `pip3 install matplotlib networkx` |
| P3 timelines show output bunched at the end | `brew install coreutils` (provides `gstdbuf` for line-buffered output) |
| Port already in use (5433/5434/5435) | stop the old demo cluster with `pg_ctl -D ~/pgdemo/<name> stop` |
| `postgres_fdw` / `pgcrypto` extension missing | Homebrew's postgresql@16 includes them; check with `ls $(pg_config --sharedir)/extension \| grep fdw` |
