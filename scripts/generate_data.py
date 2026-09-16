#!/usr/bin/env python3
import argparse
import os
import sys
import time
from pathlib import Path

# Auto-switch to .venv python if executed via system python
_venv_python = Path(__file__).resolve().parent.parent / ".venv" / "bin" / "python"
if _venv_python.exists() and sys.executable != str(_venv_python):
    os.execv(str(_venv_python), [str(_venv_python)] + sys.argv)

from typing import Dict, Any, List, Tuple

import duckdb
import pyarrow as pa
import pyarrow.parquet as pq


def verify_parquet_metadata(target_path: Path) -> Dict[str, Any]:
    file_size_bytes = target_path.stat().st_size
    pq_file = pq.ParquetFile(target_path)
    num_rows = pq_file.metadata.num_rows
    num_row_groups = pq_file.num_row_groups
    return {
        "path": str(target_path),
        "rows": num_rows,
        "row_groups": num_row_groups,
        "size_mb": file_size_bytes / (1024 * 1024),
    }


def generate_tpch_continuum(
    scale_factor: float, output_dir: Path, force: bool = False
) -> List[Dict[str, Any]]:
    output_dir.mkdir(parents=True, exist_ok=True)

    continuum_configs: List[Tuple[Path, int]] = [
        (output_dir / "lineitem_10k.parquet", 10000),
        (output_dir / "lineitem_50k.parquet", 50000),
        (output_dir / "lineitem_122k.parquet", 122880),
        (output_dir / "lineitem_250k.parquet", 250000),
        (output_dir / "lineitem_500k.parquet", 500000),
        (output_dir / "lineitem_1m.parquet", 1000000),
    ]

    if not force:
        all_exist = all(target_path.exists() for target_path, _ in continuum_configs)
        if all_exist:
            try:
                results = [verify_parquet_metadata(p) for p, _ in continuum_configs]
                return results
            except (OSError, pa.ArrowInvalid) as err:
                sys.stderr.write(f"Existing files invalid, re-generating: {err}\n")

    print(f"[+] Connecting to DuckDB and loading TPC-H extension...", flush=True)
    con = duckdb.connect(database=":memory:")
    try:
        con.execute("INSTALL tpch; LOAD tpch;")
        print(f"[+] Synthesizing TPC-H SF{scale_factor:.1f} dataset (~60,000,000 records)...", flush=True)
        print("    (This takes ~45-60 seconds on CPU, please wait...)", flush=True)
        t0 = time.perf_counter()
        con.execute("CALL dbgen(sf=?);", [scale_factor])
        t_gen = time.perf_counter() - t0
        print(f"[+] Data synthesis complete in {t_gen:.2f}s! Exporting 6 Parquet continuum files...", flush=True)

        results: List[Dict[str, Any]] = []
        for target_path, row_group_size in continuum_configs:
            if target_path.exists():
                target_path.unlink()

            print(f"    - Exporting '{target_path.name}' (ROW_GROUP_SIZE={row_group_size:,})...", flush=True)
            query = f"""
            COPY lineitem TO '{target_path}' (
                FORMAT PARQUET,
                ROW_GROUP_SIZE {row_group_size},
                COMPRESSION 'SNAPPY'
            );
            """
            con.execute(query)
            results.append(verify_parquet_metadata(target_path))

        print("[+] All 6 Parquet continuum datasets generated successfully!", flush=True)
        return results
    except (duckdb.Error, OSError) as err:
        sys.stderr.write(f"Data generation failure: {err}\n")
        sys.exit(1)
    finally:
        con.close()


def print_summary_table(results: List[Dict[str, Any]]) -> None:
    header = f"{'Parquet File Path':<35} | {'Total Rows':<12} | {'Row Groups':<10} | {'Size (MB)':<10}"
    divider = "-" * len(header)
    print("\n" + divider)
    print(header)
    print(divider)
    for res in results:
        path_str = res["path"]
        rows = f"{res['rows']:,}"
        rgs = f"{res['row_groups']:,}"
        size_mb = f"{res['size_mb']:.2f}"
        print(f"{path_str:<35} | {rows:<12} | {rgs:<10} | {size_mb:<10}")
    print(divider + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="TPC-H Lineitem 6-Point Parquet Storage Continuum Generator"
    )
    parser.add_argument(
        "--scale-factor",
        type=float,
        default=10.0,
        help="TPC-H Scale Factor (default: 10.0 for 60M rows)",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("data"),
        help="Target output directory for Parquet files (default: data)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Force regeneration of datasets even if valid Parquet files exist",
    )
    args = parser.parse_args()

    results = generate_tpch_continuum(args.scale_factor, args.output_dir, args.force)
    print_summary_table(results)


if __name__ == "__main__":
    main()
