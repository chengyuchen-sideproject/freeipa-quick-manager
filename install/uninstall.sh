#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — remove FreeIPA Quick Manager (systemd timer and/or cron).
#
# Removes program files and schedules. By default it KEEPS config and logs;
# pass --purge to remove those too. Must be run as root.
# =============================================================================
set -euo pipefail

INSTALL_DIR="/opt/freeipa-quick-manager"
CONFIG_DIR="/etc/freeipa-quick-manager"
LOG_DIR="/var/log/freeipa-quick-manager"
CRON_FILE="/etc/cron.d/freeipa-quick-manager"
SYSTEMD_DIR="/etc/systemd/system"

PURGE=false
[[ "${1:-}" == "--purge" ]] && PURGE=true

die() { echo "ERROR: $*" >&2; exit 1; }
[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "This uninstaller must be run as root."

# --- systemd ----------------------------------------------------------------
if command -v systemctl >/dev/null; then
    systemctl disable --now freeipa-check.timer 2>/dev/null || true
    rm -f "$SYSTEMD_DIR/freeipa-check.timer" "$SYSTEMD_DIR/freeipa-check.service"
    systemctl daemon-reload 2>/dev/null || true
    echo ">> Removed systemd timer/service."
fi

# --- cron -------------------------------------------------------------------
if [[ -f "$CRON_FILE" ]]; then
    rm -f "$CRON_FILE"
    echo ">> Removed cron drop-in."
fi

# --- program files ----------------------------------------------------------
rm -rf "$INSTALL_DIR"
echo ">> Removed $INSTALL_DIR."

# --- config & logs ----------------------------------------------------------
if [[ "$PURGE" == true ]]; then
    rm -rf "$CONFIG_DIR" "$LOG_DIR"
    echo ">> Purged config and logs."
else
    echo ">> Kept config ($CONFIG_DIR) and logs ($LOG_DIR). Use --purge to remove."
fi

echo ">> Uninstall complete."
