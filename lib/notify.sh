#!/usr/bin/env bash
# =============================================================================
# notify.sh — pluggable notification dispatch.
#
# Channels:
#   * log     : always on (handled by common.sh logging; nothing to do here).
#   * email   : sends via mailx/mail (or a custom command) when enabled.
#   * webhook : POSTs a templated JSON payload to a configurable URL. The
#               architecture is complete; drop in the Slack/Teams/custom URL
#               and payload later without touching code.
#
# Public entry point: notify_dispatch LEVEL SUBJECT BODY
# =============================================================================

# Map a level name to a number so we can compare against a channel's MIN_LEVEL.
_level_num() {
    case "$1" in
        OK)       echo 0 ;;
        WARNING)  echo 1 ;;
        CRITICAL) echo 2 ;;
        *)        echo 3 ;;
    esac
}

# notify_dispatch LEVEL SUBJECT BODY
notify_dispatch() {
    local level="$1" subject="$2" body="$3"
    _notify_email   "$level" "$subject" "$body"
    _notify_webhook "$level" "$subject" "$body"
}

# --- Email ------------------------------------------------------------------
_notify_email() {
    local level="$1" subject="$2" body="$3"
    [[ "${NOTIFY_EMAIL_ENABLED:-false}" == true ]] || return 0
    if (( $(_level_num "$level") < $(_level_num "${NOTIFY_EMAIL_MIN_LEVEL:-WARNING}") )); then
        return 0
    fi

    # Resolve the mail command: explicit override, then mailx, then mail.
    local mail_cmd="${NOTIFY_EMAIL_CMD:-}"
    if [[ -z "$mail_cmd" ]]; then
        if have_cmd mailx; then mail_cmd="mailx"
        elif have_cmd mail; then mail_cmd="mail"
        else
            log ERROR "Email notification enabled but no mailx/mail command found."
            return 1
        fi
    fi

    local host; host="$(hostname -f 2>/dev/null || hostname)"
    local full_subject="[${level}] FreeIPA ${host} — ${subject}"

    if printf '%s\n' "$body" | "$mail_cmd" -s "$full_subject" "${NOTIFY_EMAIL_TO}" 2>>"$LOG_FILE"; then
        log INFO "Email notification sent to ${NOTIFY_EMAIL_TO}"
    else
        log ERROR "Email notification failed (see log)."
    fi
}

# --- Webhook ----------------------------------------------------------------
_notify_webhook() {
    local level="$1" subject="$2" body="$3"
    [[ "${NOTIFY_WEBHOOK_ENABLED:-false}" == true ]] || return 0
    if (( $(_level_num "$level") < $(_level_num "${NOTIFY_WEBHOOK_MIN_LEVEL:-WARNING}") )); then
        return 0
    fi
    if [[ -z "${NOTIFY_WEBHOOK_URL:-}" ]]; then
        log WARNING "Webhook enabled but NOTIFY_WEBHOOK_URL is empty; skipping."
        return 0
    fi
    if ! have_cmd curl; then
        log ERROR "Webhook notification enabled but curl is not installed."
        return 1
    fi

    local host timestamp payload
    host="$(hostname -f 2>/dev/null || hostname)"
    timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"

    # Render the payload template. Bodies are JSON-escaped so newlines/quotes
    # in findings do not break the payload.
    payload="${NOTIFY_WEBHOOK_PAYLOAD}"
    payload="${payload//\{\{level\}\}/$(_json_escape "$level")}"
    payload="${payload//\{\{subject\}\}/$(_json_escape "$subject")}"
    payload="${payload//\{\{body\}\}/$(_json_escape "$body")}"
    payload="${payload//\{\{host\}\}/$(_json_escape "$host")}"
    payload="${payload//\{\{timestamp\}\}/$(_json_escape "$timestamp")}"

    local http_code
    http_code=$(curl -sS -o /dev/null -w '%{http_code}' \
        -X POST \
        -H "Content-Type: ${NOTIFY_WEBHOOK_CONTENT_TYPE:-application/json}" \
        --data "$payload" \
        --max-time 15 \
        "$NOTIFY_WEBHOOK_URL" 2>>"$LOG_FILE") || {
        log ERROR "Webhook POST failed (curl error, see log)."
        return 1
    }
    if [[ "$http_code" =~ ^2 ]]; then
        log INFO "Webhook notification sent (HTTP ${http_code})."
    else
        log ERROR "Webhook returned HTTP ${http_code}."
    fi
}

# Escape a string for safe embedding inside a JSON string literal.
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"   # backslash
    s="${s//\"/\\\"}"   # double quote
    s="${s//$'\n'/\\n}" # newline
    s="${s//$'\r'/}"    # carriage return
    s="${s//$'\t'/\\t}" # tab
    printf '%s' "$s"
}
