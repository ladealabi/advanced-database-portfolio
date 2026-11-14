#!/usr/bin/env python3
"""MIT 8103 Portfolio 4: GRAPH model for KoboTrust fraud analytics.
Usage: PGHOST=localhost PGUSER=postgres python3 fraud_graph_analysis.py [--full]"""
import csv, os, subprocess, sys, pathlib, time
import networkx as nx

HERE = pathlib.Path(__file__).resolve().parent
EVID = HERE.parent / "evidence"
DB = os.environ.get("PGDATABASE", "kobotrust")

SQL = """
SELECT s.account_number, d.account_number, count(*), sum(t.amount), min(t.created_at), max(t.created_at)
FROM bank.txn t
JOIN bank.ledger_entry ls ON ls.txn_id = t.txn_id AND ls.direction = 'D'
JOIN bank.ledger_entry ld ON ld.txn_id = t.txn_id AND ld.direction = 'C'
JOIN bank.account s ON s.account_id = ls.account_id
JOIN bank.account d ON d.account_id = ld.account_id
WHERE t.txn_type = 'TRANSFER' AND t.status = 'SUCCESS'
  AND t.created_at >= '2026-09-01' AND t.created_at < '2026-11-01'
  AND s.type_code <> 'GL' AND d.type_code <> 'GL'
GROUP BY 1, 2
"""


def load_edges():
    out = subprocess.run(["psql", "-d", DB, "-X", "-q", "-At", "-F", "|", "-c", SQL],
                         capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        src, dst, n, amt, first, last = line.split("|")
        yield src, dst, int(n), float(amt), first, last


def main():
    EVID.mkdir(exist_ok=True)
    lines = []
    log = lambda s="": (print(s), lines.append(s))

    t0 = time.time()
    G = nx.DiGraph()
    for src, dst, n, amt, first, last in load_edges():
        G.add_edge(src, dst, count=n, amount=amt, first=first, last=last)
    log(f"Graph built in {time.time()-t0:.2f}s: {G.number_of_nodes():,} account nodes, "
        f"{G.number_of_edges():,} SENT_TO edges (Sep-Oct 2026)")

    # G1
    log("\n=== G1. Round-tripping: directed cycles of length 3-5 ===")
    t0 = time.time()
    if "--full" in sys.argv:
        # exhaustive search over the whole network (about 4-15 minutes)
        search_graph, scope = G, "the whole network"
    else:
        # fast mode: a ring used for round-tripping repeats its transfers, so only
        # account pairs with 2+ transfers can form a HIGH-RISK cycle; search those
        search_graph = G.edge_subgraph([(u, v) for u, v, d in G.edges(data=True) if d["count"] >= 2]).copy()
        scope = f"{search_graph.number_of_edges():,} repeated-transfer edges (use --full for every edge)"
    cycles = [c for c in nx.simple_cycles(search_graph, length_bound=5) if len(c) >= 3]
    log(f"searched {scope}: found {len(cycles)} cycle(s) in {time.time()-t0:.1f}s.")
    log("A cycle traversed REPEATEDLY (laps = min transfers on any edge) is the round-tripping signature,")
    log("so cycles are ranked by laps, then by value. Chance cycles (each edge used once) rank as low.")
    def laps(c): return min(G[u][v]["count"] for u, v in zip(c, c[1:] + c[:1]))
    def value(c): return sum(G[u][v]["amount"] for u, v in zip(c, c[1:] + c[:1]))
    cycles.sort(key=lambda c: (-laps(c), -value(c)))
    for c in cycles[:8]:
        flag = "HIGH RISK" if laps(c) >= 2 else "low"
        log(f"  [{flag:9s}] laps={laps(c)}  " + " -> ".join(c + [c[0]]) + f"  | N{value(c):,.2f}")

    # G2
    log("\n=== G2. PageRank (weighted by amount): where does money converge? ===")
    try:
        pr = nx.pagerank(G, weight="amount")            # fast path (uses scipy)
    except ModuleNotFoundError:                          # no scipy installed: pure-Python version
        from networkx.algorithms.link_analysis.pagerank_alg import _pagerank_python
        pr = _pagerank_python(G, weight="amount")
    for acct, score in sorted(pr.items(), key=lambda x: -x[1])[:8]:
        log(f"  {acct}  pagerank={score:.6f}  in_degree={G.in_degree(acct):3d}  "
            f"received=N{sum(d['amount'] for _,_,d in G.in_edges(acct, data=True)):,.2f}")

    # G3
    log("\n=== G3. Fan-out (one account paying many) / fan-in (many paying one) ===")
    for label, deg in (("fan-out", G.out_degree()), ("fan-in", G.in_degree())):
        top = sorted(deg, key=lambda x: -x[1])[:5]
        log(f"  top {label}: " + ", ".join(f"{a} ({d})" for a, d in top))

    # G4
    log("\n=== G4. Shortest money path between two accounts (degrees of separation) ===")
    if cycles:
        a, b = cycles[0][0], cycles[0][-1]   # how far is the ring's last hop from its origin?
        log(f"  {a} -> {b}: " + " -> ".join(nx.shortest_path(G, a, b)))
    und = G.to_undirected()
    comp = max(nx.connected_components(und), key=len)
    log(f"  largest connected component: {len(comp):,} of {G.number_of_nodes():,} accounts "
        f"({100*len(comp)/G.number_of_nodes():.1f}%) are linked by some chain of transfers")

    # export for Neo4j
    with open(HERE / "neo4j_accounts.csv", "w", newline="") as f:
        w = csv.writer(f); w.writerow(["accountNumber:ID(Account)", "pagerank:float"])
        for n in G.nodes: w.writerow([n, f"{pr[n]:.8f}"])
    with open(HERE / "neo4j_sent_to.csv", "w", newline="") as f:
        w = csv.writer(f); w.writerow([":START_ID(Account)", ":END_ID(Account)", "count:int", "amount:float", ":TYPE"])
        for u, v, d in G.edges(data=True): w.writerow([u, v, d["count"], f"{d['amount']:.2f}", "SENT_TO"])
    log(f"\nExported neo4j_accounts.csv and neo4j_sent_to.csv for `neo4j-admin database import`")

    (EVID / "graph_analysis_output.txt").write_text("\n".join(lines) + "\n")
    draw_ring(G, cycles)


def draw_ring(G, cycles):
    """Picture of the detected ring plus its 1-hop neighbourhood (evidence figure)."""
    if not cycles:
        return
    import matplotlib; matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    ring = cycles[0]   # highest-risk cycle (already ranked)
    nodes = set(ring)
    for n in ring:
        nodes |= set(list(G.predecessors(n))[:3]) | set(list(G.successors(n))[:3])
    H = G.subgraph(nodes)
    pos = nx.kamada_kawai_layout(H)
    fig, ax = plt.subplots(figsize=(9, 7), dpi=150)
    ring_edges = list(zip(ring, ring[1:] + ring[:1]))
    other = [e for e in H.edges if e not in ring_edges]
    nx.draw_networkx_edges(H, pos, edgelist=other, edge_color="#c3c9d1", arrows=True, ax=ax, arrowsize=8)
    nx.draw_networkx_edges(H, pos, edgelist=ring_edges, edge_color="#d1242f", width=2.6, arrows=True,
                           ax=ax, arrowsize=16, connectionstyle="arc3,rad=0.12")
    nx.draw_networkx_nodes(H, pos, nodelist=[n for n in H if n not in ring], node_color="#9aa5b1", node_size=120, ax=ax)
    nx.draw_networkx_nodes(H, pos, nodelist=ring, node_color="#d1242f", node_size=420, ax=ax)
    nx.draw_networkx_labels(H, pos, labels={n: n for n in ring}, font_size=7, ax=ax,
                            verticalalignment="bottom")
    edge_lbl = {(u, v): f"N{G[u][v]['amount']:,.0f}" for u, v in ring_edges}
    nx.draw_networkx_edge_labels(H, pos, edge_labels=edge_lbl, font_size=6.5, font_color="#d1242f", ax=ax)
    ax.set_title(f"Detected round-tripping ring ({len(ring)} accounts) and its neighbours", fontsize=11)
    ax.axis("off"); fig.tight_layout()
    fig.savefig(EVID / "graph_fraud_ring.png")


if __name__ == "__main__":
    main()
