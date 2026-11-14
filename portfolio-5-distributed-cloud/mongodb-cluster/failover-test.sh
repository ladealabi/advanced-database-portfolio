#!/usr/bin/env bash
# Kills the current PRIMARY and shows the automatic election (Raft-like protocol).

set -uo pipefail
PRIMARY=$(docker exec kt-mongo2 mongosh --quiet --eval 'rs.status().members.find(m => m.stateStr==="PRIMARY").name')
echo "current primary: $PRIMARY"
C=${PRIMARY%%:*}   # container name = host part, e.g. kt-mongo1
OBS=kt-mongo2; [ "$C" = "kt-mongo2" ] && OBS=kt-mongo3   # observe from a node we are NOT stopping
date +"%T.%3N stopping $C"; docker stop "$C" >/dev/null
for i in $(seq 1 30); do
  NEW=$(docker exec $OBS mongosh --quiet --eval \
        'try { (rs.status().members.find(m => m.stateStr==="PRIMARY")||{name:"none"}).name } catch(e) { "none" }' 2>/dev/null)
  echo "$(date +%T.%3N) primary = $NEW"; [ "$NEW" != "none" ] && [ "$NEW" != "$PRIMARY" ] && break; sleep 1
done
echo "writes continue on the new primary (the driver discovers it automatically):"
docker exec $OBS mongosh --quiet "mongodb://kt-mongo1:27017,kt-mongo2:27017,kt-mongo3:27017/kobotrust?replicaSet=rs0" --eval '
db.rs_probe.insertOne({ at: new Date(), note: "after failover" }, { writeConcern: { w: "majority" } });
print("documents:", db.rs_probe.countDocuments());'
docker start "$C" >/dev/null; echo "old primary restarted; it rejoins as SECONDARY and catches up from the oplog"
