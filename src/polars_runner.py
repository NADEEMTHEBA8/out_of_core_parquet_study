import argparse
from datetime import date
import json
import os
from pathlib import Path
import sys
import time
from typing import Tuple

# 1. Enforce strict concurrency parity before loading engine runtime
os.environ["POLARS_MAX_THREADS"] = "4"
os.environ["RAYON_NUM_THREADS"] = "4"

import polars as pl

def run_polars(file_path: Path) -> Tuple[float, int]:
    if not file_path.exists():
        raise FileNotFoundError(f"Parquet file not found: {file_path}")

    ship_cutoff = date(1998, 12, 1)

    # 2. Construct lazy query plan using only streaming-verified operators
    lazy_plan = (
        pl.scan_parquet(file_path.as_posix(), low_memory=True)
        .filter(pl.col("l_shipdate") <= ship_cutoff)
        .with_columns(
            (pl.col("l_orderkey") % 500000).cast(pl.Int64).alias("group_key")
        )
        .group_by(["group_key", "l_returnflag", "l_linestatus"])
        .agg(
            [
                pl.col("l_quantity").sum().alias("sum_qty"),
                pl.col("l_extendedprice").sum().alias("sum_price"),
                (pl.col("l_extendedprice") * (1.0 - pl.col("l_discount"))).sum().alias("sum_disc_price"),
                pl.col("l_quantity").mean().alias("avg_qty"),
                pl.len().alias("count_order"),
            ]
        )
    )

    # 3. Handle version compatibility for streaming engine invocation
    t_start = time.perf_counter_ns()
    try:
        # Polars >= 1.20
        df = lazy_plan.collect(engine="streaming")
    except (TypeError, ValueError):
        # Polars < 1.20 legacy fallback
        df = lazy_plan.collect(streaming=True)
    
    df = df.sort("group_key")
    t_end = time.perf_counter_ns()
    
    elapsed_sec = (t_end - t_start) / 1e9
    return elapsed_sec, len(df)

def main() -> None:
    parser = argparse.ArgumentParser(description="Polars Streaming Runner")
    parser.add_argument("--parquet-path", type=Path, required=True)
    parser.add_argument("--row-group-size", type=str, required=False)
    parser.add_argument("--output-json", type=str, required=False)
    args = parser.parse_args()

    try:
        runtime, rows = run_polars(args.parquet_path)
        metrics = {
            "status": "SUCCESS",
            "engine": "polars",
            "row_group_size": args.row_group_size,
            "parquet_path": str(args.parquet_path),
            "execution_time_ms": runtime * 1000.0,
            "result_rows": rows,
            "polars_max_threads": os.environ.get("POLARS_MAX_THREADS"),
            "rayon_num_threads": os.environ.get("RAYON_NUM_THREADS"),
            "streaming_chunk_size": os.environ.get("POLARS_STREAMING_CHUNK_SIZE"),
            "error_message": None,
            "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        
        print(json.dumps(metrics, indent=2))
        
        if args.output_json:
            os.makedirs(os.path.dirname(os.path.abspath(args.output_json)), exist_ok=True)
            with open(args.output_json, "w") as f:
                json.dump(metrics, f, indent=2)

    except Exception as e:
        metrics = {
            "status": "ERROR",
            "engine": "polars",
            "error_type": type(e).__name__,
            "error_message": str(e),
        }
        print(json.dumps(metrics, indent=2), file=sys.stderr)
        
        if args.output_json:
            os.makedirs(os.path.dirname(os.path.abspath(args.output_json)), exist_ok=True)
            with open(args.output_json, "w") as f:
                json.dump(metrics, f, indent=2)
                
        sys.exit(1)

if __name__ == "__main__":
    main()
