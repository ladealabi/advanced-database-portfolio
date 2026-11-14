// Portfolio 4: 03_queries_and_aggregations.js   (mongosh)

const kt = db.getSiblingDB("kobotrust");
const show = (title, cursorOrDoc) => {
  print("\n=== " + title + " ===");
  printjson(cursorOrDoc && cursorOrDoc.toArray ? cursorOrDoc.toArray() : cursorOrDoc);
};

// D1. Customer 360 in ONE read (P1 needed customer JOIN account JOIN branch)
show("D1 customer profile with embedded accounts and beneficiaries",
  kt.customers.find({ "contact.email": "Chiamaka.Udeh1@Yahoo.com" },
                    { name: 1, kyc: 1, accounts: 1, beneficiaries: 1 })
    .collation({ locale: "en", strength: 2 })   // same collation as the index: case-insensitive AND indexed
    .limit(1)
);

// D2. Mobile home screen: balances for a customer's accounts
show("D2 home screen balances", kt.accounts.find({ customerId: 4242 }, { type: 1, balance: 1, status: 1 }));

// D3. Monthly statement: bucket pattern, a single document read by _id
// latest month that has activity for this account (uses the {account, month} index), then one read by _id
const latest = kt.statements.find({ account: "1000000027" }, { _id: 1 }).sort({ month: -1 }).limit(1).toArray()[0];
const stmt = latest && kt.statements.findOne({ _id: latest._id });
show("D3 statement bucket (summary)", stmt && { _id: stmt._id, count: stmt.count,
     totalDebit: stmt.totalDebit, totalCredit: stmt.totalCredit, closingBalance: stmt.closingBalance,
     firstEntries: stmt.entries.slice(0, 3) });

// D4. Account history: multikey index on legs.account, newest first
show("D4 last 5 transactions touching account 1000000027",
  kt.transactions.find({ "legs.account": "1000000027" },
                       { type: 1, channel: 1, amount: 1, createdAt: 1, narration: 1 })
                 .sort({ createdAt: -1 }).limit(5));

// D5. Failed transactions by channel, last week of October 2026 (partial index)
show("D5 failed transactions by channel (24-31 Oct 2026)", kt.transactions.aggregate([
  { $match: { status: "FAILED", createdAt: { $gte: ISODate("2026-10-24"), $lt: ISODate("2026-11-01") } } },
  { $group: { _id: "$channel", failed: { $sum: 1 }, value: { $sum: "$amount" } } },
  { $sort: { failed: -1 } }
]));

// D6. Monthly volume per channel in 2026 ($unwind is not needed: amount is top-level)
show("D6 2026 successful transfer volume by month and channel", kt.transactions.aggregate([
  { $match: { type: "TRANSFER", status: "SUCCESS",
              createdAt: { $gte: ISODate("2026-01-01"), $lt: ISODate("2027-01-01") } } },
  { $group: { _id: { month: { $dateToString: { format: "%Y-%m", date: "$createdAt" } }, channel: "$channel" },
              txns: { $sum: 1 }, value: { $sum: "$amount" } } },
  { $sort: { "_id.month": 1, value: -1 } },
  { $limit: 12 }
]));

// D7. Top 10 senders in October 2026, enriched with the customer's name ($lookup = join)
show("D7 top senders Oct 2026 with $lookup", kt.transactions.aggregate([
  { $match: { type: "TRANSFER", status: "SUCCESS",
              createdAt: { $gte: ISODate("2026-10-01"), $lt: ISODate("2026-11-01") } } },
  { $unwind: "$legs" },
  { $match: { "legs.dir": "D" } },
  { $group: { _id: "$legs.account", sent: { $sum: "$legs.amount" }, n: { $sum: 1 } } },
  { $sort: { sent: -1 } }, { $limit: 10 },
  { $lookup: { from: "accounts", localField: "_id", foreignField: "_id", as: "acct" } },
  { $unwind: "$acct" },
  { $lookup: { from: "customers", localField: "acct.customerId", foreignField: "_id", as: "cust" } },
  { $project: { _id: 0, account: "$_id", sent: 1, n: 1,
                customer: { $concat: [{ $first: "$cust.name.first" }, " ", { $first: "$cust.name.last" }] } } }
]));

// D8. Velocity fraud rule with $setWindowFields (MongoDB 5.0+): >=3 debits in 10 minutes
show("D8 velocity bursts in October 2026", kt.transactions.aggregate([
  { $match: { type: "TRANSFER", status: "SUCCESS",
              createdAt: { $gte: ISODate("2026-10-01"), $lt: ISODate("2026-11-01") } } },
  { $unwind: "$legs" }, { $match: { "legs.dir": "D", "legs.account": { $ne: "9990000001" } } },
  { $setWindowFields: {
      partitionBy: "$legs.account", sortBy: { createdAt: 1 },
      output: { inLast10Min: { $count: {}, window: { range: [-600, 0], unit: "second" } } } } },
  { $match: { inLast10Min: { $gte: 3 } } },
  { $group: { _id: "$legs.account", bursts: { $sum: 1 }, first: { $min: "$createdAt" } } },
  { $sort: { bursts: -1, _id: 1 } }, { $limit: 20 }
]));

// D9. Schema validation in action: an invalid document is rejected
print("\n=== D9 validator rejects a bad document ===");
try {
  kt.accounts.insertOne({ _id: "12345", customerId: 2, type: "SAVINGS", currency: "NGN",
                          balance: 100.5 /* double, not decimal */, status: "ACTIVE" });
} catch (e) { print("Rejected as expected:", e.errmsg || e.message); }

// D10. Query plans: proof that the indexes are used
print("\n=== D10 explain(): D4 uses the multikey compound index ===");
const ex = kt.transactions.find({ "legs.account": "1000000027" }).sort({ createdAt: -1 }).limit(5)
             .explain("executionStats");
printjson({ winningStage: ex.queryPlanner.winningPlan.inputStage?.stage || ex.queryPlanner.winningPlan.stage,
            index: JSON.stringify(ex.queryPlanner.winningPlan).match(/"indexName":"([^"]+)"/)?.[1],
            nReturned: ex.executionStats.nReturned, totalKeysExamined: ex.executionStats.totalKeysExamined,
            totalDocsExamined: ex.executionStats.totalDocsExamined, ms: ex.executionStats.executionTimeMillis });
