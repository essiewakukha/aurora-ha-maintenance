#!/usr/bin/env python3
"""
Availability probe for an Aurora MySQL cluster.

Acts like a tiny application: every --interval seconds it does one write and
one read, and logs each attempt to CSV (timestamp, op, endpoint, ok, latency,
which instance answered, error).

Two modes mirror the scenario:
  --mode instance  writes AND reads go to the writer's INSTANCE endpoint
                   (the company's current, fragile setup)
  --mode split     writes go to the CLUSTER endpoint, reads to the READER
                   endpoint (the recommended setup)

Usage:
  export DB_PASSWORD=...   # scripts/get_password.sh prints it
  python probe.py --mode split --writer-host <cluster ep> \
      --reader-host <reader ep> --out results/after.csv
"""
import argparse
import csv
import os
import signal
import sys
import time
from datetime import datetime, timezone

import pymysql

SETUP_SQL = """
CREATE TABLE IF NOT EXISTS heartbeat (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  ts DATETIME(3) NOT NULL,
  src VARCHAR(64) NOT NULL
)
"""

running = True


def stop(*_):
    global running
    running = False


class Conn:
    """A connection that reconnects lazily after any failure, like a real app pool."""

    def __init__(self, host, user, password, db, timeout):
        self.args = dict(host=host, user=user, password=password, database=db,
                         connect_timeout=timeout, read_timeout=timeout,
                         write_timeout=timeout, autocommit=True)
        self.conn = None

    def get(self):
        if self.conn is None:
            # A fresh connect re-resolves DNS, which is how the cluster and
            # reader endpoints follow a failover.
            self.conn = pymysql.connect(**self.args)
        return self.conn

    def reset(self):
        try:
            if self.conn:
                self.conn.close()
        except Exception:
            pass
        self.conn = None


def attempt(conn, op, label):
    t0 = time.monotonic()
    try:
        c = conn.get()
        with c.cursor() as cur:
            if op == "write":
                cur.execute("INSERT INTO heartbeat (ts, src) VALUES (UTC_TIMESTAMP(3), %s)", (label,))
            # Which instance served us, and is it read-only? Shows failovers in the log.
            cur.execute("SELECT @@aurora_server_id, @@innodb_read_only")
            server_id, read_only = cur.fetchone()
        return True, (time.monotonic() - t0) * 1000, server_id, int(read_only), ""
    except Exception as e:  # noqa: BLE001 - we want to log every failure kind
        conn.reset()
        return False, (time.monotonic() - t0) * 1000, "", "", f"{type(e).__name__}: {e}"[:200]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--mode", choices=["instance", "split"], required=True)
    p.add_argument("--writer-host", required=True, help="instance endpoint (instance mode) or cluster endpoint (split mode)")
    p.add_argument("--reader-host", help="reader endpoint (split mode only)")
    p.add_argument("--user", default="admin")
    p.add_argument("--db", default="appdb")
    p.add_argument("--interval", type=float, default=0.5)
    p.add_argument("--timeout", type=int, default=2)
    p.add_argument("--duration", type=int, default=0, help="seconds; 0 = until Ctrl-C")
    p.add_argument("--out", required=True)
    a = p.parse_args()

    if a.mode == "split" and not a.reader_host:
        p.error("--reader-host is required in split mode")
    password = os.environ.get("DB_PASSWORD")
    if not password:
        sys.exit("Set DB_PASSWORD (see scripts/get_password.sh)")

    reader_host = a.reader_host if a.mode == "split" else a.writer_host
    writer = Conn(a.writer_host, a.user, password, a.db, a.timeout)
    reader = Conn(reader_host, a.user, password, a.db, a.timeout)

        # The table already exists after the first run, so a failed setup
    # connection must not stop the probe: log it and start measuring.
    try:
        with writer.get().cursor() as cur:
            cur.execute(SETUP_SQL)
    except Exception as e:  # noqa: BLE001
        writer.reset()
        print(f"setup skipped, writer unreachable at start: {e}", flush=True)

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    started = time.monotonic()

    with open(a.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["ts_utc", "mode", "op", "host", "ok", "latency_ms", "server_id", "read_only", "error"])
        while running and (a.duration == 0 or time.monotonic() - started < a.duration):
            tick = time.monotonic()
            for op, conn, host in (("write", writer, a.writer_host), ("read", reader, reader_host)):
                ok, ms, sid, ro, err = attempt(conn, op, a.mode)
                ts = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
                w.writerow([ts, a.mode, op, host, int(ok), f"{ms:.1f}", sid, ro, err])
                if not ok:
                    print(f"{ts} {op:5} FAIL {err}", flush=True)
            f.flush()
            time.sleep(max(0.0, a.interval - (time.monotonic() - tick)))

    print(f"Wrote {a.out}")


if __name__ == "__main__":
    main()