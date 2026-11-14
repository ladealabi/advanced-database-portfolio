#!/usr/bin/env bash
# KoboTrust Advanced Database Portfolio: rebuild everything from scratch

set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(pwd)
PY=${PYTHON:-python3}   # set PYTHON=/usr/bin/python3 if matplotlib is installed for Apple's Python
export PGHOST=${PGHOST:-localhost} PGUSER=${PGUSER:-postgres} PGDATABASE=kobotrust
log() { printf '\n\033[1m[%s] %s\033[0m\n' "$(date +%T)" "$1"; }

log "P1: create database, schema, seed data, business logic, constraint tests"
dropdb --if-exists kobotrust
createdb kobotrust
cd "$ROOT/portfolio-1-database-design"
psql -X -q -v ON_ERROR_STOP=1 -f sql/01_schema.sql
psql -X -v ON_ERROR_STOP=1 -f sql/02_seed_data.sql > evidence/seed_run_output.txt 2>&1
psql -X -q -v ON_ERROR_STOP=1 -f sql/03_business_logic.sql
psql -X -f sql/04_constraint_tests.sql > evidence/constraint_tests_output.txt 2>&1
psql -X -c "\dt+ bank.*" -c "\d bank.account" -c "\d bank.ledger_entry" -c "\dD bank.*" > evidence/schema_describe.txt
psql -X -c "SELECT * FROM bank.v_customer_accounts ORDER BY customer_id LIMIT 8" > evidence/sample_rows.txt
tail -22 evidence/seed_run_output.txt

log "P2: baseline vs optimised benchmark"
cd "$ROOT/portfolio-2-query-optimisation"
rm -rf evidence && $PY run_benchmark.py --runs 5

log "P3: transaction and concurrency scenarios + stress test"
cd "$ROOT/portfolio-3-transactions-concurrency"
rm -rf evidence && $PY run_scenarios.py

log "P4: Redis key-value demo, graph analysis, SQL comparison"
cd "$ROOT/portfolio-4-nosql"
redis-cli ping >/dev/null 2>&1 || redis-server --daemonize yes
./redis/redis_demo.sh > evidence/redis_demo_output.txt 2>&1
$PY graph/fraud_graph_analysis.py
psql -X -f graph/sql_recursive_cycle_check.sql > evidence/sql_recursive_cycle_output.txt 2>&1
if [ "${EXPORT_MONGO:-0}" = "1" ]; then ./mongodb/export_from_postgres.sh ./mongodb/data; fi

log "P5: replication + failover, sharding, two-phase commit"
cd "$ROOT/portfolio-5-distributed-cloud"
./replication/replication_demo.sh > evidence/replication_demo_output.txt 2>&1
./sharding/setup_shards.sh
psql -X -f sharding/01_coordinator.sql > evidence/sharding_load_output.txt 2>&1
psql -X -f sharding/02_distributed_queries.sql > evidence/sharding_queries_output.txt 2>&1
./sharding/03_two_phase_commit.sh > evidence/two_phase_commit_output.txt 2>&1

log "Done. Evidence regenerated in every portfolio-*/evidence folder."
