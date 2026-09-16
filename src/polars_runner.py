#!/usr/bin/env python3
"""
Polars Memory-Mapped Streaming Engine Runner (STICKY 3B)

Executes a high-cardinality aggregation over wide TPC-H lineitem Parquet datasets
using Polars LazyFrames with streaming enabled (`collect(streaming=True)`).

Key Controls:
1. Thread count locked to 4 (matching DuckDB runner and cgroups CPU quota).
2. Streaming batch chunk size locked to 50,000 records.
3. Isolated execution timing around .collect(streaming=True).
4. High-cardinality aggregation: `l_orderkey % 500000`.
"""

import os
import sys
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

# Critical: Set thread and streaming environment variables BEFORE importing Polars
os.environ["POLARS_MAX_THREADS"] = "4"
os.environ["RAYON_NUM_THREADS"] = "4"
os.environ["POLARS_STREAMING_CHUNK_SIZE"] = "50000"

import argparse
import json
import time
import traceback


def parse_args():
    parser = argparse.ArgumentParser(
        description="Polars Memory-Mapped Streaming Engine Benchmark Runner"
    )
    parser.add_argument(
        "--parquet-path",
        required=True,
        help="Path to target Parquet file",
    )
    parser.add_argument(
        "--row-group-size",
        required=True,
        help="Label for row group granularity (e.g., 10k, 50k, 122k, 250k, 500k, 1m)",
    )
    parser.add_argument(
        "--output-json",
        default=None,
        help="Path to save execution results JSON",
    )
    return parser.parse_args()


def run_polars_benchmark(parquet_path: str, row_group_size: str) -> dict:
    """
    Executes the analytical query against the given Parquet file using Polars streaming engine.
    Returns operational metrics dictionary.
    """
    if not os.path.exists(parquet_path):
        raise FileNotFoundError(f"Parquet file not found: {parquet_path}")

    import polars as pl

    start_time_ns = time.perf_counter_ns()
    status = "SUCCESS"
    error_message = None
    result_rows = 0
    execution_time_ms = 0.0

    try:
        # Build LazyFrame Plan (Zero I/O during scan_parquet setup)
        lf = pl.scan_parquet(parquet_path)

        # High-cardinality aggregation with wide projection
        query = (
            lf.select(
                [
                    "l_orderkey",
                    "l_partkey",
                    "l_suppkey",
                    "l_linenumber",
                    "l_quantity",
                    "l_extendedprice",
                    "l_discount",
                    "l_tax",
                    "l_returnflag",
                    "l_linestatus",
                    "l_shipdate",
                    "l_commitdate",
                    "l_receiptdate",
                ]
            )
            .group_by(pl.col("l_orderkey") % 500000)
            .agg(
                [
                    pl.len().alias("count"),
                    pl.col("l_extendedprice").sum().alias("total_price"),
                    pl.col("l_discount").mean().alias("avg_discount"),
                    pl.col("l_quantity").sum().alias("total_quantity"),
                ]
            )
        )

        # Isolated execution timing around collect(streaming=True)
        query_start_ns = time.perf_counter_ns()
        res_df = query.collect(streaming=True)
        query_end_ns = time.perf_counter_ns()

        execution_time_ms = (query_end_ns - query_start_ns) / 1e6
        result_rows = len(res_df)

    except Exception as e:
        query_end_ns = time.perf_counter_ns()
        execution_time_ms = (query_end_ns - start_time_ns) / 1e6
        err_str = str(e)
        if "out of memory" in err_str.lower() or "allocation failed" in err_str.lower() or "MemoryError" in err_str:
            status = "OOM"
        else:
            status = "ERROR"
        error_message = f"{type(e).__name__}: {err_str}"

    metrics = {
        "engine": "polars",
        "row_group_size": row_group_size,
        "parquet_path": os.path.abspath(parquet_path),
        "status": status,
        "execution_time_ms": round(execution_time_ms, 3),
        "result_rows": result_rows,
        "polars_max_threads": os.environ.get("POLARS_MAX_THREADS"),
        "rayon_num_threads": os.environ.get("RAYON_NUM_THREADS"),
        "streaming_chunk_size": os.environ.get("POLARS_STREAMING_CHUNK_SIZE"),
        "error_message": error_message,
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    return metrics


def main():
    args = parse_args()
    results = run_polars_benchmark(args.parquet_path, args.row_group_size)

    # Print pretty JSON summary to stdout
    print(json.dumps(results, indent=2))

    if args.output_json:
        os.makedirs(os.path.dirname(os.path.abspath(args.output_json)), exist_ok=True)
        with open(args.output_json, "w") as f:
            json.dump(results, f, indent=2)
        print(f"\n[+] Saved metrics to {args.output_json}")

    if results["status"] != "SUCCESS":
        print(f"\n[-] Benchmark finished with status: {results['status']}", file=sys.stderr)
        if results["error_message"]:
            print(f"    Details: {results['error_message']}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
