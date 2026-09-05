"""
Runs the whole SQL project top to bottom and captures the results.

There is no PostgreSQL server on this machine, so DuckDB is used as the
execution engine. It is close enough to PostgreSQL for everything in sql/01
through sql/09 to run unmodified - the two places where the dialects part ways
(materialised views, savepoints, PL/pgSQL) are kept out in
sql/10_postgres_extensions.sql, which this runner does not execute.

What it does:
  1. builds the schema and loads the seed data into output/sales_analytics.duckdb
  2. executes every statement in every script, in order
  3. exports each "-- @report <name>" query in 09 to output/<name>.csv
  4. writes output/report_pack.md and output/run_log.txt

Usage:  python tools/run_project.py
"""

import re
import sys
import time
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
SQL_DIR = ROOT / "sql"
OUT_DIR = ROOT / "output"

SCRIPTS = [
    "01_schema.sql",
    "02_seed_data.sql",
    "03_crud_operations.sql",
    "04_joins.sql",
    "05_aggregate_analytics.sql",
    "06_advanced_analytics.sql",
    "07_views.sql",
    "08_indexes_optimization.sql",
    "09_business_reports.sql",
]

REPORT_MARKER = re.compile(r"^\s*--\s*@report\s+(\S+)", re.IGNORECASE)
RETURNS_ROWS = re.compile(r"^\s*(SELECT|WITH|EXPLAIN|SHOW|PRAGMA|VALUES|TABLE)\b", re.IGNORECASE)


def strip_line_comment(line):
    """Remove a trailing -- comment, ignoring -- that sits inside a string."""
    in_string = False
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == "'":
            # '' inside a string is an escaped quote, not a terminator
            if in_string and i + 1 < len(line) and line[i + 1] == "'":
                i += 2
                continue
            in_string = not in_string
        elif ch == "-" and not in_string and i + 1 < len(line) and line[i + 1] == "-":
            return line[:i]
        i += 1
    return line


def parse_statements(path):
    """Yield (report_name_or_None, sql) for each statement in a script."""
    statements = []
    buffer = []
    pending_report = None
    current_report = None

    for raw in path.read_text(encoding="utf-8").splitlines():
        marker = REPORT_MARKER.match(raw)
        if marker:
            pending_report = marker.group(1)

        code = strip_line_comment(raw)
        if not code.strip():
            continue

        if not buffer and pending_report:
            current_report, pending_report = pending_report, None

        buffer.append(code)

        while ";" in code:
            head, _, code = code.partition(";")
            buffer[-1] = head
            sql = "\n".join(buffer).strip()
            if sql:
                statements.append((current_report, sql))
            buffer, current_report = [], None
            if code.strip():
                buffer.append(code)
                if pending_report:
                    current_report, pending_report = pending_report, None

    leftover = "\n".join(buffer).strip()
    if leftover:
        statements.append((current_report, leftover))
    return statements


def to_markdown(df, max_rows=40):
    if df.empty:
        return "_(no rows)_\n"
    shown = df.head(max_rows).copy()
    # pandas widens DATE columns to datetime64; trim the 00:00:00 back off.
    for col in shown.columns:
        if str(shown[col].dtype).startswith("datetime"):
            shown[col] = shown[col].dt.strftime("%Y-%m-%d")
    cols = list(shown.columns)
    lines = ["| " + " | ".join(str(c) for c in cols) + " |",
             "| " + " | ".join("---" for _ in cols) + " |"]
    for _, row in shown.iterrows():
        cells = []
        for v in row:
            cells.append("" if v is None or (isinstance(v, float) and v != v) else str(v))
        lines.append("| " + " | ".join(cells) + " |")
    out = "\n".join(lines) + "\n"
    if len(df) > max_rows:
        out += f"\n_{len(df) - max_rows} more row(s) not shown._\n"
    return out


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    db_path = OUT_DIR / "sales_analytics.duckdb"
    if db_path.exists():
        db_path.unlink()

    con = duckdb.connect(str(db_path))
    log = []
    report_blocks = []
    failures = []
    total_statements = 0

    for script in SCRIPTS:
        path = SQL_DIR / script
        statements = parse_statements(path)
        log.append(f"\n=== {script}  ({len(statements)} statements) ===")
        started = time.perf_counter()

        for idx, (report, sql) in enumerate(statements, start=1):
            total_statements += 1
            try:
                if RETURNS_ROWS.match(sql):
                    df = con.execute(sql).df()
                    label = report or f"{script}#{idx}"
                    log.append(f"  [ok] {label:<34} {len(df):>5} row(s)")
                    if report:
                        df.to_csv(OUT_DIR / f"{report}.csv", index=False)
                        title = report.split("_", 1)[1].replace("_", " ").title()
                        report_blocks.append(f"## {report[:3].upper()} - {title}\n\n"
                                             f"{to_markdown(df)}")
                else:
                    con.execute(sql)
                    log.append(f"  [ok] {script}#{idx:<27} "
                               f"{sql.split()[0].upper()} {sql.split()[1][:24] if len(sql.split()) > 1 else ''}")
            except Exception as exc:
                first = str(exc).splitlines()[0]
                failures.append((script, idx, first, sql[:400]))
                log.append(f"  [FAIL] {script}#{idx}: {first}")

        log.append(f"  -- {script} finished in {time.perf_counter() - started:.2f}s")

    (OUT_DIR / "run_log.txt").write_text("\n".join(log), encoding="utf-8")

    header = (
        "# Report Pack\n\n"
        "Generated by `python tools/run_project.py`. Every table below is the\n"
        "actual result of the matching `-- @report` query in\n"
        "`sql/09_business_reports.sql`, run against the seed dataset.\n\n"
        "All money values are in INR.\n\n---\n\n"
    )
    (OUT_DIR / "report_pack.md").write_text(header + "\n---\n\n".join(report_blocks),
                                            encoding="utf-8")
    con.close()

    print(f"statements executed : {total_statements}")
    print(f"failures            : {len(failures)}")
    for script, idx, msg, sql in failures:
        print(f"\n--- FAIL {script} #{idx}: {msg}\n{sql}\n")
    print(f"\ndatabase   : {db_path}")
    print(f"report pack: {OUT_DIR / 'report_pack.md'}")
    print(f"run log    : {OUT_DIR / 'run_log.txt'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
