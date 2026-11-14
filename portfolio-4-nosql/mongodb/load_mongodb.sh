#!/usr/bin/env bash
# Portfolio 4: load_mongodb.sh
# Usage: ./load_mongodb.sh [datadir]    (datadir from export_from_postgres.sh)

set -euo pipefail
cd "$(dirname "$0")"
DATA="${1:-./data}"
URI="${MONGO_URI:-mongodb://localhost:27017/kobotrust}"

mongosh "$URI" --quiet 01_collections_and_validation.js
for c in customers accounts transactions statements; do
  # kyc.tier must be stored as int for the validator; mongoimport keeps JSON
  # integers as int32/int64 and $numberDecimal as Decimal128.
  mongoimport --uri "$URI" --collection "$c" --file "$DATA/$c.ndjson" --numInsertionWorkers 4
done
mongosh "$URI" --quiet 02_indexes.js
mongosh "$URI" --quiet --eval 'db.getCollectionNames().sort().forEach(c => print(c.padEnd(14), db[c].estimatedDocumentCount()))'
