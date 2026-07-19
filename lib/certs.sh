#!/usr/bin/env bash
# =============================================================================
# certs.sh — certificate expiry inspection and renewal guidance.
#
# Sources of certificates:
#   1. certmonger-tracked certs, discovered via "getcert list".
#   2. Extra PEM files listed in EXTRA_CERT_FILES.
#
# For each cert we compute days-to-expiry and compare against CERT_WARN_DAYS /
# CERT_CRIT_DAYS, then attach a concrete recommended action.
# =============================================================================

# Recommendation text shown when a certmonger-tracked cert is near expiry.
_cert_advice_certmonger() {
    cat <<'ADVICE'
Recommended actions:
  * Certmonger normally auto-renews tracked certs. If it has not, force it:
      getcert list                 # find the Request ID and its status
      getcert resubmit -i <ID>     # trigger renewal for that request
  * If the IPA CA / subsystem certs are involved, act on the CA renewal master:
      getcert resubmit -i <ID>     # renew a certmonger-tracked subsystem cert
      ipa-cacert-manage renew      # renew the IPA CA certificate itself
      ipa-certupdate               # refresh local trust/db after renewal
  * Verify time sync (chrony/ntp) and that the CA is running: ipactl status
  * FreeIPA renewal guidance:
      https://www.freeipa.org/page/Certmonger
ADVICE
}

# Recommendation text for a plain PEM file (not certmonger-managed).
_cert_advice_file() {
    cat <<'ADVICE'
Recommended actions:
  * This certificate is not managed by certmonger. Renew it with whatever
    process issued it, then install the new PEM in place.
  * Inspect it manually:  openssl x509 -in <file> -noout -text
ADVICE
}

# check_certs — entry point registered in checks dispatch.
check_certs() {
    local warn_days="${CERT_WARN_DAYS:-30}"
    local crit_days="${CERT_CRIT_DAYS:-7}"
    local found_any=false

    # --- certmonger-tracked certificates ------------------------------------
    if have_cmd getcert; then
        # Parse "getcert list": each request has "Request ID", "expires:" and
        # "status:" lines. We stream through and evaluate per request.
        local getcert_out
        if getcert_out="$(getcert list 2>>"$LOG_FILE")"; then
            _parse_getcert "$getcert_out" "$warn_days" "$crit_days" && found_any=true
        else
            record_result certs ERROR "getcert list failed (is certmonger running? are you root?)"
        fi
    else
        log INFO "[certs] getcert not found; skipping certmonger-tracked certs."
    fi

    # --- extra PEM files -----------------------------------------------------
    if [[ -n "${EXTRA_CERT_FILES:-}" ]]; then
        local f
        for f in $EXTRA_CERT_FILES; do
            [[ -r "$f" ]] || { record_result certs ERROR "Cannot read cert file: $f"; continue; }
            _check_pem_file "$f" "$warn_days" "$crit_days"
            found_any=true
        done
    fi

    if [[ "$found_any" == false ]]; then
        record_result certs WARNING "No certificates were inspected (no getcert, no EXTRA_CERT_FILES)."
    fi
}

# _parse_getcert OUTPUT WARN_DAYS CRIT_DAYS
_parse_getcert() {
    local out="$1" warn_days="$2" crit_days="$3"
    local req_id="" expires="" status="" storage="" got=false

    # Evaluate one accumulated request record.
    _flush() {
        [[ -z "$expires" ]] && return 0
        got=true
        local days; days=$(days_until "$expires")
        local label="request ${req_id:-?} (${storage:-unknown})"
        if [[ "$days" == "NaN" ]]; then
            record_result certs ERROR "Cannot parse expiry for ${label}: '${expires}'"
        elif (( days < 0 )); then
            record_result certs CRITICAL "EXPIRED ${label}: expired $(( -days )) day(s) ago (status: ${status:-?})."
            log_note "$(_cert_advice_certmonger)"
        elif (( days <= crit_days )); then
            record_result certs CRITICAL "${label} expires in ${days} day(s) — status ${status:-?}."
            log_note "$(_cert_advice_certmonger)"
        elif (( days <= warn_days )); then
            record_result certs WARNING "${label} expires in ${days} day(s) — status ${status:-?}."
            log_note "$(_cert_advice_certmonger)"
        else
            record_result certs OK "${label} valid for ${days} more day(s) — status ${status:-?}."
        fi
        # Independently flag unhealthy certmonger status even if not near expiry.
        if [[ -n "$status" && "$status" != "MONITORING" && "$status" != "POST_SAVED_CERT" ]]; then
            if (( days > warn_days )); then
                record_result certs WARNING "${label} certmonger status is '${status}' (expected MONITORING)."
            fi
        fi
        req_id=""; expires=""; status=""; storage=""
    }

    local line
    while IFS= read -r line; do
        case "$line" in
            *"Request ID"*)
                _flush
                req_id="$(sed -n "s/.*Request ID '\([^']*\)'.*/\1/p" <<<"$line")"
                ;;
            *[Ss]tatus:*)  status="$(sed 's/.*[Ss]tatus:[[:space:]]*//' <<<"$line" | awk '{print $1}')" ;;
            *expires:*)    expires="$(sed 's/.*expires:[[:space:]]*//' <<<"$line")" ;;
            *"certificate:"*) storage="$(sed 's/.*certificate:[[:space:]]*//' <<<"$line")" ;;
        esac
    done <<<"$out"
    _flush
    [[ "$got" == true ]]
}

# _check_pem_file FILE WARN_DAYS CRIT_DAYS
_check_pem_file() {
    local file="$1" warn_days="$2" crit_days="$3"
    have_cmd openssl || { record_result certs ERROR "openssl not found; cannot check $file"; return; }
    local enddate
    enddate="$(openssl x509 -in "$file" -noout -enddate 2>>"$LOG_FILE" | sed 's/notAfter=//')" || {
        record_result certs ERROR "openssl could not read certificate: $file"; return; }
    local days; days=$(days_until "$enddate")
    if [[ "$days" == "NaN" ]]; then
        record_result certs ERROR "Cannot parse expiry for ${file}: '${enddate}'"
    elif (( days < 0 )); then
        record_result certs CRITICAL "EXPIRED ${file}: expired $(( -days )) day(s) ago."
        log_note "$(_cert_advice_file)"
    elif (( days <= crit_days )); then
        record_result certs CRITICAL "${file} expires in ${days} day(s)."
        log_note "$(_cert_advice_file)"
    elif (( days <= warn_days )); then
        record_result certs WARNING "${file} expires in ${days} day(s)."
        log_note "$(_cert_advice_file)"
    else
        record_result certs OK "${file} valid for ${days} more day(s)."
    fi
}
