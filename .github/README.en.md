<!-- Translated by AI -->
[中文](/README.md) | English | [Changelog](../CHANGELOG.md)

# Xray Management Script :sparkles:

* A pure Shell-based Xray management script
* Optional configurations:
  * mKCP (VLESS-mKCP-seed)
  * Vision (VLESS-Vision-REALITY)
  * XHTTP (VLESS-XHTTP-REALITY)
  * Trojan (Trojan-XHTTP-REALITY)
  * Fallback (includes VLESS-Vision-REALITY and VLESS-XHTTP-REALITY)
  * SNI (includes Vision_REALITY, XHTTP_REALITY, XHTTP_TLS)
* SNI configuration uses Nginx to implement SNI traffic splitting, suitable for CDN routing, upstream/downstream separation, and multi-site coexistence
* SNI share links support upstream/downstream separation (upstream xhttp+TLS+CDN | downstream xhttp+Reality, upstream xhttp+Reality | downstream xhttp+TLS+CDN)
* SNI configuration supports managing custom domains and reverse proxy apps, with independent certificates, site configs, stream mappings, and UDS per site
* Rule configuration and custom input:
  * Block BitTorrent traffic (optional)
  * Block China-bound IP traffic (optional)
  * Ad blocking (optional)
  * Add custom WARP Proxy routing rules
  * Add custom blocking routing rules
* Toggle Cloudflare WARP Proxy ( :whale: Docker deployment)
* Toggle geodata auto-update
* Xray port defaults and custom input:
  * VLESS-mKCP: randomly generated
  * ALL-REALITY: 443
* UUID defaults and custom input:
  * Randomly generated
  * Custom standard UUID input
  * Non-standard UUID mapped to UUID
* kcp(seed) and trojan(password) defaults and custom input:
  * Randomly generated (example: cw-GEMDYgwIV3_g#)
  * Custom input
* target defaults and custom input:
  * Randomly selected from serverNames.json
  * TLSv1.3 and H2 validation for custom target
  * Automatic serverNames lookup for custom target
* shortId defaults and custom input:
  * Random generation (default two shortIds, e.g. 01234567, 0123456789abcdef)
  * Custom shortId input
  * If input is 0 to 8, shortIds with length 0-16 are auto-generated
  * Supports multiple values separated by commas
* path defaults and custom input:
  * Randomly generated (example: /8ugSUeNJ.9OEnTErb.dVZMUAFu)
  * Custom input (example: /8ugSUeNJ, with or without `/`)

## FAQ

1. If installation succeeds but service is unusable, check whether the server ports are open. You can verify using `https://tcp.ping.pe/ip:port`.
2. Before using SNI configuration, ensure VPS HTTP (80) and HTTPS (443) ports are open.
3. Before using SNI configuration, do not enable CDN protection, otherwise SSL issuance may fail.
4. For upstream/downstream separation details, see [XHTTP: Beyond REALITY][XHTTP] and [xhttp 五合一配置][xhttp 五合一配置].
5. If you encounter 【Could not get nonce, let's try again】 while issuing certificates with SNI, check the [ZeroSSL status page](https://status.zerossl.com/). Most likely ZeroSSL 【Free ACME Service】 is in 【Service disruption】 or 【Service outage】.

## Changelog

1. v2025.11.19 resolves the issue where WARP was enabled without log limits, causing container logs to keep growing and eventually fill up disk space.
   1. Users who already enabled WARP routing can select 【Reset WARP Proxy】 in 【Manage Configuration】 -> 【Routing Management】 to clear container logs and reset WARP Proxy.
   2. Log limits have been added; just enable WARP directly when needed.
2. v2026.03.01 adds CA vendor switching. When switching CA vendor, the script force re-issues certificates for existing domains (`domain`, `cdn`, and `custom_sites[].domain`). It writes the new CA only after all re-issues succeed; if any step fails, it automatically rolls back to the original CA and restores related settings, preventing acme auto-renew from breaking.
   1. Force re-issue bypasses the "Domains not changed" check (acme.sh skip scenario).
   2. Watch out for CA issuance rate limits (for example, Let's Encrypt limits).
3. v2026.03.17 adds SNI custom domain and reverse proxy app management, allowing multiple extra HTTPS reverse proxy sites without affecting the existing `Reality(domain)` and `CDN(cdn)` sites.
   1. Menu path: `Manage Configuration -> SNI Configuration -> Manage custom domains and reverse proxy apps`
   2. Supports list / add / edit / delete, with an independent certificate, `sites-available/<domain>.conf`, stream mapping, and UDS for each custom site.
   3. `stream.conf` is rebuilt from `domain`, `cdn`, and `custom_sites`; UDS names use the first `12` hex chars of `SHA-256(domain)` plus the port.
   4. Proxy targets support port-only input or full `http(s)://host:port` URLs; port-only input is normalized to `http://127.0.0.1:<port>`; URLs containing `path`, `query`, or `fragment` are rejected.
   5. Editing only the upstream target skips certificate re-issuance; changing the domain issues the new certificate first and then switches over with rollback on failure; deleting a site also removes the site config, symlink, renew record, and certificate directory.
   6. A custom site domain must not duplicate `domain`, `cdn`, or another custom site domain; CA switching and "force renew all certificates" also cover custom site domains.
   7. Custom sites are "pure reverse proxy sites". They do not include Xray `xhttp/grpc` paths and are not managed by the script; the proxy layer does not inject an extra `Content-Security-Policy`, so CSP should be controlled by the upstream application.
4. v2026-09-16 improves uninstall and certificate management.
   1. The main menu adds an "Uninstall" entry for removing Nginx and the whole deployment; uninstall is now more thorough (cleans cron jobs, rolls back nginx, removes upstream).
   2. Adds "Remove single-domain certificate" to remove only the specified domain's certificate without affecting other sites or renewal tasks.
   3. Project renamed from zxcvos/Xray-script to crudguy/xray-script-personal-use-only; download URL and script filename updated accordingly.
5. v2026-09-16.1 fixes a quick-install abort and the copyright info in the startup banner.
   1. Fixes an `unbound variable` abort in Quick Install (`--vision` / `--xhttp` / `--fallback`), caused by reading an empty config.
   2. Fixes leftover old copyright info (author and repository URL) in the startup banner.
6. v2026-09-16.2 switches auto-update to commit comparison; the version number no longer needs manual maintenance.
   1. The update criterion changed from the version number to the latest commit of `main`: any upstream commit is detected, so a release no longer requires editing `version` in `config.json`.
   2. The `Version` shown in the UI is synced automatically from the installed code.
   3. Adds `--force-update`: refresh the script to the latest upstream commit without comparison or prompting; the installed commit is recorded at `${HOME}/.xray-script-personal-use-only/commit`.


7. Adds config export/import (`--export-config` / `--import-config`, menu path: `Manage Configuration -> 9`).
   1. The archive is `600` and contains only `manifest.json` and `payload/`.
   2. Import does not trust paths inside the archive: destinations come from a fixed member table, unknown entries are skipped with a warning.
   3. A rollback point is created before import, and a failure rolls back automatically.
8. Adds kernel network tuning and BBR support (menu path: `Manage Configuration -> 8`, or `--bbr` / `--net-status` / `--net-tune` / `--nofile-limit`).
   1. BBR is enabled idempotently: `modprobe` + `modules-load.d` + `sysctl.d` land together (writing only `sysctl` has no effect when the module is not loaded).
   2. BBR support is decided by whether `modprobe tcp_bbr` succeeds, not by guessing from the kernel version.
   3. A read-only `--net-status` is provided for monitoring jobs that watch whether BBR is still active.
9. Adds a one-shot full health check (menu -> 10, or `--health`).
   1. Eight sections: system resources / required commands / Xray service / Nginx service / port ownership / TLS certificates / kernel network / script config and logs.
   2. Entirely read-only, and deliberately performs no outbound probing — so that a health check never turns into an operation of unpredictable duration.
   3. `core/check.sh --health` exits `0` (no failures) or `1` (failures), which makes it usable for alerting.
10. Adds subscription generation (menu -> 11, or `--subscription`).
   1. Three formats are written to `~/.xray-script-personal-use-only/` (mode `0600`): `subscription-base64.txt` / `subscription-clash.yaml` / `subscription-singbox.json`.
   2. Every client inbound of the current mode is traversed; mKCP cannot be expressed in sing-box, so those nodes are skipped for that format and the count is reported.
   3. Subscription files are local artifacts: no URL is exposed and no extra listening port is opened.
11. Fixes subscription aggregation, plus script slimming and a stronger CI gate.
   1. Fixes Fallback / SNI subscriptions collecting only part of the nodes; they now yield 2 and 5 nodes respectively.
   2. Traffic statistics no longer depends on `numfmt` / `column` (neither is in the dependency list, so minimal systems failed outright); it is now pure `awk`.
   3. Non-interactive options such as `--health` / `--export-config` now really reach the core scripts through the entry point (previously they were silently dropped and fell back to the interactive menu).
   4. All ShellCheck legacy exceptions and ratchet baselines are cleared, and a `test/` behaviour-test step was added (subscription aggregation, traffic statistics formatting, subscription rebuild after config changes).
   5. Subscriptions are rebuilt automatically after a config change: changing the domain / port / inbounds no longer requires regenerating them by hand. (That rebuild is still conditional on the files already existing — but a fresh install now generates them, see item 12.) A failed rebuild only warns — it never breaks a config change that already succeeded.
   6. The full health check gained a "subscription freshness" item in section 8: a subscription older than the config change is reported as `[WARN]`.
12. Subscriptions are generated automatically after installation.
   1. Quick install (`--vision` / `--xhttp` / `--fallback`, and menu "Full installation") plus the custom Xray-config and SNI install flows now write `subscription-base64.txt` / `subscription-clash.yaml` / `subscription-singbox.json` as soon as the install succeeds, and print their paths; the screen still shows the raw link and QR code for v2rayN-family clients.
   2. Previously the install flow only ran `--share`, and the rebuild-on-config-change mechanism required the files to already exist — so a first-time install never produced them, and Clash / sing-box users had nothing to import until they happened to find menu item 11.
   3. Generation is best-effort: a failure only warns and never rolls back or breaks an install that already succeeded.

## Share Link Format

Implemented based on [VMessAEAD / VLESS share link proposal](https://github.com/XTLS/Xray-core/discussions/716) and [v2rayN](https://github.com/2dust/v2rayN). If other clients do not work, adjust based on the generated share link manually.

In SNI configuration, CDN share links use H2 as default ALPN. If you need H3, modify it in your client.

## Subscription

Menu item **11 → Generate subscription** — and **automatic generation right after a successful install** — aggregates every client inbound of the current mode into three subscription files, written atomically to `~/.xray-script-personal-use-only/` on the server (mode `0600`; no plaintext and no QR code is ever printed):

| File | Format | Clients |
| --- | --- | --- |
| `subscription-base64.txt` | base64 of the share links (single line) | v2rayN / NekoBox / FoXray and other generic subscriptions |
| `subscription-clash.yaml` | Clash / mihomo | Clash Verge / ClashX Meta etc. (includes proxy-groups and direct rules) |
| `subscription-singbox.json` | sing-box outbounds | sing-box / SFA / SFM etc. |

All three traverse **every client inbound** of that mode (Fallback = 2, SNI = 5, other modes as many as the config has) — never just a single node. mKCP transport cannot be expressed in sing-box, so those nodes are skipped for that format and the skip count is reported. Subscription files are local artifacts: no URL is exposed and no extra listening port is opened.

A subscription has the domain / port / UUID / SNI baked into it, so **any config change silently invalidates the old one** (clients keep dialling with the stale parameters). The script therefore rebuilds subscriptions at every config-write checkpoint, and **also generates them once right after a successful install** — so a fresh deployment hands you all three files without an extra step, and later config changes keep them in sync. Generation is best-effort: a failure only warns, never breaking an install or config change that already succeeded.

For the difference between the on-screen share link and these files, how to copy them off the server, and client-by-client import steps, see [Share Links, Subscription Files & Clients](#share-links-subscription-files--clients).

To check whether the subscription in hand is stale, run **menu → 10 Full health check**: section 8 compares the subscription's mtime against the config's and reports `[WARN]` when it lags behind; with no subscription generated it shows `[SKIP]` and does not count towards failures.

## How to Use

After installation the script auto-opens the management menu; **re-running the same file when already installed re-enters the menu without re-downloading or reinstalling**. Copy the command for your scenario:

### Install (first deployment)

Downloads the installer and runs it, completing dependency install, project deployment, and opening the management menu:

```sh
wget --no-check-certificate -O ${HOME}/xray-script-personal-use-only.sh https://raw.githubusercontent.com/crudguy/xray-script-personal-use-only/main/install.sh
```

### Start / Launch UI (already installed)

Re-open the management menu for configuration, start/stop and maintenance (no re-download, no reinstall):

```sh
bash ${HOME}/xray-script-personal-use-only.sh
```

### Install and start (one-liner)

Download, deploy and open the menu in a single command:

```sh
wget --no-check-certificate -O ${HOME}/xray-script-personal-use-only.sh https://raw.githubusercontent.com/crudguy/xray-script-personal-use-only/main/install.sh && bash ${HOME}/xray-script-personal-use-only.sh
```

### Quick install (skip the menu)

```sh
bash ${HOME}/xray-script-personal-use-only.sh --vision       # VLESS + Vision + REALITY
bash ${HOME}/xray-script-personal-use-only.sh --xhttp        # VLESS + XHTTP + REALITY
bash ${HOME}/xray-script-personal-use-only.sh --fallback     # Fallback (dual-protocol)
bash ${HOME}/xray-script-personal-use-only.sh --force-update # refresh to latest commit
```

### Ports & coexistence

- **Default (VLESS + Vision + REALITY, direct)**: Xray listens on `0.0.0.0:443` (exclusive TCP). No certificate is required (REALITY borrows the TLS fingerprint of a real site). In this mode 443 is owned by Xray — **do not deploy other services that bind TCP 443 on the same host** (e.g. an Nginx site, Caddy, Apache).
- **SNI mode**: Nginx listens on 443 and splits traffic by SNI at L4 (`ssl_preread`); Xray runs over a Unix socket, so "Xray proxy + a real website" can share 443 without conflict. Note REALITY traffic must still complete TLS inside Xray — **do not** reverse-proxy it at Nginx L7.
- `80` (HTTP) and bare `UDP 443` (HTTP/3 QUIC) do not conflict with Xray's TCP 443 and may be used separately.

## Command-line Options

All options are passed to the **same entry file** — the `install.sh` copy downloaded on first run, normally at `${HOME}/xray-script-personal-use-only.sh`. Use this one file whether you are installing for the first time or managing an existing install:

```sh
bash ${HOME}/xray-script-personal-use-only.sh <option>
```

- First run: downloads the project → installs → then runs the option.
- Later runs: skips the download and re-install, runs the option directly.

Options fall into two groups:

**A. Installer-only** (handled by install.sh itself, never enters the menu)

| Option | Effect |
| --- | --- |
| `--lang=zh` / `--lang=en` | Set the UI language |
| `--check-deps` | Force a dependency re-check and reinstall |
| `--force-update` | Skip the comparison and refresh to the latest upstream commit |
| `-d <dir>` | Install into a custom directory |
| `--help` / `-h` | Show help |

**B. Unattended / scriptable** (forwarded to the core module; safe for cron and scripts)

| Option | Effect | Notes |
| --- | --- | --- |
| `--vision` / `--xhttp` / `--fallback` | Quick-install the given mode | First install; drops into the menu afterwards |
| `--health` | Full health check | Exit code `0` = no failures, `1` = failures, `2` = bad usage; usable for cron alerts |
| `--net-status` | Read-only view of kernel network and BBR state | Good for monitoring jobs |
| `--bbr` | Enable/repair BBR congestion control | Idempotent, safe to re-run |
| `--net-tune` | Kernel network tuning for high concurrency | Changes kernel parameters; asks for confirmation |
| `--nofile-limit` | Raise the process file-descriptor limit | Changes kernel parameters; asks for confirmation |
| `--export-config [--with-docker] [--yes]` | Export config and certificates to an archive | Container data is included only with `--with-docker` |
| `--import-config <archive> [--yes]` | Restore config and certificates from an archive | A rollback point is created before writing |
| `--subscription` | Generate base64 / Clash / sing-box subscriptions | Written to `~/.xray-script-personal-use-only/` |
| `--start` / `--stop` / `--restart` | Start / stop / restart the Xray service | Idempotent, with an active-state recheck |
| `--share [--save] [--no-qr]` | Show share links | Can save to a file / skip the QR code |

Examples:

```sh
# First install or re-install Vision (REALITY), fully unattended
bash ${HOME}/xray-script-personal-use-only.sh --vision

# Read-only health check on an existing install (good for cron)
bash ${HOME}/xray-script-personal-use-only.sh --health

# Force the script itself to the latest commit
bash ${HOME}/xray-script-personal-use-only.sh --force-update

# Export before migrating (including container data), then restore on the new host
bash ${HOME}/xray-script-personal-use-only.sh --export-config --with-docker --yes
bash ${HOME}/xray-script-personal-use-only.sh --import-config /root/xray-backup.tar.gz --yes
```

> **Note**: A few actions such as changing the port (`change-port`) and switching the CA (`ca-server`) remain **interactive menu items** and do not yet have a public unattended flag. All other frequent operations — health check / start / stop / restart / share / subscription / export / import — already support unattended invocation.

## Share Links, Subscription Files & Clients

After installation you get two kinds of output at once: **share links printed on screen** (scan or copy them directly) and **three subscription files on the server** (covering every node).

### 1. On screen: share links

Printed when the install finishes, and reproducible anytime via the menu "Share links & QR codes" or `--share`.

| Output | Description |
| --- | --- |
| `vless://…` / `trojan://…` link | Carries UUID, address, port, Reality public key, SNI, flow and everything else; the trailing `#tag` is the node name |
| Terminal QR code | ANSI QR of that same link — scannable directly from a phone (needs `qrencode` on the server; if missing it only warns, never aborts) |
| How many links | 1 for normal modes; **2 for Fallback** (Vision + XHTTP); **5 for SNI** (incl. upstream/downstream split and CDN) |

Two extra flags for `--share`:

- `--share --save`: writes the link and client config to `~/.xray-script-personal-use-only/share-link.txt` with mode `0600`, and **prints no plaintext or QR on screen** (use it when you want to keep a copy without spraying secrets across the terminal).
- `--share --no-qr`: prints the link only, no QR code (good for logs / cron).

> Screen output **contains secrets** — the script warns before the first link is printed. Be careful with screen recording, screen sharing and terminal scrollback.

### 2. On the server: three subscription files

**Generated automatically right after installation** into `~/.xray-script-personal-use-only/` with mode `0600` (they contain UUID / password / public key — keep them safe and do not leak them). Rebuilt automatically on config changes, and refreshable anytime via menu item 11 or `--subscription`.

| File | Format | Description |
| --- | --- | --- |
| `subscription-base64.txt` | v2rayN-style base64 (single line) | Every node + XHTTP extra |
| `subscription-clash.yaml` | Clash / mihomo YAML | Includes proxy-groups and direct rules |
| `subscription-singbox.json` | sing-box outbound JSON | Works across all sing-box platforms |

Difference from the screen links: the subscription files walk **every client inbound** of the current mode (custom / multi-inbound configs are never truncated), whereas the screen link prints only the first inbound in normal modes.

**How to get the files onto your device** (the script exposes no subscription URL and opens no extra port — the files live on the server only):

- **Copy and paste** (easiest; base64 is a single line):
  `cat ~/.xray-script-personal-use-only/subscription-base64.txt`
- **Download to your computer**:
  `scp root@<server-ip>:~/.xray-script-personal-use-only/subscription-clash.yaml ./`
  (on Windows use WinSCP / FinalShell / Xshell's built-in sftp)
- **Onto a phone**: send the contents of `subscription-base64.txt` or `subscription-singbox.json` to yourself over a channel you trust, then use the client's "Import from file".

### 3. How to use each client

| System | Recommended client | Use this | How to import |
| --- | --- | --- | --- |
| Windows | **v2rayN** | Screen link or `base64` | Copy the `vless://` link → "Servers → Import from clipboard"; or add the base64 content under "Subscription group settings" |
| Windows / macOS | **Clash Verge Rev** | `subscription-clash.yaml` | "Profiles" → import / new → pick the local YAML file (or paste its content) |
| Win / mac / Linux | **NekoBox / Nekoray** | `base64` or `clash.yaml` | Pick by active core: v2ray core → base64 link, Clash core → YAML |
| Android | **v2rayNG** | Screen QR or `base64` | Scan the QR; or "Subscription → add subscription" with the base64 content / import from file |
| Android | **Clash for Android / sing-box** | `clash.yaml` / `singbox.json` | "Profiles → import from file" |
| iOS | **FoXray** | Screen link or `base64` | "Import from clipboard", or import from QR / file |
| iOS | **Shadowrocket / Stash** | Screen link or `clash.yaml` | Paste the link; Stash can import the YAML directly |
| All platforms | **sing-box** (SFA / SFM / desktop) | `subscription-singbox.json` | Import the JSON config (SFA supports QR or file import) |

### 4. Usage notes and known limits

- **XHTTP mode: disable global mux.cool on the client** (both v2rayN and v2rayNG have this switch), otherwise it cannot connect to the newer Xray server.
- **sing-box has no mKCP**: with an mKCP config the sing-box subscription skips those nodes automatically (the rest work; the skip count is reported at generation time).
- **Clash / sing-box carry the primary connection only**: XHTTP downlink acceleration (extra) is Xray-specific and is preserved only in the base64 link; it does not take effect under Clash / sing-box.
- **Subscriptions are rebuilt automatically on config changes.** If you suspect the copy in hand is stale, run menu → 10 "Full health check": section 8 compares the subscription's mtime against the config's and reports `[WARN]` when it lags behind.
- **Generated automatically after installation**: a first install writes all three files and prints their paths, so no manual step is needed; afterwards they are rebuilt automatically on config changes, and you can regenerate them anytime via `--subscription` or the menu item.

## Script UI

```sh
 __   __  _    _   _______   _______   _____  
 \ \ / / | |  | | |__   __| |__   __| |  __ \ 
  \ V /  | |__| |    | |       | |    | |__) |
   > <   |  __  |    | |       | |    |  ___/ 
  / . \  | |  | |    | |       | |    | |     
 /_/ \_\ |_|  |_|    |_|       |_|    |_|     

Copyright (C) crudguy | https://github.com/crudguy/xray-script-personal-use-only

-------------------------------------------
Xray       : v26.3.27
CONFIG     : VLESS-Vision-REALITY
WARP Proxy : Running
-------------------------------------------

--------------- xray-script-personal-use-only ---------------
 Version      : v2026-09-18
 Description  : Xray Management Script
----------------- Install -----------------
1. Full installation
2. Install/Update only
3. Uninstall
----------------- Operation ----------------
4. Start
5. Stop
6. Restart
---------------- Configuration -------------
7. Share links and QR codes
8. Statistics
9. Manage configuration
----------------- Diagnostics ----------------
10. Full health check
------------------ Subscription ----------------
11. Generate subscription (base64/Clash/sing-box)
-------------------------------------------
0. Exit
```

## Tested Systems

| Platform | Version    |
| -------- | ---------- |
| Debian   | 10, 11, 12 |
| Ubuntu   | 20, 22, 24 |
| CentOS   | 7, 8, 9    |
| Rocky    | 8, 9       |

The distributions above were tested on Vultr.

Other Debian-based and Red Hat-based systems may work, but are untested and may have issues.

## Installation Time Notes

SNI configuration is intended for long-term use after one setup, and is not suitable for repeated reinstall/reset, which consumes significant time. If you need to change configuration or domain, use the options in the management UI.

After switching to a non-SNI config, Nginx will be stopped but kept on the machine. Re-enabling SNI will not reinstall Nginx.

### Installation Time Reference

Installation flow:

Update package index -> install dependencies -> [install Docker] -> [install Cloudflare-warp] -> install Xray -> install Nginx -> issue certificate -> apply configuration

**Average install time on a 1-core 1GB server (for reference only):**

| Item                | Duration  |
| ------------------- | --------- |
| Update package index| 0-10 min  |
| Install dependencies| 0-5 min   |
| Install Docker      | 1-2 min   |
| Install Cloudflare-warp | 3-5 min |
| Install Xray        | < 0.5 min |
| Install Nginx       | 13-15 min |
| Issue certificate   | 1-2 min   |
| Apply configuration | < 0.5 min |

### Why does SNI installation take so long?

Nginx in this script is managed by source compilation.

Compared with installing prebuilt binaries, compilation advantages are:

1. Better runtime performance (compiled with -O3 optimization)
2. Newer software versions

The downside is long compilation time.

## Install Paths

**xray-script-personal-use-only:** `/usr/local/xray-script-personal-use-only`

**Nginx:** `/usr/local/nginx`

**Cloudflare-warp:** `$HOME/.xray-script-personal-use-only/docker/warp`

**Script state:** `$HOME/.xray-script-personal-use-only/{config.json, commit}` (script config and installed commit record)

**Xray:** See **[Xray-install](https://github.com/XTLS/Xray-install)**

## Dependency List

When using SNI configuration, the script may install the following dependencies:

| Purpose                            | Debian-based                         | Red Hat-based        |
| ---------------------------------- | ------------------------------------ | -------------------- |
| yumdb set (mark package manually installed) |                              | yum-utils            |
| dnf config-manager                 |                                      | dnf-plugins-core     |
| IP retrieval                       | iproute2                             | iproute              |
| DNS resolution                     | dnsutils                             | bind-utils           |
| wget                               | wget                                 | wget                 |
| curl                               | curl                                 | curl                 |
| wget/curl https                    | ca-certificates                      | ca-certificates      |
| kill/pkill/ps/sysctl/free          | procps                               | procps-ng            |
| epel repository                    |                                      | epel-release         |
| epel repository                    |                                      | epel-next-release    |
| remi repository                    |                                      | remi-release         |
| Firewall                           | ufw                                  | firewalld            |
| **Build basics:**                  |                                      |                      |
| Download source files              | wget                                 | wget                 |
| Extract tar source files           | tar                                  | tar                  |
| Extract tar.gz source files        | gzip                                 | gzip                 |
| gcc                                | gcc                                  | gcc                  |
| g++                                | g++                                  | gcc-c++              |
| make                               | make                                 | make                 |
| **acme.sh dependencies:**          |                                      |                      |
|                                    | curl                                 | curl                 |
|                                    | openssl                              | openssl              |
|                                    | cron                                 | crontabs             |
| **Build openssl:**                 |                                      |                      |
|                                    | perl-base (included in libperl-dev) | perl-IPC-Cmd         |
|                                    | perl-modules-5.32 (included in libperl-dev) | perl-Getopt-Long |
|                                    | libperl5.32 (included in libperl-dev) | perl-Data-Dumper   |
|                                    |                                      | perl-FindBin         |
| **Build Brotli:**                  |                                      |                      |
|                                    | git                                  | git                  |
|                                    | libbrotli-dev                        | brotli-devel         |
| **Build Nginx:**                   |                                      |                      |
|                                    | libpcre2-dev                         | pcre2-devel          |
|                                    | zlib1g-dev                           | zlib-devel           |
| --with-http_xslt_module            | libxml2-dev                          | libxml2-devel        |
| --with-http_xslt_module            | libxslt1-dev                         | libxslt-devel        |
| --with-http_image_filter_module    | libgd-dev                            | gd-devel             |
| --with-google_perftools_module     | libgoogle-perftools-dev              | gperftools-devel     |
| --with-http_geoip_module           | libgeoip-dev                         | geoip-devel          |
| --with-http_perl_module            |                                      | perl-ExtUtils-Embed  |
|                                    | libperl-dev                          | perl-devel           |

## Acknowledgements

[Xray-core][Xray-core]

[REALITY][REALITY]

[XHTTP: Beyond REALITY][XHTTP]

[integrated-examples][lxhao61/integrated-examples]

[xhttp 五合一配置][xhttp 五合一配置]

[部署 Cloudflare WARP Proxy][haoel]

[cloudflare-warp 镜像][e7h4n]

[V2Ray 路由规则文件加强版][v2ray-rules-dat]

[kirin10000/Xray-script][kirin10000/Xray-script]

**This script is for study and communication only. Do not use it for illegal purposes. Illegal acts on the network are still illegal and will be punished by law.**

[Xray-core]: https://github.com/XTLS/Xray-core (THE NEXT FUTURE)
[REALITY]: https://github.com/XTLS/REALITY (THE NEXT FUTURE)
[XHTTP]: https://github.com/XTLS/Xray-core/discussions/4113 (XHTTP: Beyond REALITY)
[lxhao61/integrated-examples]: https://github.com/lxhao61/integrated-examples (以 V2Ray（v4 版） 或 Xray、Nginx 或 Caddy（v2 版）、Hysteria 等打造常用科学上网的优化配置及最优组合示例，且提供集成特定插件的 Caddy（v2 版） 文件，分享给大家食用及自己备份。)
[xhttp 五合一配置]: https://github.com/XTLS/Xray-core/discussions/4118 (xhttp 五合一配置 \( reality 直连与过 CDN 共存, 附小白可抄的配置\))
[haoel]: https://github.com/haoel/haoel.github.io#943-docker-%E4%BB%A3%E7%90%86 (使用 Docker 快速部署 Cloudflare WARP Proxy)
[e7h4n]: https://github.com/e7h4n/cloudflare-warp (cloudflare-warp 镜像)
[v2ray-rules-dat]: https://github.com/Loyalsoldier/v2ray-rules-dat (V2Ray 路由规则文件加强版)
[kirin10000/Xray-script]: https://github.com/kirin10000/Xray-script (kirin10000/Xray-script)
