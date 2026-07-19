#!/usr/bin/env bash
# =============================================================================
# install-systemd.sh — install FreeIPA Quick Manager and a systemd timer.
#
# Copies the tool to /opt/freeipa-quick-manager, installs config to
# /etc/freeipa-quick-manager, and enables a daily systemd timer.
# Re-runnable (idempotent). Must be run as root on the FreeIPA server.
# =============================================================================
set -euo pipefail

INSTALL_DIR="/opt/freeipa-quick-manager"
CONFIG_DIR="/etc/freeipa-quick-manager"
LOG_DIR="/var/log/freeipa-quick-manager"
SYSTEMD_DIR="/etc/systemd/system"

SRC_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "This installer must be run as root."
command -v systemctl >/dev/null || die "systemctl not found; use install-cron.sh instead."

echo ">> Installing from: $SRC_DIR"
echo ">> Target dir:      $INSTALL_DIR"

# --- Copy program files -----------------------------------------------------
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"
cp -a "$SRC_DIR/bin" "$SRC_DIR/lib" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/bin/freeipa-check"

# --- Install config (never overwrite an existing one) -----------------------
if [[ -f "$CONFIG_DIR/freeipa-check.conf" ]]; then
    echo ">> Keeping existing config: $CONFIG_DIR/freeipa-check.conf"
    cp -a "$SRC_DIR/config/freeipa-check.conf.example" "$CONFIG_DIR/freeipa-check.conf.example"
else
    cp -a "$SRC_DIR/config/freeipa-check.conf.example" "$CONFIG_DIR/freeipa-check.conf"
    cp -a "$SRC_DIR/config/freeipa-check.conf.example" "$CONFIG_DIR/freeipa-check.conf.example"
    echo ">> Installed default config: $CONFIG_DIR/freeipa-check.conf"
fi

# Point the tool at the system log dir by default.
grep -q '^LOG_DIR=' "$CONFIG_DIR/freeipa-check.conf" 2>/dev/null || \
    echo "LOG_DIR=\"$LOG_DIR\"" >> "$CONFIG_DIR/freeipa-check.conf"

# --- Install systemd units --------------------------------------------------
# Rewrite ExecStart to the real install path.
sed "s#/opt/freeipa-quick-manager/bin/freeipa-check#$INSTALL_DIR/bin/freeipa-check#" \
    "$SRC_DIR/systemd/freeipa-check.service" > "$SYSTEMD_DIR/freeipa-check.service"
cp -a "$SRC_DIR/systemd/freeipa-check.timer" "$SYSTEMD_DIR/freeipa-check.timer"

systemctl daemon-reload
systemctl enable --now freeipa-check.timer

echo ""
echo ">> Installation complete."
echo "   Config:   $CONFIG_DIR/freeipa-check.conf"
echo "   Logs:     $LOG_DIR"
echo "   Timer:    systemctl list-timers freeipa-check.timer"
echo "   Run now:  systemctl start freeipa-check.service   (then: journalctl -u freeipa-check)"
echo "   Manual:   $INSTALL_DIR/bin/freeipa-check"
