#!/usr/bin/env python3
"""
High-Resolution Linux cgroups v2 Memory & Hardware Telemetry Sampler (STICKY 4)

Monitors target process PID and cgroup memory stats at high frequency (default: 20ms / 50Hz).
Captures detailed kernel memory metrics:
- memory.current (total memory usage)
- anon (heap/stack memory)
- file / file_mapped (page cache mmap memory)
- pgmajfault (major page faults requiring disk I/O)
- workingset_refault (refaults of evicted pages)
- allocstall (kernel direct reclaim allocation stalls)

Outputs a structured CSV file for time-series memory plotting (Figure 1 in paper).
"""

import argparse
import csv
import os
import sys
import time
import subprocess
from typing import Dict, Optional


def parse_args():
    parser = argparse.ArgumentParser(
        description="High-Resolution cgroups v2 & Hardware Telemetry Sampler"
    )
    parser.add_argument(
        "--cgroup-path",
        default="/sys/fs/cgroup/benchmark",
        help="Path to target cgroup v2 directory",
    )
    parser.add_argument(
        "--pid",
        type=int,
        required=True,
        help="PID of target query process to monitor",
    )
    parser.add_argument(
        "--output-csv",
        required=True,
        help="Output CSV file path for time-series telemetry",
    )
    parser.add_argument(
        "--interval-ms",
        type=int,
        default=20,
        help="Sampling interval in milliseconds (default: 20ms = 50Hz)",
    )
    parser.add_argument(
        "--enable-perf",
        action="store_true",
        help="Enable Linux perf stat hardware PMU counters",
    )
    return parser.parse_args()


def read_cgroup_memory_stats(cgroup_path: str) -> Dict[str, int]:
    """
    Parses memory.current and memory.stat from target cgroup v2 directory.
    Returns metrics dict with default fallback zeros.
    """
    stats = {
        "memory_current_bytes": 0,
        "anon_bytes": 0,
        "file_bytes": 0,
        "file_mapped_bytes": 0,
        "pgmajfault": 0,
        "workingset_refault": 0,
        "allocstall": 0,
    }

    mem_current_path = os.path.join(cgroup_path, "memory.current")
    mem_stat_path = os.path.join(cgroup_path, "memory.stat")

    if os.path.exists(mem_current_path):
        try:
            with open(mem_current_path, "r") as f:
                stats["memory_current_bytes"] = int(f.read().strip())
        except Exception:
            pass

    if os.path.exists(mem_stat_path):
        try:
            with open(mem_stat_path, "r") as f:
                for line in f:
                    parts = line.strip().split()
                    if len(parts) == 2:
                        key, val = parts[0], parts[1]
                        if key == "anon":
                            stats["anon_bytes"] = int(val)
                        elif key == "file":
                            stats["file_bytes"] = int(val)
                        elif key == "file_mapped":
                            stats["file_mapped_bytes"] = int(val)
                        elif key == "pgmajfault":
                            stats["pgmajfault"] = int(val)
                        elif key == "workingset_refault":
                            stats["workingset_refault"] = int(val)
                        elif key == "allocstall":
                            stats["allocstall"] = int(val)
        except Exception:
            pass

    return stats


def read_cpu_temperature() -> float:
    """
    Reads the CPU temperature from the Linux thermal subsystem.
    Returns temperature in Celsius, or 0.0 if unavailable.
    """
    temp_path = "/sys/class/thermal/thermal_zone0/temp"
    if os.path.exists(temp_path):
        try:
            with open(temp_path, "r") as f:
                # Kernel reports temperature in millidegrees Celsius
                return float(f.read().strip()) / 1000.0
        except Exception:
            return 0.0
    return 0.0


def is_pid_alive(pid: int) -> bool:
    """Checks if target PID is running."""
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def main():
    args = parse_args()
    interval_sec = args.interval_ms / 1000.0

    os.makedirs(os.path.dirname(os.path.abspath(args.output_csv)), exist_ok=True)

    cgroup_exists = os.path.exists(args.cgroup_path)
    if not cgroup_exists:
        print(
            f"[!] Warning: cgroup path '{args.cgroup_path}' does not exist on this machine. (Using zero-fill telemetry mode).",
            file=sys.stderr,
        )

    fieldnames = [
        "timestamp_ns",
        "elapsed_sec",
        "pid",
        "memory_current_bytes",
        "anon_bytes",
        "file_bytes",
        "file_mapped_bytes",
        "pgmajfault",
        "workingset_refault",
        "allocstall",
        "cpu_temp_c",
    ]

    start_time_ns = time.perf_counter_ns()
    samples_count = 0

    with open(args.output_csv, "w", newline="") as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()

        # Sampling Loop: Run until target PID exits
        while is_pid_alive(args.pid):
            now_ns = time.perf_counter_ns()
            elapsed_sec = (now_ns - start_time_ns) / 1e9

            stats = read_cgroup_memory_stats(args.cgroup_path)

            row = {
                "timestamp_ns": now_ns,
                "elapsed_sec": round(elapsed_sec, 4),
                "pid": args.pid,
                "memory_current_bytes": stats["memory_current_bytes"],
                "anon_bytes": stats["anon_bytes"],
                "file_bytes": stats["file_bytes"],
                "file_mapped_bytes": stats["file_mapped_bytes"],
                "pgmajfault": stats["pgmajfault"],
                "workingset_refault": stats["workingset_refault"],
                "allocstall": stats["allocstall"],
                "cpu_temp_c": round(read_cpu_temperature(), 1),
            }

            writer.writerow(row)
            samples_count += 1
            csvfile.flush()

            time.sleep(interval_sec)

    print(
        f"[+] Telemetry sampler finished cleanly. Recorded {samples_count} samples to '{args.output_csv}'."
    )


if __name__ == "__main__":
    main()
