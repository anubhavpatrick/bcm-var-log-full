#!/bin/bash
# =============================================================================
# bcm-log-monitor.sh — BCM Log & Disk Monitoring Script
# =============================================================================
# Related Incident: INC-2025-0210
#
# Standalone monitoring script intended to run every 30 minutes via cron.
# Produces a timestamped report in the configured output directory (debug/).
#
# Usage:
#   ./bcm-log-monitor.sh [path/to/bcm-log-monitor.conf]
#
# Cron entry (runs every 30 minutes):
#   */30 * * * * /root/bcm-var-log-full/scripts/bcm-log-monitor.sh /root/bcm-var-log-full/scripts/bcm-log-monitor.conf >> /root/bcm-var-log-full/debug/cron.log 2>&1
# =============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# =============================================================================
# Source configuration
# =============================================================================

CONFIG_FILE="${1:-$(dirname "$0")/bcm-log-monitor.conf}"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE" >&2
    echo "Usage: $0 [path/to/bcm-log-monitor.conf]" >&2
    exit 1
fi
# shellcheck source=bcm-log-monitor.conf
source "$CONFIG_FILE"

# =============================================================================
# Acquire exclusive lock — only one instance may run at a time
# =============================================================================

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    echo "ERROR: Another instance of ${SCRIPT_NAME} is already running (lock: ${LOCK_FILE})" >&2
    exit 1
fi

# =============================================================================
# Setup
# =============================================================================

# Day-wise directory structure
RUN_DATE="$(date '+%Y-%m-%d')"
RUN_TIME="$(date '+%H%M%S')"

DAILY_REPORT_DIR="${MONITOR_OUTPUT_DIR}/${RUN_DATE}"
DAILY_LOG_DIR="${LOG_DIR}/${RUN_DATE}"
LOG_FILE="${DAILY_LOG_DIR}/bcm-log-monitor.log"
REPORT_FILE="${DAILY_REPORT_DIR}/monitor-${RUN_TIME}.txt"

mkdir -p "${DAILY_REPORT_DIR}"
mkdir -p "${DAILY_LOG_DIR}"

# If running interactively (TTY), also print to stdout
IS_INTERACTIVE=false
if [[ -t 1 ]]; then
    IS_INTERACTIVE=true
fi

# Write to report (and optionally stdout)
emit() {
    echo "$@" >> "${REPORT_FILE}"
    if ${IS_INTERACTIVE}; then
        echo "$@"
    fi
}

# Write to the persistent log file (one-line-per-run style)
log() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] [${level}] $*" >> "${LOG_FILE}" 2>/dev/null || true
}

# =============================================================================
# Report: Header
# =============================================================================

report_header() {
    emit "============================================="
    emit "  BCM Log Monitor Report"
    emit "  Host: $(hostname)"
    emit "  Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    emit "============================================="
    emit ""
}

# =============================================================================
# Report: Disk usage
# =============================================================================

report_disk_usage() {
    emit "=== /var DISK USAGE ==="
    emit ""
    df -h "${VAR_MOUNT_POINT}" >> "${REPORT_FILE}"
    if ${IS_INTERACTIVE}; then
        df -h "${VAR_MOUNT_POINT}"
    fi
    emit ""

    local usage_pct
    usage_pct=$(df "${VAR_MOUNT_POINT}" --output=pcent | tail -1 | tr -d ' %')
    emit "Current usage: ${usage_pct}%"
    emit ""
}

# =============================================================================
# Report: Top space consumers
# =============================================================================

report_top_consumers() {
    emit "=== TOP ${TOP_CONSUMERS_COUNT} SPACE CONSUMERS IN /var ==="
    emit ""
    # Capture du output; some subdirectories may be permission-denied
    local du_output
    du_output=$(du -sh "${VAR_MOUNT_POINT}"/*/ 2>/dev/null | sort -rh | head -"${TOP_CONSUMERS_COUNT}" || true)
    if [[ -n "${du_output}" ]]; then
        emit "${du_output}"
    else
        emit "(no directories found)"
    fi
    emit ""
}

# =============================================================================
# Report: Log file sizes and recent activity
# =============================================================================

report_log_files() {
    emit "=== LOG FILE SIZES ==="
    emit ""
    for logfile in ${MONITORED_LOGS}; do
        if [[ -f "${logfile}" ]]; then
            local size
            size=$(du -h "${logfile}" 2>/dev/null | cut -f1)
            emit "  ${size}  ${logfile}"
        else
            emit "  --     ${logfile}  (not found)"
        fi
    done
    emit ""

    emit "=== RECENT LOG ACTIVITY (last ${TAIL_LINES} lines each) ==="
    emit ""
    for logfile in ${MONITORED_LOGS}; do
        emit "--- ${logfile} ---"
        if [[ -f "${logfile}" ]]; then
            tail -"${TAIL_LINES}" "${logfile}" >> "${REPORT_FILE}" 2>/dev/null || emit "(unable to read)"
            if ${IS_INTERACTIVE}; then
                tail -"${TAIL_LINES}" "${logfile}" 2>/dev/null || echo "(unable to read)"
            fi
        else
            emit "(file not found)"
        fi
        emit ""
    done
}

# =============================================================================
# Threshold alerting
# =============================================================================

check_thresholds() {
    local usage_pct="$1"

    emit "=== THRESHOLD CHECK ==="
    emit ""

    if [[ ${usage_pct} -ge ${VAR_CRITICAL_THRESHOLD} ]]; then
        local msg="CRITICAL: /var is at ${usage_pct}% capacity (threshold: ${VAR_CRITICAL_THRESHOLD}%)"
        emit "${msg}"
        log "CRITICAL" "${msg}"
        logger -p daemon.crit -t "${SCRIPT_NAME}" "${msg}" 2>/dev/null || true
        echo "$(date '+%Y-%m-%d %H:%M:%S') ${msg}" >> "${MONITOR_OUTPUT_DIR}/ALERTS.log"

    elif [[ ${usage_pct} -ge ${VAR_WARN_THRESHOLD} ]]; then
        local msg="WARNING: /var is at ${usage_pct}% capacity (threshold: ${VAR_WARN_THRESHOLD}%)"
        emit "${msg}"
        log "WARN" "${msg}"
        logger -p daemon.warning -t "${SCRIPT_NAME}" "${msg}" 2>/dev/null || true
        echo "$(date '+%Y-%m-%d %H:%M:%S') ${msg}" >> "${MONITOR_OUTPUT_DIR}/ALERTS.log"

    else
        emit "OK: /var is at ${usage_pct}% (below ${VAR_WARN_THRESHOLD}% warning threshold)"
    fi
    emit ""
}

# =============================================================================
# Cleanup old reports
# =============================================================================

cleanup_old_reports() {
    emit "=== REPORT CLEANUP ==="
    emit ""

    # Remove daily report directories older than RETENTION_DAYS
    local deleted_count=0
    while IFS= read -r old_dir; do
        rm -rf "${old_dir}"
        (( deleted_count++ )) || true
    done < <(find "${MONITOR_OUTPUT_DIR}" -mindepth 1 -maxdepth 1 -type d -mtime +"${RETENTION_DAYS}" 2>/dev/null)

    if [[ ${deleted_count} -gt 0 ]]; then
        emit "Cleaned ${deleted_count} daily report dir(s) older than ${RETENTION_DAYS} days"
        log "INFO" "Cleaned ${deleted_count} daily report dir(s) older than ${RETENTION_DAYS} days"
    else
        emit "No old report directories to clean"
    fi

    # Also clean old daily log directories
    local log_deleted=0
    while IFS= read -r old_dir; do
        rm -rf "${old_dir}"
        (( log_deleted++ )) || true
    done < <(find "${LOG_DIR}" -mindepth 1 -maxdepth 1 -type d -mtime +"${RETENTION_DAYS}" 2>/dev/null)

    if [[ ${log_deleted} -gt 0 ]]; then
        emit "Cleaned ${log_deleted} daily log dir(s) older than ${RETENTION_DAYS} days"
    fi

    emit ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    log "INFO" "Monitor run started — report: ${REPORT_FILE}"

    report_header

    report_disk_usage

    local usage_pct
    usage_pct=$(df "${VAR_MOUNT_POINT}" --output=pcent | tail -1 | tr -d ' %')

    log "INFO" "/var usage: ${usage_pct}%"

    report_top_consumers
    report_log_files
    check_thresholds "${usage_pct}"
    cleanup_old_reports

    emit "============================================="
    emit "  End of Report — ${REPORT_FILE}"
    emit "============================================="

    log "INFO" "Monitor run completed — report: ${REPORT_FILE}"
}

main "$@"
