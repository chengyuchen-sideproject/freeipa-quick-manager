#!/usr/bin/env bash
# =============================================================================
# checks.sh — FreeIPA service and health checks (read-only).
#
# Every check function is named check_<name> and reports via record_result.
# The dispatcher in bin/freeipa-check maps ENABLED_CHECKS / --check to these.
# =============================================================================

# --- ipactl status ----------------------------------------------------------
# Parses "ipactl status" which prints one line per service ending in
# "RUNNING" or "STOPPED".
check_ipactl() {
    have_cmd ipactl || { record_result ipactl ERROR "ipactl not found — is this a FreeIPA server?"; return; }
    local out rc
    out="$(ipactl status 2>&1)"; rc=$?
    if (( rc != 0 )) && ! grep -qi "RUNNING" <<<"$out"; then
        record_result ipactl CRITICAL "ipactl status failed (rc=$rc): $(head -n1 <<<"$out")"
        return
    fi
    local stopped
    stopped="$(grep -iE 'STOPPED|not running' <<<"$out" || true)"
    if [[ -n "$stopped" ]]; then
        local n_stopped; n_stopped="$(grep -ic 'STOPPED' <<<"$stopped")"
        record_result ipactl CRITICAL "${n_stopped} FreeIPA service(s) STOPPED. Recommended: 'ipactl start' (or 'ipactl restart'); review /var/log/ for the failing service."
        log_note "Stopped services:"
        log_note "$stopped"
    else
        local count; count="$(grep -ic "RUNNING" <<<"$out")"
        record_result ipactl OK "All ${count} FreeIPA service(s) RUNNING."
    fi
}

# --- systemd unit -----------------------------------------------------------
check_systemd() {
    have_cmd systemctl || { record_result systemd ERROR "systemctl not found."; return; }
    local unit="ipa"
    if ! systemctl list-unit-files 2>/dev/null | grep -q "^${unit}.service"; then
        log INFO "[systemd] ipa.service not present; skipping (older FreeIPA?)."
        record_result systemd OK "ipa.service not present on this host (skipped)."
        return
    fi
    local state; state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    if [[ "$state" == "active" ]]; then
        record_result systemd OK "ipa.service is active."
    else
        record_result systemd CRITICAL "ipa.service is '${state}'. Recommended: 'systemctl start ipa' and 'journalctl -u ipa'."
    fi
}

# --- LDAP / Directory Server ------------------------------------------------
check_ldap() {
    # Prefer the lightweight "ipa ping"; fall back to an anonymous rootDSE read.
    if have_cmd ldapsearch; then
        if ldapsearch -x -H ldap://localhost -b "" -s base "objectclass=*" >/dev/null 2>>"$LOG_FILE"; then
            record_result ldap OK "LDAP (389-ds) answered anonymous rootDSE query."
            return
        fi
        # Try LDAPS as a fallback (some deployments block plain ldap).
        if ldapsearch -x -H ldaps://localhost -b "" -s base "objectclass=*" >/dev/null 2>>"$LOG_FILE"; then
            record_result ldap OK "LDAPS answered anonymous rootDSE query."
            return
        fi
        record_result ldap CRITICAL "LDAP did not respond. Recommended: check 'ipactl status', 'systemctl status dirsrv@*', and /var/log/dirsrv/."
    else
        log INFO "[ldap] ldapsearch not installed; skipping direct LDAP probe."
        record_result ldap OK "ldapsearch not installed (LDAP probe skipped)."
    fi
}

# --- Kerberos KDC -----------------------------------------------------------
check_kerberos() {
    # Non-intrusive: confirm the KDC service is up and the host keytab exists.
    local ok=true detail=""
    if have_cmd systemctl; then
        local kdc; kdc="$(systemctl is-active krb5kdc 2>/dev/null || true)"
        if [[ -n "$kdc" && "$kdc" != "active" && "$kdc" != "unknown" ]]; then
            ok=false; detail+="krb5kdc is '${kdc}'. "
        fi
    fi
    if [[ ! -s /etc/krb5.keytab ]]; then
        ok=false; detail+="/etc/krb5.keytab missing or empty. "
    fi
    if [[ "$ok" == true ]]; then
        record_result kerberos OK "KDC service active and host keytab present."
    else
        record_result kerberos CRITICAL "Kerberos problem: ${detail}Recommended: 'ipactl status', 'systemctl status krb5kdc', check /var/log/krb5kdc.log."
    fi
}

# --- DNS (only if FreeIPA manages DNS) --------------------------------------
check_dns() {
    if ! have_cmd systemctl || ! systemctl list-unit-files 2>/dev/null | grep -qE '^named(-pkcs11)?\.service'; then
        log INFO "[dns] Integrated DNS not installed; skipping."
        record_result dns OK "Integrated DNS not installed on this host (skipped)."
        return
    fi
    local svc="named-pkcs11"
    systemctl list-unit-files 2>/dev/null | grep -q '^named\.service' && svc="named"
    local state; state="$(systemctl is-active "$svc" 2>/dev/null || true)"
    if [[ "$state" != "active" ]]; then
        record_result dns CRITICAL "${svc} is '${state}'. Recommended: 'systemctl start ${svc}' and check /var/log/messages."
        return
    fi
    # Functional probe: resolve our own hostname against localhost.
    if have_cmd dig; then
        local host; host="$(hostname -f 2>/dev/null || hostname)"
        if dig +short +time=3 +tries=1 @localhost "$host" >/dev/null 2>>"$LOG_FILE"; then
            record_result dns OK "${svc} active and resolving via localhost."
        else
            record_result dns WARNING "${svc} active but query for ${host} via localhost failed. Check named logs and forwarders."
        fi
    else
        record_result dns OK "${svc} active (dig not installed; skipped functional probe)."
    fi
}

# --- Web UI / httpd ---------------------------------------------------------
check_webui() {
    have_cmd curl || { record_result webui OK "curl not installed (Web UI probe skipped)."; return; }
    local code
    # curl already prints "000" for connection failures; capture it and only
    # substitute a default if the output is empty (do not chain "|| echo",
    # which would double-print and yield "000000").
    code="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 https://localhost/ipa/ui/ 2>>"$LOG_FILE")" || true
    [[ -z "$code" ]] && code="000"
    if [[ "$code" =~ ^(200|301|302|401)$ ]]; then
        record_result webui OK "Web UI reachable (HTTP ${code})."
    else
        record_result webui CRITICAL "Web UI returned HTTP ${code}. Recommended: 'systemctl status httpd', check /var/log/httpd/error_log and SELinux denials."
    fi
}

# --- Replication ------------------------------------------------------------
check_replication() {
    have_cmd ipa-replica-manage || {
        log INFO "[replication] ipa-replica-manage not found; skipping."
        record_result replication OK "ipa-replica-manage not available (skipped)."
        return
    }
    local out rc
    out="$(ipa-replica-manage list 2>&1)"; rc=$?
    if (( rc != 0 )); then
        # Non-fatal: this often needs a Directory Manager bind; report as info.
        record_result replication WARNING "Could not list replicas (rc=$rc). This may need DM credentials; run manually: ipa-replica-manage list -v"
        return
    fi
    local peers; peers="$(grep -c ':' <<<"$out" || true)"
    if (( peers <= 1 )); then
        record_result replication OK "Single-server topology or no additional replicas detected."
    else
        record_result replication OK "${peers} server(s) in topology. Verify agreements with: ipa-replica-manage list -v <host>"
    fi
}

# --- Disk space -------------------------------------------------------------
check_disk() {
    local warn="${DISK_WARN_PERCENT:-85}" crit="${DISK_CRIT_PERCENT:-95}"
    local paths="${DISK_PATHS:-/ /var /var/log}"
    local p
    for p in $paths; do
        [[ -e "$p" ]] || continue
        local used
        used="$(df -P "$p" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
        [[ -z "$used" ]] && continue
        if (( used >= crit )); then
            record_result disk CRITICAL "${p} is ${used}% full. Free space urgently; a full dirsrv/log volume corrupts FreeIPA."
        elif (( used >= warn )); then
            record_result disk WARNING "${p} is ${used}% full (warn ≥ ${warn}%). Plan cleanup."
        else
            record_result disk OK "${p} is ${used}% full."
        fi
    done
}

# --- ipa-healthcheck --------------------------------------------------------
check_healthcheck() {
    [[ "${RUN_HEALTHCHECK:-true}" == true ]] || { log INFO "[healthcheck] disabled in config."; return; }
    have_cmd ipa-healthcheck || {
        log INFO "[healthcheck] ipa-healthcheck not installed; skipping."
        record_result healthcheck OK "ipa-healthcheck not installed (skipped)."
        return
    }
    local out rc
    out="$(ipa-healthcheck --output-type json 2>>"$LOG_FILE")"; rc=$?
    # ipa-healthcheck exits non-zero when any check is not SUCCESS.
    if [[ -z "$out" ]]; then
        record_result healthcheck WARNING "ipa-healthcheck produced no output (rc=$rc)."
        return
    fi
    local errors warnings
    if have_cmd jq; then
        errors="$(jq '[.[] | select(.result=="ERROR" or .result=="CRITICAL")] | length' <<<"$out" 2>/dev/null || echo "?")"
        warnings="$(jq '[.[] | select(.result=="WARNING")] | length' <<<"$out" 2>/dev/null || echo "?")"
    else
        errors="$(grep -o '"result": *"ERROR"' <<<"$out" | wc -l)"
        errors=$(( errors + $(grep -o '"result": *"CRITICAL"' <<<"$out" | wc -l) ))
        warnings="$(grep -o '"result": *"WARNING"' <<<"$out" | wc -l)"
    fi
    if [[ "$errors" != "?" ]] && (( errors > 0 )); then
        record_result healthcheck CRITICAL "ipa-healthcheck reported ${errors} error(s), ${warnings} warning(s). Run 'ipa-healthcheck --failures-only' for details."
    elif [[ "$warnings" != "?" ]] && (( warnings > 0 )); then
        record_result healthcheck WARNING "ipa-healthcheck reported ${warnings} warning(s). Run 'ipa-healthcheck --failures-only' for details."
    else
        record_result healthcheck OK "ipa-healthcheck reported no failures."
    fi
}
