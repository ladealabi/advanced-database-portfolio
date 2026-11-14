// Portfolio 4: 02_indexes.js   (mongosh)

const kt = db.getSiblingDB("kobotrust");

// customers: login by e-mail / phone, KYC lookup by BVN (all unique)
kt.customers.createIndex({ "contact.email": 1 }, { unique: true, collation: { locale: "en", strength: 2 } }); // case-insensitive
kt.customers.createIndex({ "contact.phone": 1 }, { unique: true });
kt.customers.createIndex({ bvn: 1 }, { unique: true });
// multikey index on an embedded array: "which customer owns account X?"
kt.customers.createIndex({ "accounts.accountNumber": 1 });

// accounts: home screen (all accounts of a customer)
kt.accounts.createIndex({ customerId: 1 });

// transactions: account history. Multikey on legs.account (E), createdAt (S/R)
kt.transactions.createIndex({ "legs.account": 1, createdAt: -1 });
// operations dashboard: partial index, only FAILED transactions
kt.transactions.createIndex({ createdAt: -1 },
  { partialFilterExpression: { status: "FAILED" }, name: "failed_by_time" });
kt.transactions.createIndex({ channel: 1, createdAt: -1 });

// statements: the _id "account:YYYY-MM" already gives direct lookup; this
// index serves "all months of an account"
kt.statements.createIndex({ account: 1, month: -1 });

["customers", "accounts", "transactions", "statements"].forEach(c =>
  print(c.padEnd(13), kt.getCollection(c).getIndexes().map(i => i.name).join(", ")));
