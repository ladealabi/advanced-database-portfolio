// Portfolio 5: MongoDB sharding plan for KoboTrust (run on a mongos router)

sh.enableSharding("kobotrust");

// transactions: hashed _id spreads writes evenly
sh.shardCollection("kobotrust.transactions", { _id: "hashed" });

// statements: range on {account, month}, so one account's months are co-located
// and a statement read is a single-shard targeted query.
sh.shardCollection("kobotrust.statements", { account: 1, month: 1 });

// accounts and customers: hashed on _id (point lookups only)
sh.shardCollection("kobotrust.accounts",  { _id: "hashed" });
sh.shardCollection("kobotrust.customers", { _id: "hashed" });

// Zone sharding (data residency): pin each region's data to its own shards

sh.status();
