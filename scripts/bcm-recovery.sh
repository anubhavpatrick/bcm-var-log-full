#!/bin/bash
# =============================================================================
# bcm-recovery.sh — BCM Head Node Recovery Script
# =============================================================================
# Related Incident: INC-2025-0210
#
# Recovers a BCM head node after /var disk exhaustion caused by unbounded
# syslog growth and an rsyslog error loop.
#
# Usage: sudo ./bcm-recovery.sh [--skip-backup] [path/to/bcm-recovery.conf]
#
# Phases:
#   Pre-flight : Validate prerequisites (root, commands, disk, services, backup space)
#   Phase 1    : Backup syslog to root partition, truncate it, verify space recovered
#   Phase 2    : Restart rsyslog, flush postfix, clean cmd spool, restart CMDaemon, verify cmsh
#   Phase 3    : Update logrotate (with dry-run validation), add rsyslog rate limiting
# =============================================================================

set -euo pipefail

SCRIPT_VERSION="1.0.0"
SCRIPT_NAME="$(basename "$0")"
START_TIME="$(date +%s)"

# =============================================================================
# Parse arguments
# =============================================================================

SKIP_BACKUP=false
CONFIG_ARG=""
for arg in "$@"; do
    case "${arg}" in
        --skip-backup) SKIP_BACKUP=true ;;
        *)             CONFIG_ARG="${arg}" ;;
    esac
done

# =============================================================================
# Source configuration
# =============================================================================

CONFIG_FILE="${CONFIG_ARG:-$(dirname "$0")/bcm-recovery.conf}"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE" >&2
    echo "Usage: $0 [path/to/bcm-recovery.conf]" >&2
    exit 1
fi
# shellcheck source=bcm-recovery.conf
source "$CONFIG_FILE"

# Timestamp for this run — used for the backup subdirectory
RUN_TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
RUN_DATE="$(date '+%Y-%m-%d')"
BACKUP_DIR="${BACKUP_BASE_DIR}/${RUN_TIMESTAMP}"

# Day-wise log file
LOG_FILE="${LOG_DIR}/${RUN_DATE}/bcm-recovery.log"

# =============================================================================
# Utility functions
# =============================================================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${timestamp}] [${level}] ${message}"

    # Append to log file (create if needed)
    echo "${line}" >> "${LOG_FILE}" 2>/dev/null || true

    # Print to stdout/stderr with color
    case "${level}" in
        INFO)    echo -e "\033[0;34m${line}\033[0m" ;;
        SUCCESS) echo -e "\033[0;32m${line}\033[0m" ;;
        WARN)    echo -e "\033[0;33m${line}\033[0m" ;;
        ERROR)   echo -e "\033[0;31m${line}\033[0m" >&2 ;;
        *)       echo "${line}" ;;
    esac
}

fail_and_exit() {
    local message="$1"
    log "ERROR" "FATAL: ${message}"
    log "ERROR" "Recovery ABORTED. No further steps executed."
    log "ERROR" "Review log file: ${LOG_FILE}"
    exit 1
}

get_disk_usage_pct() {
    # Returns integer percentage for a given mount point
    df "$1" --output=pcent | tail -1 | tr -d ' %'
}

get_free_space_gb() {
    # Returns integer available GB for the partition containing a path
    df -BG "$1" --output=avail | tail -1 | tr -d ' G'
}

check_command_exists() {
    if ! command -v "$1" &>/dev/null; then
        fail_and_exit "Required command not found: $1"
    fi
}

# =============================================================================
# Pre-flight checks
# =============================================================================

preflight_check_root() {
    log "INFO" "Checking root privileges..."
    if [[ $EUID -ne 0 ]]; then
        fail_and_exit "This script must be run as root. Use: sudo $0"
    fi
    log "SUCCESS" "Running as root"
}

preflight_check_commands() {
    log "INFO" "Checking required commands..."
    local cmds=( df du cp truncate systemctl logrotate postsuper "${CMSH_COMMAND}" stat grep )
    for cmd in "${cmds[@]}"; do
        check_command_exists "${cmd}"
    done
    log "SUCCESS" "All required commands available"
}

preflight_check_disk() {
    log "INFO" "Checking /var disk usage..."
    local usage
    usage=$(get_disk_usage_pct "${VAR_MOUNT_POINT}")
    log "INFO" "/var is at ${usage}% capacity"

    # Log detailed df output
    df -h "${VAR_MOUNT_POINT}" >> "${LOG_FILE}" 2>/dev/null || true

    if [[ ${usage} -lt ${VAR_WARN_THRESHOLD} ]]; then
        log "WARN" "/var usage (${usage}%) is below the warning threshold (${VAR_WARN_THRESHOLD}%)."
        log "WARN" "Recovery may not be needed."
        read -r -p "Continue anyway? (y/n): " answer
        if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
            log "INFO" "User chose to abort."
            exit 0
        fi
    fi
}

preflight_check_services() {
    log "INFO" "Checking current service status..."
    for svc in "${RSYSLOG_SERVICE}" "${CMD_SERVICE}" "${POSTFIX_SERVICE}"; do
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            log "INFO" "  ${svc}: active"
        elif systemctl is-failed --quiet "${svc}" 2>/dev/null; then
            log "WARN" "  ${svc}: failed"
        else
            log "WARN" "  ${svc}: inactive / not found"
        fi
    done
}

preflight_check_backup_destination() {
    if [[ "${SKIP_BACKUP}" == true ]]; then
        log "INFO" "Skipping backup destination check (--skip-backup)"
        # Still create the backup directory — Phase 3 uses it for config backups
        mkdir -p "${BACKUP_DIR}"
        return 0
    fi

    log "INFO" "Checking backup destination..."

    # Determine the mount point for the parent of BACKUP_BASE_DIR
    local parent_dir
    parent_dir="$(dirname "${BACKUP_BASE_DIR}")"
    if [[ ! -d "${parent_dir}" ]]; then
        fail_and_exit "Parent directory of BACKUP_BASE_DIR does not exist: ${parent_dir}"
    fi

    local avail_gb
    avail_gb=$(get_free_space_gb "${parent_dir}")
    log "INFO" "Available space on backup partition: ${avail_gb} GB"

    if [[ ${avail_gb} -lt ${REQUIRED_FREE_SPACE_GB} ]]; then
        fail_and_exit "Insufficient space for syslog backup. Need ${REQUIRED_FREE_SPACE_GB} GB, have ${avail_gb} GB."
    fi

    # Create timestamped backup directory
    mkdir -p "${BACKUP_DIR}"
    log "SUCCESS" "Backup directory created: ${BACKUP_DIR}"
}

preflight_run_all() {
    log "INFO" "========================================"
    log "INFO" "  PRE-FLIGHT CHECKS"
    log "INFO" "========================================"
    preflight_check_root
    preflight_check_commands
    preflight_check_disk
    preflight_check_services
    preflight_check_backup_destination
    log "SUCCESS" "All pre-flight checks passed"
    echo
}

# =============================================================================
# Phase 1 — Emergency Disk Recovery
# =============================================================================

phase1_backup_syslog() {
    if [[ "${SKIP_BACKUP}" == true ]]; then
        log "WARN" "Syslog backup SKIPPED (--skip-backup flag set)"
        log "WARN" "The syslog file will be truncated without a backup"
        return 0
    fi

    local src="${SYSLOG_FILE}"
    local dst="${BACKUP_DIR}/syslog.incident-backup"

    if [[ ! -f "${src}" ]]; then
        fail_and_exit "Syslog file not found: ${src}"
    fi

    local src_size_bytes
    src_size_bytes=$(stat -c%s "${src}")
    local src_size_human
    src_size_human=$(du -h "${src}" | cut -f1)

    log "INFO" "Backing up syslog — ${src_size_human} to copy, this may take a long time..."
    log "INFO" "  Source: ${src}"
    log "INFO" "  Destination: ${dst}"
    log "INFO" "  Note: rsyslog is still writing; the backup may be slightly larger than ${src_size_human}"

    local copy_start
    copy_start=$(date +%s)

    local copy_failed=false
    if ! cp -- "${src}" "${dst}"; then
        copy_failed=true
    fi

    local copy_end
    copy_end=$(date +%s)
    local copy_duration=$(( copy_end - copy_start ))

    if [[ "${copy_failed}" == true ]]; then
        log "ERROR" "Syslog backup failed after ${copy_duration} seconds"
        log "WARN" "You can skip the backup and proceed directly to truncation."
        log "WARN" "The syslog data will be PERMANENTLY LOST if you continue without a backup."
        read -r -p "Continue without backup? (y/n): " answer
        if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
            fail_and_exit "Backup failed and user chose to abort"
        fi
        log "WARN" "User chose to continue without backup"
        return 0
    fi

    log "INFO" "Copy completed in ${copy_duration} seconds"

    # Verify backup exists and is at least as large as the pre-copy source size.
    # The backup may be larger because rsyslog continues writing during the copy.
    local backup_ok=true

    if [[ ! -f "${dst}" ]]; then
        log "ERROR" "Backup verification failed: file not found at ${dst}"
        backup_ok=false
    fi

    if [[ "${backup_ok}" == true ]]; then
        local dst_size_bytes
        dst_size_bytes=$(stat -c%s "${dst}")
        if [[ "${dst_size_bytes}" -lt "${src_size_bytes}" ]]; then
            log "ERROR" "Backup may be incomplete: expected at least ${src_size_bytes} bytes, got ${dst_size_bytes} bytes"
            backup_ok=false
        fi
    fi

    if [[ "${backup_ok}" == false ]]; then
        log "WARN" "Backup verification failed. You can still proceed with truncation."
        log "WARN" "A partial backup may exist at: ${dst}"
        read -r -p "Continue despite backup verification failure? (y/n): " answer
        if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
            fail_and_exit "Backup verification failed and user chose to abort"
        fi
        log "WARN" "User chose to continue despite backup verification failure"
        return 0
    fi

    local dst_size_human
    dst_size_human=$(du -h "${dst}" | cut -f1)
    log "SUCCESS" "Syslog backed up and verified: ${dst} (${dst_size_human})"
}

phase1_truncate_syslog() {
    log "INFO" "Truncating syslog file..."

    if ! truncate -s 0 "${SYSLOG_FILE}"; then
        fail_and_exit "Failed to truncate ${SYSLOG_FILE}"
    fi

    # Verify
    local new_size
    new_size=$(stat -c%s "${SYSLOG_FILE}")
    if [[ "${new_size}" -ne 0 ]]; then
        fail_and_exit "Truncation verification failed: size is ${new_size} bytes (expected 0)"
    fi

    log "SUCCESS" "Syslog truncated to 0 bytes"
}

phase1_verify_space() {
    log "INFO" "Verifying disk space recovery..."
    sleep 2

    local usage
    usage=$(get_disk_usage_pct "${VAR_MOUNT_POINT}")
    log "INFO" "/var is now at ${usage}%"
    df -h "${VAR_MOUNT_POINT}" | tee -a "${LOG_FILE}"

    if [[ ${usage} -ge ${VAR_WARN_THRESHOLD} ]]; then
        log "WARN" "/var usage is still at ${usage}%. Additional cleanup may be needed."
    else
        log "SUCCESS" "Disk space recovered successfully"
    fi
}

phase1_run() {
    log "INFO" "========================================"
    log "INFO" "  PHASE 1: EMERGENCY DISK RECOVERY"
    log "INFO" "========================================"
    phase1_backup_syslog
    phase1_truncate_syslog
    phase1_verify_space
    log "SUCCESS" "Phase 1 completed"
    echo
}

# =============================================================================
# Phase 2 — Service Restoration
# =============================================================================

phase2_restart_rsyslog() {
    log "INFO" "Restarting rsyslog..."

    if ! systemctl restart "${RSYSLOG_SERVICE}"; then
        fail_and_exit "Failed to restart ${RSYSLOG_SERVICE}"
    fi

    sleep 2

    if ! systemctl is-active --quiet "${RSYSLOG_SERVICE}"; then
        fail_and_exit "${RSYSLOG_SERVICE} is not active after restart"
    fi

    log "SUCCESS" "rsyslog restarted and active"
    systemctl status "${RSYSLOG_SERVICE}" --no-pager -l 2>&1 | head -15 | tee -a "${LOG_FILE}"
}

phase2_flush_postfix() {
    log "INFO" "Flushing Postfix mail queue..."

    if postsuper -d ALL 2>&1 | tee -a "${LOG_FILE}"; then
        log "SUCCESS" "Postfix queue flushed"
    else
        log "WARN" "postsuper failed (non-critical — Postfix may not be running)"
    fi
}

phase2_clean_cmd_spool() {
    log "INFO" "Cleaning CMDaemon spool directory..."

    local count=0
    if [[ -d "${CMDAEMON_SPOOL}" ]]; then
        count=$(find "${CMDAEMON_SPOOL}" -name "cmd.output.*" 2>/dev/null | wc -l)
        if [[ ${count} -gt 0 ]]; then
            rm -f "${CMDAEMON_SPOOL}"/cmd.output.*
            log "SUCCESS" "Removed ${count} stale spool file(s) from ${CMDAEMON_SPOOL}"
        else
            log "INFO" "No stale spool files found"
        fi
    else
        log "INFO" "Spool directory does not exist: ${CMDAEMON_SPOOL}"
    fi
}

phase2_restart_cmd_service() {
    log "INFO" "Restarting CMDaemon (${CMD_SERVICE})..."

    local attempt=0
    while [[ ${attempt} -lt ${MAX_SERVICE_RESTART_RETRIES} ]]; do
        attempt=$(( attempt + 1 ))
        log "INFO" "Attempt ${attempt}/${MAX_SERVICE_RESTART_RETRIES}..."

        if timeout "${SERVICE_RESTART_TIMEOUT}" systemctl restart "${CMD_SERVICE}" 2>&1 | tee -a "${LOG_FILE}"; then
            sleep "${SERVICE_RESTART_DELAY}"

            if systemctl is-active --quiet "${CMD_SERVICE}"; then
                log "SUCCESS" "CMDaemon is active"
                systemctl status "${CMD_SERVICE}" --no-pager -l 2>&1 | head -15 | tee -a "${LOG_FILE}"
                return 0
            fi
        fi

        log "WARN" "CMDaemon not active yet, waiting ${SERVICE_RESTART_DELAY}s before retry..."
        sleep "${SERVICE_RESTART_DELAY}"
    done

    fail_and_exit "CMDaemon failed to start after ${MAX_SERVICE_RESTART_RETRIES} attempts (timeout: ${SERVICE_RESTART_TIMEOUT}s each). Check: journalctl -u ${CMD_SERVICE} -n 50"
}

phase2_verify_cmsh() {
    log "INFO" "Verifying cmsh access..."

    local output
    if output=$(timeout "${CMSH_TIMEOUT}" "${CMSH_COMMAND}" -c "${CMSH_TEST_COMMAND}" 2>&1); then
        log "SUCCESS" "cmsh is accessible and responding"
        log "INFO" "Cluster status:"
        echo "${output}" | tee -a "${LOG_FILE}"
    else
        fail_and_exit "cmsh verification failed (exit code $?). Check: ${CMDAEMON_SPOOL}/../cmdaemon.log"
    fi
}

phase2_run() {
    log "INFO" "========================================"
    log "INFO" "  PHASE 2: SERVICE RESTORATION"
    log "INFO" "========================================"
    phase2_restart_rsyslog
    phase2_flush_postfix
    phase2_clean_cmd_spool
    phase2_restart_cmd_service
    phase2_verify_cmsh
    log "SUCCESS" "Phase 2 completed"
    echo
}

# =============================================================================
# Phase 3 — Preventive Configuration
# =============================================================================

phase3_backup_logrotate() {
    log "INFO" "Backing up logrotate config..."

    local src="${LOGROTATE_RSYSLOG_CONF}"
    local dst="${BACKUP_DIR}/$(basename "${src}")${CONFIG_BACKUP_SUFFIX}"

    if [[ ! -f "${src}" ]]; then
        fail_and_exit "Logrotate config not found: ${src}"
    fi

    if ! cp -- "${src}" "${dst}"; then
        fail_and_exit "Failed to backup logrotate config to ${dst}"
    fi

    log "SUCCESS" "Logrotate config backed up: ${dst}"
}

phase3_write_logrotate() {
    log "INFO" "Writing new logrotate configuration..."

    if ! printf '%s\n' "${LOGROTATE_CONFIG}" > "${LOGROTATE_RSYSLOG_CONF}"; then
        fail_and_exit "Failed to write new logrotate config to ${LOGROTATE_RSYSLOG_CONF}"
    fi

    log "SUCCESS" "New logrotate config written to ${LOGROTATE_RSYSLOG_CONF}"
    log "INFO" "Key changes: weekly->daily, added maxsize 5G (syslog) / 500M (others)"
}

phase3_validate_logrotate() {
    log "INFO" "Validating logrotate configuration (dry-run)..."

    if logrotate -d "${LOGROTATE_RSYSLOG_CONF}" >> "${LOG_FILE}" 2>&1; then
        log "SUCCESS" "Logrotate dry-run passed"
    else
        log "ERROR" "Logrotate dry-run FAILED — restoring original config"

        local backup="${BACKUP_DIR}/$(basename "${LOGROTATE_RSYSLOG_CONF}")${CONFIG_BACKUP_SUFFIX}"
        if [[ -f "${backup}" ]]; then
            cp -- "${backup}" "${LOGROTATE_RSYSLOG_CONF}"
            log "INFO" "Original config restored from ${backup}"
        fi

        fail_and_exit "Logrotate validation failed. Original config has been restored."
    fi
}

phase3_backup_rsyslog_conf() {
    log "INFO" "Backing up rsyslog.conf..."

    local src="${RSYSLOG_CONF}"
    local dst="${BACKUP_DIR}/$(basename "${src}")${CONFIG_BACKUP_SUFFIX}"

    if [[ ! -f "${src}" ]]; then
        fail_and_exit "rsyslog.conf not found: ${src}"
    fi

    if ! cp -- "${src}" "${dst}"; then
        fail_and_exit "Failed to backup rsyslog.conf to ${dst}"
    fi

    log "SUCCESS" "rsyslog.conf backed up: ${dst}"
}

phase3_add_rate_limiting() {
    log "INFO" "Adding rsyslog rate limiting..."

    if grep -q 'SystemLogRateLimitInterval' "${RSYSLOG_CONF}"; then
        log "WARN" "Rate limiting already present in ${RSYSLOG_CONF} — skipping"
        return 0
    fi

    local rate_config
    rate_config=$(cat <<EOF

# BCM Recovery: Rate limiting to prevent rsyslog error loops
# Added by ${SCRIPT_NAME} on $(date)
\$SystemLogRateLimitInterval ${RSYSLOG_RATE_LIMIT_INTERVAL}
\$SystemLogRateLimitBurst ${RSYSLOG_RATE_LIMIT_BURST}
EOF
)

    if ! printf '%s\n' "${rate_config}" >> "${RSYSLOG_CONF}"; then
        fail_and_exit "Failed to append rate limiting to ${RSYSLOG_CONF}"
    fi

    log "SUCCESS" "Rate limiting added: ${RSYSLOG_RATE_LIMIT_BURST} msgs per ${RSYSLOG_RATE_LIMIT_INTERVAL}s"
}

phase3_restart_rsyslog() {
    log "INFO" "Restarting rsyslog to apply new configuration..."

    if ! systemctl restart "${RSYSLOG_SERVICE}"; then
        fail_and_exit "Failed to restart rsyslog after config changes"
    fi

    sleep 2

    if ! systemctl is-active --quiet "${RSYSLOG_SERVICE}"; then
        fail_and_exit "rsyslog is not active after config changes. Check: journalctl -u ${RSYSLOG_SERVICE} -n 50"
    fi

    log "SUCCESS" "rsyslog restarted with new configuration"
}

phase3_run() {
    log "INFO" "========================================"
    log "INFO" "  PHASE 3: PREVENTIVE CONFIGURATION"
    log "INFO" "========================================"
    phase3_backup_logrotate
    phase3_write_logrotate
    phase3_validate_logrotate
    phase3_backup_rsyslog_conf
    phase3_add_rate_limiting
    phase3_restart_rsyslog
    log "SUCCESS" "Phase 3 completed"
    echo
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo "============================================="
    echo "  BCM Head Node Recovery Script v${SCRIPT_VERSION}"
    echo "============================================="
    echo

    # Ensure day-wise log directory exists
    mkdir -p "${LOG_DIR}/${RUN_DATE}" 2>/dev/null || true

    log "INFO" "Recovery started at $(date)"
    log "INFO" "Configuration: ${CONFIG_FILE}"
    log "INFO" "Log file: ${LOG_FILE}"
    log "INFO" "Backup directory: ${BACKUP_DIR}"
    echo

    preflight_run_all
    phase1_run
    phase2_run
    phase3_run

    local end_time
    end_time=$(date +%s)
    local duration=$(( end_time - START_TIME ))

    log "SUCCESS" "========================================"
    log "SUCCESS" "  RECOVERY COMPLETED SUCCESSFULLY"
    log "SUCCESS" "========================================"
    log "INFO" "Total time: ${duration} seconds"
    log "INFO" "Backups: ${BACKUP_DIR}"
    log "INFO" "Log: ${LOG_FILE}"
}

main "$@"
