#!/usr/bin/env python3
"""
Turn probe CSVs into downtime numbers and a timeline chart.

  python analyze.py results/before.csv results/after.csv --chart results/timeline.png

An "outage" is a run of consecutive failed attempts for one operation; its
length runs from the first failure to the next success.
"""
import argparse
import csv
from datetime import datetime

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402


def load(path):
    with open(path) as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        r["t"] = datetime.fromisoformat(r["ts_utc"])
        r["ok"] = r["ok"] == "1"
    return rows


def outages(rows, op):
    rs = [r for r in rows if r["op"] == op]
    out, start = [], None
    for r in rs:
        if not r["ok"] and start is None:
            start = r["t"]
        elif r["ok"] and start is not None:
            out.append((start, r["t"]))
            start = None
    if start is not None:  # still down when the probe stopped
        out.append((start, rs[-1]["t"]))
    return out


def summarize(path, rows):
    mode = rows[0]["mode"] if rows else "?"
    lines = []
    for op in ("write", "read"):
        rs = [r for r in rows if r["op"] == op]
        if not rs:
            continue
        o = outages(rows, op)
        total = sum((e - s).total_seconds() for s, e in o)
        longest = max(((e - s).total_seconds() for s, e in o), default=0.0)
        fails = sum(not r["ok"] for r in rs)
        servers = []
        for r in rs:
            if r["ok"] and (not servers or servers[-1] != r["server_id"]):
                servers.append(r["server_id"])
        lines.append(
            f"| {path} | {mode} | {op} | {len(rs)} | {fails} | {100 * (len(rs) - fails) / len(rs):.2f}% "
            f"| {len(o)} | {total:.1f}s | {longest:.1f}s | {' → '.join(servers)} |"
        )
    return lines


def chart(datasets, out):
    fig, axes = plt.subplots(len(datasets), 1, figsize=(11, 2.4 * len(datasets)), squeeze=False)
    for ax, (path, rows) in zip(axes[:, 0], datasets):
        t0 = rows[0]["t"]
        for y, op in ((1, "write"), (0, "read")):
            for ok, color in ((True, "#2a9d8f"), (False, "#e63946")):
                xs = [(r["t"] - t0).total_seconds() for r in rows if r["op"] == op and r["ok"] == ok]
                ax.scatter(xs, [y] * len(xs), s=6, c=color, marker="|", label=("ok" if ok else "failed") if y else None)
        ax.set_yticks([0, 1], ["read", "write"])
        ax.set_ylim(-0.6, 1.6)
        ax.set_title(f"{rows[0]['mode']} mode — {path}", fontsize=10, loc="left")
        ax.spines[["top", "right"]].set_visible(False)
    axes[-1, 0].set_xlabel("seconds since probe start")
    axes[0, 0].legend(loc="upper right", frameon=False, fontsize=8)
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    print(f"Chart: {out}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("csv", nargs="+")
    p.add_argument("--chart")
    a = p.parse_args()

    datasets = [(path, load(path)) for path in a.csv]
    print("| file | mode | op | attempts | failed | success | outages | total down | longest | instances served |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for path, rows in datasets:
        for line in summarize(path, rows):
            print(line)
    if a.chart:
        chart(datasets, a.chart)


if __name__ == "__main__":
    main()