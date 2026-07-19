# FreeIPA 快速管理工具（FreeIPA Quick Manager）

[English](README.md) | **繁體中文**

一套針對 FreeIPA 伺服器的**唯讀**健康檢查與憑證到期檢查工具，具備結構化日誌、
針對任何變更動作的還原紀錄（rollback journal），以及可插拔的告警管道
（log／email／webhook）。可互動執行，也可透過 systemd timer 或 cron 無人值守定期執行。

> ⚠️ 本工具需在 **FreeIPA 伺服器本機**上執行（RHEL／Rocky／AlmaLinux／CentOS／
> Fedora）。純 Bash 撰寫，除了 FreeIPA 主機上本來就有的指令外，無其他相依套件。

## 功能特色

- **服務健康檢查** — `ipactl`、`ipa.service`、LDAP（389-ds）、Kerberos KDC、
  整合式 DNS、Web UI／httpd、複寫（replication）拓撲、磁碟空間，以及
  `ipa-healthcheck`（若已安裝）。
- **憑證到期檢查** — 檢查所有 certmonger 追蹤的憑證（以及你額外指定的 PEM 檔），
  在到期前示警，並針對每一項問題印出**具體的建議處理做法**。
- **所有動作皆記錄 log** — 每次執行都會在 `/var/log/freeipa-quick-manager/`
  寫入帶時間戳記的日誌，並維護 `latest.log` 捷徑。
- **還原紀錄（rollback journal）** — 本工具預設為唯讀、不會變更任何狀態；但框架
  會為任何未來的變更動作產生一份可執行的「如何還原」腳本，滿足稽核與可回復需求。
- **無人值守執行** — 可安裝 systemd timer **或** cron 排程。
- **告警管道** — log ＋ 終端輸出永遠開啟；email 與 webhook（Slack／Teams／自訂）
  可在設定檔中啟用。webhook 的 payload 採樣板化設計，日後要接哪個推送工具，
  只需填 URL 與樣板、無需改程式碼。

## 快速開始

```bash
# 在 FreeIPA 伺服器上的專案目錄中：
sudo ./install/install-systemd.sh      # systemd timer（每天 07:00）
#   ...或...
sudo ./install/install-cron.sh         # cron（每天 07:00）

# 隨時手動執行：
sudo /opt/freeipa-quick-manager/bin/freeipa-check
```

只跑單一檢查，或輸出 JSON：

```bash
freeipa-check --check certs            # 只跑憑證檢查
freeipa-check --check ipactl,ldap,disk
freeipa-check --json                   # 機器可讀的摘要
freeipa-check --list-checks            # 列出所有檢查名稱
```

離開代碼：`0` = 正常，`1` = 警告，`2` = 嚴重，`3` = 錯誤（無法執行）。

## 設定

複製範例檔並編輯（安裝腳本會自動幫你放到 `/etc/freeipa-quick-manager/`）：

```bash
cp config/freeipa-check.conf.example config/freeipa-check.conf
```

主要設定項：

| 設定 | 說明 |
| --- | --- |
| `CERT_WARN_DAYS` / `CERT_CRIT_DAYS` | 憑證到期警告／嚴重門檻（天數）。 |
| `EXTRA_CERT_FILES` | 除 certmonger 外，額外要檢查的 PEM 憑證檔。 |
| `DISK_WARN_PERCENT` / `DISK_CRIT_PERCENT` | 磁碟使用率門檻。 |
| `ENABLED_CHECKS` | `all`，或指定要跑的檢查名稱子集。 |
| `NOTIFY_EMAIL_*` | 透過 `mailx`／`mail` 寄送 email 告警。 |
| `NOTIFY_WEBHOOK_*` | Webhook 告警（URL ＋ 樣板化 payload）。 |

設定檔搜尋順序（後者覆蓋前者）：
`/etc/freeipa-quick-manager/freeipa-check.conf` →
`<專案>/config/freeipa-check.conf` → `--config FILE`。

## 日誌與還原

- **執行日誌：** `/var/log/freeipa-quick-manager/freeipa-check-<時間戳>.log`
  （另有 `latest.log`）。若以非 root 使用者在專案目錄中執行，日誌改寫入
  `<專案>/logs/`。
- **還原紀錄：** `<日誌目錄>/rollback/rollback-<時間戳>.sh` — 一份可執行腳本，
  列出該次執行所做任何變更動作的還原方式。唯讀執行會產生一份空的（僅說明用）紀錄。

## 排程

- **systemd：** 編輯 `/etc/systemd/system/freeipa-check.timer` 中的
  `OnCalendar=`，然後執行
  `systemctl daemon-reload && systemctl restart freeipa-check.timer`。
  以 `systemctl list-timers freeipa-check.timer` 與
  `journalctl -u freeipa-check` 檢視。
- **cron：** 編輯 `/etc/cron.d/freeipa-quick-manager`（或在執行
  `install-cron.sh` 前設定 `CRON_SCHEDULE="0 */6 * * *"`）。

## 移除

```bash
sudo ./install/uninstall.sh            # 保留設定與日誌
sudo ./install/uninstall.sh --purge    # 全部移除
```

## 檢查項目對照表

| 檢查 | 驗證內容 |
| --- | --- |
| `ipactl` | 所有 FreeIPA 服務皆為 RUNNING。 |
| `systemd` | `ipa.service` 為 active。 |
| `ldap` | 389-ds 可回應匿名 rootDSE 查詢。 |
| `kerberos` | KDC 為 active 且主機 keytab 存在。 |
| `dns` | 整合式 DNS（`named`）為 active 且可解析（若已安裝）。 |
| `webui` | `https://localhost/ipa/ui/` 有回應。 |
| `replication` | 可列出複寫拓撲。 |
| `certs` | certmonger ＋ 額外憑證，比對到期門檻。 |
| `disk` | FreeIPA 關鍵磁碟區的可用空間。 |
| `healthcheck` | 併入 `ipa-healthcheck` 結果（若已安裝）。 |

## 開發備註

- 所有程式碼與註解皆使用英文；文件為雙語（English ＋ 繁體中文）。
- 透過 `.gitattributes` 強制 shell 腳本使用 LF 換行，即使在 Windows 上編輯，
  也能在 Linux 正常執行。
- 本機可用 [ShellCheck](https://www.shellcheck.net/) 靜態檢查：
  `shellcheck bin/freeipa-check lib/*.sh install/*.sh`。

## 授權

[MIT](LICENSE)
