[中文](/README.md) | English

# Xray Management Script

> A pure Shell-based Xray management script covering the full lifecycle:
> **install → configure → issue certificates → share/subscribe → health-check → backup & migrate**.
>
> - **No** database, web panel, or long-running service — all state lives in config files and systemd units.
> - **Share links and health checks** are produced locally / read-only; no extra listening surface is added.
> - **Personal-use by design**: single-tenant, one set of credentials — not multi-user isolated (see *Bundled components* below).

## Table of Contents

- [Features](#features)
  - [Protocols & Transport](#protocols--transport)
  - [Ports & Coexistence](#ports--coexistence)
  - [Parameter Defaults](#parameter-defaults)
  - [SNI Splitting & Site Management](#sni-splitting--site-management)
  - [Certificate Management](#certificate-management)
  - [Rules & Routing](#rules--routing)
  - [Ops, Diagnostics & Subscription](#ops-diagnostics--subscription)
  - [Interface Language](#interface-language)
  - [Bundled Components](#bundled-components)
- [Install & Launch](#install--launch)
- [Command-line Options](#command-line-options)
- [Share Links, Subscription Files & Clients](#share-links-subscription-files--clients)
- [Install Paths](#install-paths)
- [Dependency List](#dependency-list)
- [FAQ](#faq)
- [Installation Time Notes](#installation-time-notes)
- [Backup & Migration](#backup--migration)

## Features

### Protocols & Transport

At install you can pick "one-click install" (stable Vision + Reality, with bt / China-return / ads blocking on and geodata auto-update) or "custom config":

| Config | Description |
| --- | --- |
| VLESS + mKCP + seed | Trades bandwidth for lower latency; uses more traffic than TCP for the same payload |
| VLESS + Vision + REALITY | XTLS solves the TLS-in-TLS problem |
| VLESS + XHTTP + REALITY | Multiplexing on by default, low latency; disable client-side global mux.cool first |
| Trojan + XHTTP + REALITY | Same as above with Trojan instead of VLESS |
| Fallback (dual-protocol) | Vision falls back to XHTTP, sharing port 443 |
| SNI (split) | Nginx splits by SNI — REALITY direct and via-CDN coexist |

Xray version can be latest / stable / pin a specific one.

### Ports & Coexistence

- **Default (VLESS + Vision + REALITY, direct)**: Xray listens on `0.0.0.0:443` (exclusive TCP). No certificate is needed (REALITY borrows a real site's TLS fingerprint). In this mode 443 is owned by Xray — **do not deploy other services that bind TCP 443 on the same host** (e.g. an Nginx site, Caddy, Apache).
- **SNI mode**: Nginx listens on 443 and splits traffic by SNI at L4 (`ssl_preread`); Xray runs over a Unix socket, so "Xray proxy + a real website" can share 443 without conflict. Note REALITY traffic must still complete TLS inside Xray — **do not** reverse-proxy it at Nginx L7.
- `80` (HTTP) and bare `UDP 443` (HTTP/3 QUIC) do not conflict with Xray's TCP 443 and may be used separately.

### Parameter Defaults

- **Port**: REALITY family defaults to 443; mKCP is randomly generated; non-SNI configs may change the listen port with an automatic restart.
- **UUID**: random by default; customizable; a non-standard UUID is mapped to a standard one.
- **kcp seed / trojan password**: random or custom. Note Xray 26.x moved mKCP `seed` out of `kcpSettings` into `finalmask`, and the type id was renamed along the way: 26.2.6–26.5.x use `mkcp-aes128gcm` (field `settings.password`) while 26.6+ uses `mkcp-legacy` (field `settings.value`). The two forms are **not interchangeable** — a config written in one form fails to load on Xray built for the other. Instead of hard-coding a version, the script **probes the locally installed xray binary** (`xray run -test` dry run) and picks whichever form this machine accepts, so both new and old Xray builds work out of the box. If xray is missing or does not support `-test`, it falls back to the legacy `kcpSettings.seed` form and prints a notice.
- **Reality target (camouflage)**: if left empty, a domain is picked at random from the `.target` pool in `config.json` (every preset domain is itself verified across DNS / 443 / TLS 1.3 / X25519); or you can supply your own, which is verified the same way on the spot. It is "which SNI the client should pretend to be" and **does not need to resolve to this host**. Before changing presets, run `bash test/target_probe.sh` to re-verify the list, or `bash test/target_probe.sh <domain>` to spot-check one. **The preset pool auto-syncs with upstream on every launch**: newly added upstream presets are merged into the local config, and ones marked expired (`target_removed` in `config.json`) are removed with a `config.json.bak` kept; domains you added or serverNames you edited are never touched.
- **shortId**: random (two by default), comma-separated multiple values supported; input 0–8 auto-generates that many of the corresponding length.
- **path**: random or custom.

### SNI Splitting & Site Management

- Nginx `ssl_preread` splits by SNI — good for CDN routing, upstream/downstream separation, and multi-site coexistence.
- Upstream/downstream separation: upstream xhttp+TLS+CDN / downstream xhttp+Reality, or the reverse.
- Manage the default domain (Reality) and the CDN domain.
- Custom domains and reverse-proxy apps: list / add / edit / delete, each with its own certificate, site config, stream mapping and UDS.
- Manual and automatic Nginx update toggles.

> The three site templates (`domain` / `cdn` / `custom-site`, i.e. three `*.example.com.conf`) ship with the repo under `config/nginx/conf/sites-available/`. They are **placeholder templates**: the script copies one and substitutes the placeholder domain / path with your real values, so a single template serves any domain and needs no manual editing. To customize the camo site content, edit these templates; the constraints (only one `quic reuseport` in the whole set, placeholders must be preserved, etc.) are pinned by T1r/T2r/T3r/T13r in `test/http3_test.sh`.

### Certificate Management

- CA vendor: ZeroSSL (default) or Let's Encrypt; switching force re-issues existing domain certificates and auto-rolls-back on mid-way failure.
- Issue certificates, force-renew all, or remove a single domain's certificate.
- Auto-renewal: the cron job is written into crontab by acme.sh itself, but it **swallows install failures into the same exit code**; so when installing acme.sh the script additionally self-checks whether the cron really landed — if missing it tries to fix it, and if it still can't it warns clearly. A failed renewal itself leaves no log (cron's output is discarded upstream), so health-check section 6 infers it from "days-left fell into the renewal window yet nothing renewed" — it is recommended to run `--health` periodically via cron to watch this chain.

### Rules & Routing

- Optionally block BitTorrent traffic, China-bound IP traffic, and ads.
- Custom routing: block ip / domain, WARP ip / domain.
- geodata auto-update toggle.

### Ops, Diagnostics & Subscription

- Load management: full install / install-update only / uninstall (Xray and Nginx can be removed separately); **install-update only swaps the xray binary and never touches the running config**.
- Operation management: start / stop / restart.
- Share links & QR codes, traffic statistics.
- BBR & kernel network acceleration: enable or repair BBR (idempotent), read-only network health check, kernel network high-concurrency tuning, file-descriptor limit, IPv6 status detection (read-only), IPv6 enable / soft-disable / hard-disable (kernel params, all require confirmation).
- One-shot full health check: eight sections, fully read-only, exit code `0`/`1` directly usable for alerting, including subscription freshness and the certificate auto-renewal chain (cron present / renewal actually happened).
- Subscription generation: base64 / Clash / sing-box, written to `~/.xray-script-personal-use-only/` with mode `0600`; **generated automatically after install**, rebuilt automatically on config change.

### Interface Language

Chinese / English. Switch via Manage configuration → Set language, or pass `--lang=zh` / `--lang=en`.

### Bundled Components

- Cloudflare WARP Proxy: Xray-native WireGuard outbound, no extra dependency, supports reset.

## Install & Launch

After installation the script auto-opens the management menu; **re-running the same file when already installed re-enters the menu without re-downloading or reinstalling**. Copy the command for your scenario:

### Install (first deployment)

Downloads the installer script to the server only — **no installation is performed**. To actually deploy, run the next command, or use "Install and start (one-liner)":

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
| `--ipv6-status` | Read-only IPv6 status detection (seven tiers, incl. "half-broken") | |
| `--ipv6-enable` | Enable IPv6 (idempotent) | |
| `--ipv6-disable` | Soft-disable IPv6 (drop external side, keep loopback; does not affect nginx `listen [::]`) | |
| `--ipv6-disable-hard` | Hard-disable IPv6 (drop the stack; refuses to run if nginx has `listen [::]`) | |
| `--bbr` | Enable/repair BBR congestion control | Idempotent, safe to re-run |
| `--net-tune` | Kernel network tuning for high concurrency | Changes kernel params; asks for confirmation |
| `--nofile-limit` | Raise the process file-descriptor limit | Changes kernel params; asks for confirmation |
| `--export-config [--yes]` | Export config and certificates to an archive | Use `--yes` for unattended mode |
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

# Export before migrating, then restore on the new host
bash ${HOME}/xray-script-personal-use-only.sh --export-config --yes
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
- **Onto a phone**: send the contents of `subscription-base64.txt` or `subscription-singbox.json` to yourself over a channel you trust, then use the client's "Import from file".

### 3. How to use each client

> **Platform cheat-sheet**: v2rayN is **cross-platform** (Avalonia rewrite since v7.x — Windows / macOS / Linux); NekoBox is **Android only** (officially maintained); v2rayNG is **Android only**; FoXray / Shadowrocket / Stash are **iOS only**; Clash Verge Rev and the sing-box desktop build cover **Windows / macOS / Linux**; Hiddify is cross-platform. Recommended clients per system:

| System | Recommended client | Use this | How to import |
| --- | --- | --- | --- |
| Windows / macOS / Linux | **v2rayN** (cross-platform since v7.x; macOS needs `xattr -cr` to lift quarantine, Linux needs .NET 8 / deb·rpm) | Screen link or `base64` | Copy the `vless://` link → "Servers → Import from clipboard"; or add the base64 content under "Subscription group settings" |
| Windows / macOS / Linux | **Clash Verge Rev** | `subscription-clash.yaml` | "Profiles" → import / new → pick the local YAML file (or paste its content) |
| Windows / macOS / Linux | **sing-box** (desktop) | `subscription-singbox.json` | Import the JSON config (desktop build imports from file) |
| Android | **v2rayNG** | Screen QR or `base64` | Scan the QR; or "Subscription → add subscription" with the base64 content / import from file |
| Android | **NekoBox** (Android only, officially maintained) | `base64` or `clash.yaml` | Pick by active core: sing-box core → base64 link, Clash core → YAML |
| Android | **sing-box** (SFA) | `subscription-singbox.json` | Import the JSON config (SFA supports QR or file import) |
| iOS | **FoXray** | Screen link or `base64` | "Import from clipboard", or import from QR / file |
| iOS | **Shadowrocket** | Screen link or `clash.yaml` | Paste the link; or import from a Clash config |
| iOS | **Stash** | `clash.yaml` | Import the YAML config directly |
| iOS | **sing-box** (SFM) | `subscription-singbox.json` | Import the JSON config |
| All platforms | **Hiddify** (Android / iOS / Windows / macOS / Linux, built on sing-box) | `subscription-singbox.json` or `base64` | Import the subscription (supports sing-box / V2Ray / Clash formats) |

> ⚠️ **Clash for Android (Kr328 build) is no longer maintained** and is not recommended; on Android use **Clash Meta for Android (CMFA) / FlClash / NekoBox / sing-box (SFA)** instead.
> ⚠️ **NekoRay** (the desktop sibling of NekoBox, same author) was **archived in March 2025** and is no longer updated — new users should start with Clash Verge Rev or the sing-box desktop build instead.

### 4. Usage notes and known limits

- **XHTTP mode: disable global mux.cool on the client** (both v2rayN and v2rayNG have this switch), otherwise it cannot connect to the newer Xray server.
- **sing-box has no mKCP**: with an mKCP config the sing-box subscription skips those nodes automatically (the rest work; the skip count is reported at generation time).
- **Clash / sing-box carry the primary connection only**: XHTTP downlink acceleration (extra) is Xray-specific and is preserved only in the base64 link; it does not take effect under Clash / sing-box.
- **Subscriptions are rebuilt automatically on config changes.** If you suspect the copy in hand is stale, run menu → 10 "Full health check": section 8 compares the subscription's mtime against the config's and reports `[WARN]` when it lags behind.

## Install Paths

**xray-script-personal-use-only:** `/usr/local/xray-script-personal-use-only`

**Nginx:** `/usr/local/nginx`

**Cloudflare WARP:** `$HOME/.xray-script-personal-use-only/warp.json` (WireGuard credentials)

**Script state:** `$HOME/.xray-script-personal-use-only/{config.json, commit}` (script config and installed commit record)

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
| Terminal QR code (share link, optional) | qrencode                       | qrencode             |

Two notes:

- The list **does not include `socat`**: it is only needed by acme.sh's standalone mode (which listens on port 80 itself), while this project always issues certificates via `--webroot` (see `service/ssl.sh`), so new machines no longer install it.
- A missing `qrencode` only affects the terminal QR code of share links (it warns instead of aborting), so it is listed as optional; the dependency section of menu 10's full health check covers it as an optional dependency.

## FAQ

1. If installation succeeds but service is unusable, check whether the server ports are open (verify with an online port-checking tool).
2. Before using SNI configuration, ensure VPS HTTP (80) and HTTPS (443) ports are open.
3. Before using SNI configuration, do not enable CDN protection, otherwise SSL issuance may fail.
4. If you encounter 【Could not get nonce, let's try again】 while issuing certificates with SNI: most likely ZeroSSL 【Free ACME Service】 is in 【Service disruption】 or 【Service outage】 — retry later.

## Installation Time Notes

SNI configuration is intended for long-term use after one setup, and is not suitable for repeated reinstall/reset, which consumes significant time. If you need to change configuration or domain, use the options in the management UI.

After switching to a non-SNI config, Nginx will be stopped but kept on the machine. Re-enabling SNI will not reinstall Nginx.

## Backup & Migration

Export / import an archive that bundles the Xray config, the Nginx sites and their certificates,
and the script's own config. Import creates a rollback point first and rolls back automatically if
anything fails, so a half-applied restore never leaves the box in a mixed state.

Typical migration: export on the old host, copy the archive over, then restore on the new one.

```sh
# Export a config + certificate archive (non-interactive, skip the confirmation prompt)
bash ~/xray-script-personal-use-only.sh --export-config --yes

# Restore from that archive on the new host
bash ~/xray-script-personal-use-only.sh --import-config <archive> --yes
```

See **Command-line Options** for the full list of non-interactive flags.

**This script is for study and communication only. Do not use it for illegal purposes. Illegal acts on the network are still illegal and will be punished by law.**
