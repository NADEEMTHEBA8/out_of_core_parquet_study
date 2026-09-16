#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================="
echo " STAGE 1: LINUX CGROUPS V2 MEMORY SANDBOX SETUP"
echo "=========================================================="

CGROUP_DIR="/sys/fs/cgroup/benchmark"

echo "[1/4] Creating cgroups v2 benchmark slice at $CGROUP_DIR..."
sudo mkdir -p "$CGROUP_DIR"

echo "[2/4] Enabling memory controller in subtree control..."
if [ -f "/sys/fs/cgroup/cgroup.subtree_control" ]; then
    echo "+memory" | sudo tee /sys/fs/cgroup/cgroup.subtree_control > /dev/null || true
fi

echo "[3/4] Enforcing memory limits..."
# Soft Limit: 1 GB (1,073,741,824 bytes) - Triggers direct reclaim throttling
echo "1G" | sudo tee "$CGROUP_DIR/memory.high" > /dev/null

# Hard Limit: 1.5 GB (1,572,864,000 bytes) - Safety ceiling
echo "1500M" | sudo tee "$CGROUP_DIR/memory.max" > /dev/null

# Disable Swap: 0 bytes - Prevents anonymous heap from paging to swap
echo "0" | sudo tee "$CGROUP_DIR/memory.swap.max" > /dev/null

echo "[4/4] Verifying cgroups v2 sandbox configuration:"
echo "  - memory.high:     $(cat $CGROUP_DIR/memory.high)"
echo "  - memory.max:      $(cat $CGROUP_DIR/memory.max)"
echo "  - memory.swap.max: $(cat $CGROUP_DIR/memory.swap.max)"

echo "=========================================================="
echo " CGROUPS V2 SANDBOX READY ON LINUX TARGET"
echo "=========================================================="
