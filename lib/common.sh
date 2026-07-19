#!/usr/bin/env bash
# =============================================================================
# common.sh — shared state, logging and small utilities.
# Sourced by bin/freeipa-check and the other lib/*.sh modules.
# =============================================================================

# --- Status levels (higher number = worse) ----------------------------------
readonly STATUS_OK=0
readonly STATUS_WARNING=1
readonly STATUS_CRITICAL=2
readonly STATUS_ERROR=3   # the check itself could not run

# Human-readable names indexed by level number.
STATUS_NAME=( [0]="OK" [1]="WARNING" [2]="CRITICAL" [3]="ERROR" )

# Overall run status, raised (never lowered) as checks report findings.
OVERALL_STATUS=$STATUS_OK

# Collected one-line findings for the summary report and notifications.
declare -a FINDINGS=()

# --- Colors (disabled when not a TTY or when --no-color is set) --------------
# Use ':=' so a value already set by CLI parsing (before this file is sourced)
# is preserved rather than clobbered.
: "${COLOR_ENABLED:=true}"
c_reset=""; c_red=""; c_yellow=""; c_green=""; c_blue=""; c_bold=""
setup_colors() {
    if [[ "$COLOR_ENABLED" == true && -t 1 && -z "${NO_COLOR:-}" ]]; then
        c_reset=$'\033[0m'; c_red=$'\033[31m'; c_yellow=$'\033[33m'
        c_green=$'\033[32m'; c_blue=$'\033[34m'; c_bold=$'\033[1m'
    else
        c_reset=""; c_red=""; c_yellow=""; c_green=""; c_blue=""; c_bold=""
    fi
}

# --- Logging ----------------------------------------------------------------
# LOG_FILE is set by init_logging(). Every line goes to the log file and, unless
# quiet, to the terminal. Log format: "TIMESTAMP [LEVEL] message".
LOG_FILE=""
# ':=' preserves a value already set by CLI parsing before this file is sourced.
: "${QUIET:=false}"

init_logging() {
    # $1 = log directory
    local log_dir="$1"
    mkdir -p "$log_dir" 2>/dev/null || {
        echo "FATAL: cannot create log directory: $log_dir" >&2
        exit $STATUS_ERROR
    }
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    LOG_FILE="${log_dir}/freeipa-check-${ts}.log"
    : > "$LOG_FILE" || {
        echo "FATAL: cannot write log file: $LOG_FILE" >&2
        exit $STATUS_ERROR
    }
    # Maintain a stable "latest" symlink for convenience.
    ln -sfn "$LOG_FILE" "${log_dir}/latest.log" 2>/dev/null || true
    log INFO "Logging to ${LOG_FILE}"
}

# log LEVEL message...
log() {
    local level="$1"; shift
    local msg="$*"
    local line; line="$(date '+%Y-%m-%d %H:%M:%S') [${level}] ${msg}"
    [[ -n "$LOG_FILE" ]] && printf '%s\n' "$line" >> "$LOG_FILE"
    [[ "$QUIET" == true ]] && return 0

    local color=""
    case "$level" in
        ERROR|CRITICAL) color="$c_red" ;;
        WARNING)        color="$c_yellow" ;;
        OK|PASS)        color="$c_green" ;;
        INFO)           color="$c_blue" ;;
    esac
    printf '%s%s%s\n' "$color" "$line" "$c_reset"
}

# --- Result recording -------------------------------------------------------
# record_result CHECK_NAME LEVEL "message"
# Raises OVERALL_STATUS and stores a finding for the summary.
record_result() {
    local check="$1" level="$2" msg="$3"
    local level_num
    case "$level" in
        OK)       level_num=$STATUS_OK ;;
        WARNING)  level_num=$STATUS_WARNING ;;
        CRITICAL) level_num=$STATUS_CRITICAL ;;
        *)        level_num=$STATUS_ERROR ;;
    esac
    (( level_num > OVERALL_STATUS )) && OVERALL_STATUS=$level_num
    FINDINGS+=( "${level}|${check}|${msg}" )

    case "$level" in
        OK)       log OK       "[$check] $msg" ;;
        WARNING)  log WARNING  "[$check] $msg" ;;
        CRITICAL) log CRITICAL "[$check] $msg" ;;
        *)        log ERROR    "[$check] $msg" ;;
    esac
}

# log_note "multi-line text" — logs each line at INFO (indented) to the log
# file and terminal. Used for multi-line remediation advice so that findings
# themselves stay single-line (keeping the summary, JSON and notifications
# clean, since those are parsed one line per finding).
log_note() {
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        log INFO "    $line"
    done <<<"$1"
}

# --- Small helpers ----------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        log WARNING "Not running as root; some checks (certmonger, ipactl) may be incomplete."
        return 1
    fi
    return 0
}

# Number of days from now until a UTC/epoch date. Prints an integer (may be
# negative if already expired). $1 = date string parseable by GNU date.
days_until() {
    local when="$1" now target
    now=$(date +%s)
    target=$(date -d "$when" +%s 2>/dev/null) || { echo "NaN"; return 1; }
    echo $(( (target - now) / 86400 ))
}
