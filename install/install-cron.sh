#!/usr/bin/env bash
# =============================================================================
# install-cron.sh — install FreeIPA Quick Manager and a cron job.
#
# Use this on systems without systemd (or where cron is preferred). Installs a
# drop-in under /etc/cron.d that runs the check daily at 07:00.
# Re-runnable (idempotent). Must be run as root on the FreeIPA server.
# =============================================================================
set -euo pipefail

INSTALL_DIR="/opt/freeipa-quick-manager"
CONFIG_DIR="/etc/freeipa-quick-manager"
LOG_DIR="/var/log/freeipa-quick-manager"
CRON_FILE="/etc/cron.d/freeipa-quick-manager"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 7 * * *}"   # override via env, e.g. "0 */6 * * *"

SRC_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "This installer must be run as root."

echo ">> Installing from: $SRC_DIR"
echo ">> Target dir:      $INSTALL_DIR"

# --- Copy program files -----------------------------------------------------
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"
cp -a "$SRC_DIR/bin" "$SRC_DIR/lib" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/bin/freeipa-check"

# --- Install config (never overwrite an existing one) -----------------------
if [[ -f "$CONFIG_DIR/freeipa-check.conf" ]]; then
    echo ">> Keeping existing config: $CONFIG_DIR/freeipa-check.conf"
else
    cp -a "$SRC_DIR/config/freeipa-check.conf.example" "$CONFIG_DIR/freeipa-check.conf"
    echo ">> Installed default config: $CONFIG_DIR/freeipa-check.conf"
fi
cp -a "$SRC_DIR/config/freeipa-check.conf.example" "$CONFIG_DIR/freeipa-check.conf.example"
grep -q '^LOG_DIR=' "$CONFIG_DIR/freeipa-check.conf" 2>/dev/null || \
    echo "LOG_DIR=\"$LOG_DIR\"" >> "$CONFIG_DIR/freeipa-check.conf"

# --- Install cron drop-in ---------------------------------------------------
cat > "$CRON_FILE" <<EOF
# FreeIPA Quick Manager — scheduled health check (installed $(date '+%Y-%m-%d')).
# Runs as root; output goes to the tool's own log files. Cron mail is suppressed
# because notifications are handled inside the tool (see freeipa-check.conf).
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${CRON_SCHEDULE} root ${INSTALL_DIR}/bin/freeipa-check --quiet >/dev/null 2>&1
EOF
chmod 0644 "$CRON_FILE"

echo ""
echo ">> Installation complete."
echo "   Config:   $CONFIG_DIR/freeipa-check.conf"
echo "   Logs:     $LOG_DIR"
echo "   Cron:     $CRON_FILE  (schedule: ${CRON_SCHEDULE})"
echo "   Run now:  $INSTALL_DIR/bin/freeipa-check"
