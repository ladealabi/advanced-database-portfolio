# Portfolio 4: NoSQL and Advanced Data Models

**Case study:** KoboTrust Digital Bank, the same data and business as Portfolios 1–3.
**Thesis:** the ledger stays relational (ACID, constraints, joins), but three KoboTrust workloads are a better fit for other models. This **polyglot persistence** design gives each workload the model that suits it:

| Workload | Model | Engine | Folder | Status |
|---|---|---|---|---|
| Customer 360, account history, statements for the mobile app | **Document** | MongoDB 7 (Docker, single-node replica set) | `mongodb/` | **Executed**: `evidence/mongodb_queries_output.txt`, `evidence/mongodb_transaction_output.txt` |
| Sessions, idempotency keys, daily limits, rate limiting, cache, leaderboard, event stream | **Key-value** (+ sorted set, stream) | Redis 7 | `redis/` | **Executed**: `evidence/redis_demo_output.txt` |
| Fraud analytics on the money-flow network | **Graph** | NetworkX (executed), Neo4j/Cypher (scripts) | `graph/` | **Executed**: `evidence/graph_analysis_output.txt`, `graph_fraud_ring.png` |

---

## A. Document model (MongoDB)

### A1. Relational → document mapping
| Relational (P1) | Document (P4) | Pattern and reason |
|---|---|---|
| `customer` + `beneficiary` + a list of accounts | **`customers`**: beneficiaries **embedded**; `accounts[]` holds an **extended reference** (number, type, currency) | Read together on every login, so one read replaces a 3-table join. `beneficiaries` has a bounded size (validator `maxItems: 50`). |
| `account` + `branch` + `account_type` | **`accounts`** (`_id` = NUBAN); branch and limits **embedded as copies** | The balance changes constantly, so it lives in its own small document and is **referenced** from customers. Embedding it in the customer would rewrite a large document on every transfer. Branch and limit data change rarely, so the copy is acceptable. |
| `txn` + `ledger_entry` | **`transactions`**: ledger legs **embedded** in the transaction document | A single-document write is atomic in MongoDB, so the D/C pair is stored all-or-nothing in one write. |
| Statement = a window query over `ledger_entry` | **`statements`**: **bucket pattern**, one document per account per month (`_id: "1000000027:2026-03"`) | A monthly statement becomes **one** `_id` lookup instead of a range scan plus sort. |
| `NUMERIC(18,2)` | `Decimal128` (`$numberDecimal`) | Exact money values; the validator rejects `double` (see D9). |
| CHECK / FK constraints | `$jsonSchema` validator (`01_collections_and_validation.js`) | Schema-*flexible*, not schema-less: the core fields are still enforced. |

Sample documents produced from the real data: `mongodb/sample-data/*.sample.ndjson`.

### A2. Files and how to run
```bash
# 1. export the PostgreSQL data as MongoDB documents (executed here: 20,003 customers,
#    30,104 accounts, 591,159 transactions, 379,365 statement buckets; every line JSON-validated)
./mongodb/export_from_postgres.sh ./mongodb/data
# 2. start MongoDB as a single-node replica set (transactions need a replica set)
docker run -d --name kt-mongo -p 27017:27017 mongo:7.0 --replSet rs0
docker exec kt-mongo mongosh --eval 'rs.initiate()'
# 3. create validated collections, import, build indexes
./mongodb/load_mongodb.sh ./mongodb/data
# 4. queries, aggregations, explain(); then the ACID transfer
mongosh mongodb://localhost:27017/kobotrust mongodb/03_queries_and_aggregations.js | tee evidence/mongodb_queries_output.txt
mongosh mongodb://localhost:27017/kobotrust mongodb/04_transfer_transaction.js     | tee evidence/mongodb_transaction_output.txt
```
> **Executed** on MongoDB 7.0 in Docker (`mongo:7.0`, replica set `rs0`). All 1,009,318 documents imported with 0 failures (20,003 customers, 30,104 accounts, 579,846 transactions, 379,365 statement buckets). Results: D8 found the **11 planted velocity-burst accounts** (same as P2-Q4); D9 printed `Document failed validation`; D10 used `IXSCAN` on `legs.account_1_createdAt_-1` (5 keys examined, 5 docs, 0 ms); script 04 showed one COMMITTED transfer, one ROLLED BACK (insufficient funds, balances unchanged) and a duplicate-reference retry rejected with `E11000 duplicate key`, so the account was debited only once.

### A3. What the queries show (`03_queries_and_aggregations.js`)
D1 customer 360 in one read (case-insensitive via collation) · D2 home-screen balances · D3 statement bucket · D4 account history on a multikey compound index · D5 failed transactions via a **partial index** · D6 `$group` by month and channel · D7 top senders with `$unwind` + `$lookup` · D8 velocity fraud rule with `$setWindowFields` (the MongoDB equivalent of SQL `lag()`) · D9 validator rejection · D10 `explain("executionStats")`.

### A4. Multi-document ACID transfer (`04_transfer_transaction.js`)
`session.withTransaction()` with `readConcern: snapshot` and `writeConcern: majority`. The conditional `findOneAndUpdate({balance: {$gte: amount}}, {$inc: …})` is a document-level atomic check-and-debit, which is the MongoDB equivalent of `UPDATE … SET balance = balance - x WHERE balance >= x`, so **lost updates cannot occur**. The client reference is used as `_id`, which gives **idempotency**.

---

## B. Key-value model (Redis): executed
Evidence: `evidence/redis_demo_output.txt`

| # | Feature | Redis structure | Result |
|---|---|---|---|
| K1 | Login sessions | `SET … EX 900` | TTL 900 s. Expiry is automatic, with no cleanup job. |
| K2 | Idempotency of retried transfer requests | `SET key NX EX` | The second SET returns `(nil)`, so the duplicate is rejected before it reaches PostgreSQL |
| K3 | Customer daily limit (N60,000) | Lua script: `GET` + `INCRBYFLOAT` + `EXPIREAT midnight` | First N40,000 allowed, second N40,000 **refused**. The script is atomic, so the **write skew from P3-S5a cannot happen**, and the check is O(1) instead of SUM over the ledger (fixes P3 finding 3). |
| K4 | OTP brute-force lockout | `INCR` + `EXPIRE 300` | 4th attempt BLOCKED |
| K5 | Balance cache-aside | `HSET` + `EXPIRE` | Invalidated with `DEL` on every transfer |
| K6 | Top receivers leaderboard (Oct 2026) | Sorted set `ZINCRBY` (amounts in **kobo**, because scores are doubles) | 15,649 accounts ranked. Each new credit is O(log N) with no `GROUP BY`. |
| K7 | Transaction notification events | Stream + consumer group `XADD` / `XREADGROUP` / `XPENDING` | SMS service consumes events; un-acked messages are tracked |
| K8 | Latency | `redis-benchmark` vs `pgbench` | Redis ≈ **100k ops/s, p50 0.10 ms**; PostgreSQL indexed PK lookup ≈ **40–45k tps, 0.44–0.50 ms** (same machine, 20 clients) |

---

## C. Graph model: executed
Evidence: `evidence/graph_analysis_output.txt`, `evidence/graph_fraud_ring.png`, `evidence/sql_recursive_cycle_output.txt`

Accounts are **nodes** and aggregated transfers are **`SENT_TO` edges** (count, amount). Sep–Oct 2026 gives **24,073 nodes and 49,647 edges**.

| # | Analysis | Result |
|---|---|---|
| G1 | Directed cycles of length 3–5 (round-tripping / layering) | Default (fast) mode searches only account pairs with 2+ transfers and finds the ring **instantly**. The exhaustive `--full` search (about 4–14 min) found 13 cycles: 12 are **chance cycles** (each edge used once), and **one ring was traversed 3 times**: `1000092171 → 1000092184 → 1000092197 → 1000092210 → 1000092158 → 1000092171`, N1,395,000 moved. This is the pattern planted in the seed data, and ranking by "laps" separates it cleanly. |
| G2 | PageRank weighted by amount | Accounts where money converges (candidate collection or mule accounts) |
| G3 | Fan-out / fan-in degree | Distribution vs collection behaviour |
| G4 | Shortest path + connected components | 99.8 % of accounts are linked by some chain of transfers. This is the "small world" property, which is why investigations need hop limits. |

**SQL comparison:** `sql_recursive_cycle_check.sql` answers "does money from X return to X within 5 hops?" with a recursive CTE. It finds the same ring in **1.8 ms** when given a *starting* account, but it needs path arrays and manual revisit checks. The Cypher version (`neo4j_cypher.cypher`, Q1) is one pattern: `MATCH p=(a)-[:SENT_TO*3..5]->(a)`. Enumerating *all* cycles is expensive in any engine (the `--full` search took about 4–14 min), while pruning to repeated-transfer edges finds the same high-risk ring instantly. Production systems likewise prune first or run seeded checks from newly flagged accounts.

---

## D. Suitability: when to use which model

| Criterion | Relational (PostgreSQL) | Document (MongoDB) | Key-value (Redis) | Graph (Neo4j) |
|---|---|---|---|---|
| KoboTrust role | **System of record**: ledger, balances | Read-optimised customer/app views | Ephemeral, high-speed state | Fraud and AML analytics |
| Consistency | Strong, multi-row ACID, SERIALIZABLE | Single-doc atomic; multi-doc txns need a replica set and cost more | Single-command / Lua atomic; persistence optional | ACID per transaction |
| Schema | Rigid, enforced | Flexible + `$jsonSchema` | None (app-defined keys) | Labels and properties |
| Best query shape | Joins, aggregates, constraints | Fetch an aggregate by key; nested data | O(1) key lookups, counters, rankings | Variable-length paths, neighbourhoods |
| Weakness here | Hot read paths need joins; path queries are clumsy | Duplicated data (branch copied into accounts) must be kept in sync | RAM-bound; not a system of record | Not suited to the ledger's bulk aggregates |

**Why the ledger was *not* moved to NoSQL:** double-entry correctness depends on multi-row invariants (Σdebits = Σcredits, no overdraft, customer-level limits). P3 showed that even *within* PostgreSQL these need row locks or SERIALIZABLE. A document store can model a single transfer atomically, but customer-level rules across many documents would push the integrity logic back into application code. The NoSQL stores here are **derived** from the ledger (export, cache, events) and are never the source of truth.
