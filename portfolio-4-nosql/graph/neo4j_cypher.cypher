// Portfolio 4: neo4j_cypher.cypher

// ---- schema
CREATE CONSTRAINT account_pk IF NOT EXISTS FOR (a:Account) REQUIRE a.accountNumber IS UNIQUE;

// ---- load
LOAD CSV WITH HEADERS FROM 'file:///neo4j_accounts.csv' AS row
MERGE (:Account {accountNumber: row.`accountNumber:ID(Account)`, pagerank: toFloat(row.`pagerank:float`)});

LOAD CSV WITH HEADERS FROM 'file:///neo4j_sent_to.csv' AS row
MATCH (s:Account {accountNumber: row.`:START_ID(Account)`})
MATCH (d:Account {accountNumber: row.`:END_ID(Account)`})
MERGE (s)-[:SENT_TO {count: toInteger(row.`count:int`), amount: toFloat(row.`amount:float`)}]->(d);

// ---- Q1: round-tripping: money returns to the same account within 3-5 hops
MATCH p = (a:Account)-[:SENT_TO*3..5]->(a)
WHERE all(r IN relationships(p) WHERE r.count >= 2)
RETURN [n IN nodes(p) | n.accountNumber] AS ring,
       reduce(s = 0.0, r IN relationships(p) | s + r.amount) AS value
ORDER BY value DESC LIMIT 10;

// ---- Q2: everyone within 2 hops of a flagged account (investigation scope)
MATCH (flag:Account {accountNumber: '1000092171'})-[:SENT_TO*1..2]-(n:Account)
RETURN DISTINCT n.accountNumber, n.pagerank ORDER BY n.pagerank DESC LIMIT 25;

// ---- Q3: shortest money path between two accounts
MATCH p = shortestPath((a:Account {accountNumber:'1000092171'})-[:SENT_TO*..6]->(b:Account {accountNumber:'1000092158'}))
RETURN [n IN nodes(p) | n.accountNumber] AS path, length(p) AS hops;

// ---- Q4: collection accounts (fan-in from many distinct senders) = possible mules
MATCH (s:Account)-[r:SENT_TO]->(m:Account)
WITH m, count(DISTINCT s) AS senders, sum(r.amount) AS received
WHERE senders >= 8
RETURN m.accountNumber, senders, received ORDER BY senders DESC, received DESC LIMIT 10;
