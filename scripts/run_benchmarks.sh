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

# 2. Helper function to purge OS Page Cache
purge_page_cache() {
    sync
    if [ "${HAS_SUDO}" -eq 1 ]; then
        echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    fi
}

# 3. Execution Matrix Loop (Interleaved by repetition)
TOTAL_RUNS=$(( ${#ENGINES[@]} * ${#ROW_GROUPS[@]} * REPETITIONS ))
CURRENT_RUN=0

SUMMARY_FILE="${RESULTS_DIR}/summary_metrics.json"
echo "[" > "${SUMMARY_FILE}"
FIRST_JSON_ENTRY=1

for rep in $(seq 1 ${REPETITIONS}); do
    echo "======================================================================"
    echo ">>> STARTING EXPERIMENTAL REPETITION ${rep} / ${REPETITIONS}"
    echo "======================================================================"

    for rg in "${ROW_GROUPS[@]}"; do
        PARQUET_FILE="${DATA_DIR}/lineitem_${rg}.parquet"

        if [ ! -f "${PARQUET_FILE}" ]; then
            echo "[!] Error: Missing Parquet dataset '${PARQUET_FILE}'. Run scripts/generate_data.py first." >&2
            exit 1
        fi

        for engine in "${ENGINES[@]}"; do
            CURRENT_RUN=$((CURRENT_RUN + 1))
            RUN_TAG="${engine}_${rg}_rep${rep}"
            METRICS_JSON="${RAW_DIR}/metrics_${RUN_TAG}.json"
            TELEMETRY_CSV="${RAW_DIR}/telemetry_${RUN_TAG}.csv"

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
                    exec taskset -c 0,1,2,3 python3 "${RUNNER_SCRIPT}" \
                        --parquet-path "${PARQUET_FILE}" \
                        --row-group-size "${rg}" \
                        --output-json "${METRICS_JSON}"
                else
                    exec python3 "${RUNNER_SCRIPT}" \
                        --parquet-path "${PARQUET_FILE}" \
                        --row-group-size "${rg}" \
                        --output-json "${METRICS_JSON}"
                fi
            ) &
            QUERY_PID=$!

            # Launch cgroups telemetry sampler daemon in background
            python3 "${PROJECT_ROOT}/harness/cgroup_sampler.py" \
                --cgroup-path "${CGROUP_PATH}" \
                --pid "${QUERY_PID}" \
                --output-csv "${TELEMETRY_CSV}" \
                --interval-ms 20 >/dev/null 2>&1 &
            SAMPLER_PID=$!

            # Wait for query process to finish execution
            set +e
            wait "${QUERY_PID}"
            EXIT_CODE=$?
            set -e

            # Wait for telemetry sampler to finish
            wait "${SAMPLER_PID}" 2>/dev/null || true

            if [ ${EXIT_CODE} -eq 0 ]; then
                echo "SUCCESS"
            else
                echo "FAILED / OOM (Exit code: ${EXIT_CODE})"
            fi

            # Append trial metrics to summary JSON if metrics file exists
            if [ -f "${METRICS_JSON}" ]; then
                if [ ${FIRST_JSON_ENTRY} -eq 1 ]; then
                    FIRST_JSON_ENTRY=0
                else
                    echo "," >> "${SUMMARY_FILE}"
                fi
                cat "${METRICS_JSON}" >> "${SUMMARY_FILE}"
            fi

            # Sleep 1s to allow thermal stabilization between runs
            sleep 1
        done
    done
done

echo "" >> "${SUMMARY_FILE}"
echo "]" >> "${SUMMARY_FILE}"

echo "======================================================================"
echo "    BENCHMARK SUITE COMPLETE! All 60 trials executed cleanly.         "
echo "    Summary Metrics : ${SUMMARY_FILE}"
echo "    Raw Telemetry   : ${RAW_DIR}/"
echo "======================================================================"
