#!/usr/bin/env bash
# Initiates the 3-member replica set rs0 and demonstrates write/read concerns.

set -euo pipefail
docker exec kt-mongo1 mongosh --quiet --eval '
rs.initiate({ _id: "rs0", members: [
  { _id: 0, host: "kt-mongo1:27017", priority: 2 },   // preferred primary (e.g. Lagos DC)
  { _id: 1, host: "kt-mongo2:27017", priority: 1 },   // Abuja DC
  { _id: 2, host: "kt-mongo3:27017", priority: 1 }    // third site / cloud region
]});'
echo "waiting for election..."; sleep 12
docker exec kt-mongo1 mongosh --quiet --eval '
rs.status().members.forEach(m => print(m.name.padEnd(18), m.stateStr.padEnd(10), "health=" + m.health));
const kt = db.getSiblingDB("kobotrust");
// w:"majority": acknowledged only after 2 of 3 members have the write (survives a primary crash)
const t0 = Date.now();
kt.rs_probe.insertOne({ at: new Date(), note: "majority write" }, { writeConcern: { w: "majority", j: true } });
print("w:majority insert took", Date.now() - t0, "ms");
const t1 = Date.now();
kt.rs_probe.insertOne({ at: new Date(), note: "w1 write" }, { writeConcern: { w: 1 } });
print("w:1 insert took", Date.now() - t1, "ms");
'
echo "read from a SECONDARY (eventually consistent read scaling):"
docker exec kt-mongo2 mongosh --quiet --eval '
db.getMongo().setReadPref("secondaryPreferred");
printjson(db.getSiblingDB("kobotrust").rs_probe.find({}, {_id:0}).toArray());'
