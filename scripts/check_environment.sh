#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================="
echo " STAGE 0: BARE-METAL HARDWARE & KERNEL PRE-FLIGHT AUDIT"
echo "=========================================================="

# 1. CPU Topology & Physical Core Check
echo -e "\n[1/5] Checking CPU Topology & SMT Mapping..."
if command -v lscpu &> /dev/null; then
    lscpu --extended
else
    echo "NOTICE: 'lscpu' not found (macOS / Darwin environment)."
fi

# 2. CPU Governor Check
echo -e "\n[2/5] Verifying CPU Scaling Governor..."
if [ -d "/sys/devices/system/cpu/cpu0/cpufreq" ]; then
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        core=$(basename $(dirname $gov))
        val=$(cat $gov)
        echo "  - $core: $val"
        if [ "$val" != "performance" ]; then
            echo "    WARNING: Core $core governor is NOT 'performance'!"
        fi
    done
else
    echo "NOTICE: cpufreq sysfs interface not present (Darwin / macOS host)."
fi

# 3. Transparent Huge Pages (THP) Check
echo -e "\n[3/5] Verifying Transparent Huge Pages (THP)..."
THP_FILE="/sys/kernel/mm/transparent_hugepage/enabled"
if [ -f "$THP_FILE" ]; then
    echo "  - THP Status: $(cat $THP_FILE)"
else
    echo "NOTICE: THP interface not found (Darwin / macOS host)."
fi

# 4. Physical NVMe Scratchpad Mount Check
echo -e "\n[4/5] Verifying DuckDB Scratchpad Path..."
SCRATCH_DIR="${HOME}/duckdb_scratch"
mkdir -p "$SCRATCH_DIR"
DF_OUT=$(df -T "$SCRATCH_DIR" 2>/dev/null || df -h "$SCRATCH_DIR" | tail -n 1)
echo "  - Scratch Path: $SCRATCH_DIR"
echo "  - Mount Info:   $DF_OUT"

if echo "$DF_OUT" | grep -q "tmpfs"; then
    echo "ERROR: Scratch directory is on 'tmpfs' RAM disk! Spills will write to RAM!"
    exit 1
else
    echo "  - SUCCESS: Scratchpad is backed by non-tmpfs storage."
fi

# 5. NVMe SMART Controller Health Check
echo -e "\n[5/5] Checking NVMe SMART Telemetry..."
if command -v nvme &> /dev/null; then
    sudo nvme smart-log /dev/nvme0n1 || echo "NOTICE: Run with sudo for NVMe SMART logs."
else
    echo "NOTICE: 'nvme-cli' not installed or running on macOS host."
fi

echo -e "\n=========================================================="
echo " PRE-FLIGHT AUDIT SCRIPT READY"
echo "=========================================================="
