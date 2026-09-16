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

# 2. Setup Python Virtual Environment (.venv)
VENV_DIR="${PROJECT_ROOT}/.venv"
if [ ! -d "${VENV_DIR}" ]; then
    echo "----------------------------------------------------------------------"
    echo "[+] Creating Python virtual environment in '${VENV_DIR}'..."
    python3 -m venv "${VENV_DIR}"
fi

echo "[+] Activating virtual environment..."
# shellcheck source=/dev/null
source "${VENV_DIR}/bin/activate"

# 3. Install Python Dependencies inside Virtual Environment
echo "----------------------------------------------------------------------"
echo "[+] Installing Python packages into virtual environment from requirements.txt..."
python3 -m pip install --upgrade pip
python3 -m pip install -r "${PROJECT_ROOT}/requirements.txt"

echo "======================================================================"
echo "    ALL DEPENDENCIES INSTALLED IN VENV SUCCESSFULLY!                 "
echo "    To activate the virtual environment manually, run:                "
echo "    source .venv/bin/activate                                         "
echo "======================================================================"
