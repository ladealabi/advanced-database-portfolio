// Portfolio 4: 04_transfer_transaction.js (mongosh; needs a replica set)

const kt = db.getSiblingDB("kobotrust");

function transfer(from, to, amountStr, channel, ref) {
  const amount = NumberDecimal(amountStr);
  const session = db.getMongo().startSession();
  const accounts = session.getDatabase("kobotrust").accounts;
  const txns = session.getDatabase("kobotrust").transactions;
  try {
    session.withTransaction(() => {                       // retries TransientTransactionError automatically
      // idempotency: _id = client-supplied reference, so a duplicate insert fails
      const src = accounts.findOneAndUpdate(
        { _id: from, status: "ACTIVE", balance: { $gte: amount } },
        { $inc: { balance: NumberDecimal("-" + amountStr) } },
        { returnDocument: "after" });
      if (!src) throw new Error("Insufficient funds or inactive source account " + from);

      const dst = accounts.findOneAndUpdate(
        { _id: to, status: "ACTIVE", currency: src.currency },
        { $inc: { balance: amount } },
        { returnDocument: "after" });
      if (!dst) throw new Error("Destination account invalid: " + to);

      txns.insertOne({
        _id: ref, type: "TRANSFER", channel, status: "SUCCESS", amount,
        narration: "mongosh demo transfer", createdAt: new Date(),
        legs: [ { account: from, dir: "D", amount, balanceAfter: src.balance },
                { account: to,   dir: "C", amount, balanceAfter: dst.balance } ] });
    }, { readConcern: { level: "snapshot" }, writeConcern: { w: "majority" } });
    print(`COMMITTED ${ref}: ${from} -> ${to}  N${amountStr}`);
  } catch (e) {
    print(`ROLLED BACK ${ref}: ${e.message}`);
  } finally { session.endSession(); }
}

const bal = () => kt.accounts.find({ _id: { $in: ["1000000027", "1000000040"] } }, { balance: 1 }).toArray();
print("Before:"); printjson(bal());
transfer("1000000027", "1000000040", "2500.00", "MOBILE", "demo-ok-" + Date.now());
print("After successful transfer:"); printjson(bal());
transfer("1000000027", "1000000040", "999999999.00", "MOBILE", "demo-fail-" + Date.now());
print("After failed transfer (unchanged, because the whole transaction rolled back):"); printjson(bal());
const dupRef = "demo-dup-" + Date.now();
transfer("1000000027", "1000000040", "100.00", "USSD", dupRef);
transfer("1000000027", "1000000040", "100.00", "USSD", dupRef);   // retry with the same ref: duplicate _id, so it rolls back
print("After duplicate retry (debited only once):"); printjson(bal());
