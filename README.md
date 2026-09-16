# Evaluating Out-of-Core Analytical Execution: Buffer Pools vs. Memory-Mapped Streaming across the Parquet Row-Group Continuum

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https.mit-license.org)
[![Python 3.10+](https://img.shields.io/badge/python-3.10+-blue.svg)](https://www.python.org/)
[![DuckDB 1.0+](https://img.shields.io/badge/DuckDB-1.0+-yellow.svg)](https://duckdb.org/)
[![Polars 1.0+](https://img.shields.io/badge/Polars-1.0+-orange.svg)](https://pola.rs/)

This repository contains the complete empirical research codebase, cgroups v2 memory throttling harness, telemetry collector, figure generation pipeline, and ACM SIGCONF LaTeX manuscript for evaluating out-of-core analytical query execution.

We present a head-to-head empirical study comparing **DuckDB (Managed Buffer Pool Engine)** versus **Polars (Memory-Mapped Streaming Engine)** across a 6-point Parquet row-group continuum (`10K`, `50K`, `122K`, `250K`, `500K`, `1M`) operating under kernel-enforced memory throttling (`memory.high = 1G`).

---

## 📌 Key Empirical Findings

1. **Optimal Row-Group Continuum**: **122,880 rows (~122K)** per row-group represents the optimal Pareto frontier boundary for out-of-core execution, achieving up to $2.1\times$ lower latency than sub-optimal configurations.
2. **Buffer Pool vs. `mmap` Eviction**:
   - **DuckDB** maintains predictable latency under tight RAM constraints by explicitly managing LRU frame eviction to NVMe scratch storage.
   - **Polars** experiences kernel direct reclaim stalls (`allocstall`) and page-fault thrashing (`pgmajfault`) at large row-group sizes ($500K$--$1M$) due to OS memory-mapped paging pressure.
3. **Metadata vs. Decompression Bottlenecks**:
   - **Small Row-Groups ($10K$--$50K$)**: High metadata parsing overhead and dictionary decoding churn.
   - **Large Row-Groups ($500K$--$1M$)**: Massive memory allocation spikes during decompression pushing heap usage past cgroup thresholds.

---

## 🖥️ Bare-Metal Hardware & OS Testbed

All benchmarks were conducted on a bare-metal testbed:

| Component | Specification |
| :--- | :--- |
| **Model** | Lenovo Legion 5 15IMH05 (82AU) |
| **CPU** | Intel Core i5-10300H (4 physical cores / 8 threads, 8MB L3 Cache) |
| **RAM** | 8GB DDR4-2933 MHz |
| **Storage** | WDC PC SN730 512GB PCIe 3.0 x4 NVMe SSD (`ext4` mount) |
| **OS / Kernel** | Ubuntu 24.04 LTS (Linux Kernel 6.8.0) |
| **Memory Isolation** | Linux `cgroups v2` (`memory.high = 1G`, `memory.swap.max = 0`) |
| **CPU Governor** | `performance` (Core affinity locked via `taskset -c 0,1,2,3`) |

---

## 📁 Repository Architecture

```
.
├── data/                       # Generated Parquet continuum datasets (10k to 1m)
├── src/                        # Engine execution runners
│   ├── duckdb_runner.py        # DuckDB buffer pool runner (spill tracking, thread lock)
│   └── polars_runner.py        # Polars mmap streaming runner (Rayon parity, chunk lock)
├── harness/                    # Telemetry & cgroups instrumentation
│   └── cgroup_sampler.py       # High-frequency (20ms/50Hz) cgroup memory & page fault daemon
├── scripts/                    # Environment setup & benchmark orchestrators
│   ├── check_environment.sh    # Pre-flight hardware, storage & governor audit
│   ├── setup_cgroup.sh         # Linux cgroups v2 memory throttling initializer
│   ├── generate_data.py        # TPC-H SF10 multi-granularity Parquet generator
│   └── run_benchmarks.sh       # 60-run interleaved full-factorial experiment suite
├── results/                    # Execution metrics & raw 20ms time-series CSVs
│   ├── summary_metrics.json    # Consolidated experimental results
│   └── raw/                    # Raw telemetry samples
├── plots/                      # Publication-grade vector graphics (.pdf & .png)
│   ├── make_figures.py         # Matplotlib ACM SIGCONF vector graphics plotting pipeline
│   ├── figure1_memory_over_time.pdf
│   └── figure2_pareto_frontier.pdf
└── paper/                      # 5-page ACM SIGCONF LaTeX manuscript
    └── main.tex                # Paper LaTeX source code
```

---

## 🚀 Step-by-Step Reproduction Guide

### 1. Pre-Flight Hardware Audit
Execute the environment audit script to verify CPU core count, governor settings, and storage mount:
```bash
./scripts/check_environment.sh
```

### 2. Configure cgroups v2 Memory Throttling
Provision the 1GB memory limit cgroup on your Linux host:
```bash
sudo ./scripts/setup_cgroup.sh
```

### 3. Generate Parquet Row-Group Continuum
Synthesize the TPC-H SF10 `lineitem` datasets across the 6 row-group granularities:
```bash
python3 scripts/generate_data.py
```

### 4. Execute 60-Run Interleaved Benchmark Suite
Run the full-factorial experimental matrix (2 engines $\times$ 6 granularities $\times$ 5 interleaved trials with OS page cache purging between runs):
```bash
./scripts/run_benchmarks.sh
```

### 5. Generate Vector Graphics Figures
Produce ACM SIGCONF publication-grade vector graphics (`.pdf` and `.png`):
```bash
python3 plots/make_figures.py
```

### 6. Compile LaTeX Manuscript
Compile the 5-page ACM SIGCONF research paper:
```bash
cd paper
pdflatex main.tex
```

---

## 📄 ACM Paper Abstract

> Analytical database engines increasingly process datasets exceeding physical main memory. Modern systems employ two dominant paradigms for memory-constrained analytical processing: explicit engine-managed buffer pools (e.g., DuckDB) and implicit memory-mapped OS streaming (e.g., Polars over `mmap`). However, the interaction between these execution architectures, underlying storage granularity (Parquet row-group sizes), and Linux kernel memory reclamation mechanics under severe cgroup constraints remains insufficiently quantified.
>
> In this paper, we present an empirical evaluation of DuckDB versus Polars operating under kernel-enforced memory throttling (`memory.high = 1G`) on a bare-metal Intel Core i5-10300H testbed with NVMe storage. We evaluate a 6-point Parquet row-group continuum ranging from 10K to 1M rows over TPC-H `lineitem` projections (>1.2GB uncompressed). Using high-frequency 20ms cgroups v2 telemetry and hardware PMU counters, we demonstrate that DuckDB's managed buffer pool maintains predictable query latency by explicitly evicting LRU blocks to NVMe scratch space. Conversely, Polars' `mmap` architecture suffers severe performance degradation at extreme row-group sizes due to kernel direct reclaim stalls (`allocstall`) and major page fault thrashing (`pgmajfault`). We identify 122K rows per row-group as the optimal out-of-core Pareto frontier boundary.

---

## 📜 Citation & License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

```bibtex
@inproceedings{theba2024out-of-core-parquet,
  author    = {Theba, Nadeem},
  title     = {Evaluating Out-of-Core Analytical Execution: Buffer Pools vs. Memory-Mapped Streaming across the Parquet Row-Group Continuum},
  booktitle = {Proceedings of the ACM International Conference on Management of Data (SIGMOD)},
  year      = {2024}
}
```
