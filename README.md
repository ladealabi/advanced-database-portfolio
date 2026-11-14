# Advanced Database Systems Portfolio: KoboTrust Digital Bank

**Course:** MIT 8103 Advanced Database Systems, 2026/2027 First Semester Continuous Assessment
**Student:** Alabi Ololade (301907269) · **Assessment:** Individual Practical Database Portfolio (40 marks)

---

## Selected case study / organisation

| | |
|---|---|
| **Organisation** | **KoboTrust Digital Bank**, a *simulated* Nigerian digital bank (fictional; all data is synthetic) |
| **Nature of the business** | A licensed retail digital bank. Customers open savings, current, kiddies and domiciliary (USD) accounts and move money through a mobile app, USSD, web, POS/ATM and 12 physical branches across Nigeria (Lagos, Ibadan, Port Harcourt, Enugu, Benin, Abuja, Kano, Kaduna, Jos). |
| **Users of the database** | Customers (self-service channels) · tellers and relationship officers (branch operations) · compliance officers (fraud, KYC, regulatory reports) · operations staff (reversals, reconciliation) · management (branch performance reports) |
| **Major data stored** | Customers (BVN, KYC tier, contacts), branches and staff hierarchy, account products and limits, accounts and balances, beneficiaries, transactions, **double-entry ledger postings**, audit log |
| **Key operations** | Open accounts · deposit, withdraw and **transfer funds** (idempotent, atomic) · **reverse failed transactions** · generate statements · enforce daily and KYC limits · audit balances and reconcile the ledger · detect fraud (velocity bursts, round-tripping rings) · branch and regulatory reporting |
| **Scale of the data set** | 20,001 customers · 30,001 accounts · ~519k transactions · ~1.01 million ledger entries (reproducible generator) |

The same case study is used in all five portfolio activities.

---

## Repository structure

```
advanced-database-portfolio/
├── portfolio-1-database-design/        ER diagram, schema DDL, constraints, normalisation, seed data
├── portfolio-2-query-optimisation/     workload queries, EXPLAIN ANALYZE before/after, indexes, benchmark
├── portfolio-3-transactions-concurrency/ commit/rollback, isolation levels, lost update, write skew, deadlock, pgbench
├── portfolio-4-nosql/                  MongoDB document model, Redis key-value, graph (NetworkX + Neo4j Cypher)
├── portfolio-5-distributed-cloud/      streaming replication + failover, postgres_fdw sharding, 2PC, MongoDB RS, cloud design
├── run_all.sh                          rebuilds everything and regenerates all evidence
└── README.md
```
Each folder has its own **README.md** that explains how the activity was implemented and tested, and an **`evidence/`** folder with captured output (plans, timelines, logs, charts).

## Technology
PostgreSQL 16.15 (with `postgres_fdw`, `pgcrypto`, `pg_stat_statements`, `pgbench`) · MongoDB 7.0 (scripts) · Redis 7.0.15 · Python 3 (matplotlib, NetworkX) · Mermaid (diagrams)

## How to reproduce
```bash
export PGHOST=localhost PGUSER=postgres
./run_all.sh            # about 15 min: P1 → P5, regenerates every evidence file
```
Or run a single portfolio by following the commands in its README. **Step-by-step test guide for macOS: [TESTING.md](TESTING.md).**

## Results at a glance

| Portfolio | Highlights (all numbers come from the `evidence/` files) |
|---|---|
| **1. Design** | 9 tables in BCNF with one documented, controlled denormalisation (`balance`). Domains, CHECKs, composite keys and a **deferred constraint trigger** enforcing Σdebit = Σcredit. 10/10 invalid operations rejected. 0 integrity violations across about 1M ledger rows. |
| **2. Optimisation** | 8-query workload measured before and after. Composite, partial, expression, covering and BRIN indexes, a materialized view and a query rewrite give speed-ups from about 1× (already optimal) to several thousand× (see `portfolio-2…/evidence/benchmark_chart.png`). |
| **3. Concurrency** | Real concurrent sessions demonstrate a **lost update** (N10,000 vanished) and three fixes, **write skew** under REPEATABLE READ prevented by **SERIALIZABLE**, and a **deadlock** prevented by ordered locking. pgbench, 16 clients: naive code deadlocks; `transfer_funds()` has 0 failures, 0 deadlocks and money conserved. |
| **4. NoSQL** | MongoDB document model (embedding, extended reference, bucket pattern, `$jsonSchema`, multi-doc transaction). **Redis** for sessions, idempotency, an atomic daily-limit counter, a leaderboard and a stream (executed). **Graph** analysis found the planted money-laundering ring among 24k accounts (executed). |
| **5. Distributed** | Streaming replication: stale reads measured (~0.28 s), sync commit cost (+0.17 ms), the CP behaviour when the sync standby is down, failover in 0.15 s with RPO 0. **Sharding** across 2 nodes with pruning, pushdown and a 140× fix from remote estimates. **Two-phase commit** across shards, including the blocking in-doubt failure case. |

## Academic integrity, AI use and references
See `docs/AI_USE_AND_REFERENCES.md`.
