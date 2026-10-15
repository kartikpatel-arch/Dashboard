#!/usr/bin/env bash
#
# cronjob.sh — weekly ASM pipeline entry point.
#
# Install once in crontab (see MANUAL_SETUP.md), e.g.:
#   0 3 * * 1  /home/kartik_patel_gameberrylabs_com/projects/asm/cronjob.sh >> /home/kartik_patel_gameberrylabs_com/projects/asm/logs/cron.log 2>&1
#
# What it does, in order:
#   1. Update every PD tool with pdtm, and update nuclei templates.
#   2. Run discovery.py  (subdomains, DNS, cloud inventory, buckets, Route53)
#   3. Run asm.py        (ports, TLS, httpx, katana, ffuf, nuclei, takeover,
#                          screenshots, diff, notify)
#
# Deliberately NOT using `set -e`: one step failing (e.g. a flaky tool
# update) shouldn't abort the rest of the weekly run. Each python script
# already handles its own per-tool errors and keeps going; this script's
# job is just to make sure both stages get a chance to run and that a
# fatal error is visible in the log.

set -uo pipefail

ASM_HOME="/home/kartik_patel_gameberrylabs_com/projects/asm"
VENV="${ASM_HOME}/venv"
export ASM_CONFIG="${ASM_HOME}/config.yaml"
LOG_DIR="${ASM_HOME}/logs"
mkdir -p "${LOG_DIR}"

TS="$(date '+%Y-%m-%d %H:%M:%S')"
echo "===== ASM run started: ${TS} ====="

# --------------------------------------------------------------------------
# 1. Update tools. pdtm manages subfinder, chaos, alterx, dnsx, cdncheck,
#    tlsx, naabu, httpx, katana, nuclei, notify, cloudlist.
#    ffuf, gowitness, nmap are installed separately (pdtm doesn't manage them)
#    and are just version-pinned at install time — see MANUAL_SETUP.md for
#    how to update those if you ever need to.
# --------------------------------------------------------------------------
echo "--- updating ProjectDiscovery tools via pdtm ---"
pdtm -ua
if [ $? -ne 0 ]; then
    echo "WARNING: pdtm update reported an error — continuing with whatever versions are installed."
fi

echo "--- updating nuclei templates ---"
nuclei -update-templates
if [ $? -ne 0 ]; then
    echo "WARNING: nuclei template update failed — continuing with existing templates."
fi

# --------------------------------------------------------------------------
# 2. Activate venv (psycopg2, boto3, pyyaml live here — see MANUAL_SETUP.md)
# --------------------------------------------------------------------------
if [ -f "${VENV}/bin/activate" ]; then
    # shellcheck disable=SC1091
    source "${VENV}/bin/activate"
else
    echo "ERROR: python venv not found at ${VENV}. Run the setup steps in MANUAL_SETUP.md first."
    exit 1
fi

# --------------------------------------------------------------------------
# 3. Discovery stage
# --------------------------------------------------------------------------
echo "--- running discovery.py ---"
python3 "${ASM_HOME}/discovery.py"
DISCOVERY_STATUS=$?
if [ ${DISCOVERY_STATUS} -ne 0 ]; then
    echo "ERROR: discovery.py exited with status ${DISCOVERY_STATUS}."
    echo "Proceeding to asm.py anyway — it will just scan whatever hand-off data exists (possibly none)."
fi

# --------------------------------------------------------------------------
# 4. ASM / active scanning stage
# --------------------------------------------------------------------------
echo "--- running asm.py ---"
python3 "${ASM_HOME}/asm.py"
ASM_STATUS=$?
if [ ${ASM_STATUS} -ne 0 ]; then
    echo "ERROR: asm.py exited with status ${ASM_STATUS}."
fi

# --------------------------------------------------------------------------
# 5. Refresh the dashboard data (reads the JSONL files, needs no database).
#    A failure here never affects the scan results, so it is only a warning.
# --------------------------------------------------------------------------
echo "--- building dashboard data ---"
python3 "${ASM_HOME}/dashboard.py" build
if [ $? -ne 0 ]; then
    echo "WARNING: dashboard build failed. Scan results are fine; run 'python3 dashboard.py build' by hand to see why."
fi

deactivate 2>/dev/null || true

TS="$(date '+%Y-%m-%d %H:%M:%S')"
echo "===== ASM run finished: ${TS} (discovery=${DISCOVERY_STATUS}, asm=${ASM_STATUS}) ====="

# Non-zero exit if either stage failed hard, so cron mail / monitoring notices.
if [ ${DISCOVERY_STATUS} -ne 0 ] || [ ${ASM_STATUS} -ne 0 ]; then
    exit 1
fi
exit 0