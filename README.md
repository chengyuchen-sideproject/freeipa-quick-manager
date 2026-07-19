# FreeIPA Quick Manager

**English** | [繁體中文](README.zh-TW.md)

A read-only health and certificate checker for FreeIPA servers, with structured
logging, a rollback journal for any state-changing action, and pluggable
notifications (log / email / webhook). Runs interactively or unattended via a
systemd timer or cron.

> ⚠️ Runs **on the FreeIPA server itself** (RHEL / Rocky / AlmaLinux / CentOS /
> Fedora). Pure Bash, no runtime dependencies beyond the FreeIPA tooling that is
> already present on such a host.

## Features

- **Service health checks** — `ipactl`, `ipa.service`, LDAP (389-ds), Kerberos
  KDC, integrated DNS, Web UI/httpd, replication topology, disk space, and
  `ipa-healthcheck` (if installed).
- **Certificate expiry** — inspects every certmonger-tracked certificate (plus
  any extra PEM files you list), warns before expiry, and prints **concrete
  recommended remediation** for each finding.
- **Everything is logged** — each run writes a timestamped log to
  `/var/log/freeipa-quick-manager/` with a `latest.log` symlink.
- **Rollback journal** — the tool is read-only by default, so it changes
  nothing; but the framework records a runnable "how to restore" script for any
  future state-changing action, satisfying an audit trail requirement.
- **Unattended operation** — install a systemd timer *or* a cron job.
- **Notifications** — log + terminal always; email and webhook (Slack/Teams/
  custom) are ready to enable in config. The webhook payload is templated, so
  you can point it at any tool later without code changes.

## Quick start

```bash
# From a checkout on the FreeIPA server:
sudo ./install/install-systemd.sh      # systemd timer (daily 07:00)
#   ...or...
sudo ./install/install-cron.sh         # cron (daily 07:00)

# Run manually any time:
sudo /opt/freeipa-quick-manager/bin/freeipa-check
```

Run a single check, or emit JSON:

```bash
freeipa-check --check certs            # only the certificate check
freeipa-check --check ipactl,ldap,disk
freeipa-check --json                   # machine-readable summary
freeipa-check --list-checks            # show all check names
```

Exit codes: `0` = OK, `1` = WARNING, `2` = CRITICAL, `3` = ERROR (could not run).

## Configuration

Copy the example and edit it (the installer does this for you under
`/etc/freeipa-quick-manager/`):

```bash
cp config/freeipa-check.conf.example config/freeipa-check.conf
```

Key settings:

| Setting | Meaning |
| --- | --- |
| `CERT_WARN_DAYS` / `CERT_CRIT_DAYS` | Certificate expiry thresholds (days). |
| `EXTRA_CERT_FILES` | Extra PEM files to inspect beyond certmonger. |
| `DISK_WARN_PERCENT` / `DISK_CRIT_PERCENT` | Disk-usage thresholds. |
| `ENABLED_CHECKS` | `all`, or a subset of check names. |
| `NOTIFY_EMAIL_*` | Email alerts via `mailx`/`mail`. |
| `NOTIFY_WEBHOOK_*` | Webhook alerts (URL + templated payload). |

Config search order (later wins):
`/etc/freeipa-quick-manager/freeipa-check.conf` →
`<repo>/config/freeipa-check.conf` → `--config FILE`.

## Logs and rollback

- **Run logs:** `/var/log/freeipa-quick-manager/freeipa-check-<timestamp>.log`
  (plus `latest.log`). When run as a non-root user from a checkout, logs go to
  `<repo>/logs/` instead.
- **Rollback journals:** `<log dir>/rollback/rollback-<timestamp>.sh` — an
  executable script listing how to undo any state-changing action taken in that
  run. Read-only runs produce an empty (informational) journal.

## Scheduling

- **systemd:** edit `OnCalendar=` in
  `/etc/systemd/system/freeipa-check.timer`, then
  `systemctl daemon-reload && systemctl restart freeipa-check.timer`.
  Inspect with `systemctl list-timers freeipa-check.timer` and
  `journalctl -u freeipa-check`.
- **cron:** edit `/etc/cron.d/freeipa-quick-manager` (or set
  `CRON_SCHEDULE="0 */6 * * *"` before running `install-cron.sh`).

## Uninstall

```bash
sudo ./install/uninstall.sh            # keep config + logs
sudo ./install/uninstall.sh --purge    # remove everything
```

## Checks reference

| Check | What it verifies |
| --- | --- |
| `ipactl` | All FreeIPA services report RUNNING. |
| `systemd` | `ipa.service` is active. |
| `ldap` | 389-ds answers an anonymous rootDSE query. |
| `kerberos` | KDC active and host keytab present. |
| `dns` | Integrated DNS (`named`) active and resolving (if installed). |
| `webui` | `https://localhost/ipa/ui/` responds. |
| `replication` | Replication topology can be listed. |
| `certs` | Certmonger + extra certs, expiry vs. thresholds. |
| `disk` | Free space on FreeIPA-critical volumes. |
| `healthcheck` | Folds in `ipa-healthcheck` results (if installed). |

## Compatibility

| Component | Supported / tested against |
| --- | --- |
| OS | RHEL / Rocky / AlmaLinux 8 & 9, CentOS 7 / 8-Stream, Fedora 38+. |
| FreeIPA (core checks) | **4.4+** — needs `ipactl` and certmonger's `getcert`, present on any modern FreeIPA server. |
| FreeIPA (`healthcheck` check) | **4.8.4+** (RHEL 8.1+), which is when `ipa-healthcheck` was introduced. On older releases this one check is skipped automatically. |
| Shell | Bash **4.2 or newer** (CentOS 7 ships 4.2, RHEL 8 ships 4.4, RHEL 9 ships 5.1). |
| Privileges | Run as **root** for full coverage; non-root runs skip certmonger/ipactl and log a warning. |

> Version note: these are the baselines the tool targets, verified against the
> point when each command became available in FreeIPA — not exhaustively tested
> on every release. Optional commands are always feature-detected and skipped
> when absent, so newer FreeIPA versions work without changes.

Optional tools that are *used if present* and skipped otherwise: `ldapsearch`,
`dig`, `curl`, `jq`, `ipa-healthcheck`, `ipa-replica-manage`, `mailx`/`mail`.
Core FreeIPA commands (`ipactl`, `getcert`) are expected on a FreeIPA server.

## Portability & moving between machines

- **Runs only on the FreeIPA server itself** — it inspects local services,
  sockets and certificate stores. It is not a remote client.
- **No external dependencies** beyond the FreeIPA tooling already on such a
  host; it is pure Bash with no packages to install.
- **Line endings:** shell scripts are pinned to LF via `.gitattributes`, so the
  repo works even when cloned/edited on Windows. If you copy files by some means
  that rewrites them to CRLF, run `sed -i 's/\r$//' bin/freeipa-check lib/*.sh`
  before executing.
- **Relocatable:** the tool resolves its own `lib/` relative to `bin/`, so a
  checkout runs from anywhere. The installers place it under
  `/opt/freeipa-quick-manager` with config in `/etc/freeipa-quick-manager`.
- **After moving to a new host:** re-run the appropriate installer
  (`install-systemd.sh` or `install-cron.sh`) so the schedule and paths are set
  up for that machine; review `/etc/freeipa-quick-manager/freeipa-check.conf`.

## Development notes

- All code and comments are in English; documentation is bilingual
  (English + 繁體中文).
- Shell scripts are forced to LF line endings via `.gitattributes` so they run
  on Linux even when edited on Windows.
- Static-check locally with [ShellCheck](https://www.shellcheck.net/):
  `shellcheck bin/freeipa-check lib/*.sh install/*.sh`.

## License

[MIT](LICENSE)
