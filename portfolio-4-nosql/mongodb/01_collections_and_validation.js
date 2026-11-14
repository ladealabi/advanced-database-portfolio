// Portfolio 4: 01_collections_and_validation.js   (run with mongosh)

const kt = db.getSiblingDB("kobotrust");
["customers", "accounts", "transactions", "statements"].forEach(c => kt.getCollection(c).drop());

const decimal = { bsonType: "decimal" };

kt.createCollection("customers", {
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["_id", "bvn", "name", "contact", "kyc", "status", "accounts"],
    properties: {
      bvn:     { bsonType: "string", pattern: "^[0-9]{11}$" },
      name:    { bsonType: "object", required: ["first", "last"] },
      contact: { bsonType: "object", required: ["email", "phone"],
                 properties: { phone: { bsonType: "string", pattern: "^\\+234[0-9]{10}$" } } },
      kyc:     { bsonType: "object", required: ["tier"],
                 properties: { tier: { bsonType: "number", minimum: 1, maximum: 3 } } },
      status:  { enum: ["ACTIVE", "SUSPENDED", "CLOSED"] },
      accounts:      { bsonType: "array", minItems: 1, items: { bsonType: "object", required: ["accountNumber", "type"] } },
      beneficiaries: { bsonType: "array", maxItems: 50 }      // bounded array: avoids unbounded document growth
    } } },
  validationLevel: "strict", validationAction: "error"
});

kt.createCollection("accounts", {
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["_id", "customerId", "type", "currency", "balance", "status"],
    properties: {
      _id:      { bsonType: "string", pattern: "^[0-9]{10}$" },          // NUBAN as natural _id
      type:     { enum: ["SAVINGS", "CURRENT", "KIDDIES", "DOMUSD", "GL"] },
      currency: { enum: ["NGN", "USD", "GBP"] },
      balance:  decimal,                                                  // Decimal128, never double, for money
      status:   { enum: ["ACTIVE", "DORMANT", "FROZEN", "CLOSED"] }
    } } }
});

kt.createCollection("transactions", {
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["_id", "type", "channel", "status", "amount", "createdAt", "legs"],
    properties: {
      type:    { enum: ["DEPOSIT", "WITHDRAWAL", "TRANSFER", "REVERSAL", "FEE"] },
      channel: { enum: ["MOBILE", "USSD", "WEB", "POS", "ATM", "BRANCH"] },
      status:  { enum: ["PENDING", "SUCCESS", "FAILED", "REVERSED"] },
      amount:  decimal,
      legs:    { bsonType: "array",
                 items: { bsonType: "object", required: ["account", "dir", "amount"],
                          properties: { dir: { enum: ["D", "C"] }, amount: decimal } } }
    } } }
});

kt.createCollection("statements");   // bucket documents, written only by the batch job

print("Collections created:", kt.getCollectionNames().sort().join(", "));
