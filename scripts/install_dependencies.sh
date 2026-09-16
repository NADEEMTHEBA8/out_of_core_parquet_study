#!/usr/bin/env bash
# ==============================================================================
# Automated Dependencies Installation Helper for Linux Host (Ubuntu/Debian)
#
# Installs:
# 1. System packages (cgroup-tools, util-linux, linux-tools)
# 2. Python packages from requirements.txt
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "======================================================================"
echo "    INSTALLING BENCHMARK DEPENDENCIES ON LINUX TARGET                 "
echo "======================================================================"

# 1. Install System APT Packages (Requires Sudo)
if command -v apt-get &>/dev/null; then
    echo "[+] Updating apt repositories and installing system tools (cgroup-tools, util-linux, perf)..."
    sudo apt-get update -y
    sudo apt-get install -y \
        cgroup-tools \
        util-linux \
        linux-tools-common \
        linux-tools-generic \
        python3-pip \
        python3-venv \
        build-essential
else
    echo "[!] Warning: Non-APT system detected. Please install 'cgroup-tools', 'util-linux', and 'perf' via your package manager."
fi

# 2. Install Python Dependencies
echo "----------------------------------------------------------------------"
echo "[+] Installing Python packages from requirements.txt..."
python3 -m pip install --upgrade pip
python3 -m pip install -r "${PROJECT_ROOT}/requirements.txt"

echo "======================================================================"
echo "    ALL SYSTEM & PYTHON DEPENDENCIES INSTALLED SUCCESSFULLY!          "
echo "======================================================================"
