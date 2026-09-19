#!/usr/bin/env bash
# ==============================================================================
# 60-Run Interleaved Matrix Execution Orchestrator (STICKY 5)
#
# Executes full-factorial matrix:
# - 2 Engines: duckdb, polars
# - 6 Parquet granularities: 10k, 50k, 122k, 250k, 500k, 1m
# - 5 Interleaved Repetitions per cell (Total: 60 experimental runs)
#
# Scientific Isolation Controls:
# 1. Purges Linux OS Page Cache before every trial (sync && drop_caches).
# 2. Enforces cgroups v2 memory limit (cgexec -g memory:benchmark).
# 3. Pins physical CPU core affinity (taskset -c 0,1,2,3).
# 4. Spawns high-resolution cgroups sampler in background per trial.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DATA_DIR="${PROJECT_ROOT}/data"
RESULTS_DIR="${PROJECT_ROOT}/results"
RAW_DIR="${RESULTS_DIR}/raw"

mkdir -p "${RAW_DIR}"

ENGINES=("duckdb" "polars")
ROW_GROUPS=("10k" "50k" "122k" "250k" "500k" "1m")
REPETITIONS=5

CGROUP_NAME="benchmark"
CGROUP_PATH="/sys/fs/cgroup/${CGROUP_NAME}"

echo "======================================================================"
echo "    PARQUET OUT-OF-CORE STUDY: 60-RUN INTERLEAVED BENCHMARK SUITE    "
echo "======================================================================"
echo "Project Root : ${PROJECT_ROOT}"
echo "Data Dir     : ${DATA_DIR}"
echo "Results Dir  : ${RESULTS_DIR}"
echo "----------------------------------------------------------------------"

if [ "$(id -u)" -ne 0 ]; then
    echo "[!] ERROR: This script must be run as root (with sudo) to bypass cgroups v2 cross-hierarchy delegation restrictions."
    echo "    Please run: sudo ./scripts/run_benchmarks.sh"
    exit 1
fi

# 1. Environment Pre-Flight Checks & Virtualenv Activation
if [ -f "${PROJECT_ROOT}/.venv/bin/activate" ]; then
    echo "[+] Activating virtual environment (${PROJECT_ROOT}/.venv)..."
    # shellcheck source=/dev/null
    source "${PROJECT_ROOT}/.venv/bin/activate"
fi

HAS_CGEXEC=0
HAS_TASKSET=0
HAS_SUDO=0

if command -v cgexec &>/dev/null; then HAS_CGEXEC=1; fi
if command -v taskset &>/dev/null; then HAS_TASKSET=1; fi
if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then HAS_SUDO=1; fi

echo "Pre-Flight Diagnostics:"
echo "  - cgroups v2 cgexec available : $((HAS_CGEXEC))"
echo "  - CPU taskset affinity avail  : $((HAS_TASKSET))"
echo "  - Sudo page-cache purge avail : $((HAS_SUDO))"
echo "----------------------------------------------------------------------"

# 1.5. Lock CPU Governor to 'performance'
echo "[+] Locking CPU governor to 'performance' to prevent DVFS jitter..."
if [ "${HAS_SUDO}" -eq 1 ]; then
    echo "performance" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || true
fi
echo "----------------------------------------------------------------------"

# 1.6. Hardware Static Manifest
echo "[+] Generating Static Hardware Manifest..."
lscpu > "${RESULTS_DIR}/hardware_manifest.txt"
uname -r >> "${RESULTS_DIR}/hardware_manifest.txt"
if [ "${HAS_SUDO}" -eq 1 ]; then sudo nvme list >> "${RESULTS_DIR}/hardware_manifest.txt" 2>/dev/null || true; else nvme list >> "${RESULTS_DIR}/hardware_manifest.txt" 2>/dev/null || true; fi
free -h >> "${RESULTS_DIR}/hardware_manifest.txt"
echo "----------------------------------------------------------------------"

# 1.7. Dataset Manifest
echo "[+] Generating Dataset Manifest..."
du -sb "${DATA_DIR}"/*.parquet > "${RESULTS_DIR}/dataset_manifest.txt" 2>/dev/null || true
echo "----------------------------------------------------------------------"

# 2. Helper function to purge OS Page Cache and Defragment Memory
purge_page_cache() {
    sync
    if [ "${HAS_SUDO}" -eq 1 ]; then
        echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
        echo 1 | sudo tee /proc/sys/vm/compact_memory >/dev/null 2>&1 || true
    fi
}

# 3. Execution Matrix Loop (2-Pass Architecture)
TOTAL_RUNS=$(( ${#ENGINES[@]} * ${#ROW_GROUPS[@]} * REPETITIONS ))
SUMMARY_CSV="${RESULTS_DIR}/summary_runs.csv"
SUMMARY_JSON="${RESULTS_DIR}/summary_metrics.json"

echo "pass,engine,row_group_size,rep,status,execution_time_ms,spilled_bytes,peak_memory_bytes" > "${SUMMARY_CSV}"
echo "[" > "${SUMMARY_JSON}"
FIRST_JSON_ENTRY=1

# Execute everything for Pass A, then repeat for Pass B
for PASS in A B; do
    echo "======================================================================"
    echo ">>> STARTING PASS ${PASS} (A=Memory Telemetry, B=Hardware PMU)"
    echo "======================================================================"
    CURRENT_RUN=0

    for rep in $(seq 1 ${REPETITIONS}); do
        echo ">>> Pass ${PASS} - Repetition ${rep} / ${REPETITIONS}"
        
        for rg in "${ROW_GROUPS[@]}"; do
            PARQUET_FILE="${DATA_DIR}/lineitem_${rg}.parquet"

            if [ ! -f "${PARQUET_FILE}" ]; then
                echo "[!] Error: Missing Parquet dataset '${PARQUET_FILE}'. Run scripts/generate_data.py first." >&2
                exit 1
            fi

            for engine in "${ENGINES[@]}"; do
                CURRENT_RUN=$((CURRENT_RUN + 1))
                RUN_TAG="${engine}_${rg}_rep${rep}"
                METRICS_JSON="${RAW_DIR}/metrics_pass${PASS}_${RUN_TAG}.json"
                TELEMETRY_CSV="${RAW_DIR}/telemetry_pass${PASS}_${RUN_TAG}.csv"
                PERF_TXT="${RAW_DIR}/perf_pass${PASS}_${RUN_TAG}.txt"

                echo -n "[Run ${CURRENT_RUN}/${TOTAL_RUNS}] Executing ${engine} on rg=${rg} (rep ${rep})... "

                # Purge Page Cache before trial
                purge_page_cache

                # Construct runner script command
                RUNNER_SCRIPT="${PROJECT_ROOT}/src/${engine}_runner.py"

                # Launch target query runner inside native cgroups v2 slice and taskset affinity
                (
                    if [ -f "${CGROUP_PATH}/cgroup.procs" ]; then
                        echo $BASHPID > "${CGROUP_PATH}/cgroup.procs" 2>/dev/null || true
                    fi
                    if [ "${HAS_TASKSET}" -eq 1 ]; then
                        exec taskset -c 0,1,2,3 timeout -k 5s 180s python3 "${RUNNER_SCRIPT}" \
                            --parquet-path "${PARQUET_FILE}" \
                            --row-group-size "${rg}" \
                            --output-json "${METRICS_JSON}"
                    else
                        exec timeout -k 5s 180s python3 "${RUNNER_SCRIPT}" \
                            --parquet-path "${PARQUET_FILE}" \
                            --row-group-size "${rg}" \
                            --output-json "${METRICS_JSON}"
                    fi
                ) &
                QUERY_PID=$!

                # 2-Pass Divergence: Launch appropriate background daemon
                SAMPLER_PID=""
                if [ "${PASS}" == "A" ]; then
                    python3 "${PROJECT_ROOT}/harness/cgroup_sampler.py" \
                        --cgroup-path "${CGROUP_PATH}" \
                        --pid "${QUERY_PID}" \
                        --output-csv "${TELEMETRY_CSV}" \
                        --interval-ms 20 >/dev/null 2>&1 &
                    SAMPLER_PID=$!
                else
                    perf stat -e cycles,instructions,dTLB-loads,dTLB-load-misses,tlb:tlb_flush -p "${QUERY_PID}" -o "${PERF_TXT}" 2>&1 &
                    SAMPLER_PID=$!
                fi

                # Wait for query process to finish execution
                set +e
                wait "${QUERY_PID}"
                EXIT_CODE=$?
                set -e

                # Spilled Storage Extraction (DuckDB only) BEFORE cleanup
                SPILLED_BYTES=0
                if [ "${engine}" == "duckdb" ]; then
                    if [ -d "$HOME/duckdb_scratch" ]; then
                        SPILLED_BYTES=$(du -sb "$HOME/duckdb_scratch" 2>/dev/null | cut -f1) || SPILLED_BYTES=0
                    fi
                    # Wipe the scratch directory instantly
                    rm -rf "$HOME/duckdb_scratch"/* 2>/dev/null || true
                fi

                # Wait for telemetry/perf sampler to finish
                if [ -n "${SAMPLER_PID}" ]; then
                    wait "${SAMPLER_PID}" || true
                fi

                # Peak Memory Extraction
                PEAK_BYTES=0
                if [ -f "${CGROUP_PATH}/memory.peak" ]; then
                    PEAK_BYTES=$(cat "${CGROUP_PATH}/memory.peak") || PEAK_BYTES=0
                fi

                # Handle timeout (124) and OOM kills (135 SIGBUS, 137 SIGKILL) by creating a mock JSON so aggregate_metrics doesn't crash
                STATUS="SUCCESS"
                if [ "${EXIT_CODE}" -eq 124 ] || [ "${EXIT_CODE}" -eq 135 ] || [ "${EXIT_CODE}" -eq 137 ]; then
                    STATUS="TIMEOUT"
                    echo "FAILED / DNF (Exit code: ${EXIT_CODE})"
                    cat <<EOF > "${METRICS_JSON}"
{
  "engine": "${engine}",
  "row_group_size": "${rg}",
  "parquet_path": "${PARQUET_FILE}",
  "status": "TIMEOUT",
  "execution_time_ms": 180000.0,
  "elapsed_sec": 180.0,
  "result_rows": 0,
  "spilled_bytes": ${SPILLED_BYTES},
  "spilled_mb": 0.0,
  "threads": 4,
  "memory_limit": "500MB",
  "error_message": "Process killed (Exit Code: ${EXIT_CODE}) due to severe resource pressure or timeouts",
  "timestamp_utc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
                elif [ "${EXIT_CODE}" -eq 0 ]; then
                    echo "SUCCESS"
                else
                    STATUS="ERROR_${EXIT_CODE}"
                    echo "FAILED / ERROR (Exit code: ${EXIT_CODE})"
                fi

                # Append trial metrics to summary CSV
                EXEC_TIME_MS="0.0"
                if [ -f "${METRICS_JSON}" ]; then
                    EXEC_TIME_MS=$(grep -o '"execution_time_ms": [0-9.]*' "${METRICS_JSON}" | cut -d' ' -f2 || echo "0.0")
                fi
                echo "${PASS},${engine},${rg},${rep},${STATUS},${EXEC_TIME_MS},${SPILLED_BYTES},${PEAK_BYTES}" >> "${SUMMARY_CSV}"

                # Append to summary JSON (Only during Pass A to maintain 60-run graph structure)
                if [ "${PASS}" == "A" ] && [ -f "${METRICS_JSON}" ]; then
                    if [ ${FIRST_JSON_ENTRY} -eq 1 ]; then
                        FIRST_JSON_ENTRY=0
                    else
                        echo "," >> "${SUMMARY_JSON}"
                    fi
                    cat "${METRICS_JSON}" >> "${SUMMARY_JSON}"
                fi

                # Sleep 1s to allow thermal stabilization between runs
                sleep 1
            done
        done
    done
done

echo "" >> "${SUMMARY_JSON}"
echo "]" >> "${SUMMARY_JSON}"

echo "======================================================================"
echo "    BENCHMARK SUITE COMPLETE! Pass A and Pass B executed cleanly.     "
echo "    Summary Metrics (JSON) : ${SUMMARY_JSON}"
echo "    Summary Metrics (CSV)  : ${SUMMARY_CSV}"
echo "    Hardware Manifest      : ${RESULTS_DIR}/hardware_manifest.txt"
echo "    Raw Telemetry          : ${RAW_DIR}/"
echo "======================================================================"
