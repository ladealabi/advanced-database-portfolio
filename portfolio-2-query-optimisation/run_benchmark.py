#!/usr/bin/env python3
"""MIT 8103 Portfolio 2: before/after optimisation benchmark for KoboTrust.
Usage:  PGHOST=localhost PGUSER=postgres python3 run_benchmark.py [--runs 7]"""
import argparse, csv, json, os, re, statistics, subprocess, pathlib

HERE = pathlib.Path(__file__).resolve().parent
SQL = HERE / "sql"
EVID = HERE / "evidence"
DB = os.environ.get("PGDATABASE", "kobotrust")


def psql(sql: str, fmt_args=("-At",)) -> str:
    """Run SQL through psql and return stdout. Errors are raised."""
    out = subprocess.run(["psql", "-d", DB, "-v", "ON_ERROR_STOP=1", "-X", "-q", *fmt_args],
                         input="SET search_path = bank, public;\n" + sql,
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr)
    return out.stdout


def load_queries(path):
    """Split a .sql file on '-- name: X' markers into {name: sql}."""
    text = path.read_text()
    parts = re.split(r"^-- name:\s*(\S+)\s*$", text, flags=re.M)
    queries = {}
    for i in range(1, len(parts), 2):
        body = "\n".join(l for l in parts[i + 1].splitlines() if not l.startswith("--")).strip()
        queries[parts[i]] = body.rstrip(";")
    return queries


def measure(name, sql, phase, runs):
    plan_dir = EVID / "plans" / phase
    plan_dir.mkdir(parents=True, exist_ok=True)
    # 1) human-readable plan (first run also warms the cache)
    psql(sql + ";")  # warm-up
    text_plan = psql(f"EXPLAIN (ANALYZE, BUFFERS, COSTS, VERBOSE OFF) {sql};", ("-X",))
    (plan_dir / f"{name}.txt").write_text(f"-- {name} ({phase})\n{sql};\n\n{text_plan}")
    # 2) result sample
    if phase == "before" or "rewritten" in name or "_mv" in name:
        res = psql(sql + "\nLIMIT 15;" if "LIMIT" not in sql.upper() else sql + ";", ("-X",))
        (EVID / "query_results").mkdir(exist_ok=True)
        (EVID / "query_results" / f"{name}.txt").write_text(f"-- {name}\n{sql};\n\n{res}")
    # 3) timings: Execution Time from EXPLAIN ANALYZE JSON (server-side, no network noise)
    times, planning, buffers = [], [], 0
    for _ in range(runs):
        j = json.loads(psql(f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {sql};"))[0]
        times.append(j["Execution Time"])
        planning.append(j["Planning Time"])
        p = j["Plan"]
        buffers = p.get("Shared Hit Blocks", 0) + p.get("Shared Read Blocks", 0)
    top = j["Plan"]
    return {"query": name, "phase": phase,
            "median_exec_ms": round(statistics.median(times), 3),
            "median_plan_ms": round(statistics.median(planning), 3),
            "shared_buffers_touched": buffers,
            "top_node": top["Node Type"],
            "plan_nodes": ", ".join(sorted(set(re.findall(r'"Node Type": "([^"]+)"',
                                                          json.dumps(j))))),
            }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=7)
    ap.add_argument("--chart-only", action="store_true", help="redraw the chart from benchmark_results.csv")
    args = ap.parse_args()
    EVID.mkdir(exist_ok=True)
    if args.chart_only:
        with open(EVID / "benchmark_results.csv") as f:
            make_chart([{**r, "median_exec_ms": float(r["median_exec_ms"])} for r in csv.DictReader(f)])
        return

    workload = load_queries(SQL / "01_workload_queries.sql")
    rewrites = load_queries(SQL / "03_rewritten_queries.sql")
    rows = []

    print("== resetting to baseline")
    psql((SQL / "00_reset_baseline.sql").read_text())
    for n, q in workload.items():
        r = measure(n, q, "before", args.runs); rows.append(r)
        print(f"  before {n:40s} {r['median_exec_ms']:>10.3f} ms  [{r['plan_nodes']}]")

    print("== applying optimisations")
    psql((SQL / "02_optimisations.sql").read_text())
    for n, q in {**workload, **rewrites}.items():
        r = measure(n, q, "after", args.runs); rows.append(r)
        print(f"  after  {n:40s} {r['median_exec_ms']:>10.3f} ms  [{r['plan_nodes']}]")

    with open(EVID / "benchmark_results.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader(); w.writerows(rows)

    # index sizes (B-tree vs BRIN vs partial ...)
    sizes = psql("""SELECT indexrelid::regclass AS index, pg_size_pretty(pg_relation_size(indexrelid)) AS size,
                    pg_relation_size(indexrelid) AS bytes
                    FROM pg_index WHERE indrelid::regclass::text IN
                    ('ledger_entry','txn','customer','account') ORDER BY bytes DESC;""", ("-X",))
    (EVID / "index_sizes.txt").write_text(sizes)

    make_chart(rows)
    print("== done: evidence/benchmark_results.csv, evidence/benchmark_chart.png, evidence/plans/")


def make_chart(rows):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    before = {r["query"]: r["median_exec_ms"] for r in rows if r["phase"] == "before"}
    after = {r["query"]: r["median_exec_ms"] for r in rows if r["phase"] == "after"}
    # best "after" variant: index-only, or the rewrite if one exists
    best = {}
    for q in before:
        alts = [v for k, v in after.items() if k == q or k.startswith(q.split("_")[0] + "_")]
        best[q] = min(alts)
    short = {"Q1": "statement", "Q2": "login lookup", "Q3": "failed txns", "Q4": "velocity fraud",
             "Q5": "dormant accts", "Q6": "last activity", "Q7": "branch report\n(→ mat. view)", "Q8": "home screen"}
    labels = [q.split("_")[0] + "\n" + short.get(q.split("_")[0], "") for q in before]
    x = range(len(labels))
    fig, ax = plt.subplots(figsize=(11, 5.2), dpi=160)
    ax.bar([i - 0.2 for i in x], [before[q] for q in before], 0.4, label="Before (baseline)", color="#9aa5b1")
    ax.bar([i + 0.2 for i in x], [best[q] for q in before], 0.4, label="After (indexes / rewrite)", color="#1f6feb")
    ax.set_yscale("log")
    ax.set_ylabel("Median execution time (ms, log scale)")
    ax.set_title("KoboTrust workload: median execution time before vs after optimisation")
    ax.set_xticks(list(x)); ax.set_xticklabels(labels, fontsize=8)
    for i, q in enumerate(before):
        sp = before[q] / best[q] if best[q] else 0
        ax.text(i + 0.2, best[q] * 1.15, f"{sp:,.0f}x" if sp >= 1.5 else f"{sp:.1f}x",
                ha="center", fontsize=8, color="#0b3d91")
    ax.legend(frameon=False, loc="upper center", bbox_to_anchor=(0.5, -0.17), ncol=2)
    ax.spines[["top", "right"]].set_visible(False)
    fig.tight_layout()
    fig.savefig(EVID / "benchmark_chart.png")


if __name__ == "__main__":
    main()
