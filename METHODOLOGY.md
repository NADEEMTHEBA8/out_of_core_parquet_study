# Systems Benchmarking Methodology

This repository employs a highly rigorous, bare-metal benchmarking architecture designed to meet the standards of top-tier systems conferences (e.g., ACM SIGMOD, VLDB, EuroSys). 

To ensure reproducibility and to scientifically isolate the performance differences between **DuckDB** (Buffer Pool Manager) and **Polars** (Memory-Mapped Streaming) during out-of-core Parquet scans, the following hardware and kernel-level controls are strictly enforced during the 60-run matrix execution.

---

## 1. Cgroups v2 Memory Sandboxing
To simulate constrained edge-device or highly-concurrent cloud environments, memory limits are enforced at the Linux kernel level rather than relying on application-level soft limits.
* **Mechanism**: Unified `cgroups v2` (`memory.high=1G`, `memory.swap.max=0`).
* **Justification**: Application-level limits (like DuckDB's `max_memory`) do not account for OS Page Cache usage or Python runtime overhead. Cgroups guarantee that the total footprint of the process, including `file_mapped` mmap pages, cannot exceed 1GB without triggering the kernel's `allocstall` reclaim loop or the OOM Killer.

## 2. Pre-Flight OS Page Cache Purge (Cold Starts)
* **Mechanism**: `sync && echo 3 > /proc/sys/vm/drop_caches`
* **Justification**: Eliminates "warm cache" bias. Before every single iteration, the Linux OS Page Cache, dentries, and inodes are forcefully dropped. This guarantees that the database engine is forced to hit the physical NVMe drive for the first block read, mirroring true cold-start query latencies.

## 3. Physical Memory Compaction (Defragmentation)
* **Mechanism**: `echo 1 > /proc/sys/vm/compact_memory`
* **Justification**: Over 60 heavy out-of-core iterations, reading and evicting gigabytes of data, physical RAM becomes severely fragmented. Without compaction, later runs would be artificially penalized by the kernel spending excessive time running `kcompactd` to find contiguous memory blocks. This command guarantees pristine, contiguous memory for every run.

## 4. CPU Frequency Scaling (DVFS) Lockdown
* **Mechanism**: `echo "performance" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor`
* **Justification**: Modern CPUs dynamically bounce clock speeds between base and turbo frequencies (e.g., 800MHz to 4.5GHz) via DVFS (`powersave` governor). If DuckDB executed during a 4.5GHz turbo boost, and Polars executed when the CPU dropped to 2.4GHz due to load, latency comparisons would be mathematically invalid. Locking the governor to `performance` completely eliminates DVFS jitter.

## 5. High-Frequency Hardware Telemetry
* **Mechanism**: A Python daemon (`harness/cgroup_sampler.py`) runs in the background, sampling the following metrics at **50Hz (20ms intervals)**:
  * `anon_bytes`: Heap/Stack memory
  * `file_mapped_bytes`: Page Cache / mmap memory
  * `pgmajfault`: Major page faults requiring disk I/O
  * `allocstall`: Kernel direct reclaim allocation stalls
  * `cpu_temp_c`: CPU Thermal sensor (`/sys/class/thermal/thermal_zone0/temp`)
  * `cpu_freq_mhz`: CPU Clock speed (`/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq`)
* **Justification**: Continuous thermal and frequency sampling proves empirically that latency spikes or crashes were caused purely by the 1GB memory constraint, not by thermal throttling or DVFS downclocking.

## 6. Timeout Escalation and Terminal Cgroup OOM Catching (DNF)
* **Mechanism**: `timeout -k 5s 180s` and Exit Code Catching (`124`, `135`, `137`).
* **Justification**: When the memory-mapped Polars engine hits the 1GB cgroup limit, the Linux kernel enters terminal `allocstall` thrashing. The process locks up inside kernel-space and will ignore a standard `SIGTERM`. The `-k 5s` flag escalates to `SIGKILL` to forcefully terminate zombie processes. Furthermore, if the kernel OOM Killer assassinates the process (`SIGKILL / 137`) or a memory-mapping fault occurs (`SIGBUS / 135`), the orchestration script safely traps the exit code and logs it as a Terminal DNF (Did Not Finish) in the metrics JSON, preserving statistical integrity for the Pareto frontier plotting.

## 7. Orphaned Spill File Wiping
* **Mechanism**: `rm -rf ~/duckdb_scratch/*`
* **Justification**: If an engine is violently assassinated by the OOM Killer, it cannot gracefully clean up its temporary spill files. Left unchecked, these files accumulate until the physical NVMe drive reaches 100% capacity, causing subsequent runs to crash with `ENOSPC` or `SIGBUS`. Wiping the scratch directory prior to every run guarantees a clean disk state.
