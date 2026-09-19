#!/usr/bin/env python3
import argparse
import json
import os
import sys
import time
import subprocess
from pathlib import Path

# Auto-create and auto-switch to .venv python
_project_root = Path(__file__).resolve().parent.parent
_venv_dir = _project_root / ".venv"
_venv_python = _venv_dir / "bin" / "python"
_req_file = _project_root / "requirements.txt"

if not _venv_python.exists():
    print("[+] Virtual environment not found. Automatically creating '.venv'...", flush=True)
    subprocess.run([sys.executable, "-m", "venv", str(_venv_dir)], check=True)
    if _req_file.exists():
        print("[+] Installing dependencies into '.venv' from requirements.txt...", flush=True)
        subprocess.run([str(_venv_python), "-m", "pip", "install", "--upgrade", "pip"], check=True)
        subprocess.run([str(_venv_python), "-m", "pip", "install", "-r", str(_req_file)], check=True)

if sys.executable != str(_venv_python):
    os.execv(str(_venv_python), [str(_venv_python)] + sys.argv)

from typing import Dict, Any, Optional

import duckdb

TPCH_HIGH_CARDINALITY_SQL = """
SELECT
    l_orderkey % 500000 AS orderkey_bucket,
    l_returnflag,
    l_linestatus,
    SUM(l_quantity) AS sum_qty,
    SUM(l_extendedprice) AS sum_base_price,
    SUM(l_extendedprice * (1.0 - l_discount)) AS sum_disc_price,
    AVG(l_quantity) AS avg_qty,
    COUNT(*) AS count_order
FROM lineitem_table
WHERE
    l_shipdate <= CAST('1998-12-01' AS DATE)
GROUP BY
    l_orderkey % 500000,
    l_returnflag,
    l_linestatus
ORDER BY
    orderkey_bucket;
"""


def get_dir_size_bytes(dir_path: Path) -> int:
    if not dir_path.exists():
        return 0
    total_bytes = 0
    for root, _, files in os.walk(dir_path):
        for f in files:
            fp = Path(root) / f
            if fp.is_file():
                total_bytes += fp.stat().st_size
    return total_bytes


def run_duckdb_benchmark(
    parquet_path: Path,
    output_json: Path,
    row_group_size: str = "unknown",
    threads: int = 4,
    memory_limit: Optional[str] = "500MB",
    scratch_dir: Optional[Path] = None,
) -> Dict[str, Any]:
    if scratch_dir is None:
        scratch_dir = Path.home() / "duckdb_scratch"
    scratch_dir.mkdir(parents=True, exist_ok=True)

    con = duckdb.connect(database=":memory:")
    try:
        con.execute(f"SET threads TO {threads};")
        if memory_limit:
            con.execute(f"SET max_memory TO '{memory_limit}';")
        con.execute(f"SET temp_directory TO '{scratch_dir}';")

        safe_path = str(parquet_path).replace("'", "''")
        con.execute(
            f"CREATE VIEW lineitem_table AS SELECT * FROM '{safe_path}';"  # noqa: S608
        )
        con.execute(f"EXPLAIN {TPCH_HIGH_CARDINALITY_SQL}")

        status = "SUCCESS"
        error_message = None
        result_rows = 0

        t_start_ns = time.perf_counter_ns()
        try:
            res = con.execute(TPCH_HIGH_CARDINALITY_SQL).fetchall()
            t_end_ns = time.perf_counter_ns()
            result_rows = len(res)
            elapsed_sec = (t_end_ns - t_start_ns) / 1e9
        except duckdb.OutOfMemoryException as err:
            t_end_ns = time.perf_counter_ns()
            elapsed_sec = (t_end_ns - t_start_ns) / 1e9
            status = "OOM"
            error_message = str(err)
        except duckdb.Error as err:
            t_end_ns = time.perf_counter_ns()
            elapsed_sec = (t_end_ns - t_start_ns) / 1e9
            status = "ERROR"
            error_message = str(err)
    finally:
        spilled_bytes = get_dir_size_bytes(scratch_dir)
        con.close()

    result_data = {
        "engine": "duckdb",
        "row_group_size": row_group_size,
        "parquet_path": str(parquet_path),
        "status": status,
        "execution_time_ms": round(elapsed_sec * 1000.0, 3),
        "elapsed_sec": round(elapsed_sec, 4),
        "result_rows": result_rows,
        "spilled_bytes": spilled_bytes,
        "spilled_mb": round(spilled_bytes / (1024 * 1024), 3),
        "threads": threads,
        "memory_limit": memory_limit,
        "error_message": error_message,
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    output_json.parent.mkdir(parents=True, exist_ok=True)
    with open(output_json, "w") as f:
        json.dump(result_data, f, indent=2)

    return result_data


def main() -> None:
    parser = argparse.ArgumentParser(
        description="DuckDB Buffer Pool Out-of-Core Execution Engine Runner"
    )
    parser.add_argument(
        "--parquet-path",
        type=Path,
        required=True,
        help="Target Parquet file path",
    )
    parser.add_argument(
        "--row-group-size",
        type=str,
        default="unknown",
        help="Row group size label (e.g., 10k, 50k, 122k, 250k, 500k, 1m)",
    )
    parser.add_argument(
        "--output-json",
        type=Path,
        required=True,
        help="Target output metadata JSON file path",
    )
    parser.add_argument(
        "--threads",
        type=int,
        default=4,
        help="DuckDB execution threads (default: 4)",
    )
    parser.add_argument(
        "--memory-limit",
        type=str,
        default="500MB",
        help="DuckDB max memory ceiling (default: 500MB)",
    )
    parser.add_argument(
        "--scratch-dir",
        type=Path,
        default=None,
        help="Physical NVMe scratchpad directory path",
    )
    args = parser.parse_args()

    res = run_duckdb_benchmark(
        args.parquet_path,
        args.output_json,
        args.row_group_size,
        args.threads,
        args.memory_limit,
        args.scratch_dir,
    )
    print(json.dumps(res, indent=2))
    print(f"\n[+] Saved metrics to {args.output_json}")

    if res["status"] != "SUCCESS":
        sys.exit(137 if res["status"] == "OOM" else 1)


if __name__ == "__main__":
    main()
