中文 | [English](/.github/README.en.md) | [更新日志](CHANGELOG.md)

# xray-script-personal-use-only

一个纯 Shell 实现的 Xray 一键部署与管理脚本，覆盖「安装 → 配置 → 签发证书 → 分享/订阅 → 体检 → 备份迁移」的完整生命周期。
脚本不引入数据库、Web 面板与常驻服务，所有状态落在配置文件与 systemd 单元里；订阅与体检都是本地只读/本地产出，不新增监听面。

## 功能说明

### 协议与传输

安装时可选「一键安装」（稳定版 Vision + Reality，默认屏蔽 bt / 回国 / 广告并开启 geodata 自动更新）或「自定义配置」：

| 配置 | 说明 |
| --- | --- |
| VLESS + mKCP + seed | 牺牲带宽降低延迟，传输同样内容比 TCP 更耗流量 |
| VLESS + Vision + REALITY | XTLS 解决 TLS in TLS 问题 |
| VLESS + XHTTP + REALITY | 默认多路复用，延迟低；使用前需关闭客户端全局 mux.cool |
| Trojan + XHTTP + REALITY | 以 Trojan 替换 VLESS |
| Fallback（双协议复合） | Vision 回落 XHTTP，共用 443 端口 |
| SNI（分流复合） | Nginx 按 SNI 分流，REALITY 直连与过 CDN 共存 |

Xray 版本可选最新版、稳定版或自选版。

### 端口与共存

- **默认（VLESS + Vision + REALITY 直连）**：Xray 直接监听 `0.0.0.0:443`（TCP 独占），不申请任何证书（REALITY 借用真实站点 TLS 特征）。该模式下 443 被 Xray 独占，**同机不要再部署其他占用 TCP 443 的服务**（如 Nginx 站点、Caddy、Apache）。
- **SNI 分流模式**：改由 Nginx 监听 443 并按 SNI 做四层（`ssl_preread`）分流，Xray 走 Unix socket，可实现「Xray 代理 + 真实网站」共用 443 互不冲突。注意 REALITY 流量仍需由 Xray 完成 TLS，**不能**用 Nginx 七层反代。
- `80`（HTTP）与纯 `UDP 443`（HTTP/3 QUIC）不与 Xray 的 TCP 443 冲突，可另行使用。

### 参数默认值

- **端口**：REALITY 系默认 443，mKCP 随机生成；非 SNI 配置可修改监听端口并自动重启
- **UUID**：随机生成；可自定义；非标准 UUID 会映射为标准 UUID
- **kcp seed / trojan 密码**：随机生成或自定义。注意 Xray 26.x 已把 mKCP 的 `seed` 从 `kcpSettings` 迁进 `finalmask`，且类型 id 在 26.6 前后改过名 —— 26.2.6～26.5.x 用 `mkcp-aes128gcm`（字段 `settings.password`），26.6 起用 `mkcp-legacy`（字段 `settings.value`），两种写法**互不兼容**。脚本在写入配置时**拿本机已装的 xray 实测**（`xray run -test` 试跑）决定用哪一种，不写死版本号，故新老 Xray 都能直接用；若本机 xray 缺失或不支持 `-test`，则退回旧写法 `kcpSettings.seed` 并给出提示
- **Reality target（伪装目标）**：留空则从 `config.json` 的 `.target` 预设池随机取（预设池内的域名都经过 DNS / 443 / TLS 1.3 / X25519 四项实测）；也可自填，会按同样四项当场校验。它是「客户端 SNI 要伪装成谁」，**不需要解析到本机**。改预设前可用 `bash test/target_probe.sh` 复验清单，`bash test/target_probe.sh <域名>` 抽查单个域名。**预设池随每次启动自动与上游对齐**：上游新增的预设自动补进本地配置，上游标记失效的（`config.json` 的 `target_removed` 名单）自动移除并留一份 `config.json.bak`；你自己加过的域名与改过的 serverNames 一律不动
- **shortId**：随机生成（默认两个），支持逗号分隔多个值，输入 0–8 时自动生成对应长度
- **path**：随机生成或自定义

### SNI 分流与站点管理

- 由 Nginx 的 `ssl_preread` 按 SNI 分流，适合过 CDN、上下行分离、多站点共存
- 上下行分离：上行 xhttp+TLS+CDN / 下行 xhttp+Reality，或反向组合
- 管理默认域名（Reality）与 CDN 域名
- 自定义域名与反代应用：列表 / 新增 / 编辑 / 删除，每个站点拥有独立证书、独立站点配置、独立 stream 映射与 UDS
- Nginx 手动更新与自动更新开关

### 证书管理

- CA 厂商：ZeroSSL（默认）或 Let's Encrypt；切换时会强制重签现有域名证书，中途失败自动回滚
- 证书申请、强制续签全部证书、移除单域名证书

### 规则与分流

- 可选屏蔽 BitTorrent 流量、回国流量与广告
- 自定义分流：屏蔽 ip / domain，WARP ip / domain
- geodata 自动更新开关（数据源 Loyalsoldier/v2ray-rules-dat）

### 运维、诊断与订阅

- 装载管理：完整安装 / 仅安装更新 / 卸载（可分别卸载 Xray 与 Nginx）；**仅安装更新只替换 xray 二进制，不改动运行配置**
- 操作管理：启动 / 停止 / 重启
- 分享链接与二维码、信息统计
- BBR 与内核网络加速：开启或修复 BBR（幂等）、只读网络体检、内核网络高并发调优、文件句柄上限、
  IPv6 状态检测（只读）、IPv6 启用 / 软禁用 / 硬禁用（改内核参数，均需二次确认）
- 一键全量体检：八个分区全程只读，退出码 `0`/`1` 可直接用于告警，含订阅新鲜度检查
- 订阅生成：base64 / Clash / sing-box 三种格式写入 `~/.xray-script-personal-use-only/`，权限 `0600`；**安装完成后自动生成**，配置变更后自动重建

### 备份与迁移

导出 / 导入归档，含 Xray 配置、Nginx 站点与证书、脚本配置；导入前自动生成回退点，失败自动回退。

### 界面语言

中文 / 英文双语，菜单「管理配置 → 设置语言」或 `--lang=zh` / `--lang=en`。

### 附带组件

- Cloudflare WARP Proxy：Xray 原生 WireGuard 出站，无需额外依赖，支持重置

## 安装与启动

脚本安装完成后会自动打开管理菜单；**已安装时重新运行同一文件即进入管理菜单，不会重复下载或重装**。请按场景复制对应命令：

### 一键安装（首次部署）

下载安装器并执行，自动完成依赖安装、项目部署，并打开管理菜单：

```sh
wget --no-check-certificate -O ${HOME}/xray-script-personal-use-only.sh https://raw.githubusercontent.com/crudguy/xray-script-personal-use-only/main/install.sh
```

### 一键启动（已安装后打开管理菜单）

重新打开管理菜单进行配置、启停与运维（不重复下载、不重装）：

```sh
bash ${HOME}/xray-script-personal-use-only.sh
```

### 一键安装并启动（一步到位）

下载、部署、打开菜单合并为一条命令：

```sh
wget --no-check-certificate -O ${HOME}/xray-script-personal-use-only.sh https://raw.githubusercontent.com/crudguy/xray-script-personal-use-only/main/install.sh && bash ${HOME}/xray-script-personal-use-only.sh
```

## 命令行参数

所有参数都加在**同一个入口文件**后面（首次下载的 `install.sh` 副本，默认位于 `~/xray-script-personal-use-only.sh`）。无论首次安装还是已安装后，都通过这一个文件调用：

```sh
bash ~/xray-script-personal-use-only.sh <参数>
```

- 首次运行：下载项目 → 安装 → 执行参数
- 已安装后运行：跳过下载、不重装，直接执行参数

参数分两类：

**A. 安装器专用**（install.sh 自行处理，不进入交互菜单）

| 参数 | 作用 |
| --- | --- |
| `--lang=zh` / `--lang=en` | 指定界面语言 |
| `--check-deps` | 强制重新检查并安装依赖 |
| `--force-update` | 跳过比对与询问，直接刷新到远端最新提交 |
| `-d <目录>` | 自定义安装目录 |
| `--help` / `-h` | 显示帮助 |

**B. 无交互直达**（转发给核心模块，可脚本化 / 放入 cron）

| 参数 | 作用 |
| --- | --- |
| `--vision` / `--xhttp` / `--fallback` | 快速安装对应模式 |
| `--health` | 一键全量体检，退出码 `0` 无失败项 / `1` 有失败项 / `2` 参数错误 |
| | 放进 cron 时请以退出码判别：`2` 表示用法有误（如拼错参数），不可当作"通过" |
| `--net-status` | 只读查看内核网络与 BBR 状态 |
| `--ipv6-status` | 只读检测 IPv6 状态（七档，含「半残」判定） |
| `--ipv6-enable` | 启用 IPv6（幂等） |
| `--ipv6-disable` | 软禁用 IPv6（关外网侧，保留回环，不影响 nginx 的 `listen [::]`） |
| `--ipv6-disable-hard` | 硬禁用 IPv6（关协议栈；nginx 配了 `listen [::]` 时会拒绝执行） |
| `--bbr` | 启用 / 修复 BBR，幂等可重复执行 |
| `--net-tune` | 内核网络高并发调优 |
| `--nofile-limit` | 提升进程文件句柄上限 |
| `--export-config [--yes]` | 导出配置与证书归档 |
| `--import-config <归档> [--yes]` | 从归档还原 |
| `--subscription` | 生成 base64 / Clash / sing-box 三种订阅 |
| `--start` / `--stop` / `--restart` | 启动 / 停止 / 重启 Xray 服务（幂等，带 active 复查） |
| `--share [--save] [--no-qr]` | 显示分享链接（可保存到文件 / 不打印二维码） |

常用示例：

```sh
# 首次或重装直接装 Vision（REALITY），全程非交互
bash ~/xray-script-personal-use-only.sh --vision

# 已安装后只读体检（适合 cron 盯 BBR 是否掉）
bash ~/xray-script-personal-use-only.sh --health

# 强制刷新脚本到最新提交
bash ~/xray-script-personal-use-only.sh --force-update

# 导出配置归档（非交互确认）
bash ~/xray-script-personal-use-only.sh --export-config --yes
```

> **注意**：改端口（`change-port`）、切换 CA（`ca-server`）等仍为**交互菜单项**，公开入口暂未提供非交互参数；如需 `bash ... --change-port` 形式的调用可继续补转发。其它高频运维动作（体检 / 启停 / 分享 / 订阅 / 导出导入）均已支持非交互。

## 分享链接、订阅文件与客户端使用

安装完成后你会同时拿到两类产物：**屏幕上的分享链接**（可直接扫码 / 复制）和**服务器上的三个订阅文件**（覆盖全部节点）。

### 一、屏幕输出：分享链接

安装结束时直接打印；之后可用菜单「分享链接与二维码」或 `--share` 随时重现。

| 产物 | 说明 |
| --- | --- |
| `vless://…` / `trojan://…` 链接 | 含 UUID、地址、端口、Reality 公钥、SNI、flow 等全部参数，末尾 `#标签` 即节点名 |
| 终端二维码 | 同一条链接的 ANSI 二维码，手机端可直接扫（需服务器装有 `qrencode`，缺失时只告警、不中断） |
| 打印条数 | 普通模式 1 条；**Fallback 2 条**（Vision + XHTTP）；**SNI 5 条**（含上下行分离与 CDN） |

`--share` 的两个附加参数：

- `--share --save`：把链接与客户端配置按 `0600` 写入 `~/.xray-script-personal-use-only/share-link.txt`，**屏幕不再打印明文与二维码**（想留存又不想明文上屏时用这个）。
- `--share --no-qr`：只打印链接、不出二维码（适合写进日志 / cron）。

> 屏幕输出**含密钥**，首次打印前脚本会给出泄露提示；录屏、共享屏幕或终端回滚时请注意。

### 二、服务器上的三个订阅文件

**安装完成后自动生成**，落在 `~/.xray-script-personal-use-only/`，权限 `0600`（含 UUID / 密码 / 公钥，请勿外泄）。配置变更会自动重建，也可随时用菜单 11 或 `--subscription` 手动刷新。

| 文件 | 格式 | 说明 |
| --- | --- | --- |
| `subscription-base64.txt` | v2rayN / NekoBox / FoXray 通用 base64（单行） | 含全部节点与 XHTTP extra |
| `subscription-clash.yaml` | Clash / mihomo YAML | 含 proxy-groups 与直连规则 |
| `subscription-singbox.json` | sing-box 出站 JSON | sing-box 全平台通用 |

与屏幕链接的区别：订阅文件会**遍历当前模式的全部客户端入站**（自定义 / 多入站配置也不会漏节点），而屏幕链接普通模式只打印首个入站。

**怎么把文件弄到你的设备上**（脚本不开放订阅 URL、不额外监听端口，文件只存在服务器本机）：

- **复制粘贴**（最省事，base64 是单行）：
  `cat ~/.xray-script-personal-use-only/subscription-base64.txt`
- **下载到电脑**：
  `scp root@<服务器IP>:~/.xray-script-personal-use-only/subscription-clash.yaml ./`
  （Windows 可用 WinSCP / FinalShell / Xshell 自带的 sftp）
- **传到手机**：把 `subscription-base64.txt` 或 `subscription-singbox.json` 的内容用你信任的方式发到手机，再用客户端「从文件导入」。

### 三、各客户端怎么用

> **平台对照速记**：v2rayN **跨平台**（v7.x 起 Avalonia 重写，覆盖 Windows / macOS / Linux）；NekoBox **仅 Android**（官方维护）；v2rayNG **仅 Android**；FoXray / Shadowrocket / Stash **仅 iOS**；Clash Verge Rev 与 sing-box 桌面版覆盖 **Windows / macOS / Linux**；Hiddify 全平台。下面按系统给出推荐客户端与对应产物。

| 系统 | 推荐客户端 | 用哪个产物 | 导入方式 |
| --- | --- | --- | --- |
| Windows / macOS / Linux | **v2rayN**（v7.x 跨平台；macOS 需 `xattr -cr` 解除隔离，Linux 需 .NET 8 / deb·rpm） | 屏幕链接 或 `base64` | 复制 `vless://` 链接 → 「服务器 → 从剪贴板导入」；或把 base64 内容加入「订阅分组设置」 |
| Windows / macOS / Linux | **Clash Verge Rev** | `subscription-clash.yaml` | 「配置（Profiles）」→ 导入 / 新建 → 选择本地 YAML 文件（或粘贴内容） |
| Windows / macOS / Linux | **sing-box**（桌面版） | `subscription-singbox.json` | 导入 JSON 配置（桌面版支持从文件导入） |
| Android | **v2rayNG** | 屏幕二维码 或 `base64` | 直接扫码；或「订阅 → 添加订阅」导入 base64 内容 / 从文件导入 |
| Android | **NekoBox**（官方仅 Android） | `base64` 或 `clash.yaml` | 按内核二选一：sing-box 内核用 base64 链接，Clash 内核用 YAML |
| Android | **sing-box**（SFA） | `subscription-singbox.json` | 导入 JSON 配置（SFA 支持扫码或文件导入） |
| iOS | **FoXray** | 屏幕链接 或 `base64` | 「从剪贴板导入」或「从二维码 / 文件导入」 |
| iOS | **Shadowrocket** | 屏幕链接 或 `clash.yaml` | 粘贴链接；或从 Clash 配置导入 |
| iOS | **Stash** | `clash.yaml` | 直接导入 YAML 配置 |
| iOS | **sing-box**（SFM） | `subscription-singbox.json` | 导入 JSON 配置 |
| 全平台 | **Hiddify**（Android / iOS / Windows / macOS / Linux，基于 sing-box） | `subscription-singbox.json` 或 `base64` | 导入订阅（支持 sing-box / V2Ray / Clash 格式） |

> ⚠️ **Clash for Android（Kr328 版）已停止维护**，不再推荐；Android 端想要 Clash 类请改用 **Clash Meta for Android（CMFA）/ FlClash / NekoBox / sing-box（SFA）**。
> ⚠️ **NekoRay（桌面端，与 NekoBox 同作者）仓库已于 2025-03 归档停更**，新用户不建议从它起步；桌面端优先用 Clash Verge Rev 或 sing-box 桌面版。

### 四、使用要点与已知限制

- **XHTTP 模式必须关闭客户端全局 mux.cool**（v2rayN 与 v2rayNG 均有此开关），否则连不上新版 Xray 服务端。
- **sing-box 不支持 mKCP**：启用 mKCP 时 sing-box 订阅会自动跳过这些节点（其余正常，跳过数量在生成时提示）。
- **Clash / sing-box 仅含主连接**：XHTTP 下行加速（extra）是 Xray 专有特性，只保留在 base64 链接中；用 Clash / sing-box 时该加速不生效。
- **订阅随配置变更自动重建**；若怀疑手上的订阅已过期，跑菜单 10「一键全量体检」，第 8 分区会比较订阅与配置的修改时间，落后则报 `[WARN]`。

## 安装位置

| 组件 | 路径 |
| --- | --- |
| xray-script-personal-use-only | `/usr/local/xray-script-personal-use-only` |
| Nginx | `/usr/local/nginx` |
| Cloudflare WARP | `~/.xray-script-personal-use-only/warp.json`（WireGuard 凭据）|
| 脚本状态 | `~/.xray-script-personal-use-only/{config.json, commit}` |

## 依赖清单

使用 SNI 配置时，脚本可能会安装以下依赖（与英文 README 的同名章节保持同口径）：

| 用途 | Debian 系 | Red Hat 系 |
| --- | --- | --- |
| yumdb set（把包标记为手动安装） |  | yum-utils |
| dnf config-manager |  | dnf-plugins-core |
| 获取 IP | iproute2 | iproute |
| DNS 解析 | dnsutils | bind-utils |
| wget | wget | wget |
| curl | curl | curl |
| wget/curl 走 https | ca-certificates | ca-certificates |
| kill/pkill/ps/sysctl/free | procps | procps-ng |
| epel 源 |  | epel-release |
| epel 源 |  | epel-next-release |
| remi 源 |  | remi-release |
| 防火墙 | ufw | firewalld |
| **编译基础：** |  |  |
| 下载源码 | wget | wget |
| 解压 tar 源码 | tar | tar |
| 解压 tar.gz 源码 | gzip | gzip |
| gcc | gcc | gcc |
| g++ | g++ | gcc-c++ |
| make | make | make |
| **acme.sh 依赖：** | curl | curl |
|  | openssl | openssl |
|  | cron | crontabs |
| **编译 OpenSSL：** | perl-base（含于 libperl-dev） | perl-IPC-Cmd |
|  | perl-modules-5.32（含于 libperl-dev） | perl-Getopt-Long |
|  | libperl5.32（含于 libperl-dev） | perl-Data-Dumper |
|  |  | perl-FindBin |
| **编译 Brotli：** | git | git |
|  | libbrotli-dev | brotli-devel |
| **编译 Nginx：** | libpcre2-dev | pcre2-devel |
|  | zlib1g-dev | zlib-devel |
| --with-http_xslt_module | libxml2-dev | libxml2-devel |
| --with-http_xslt_module | libxslt1-dev | libxslt-devel |
| --with-http_image_filter_module | libgd-dev | gd-devel |
| --with-google_perftools_module | libgoogle-perftools-dev | gperftools-devel |
| --with-http_geoip_module | libgeoip-dev | geoip-devel |
| --with-http_perl_module |  | perl-ExtUtils-Embed |
|  | libperl-dev | perl-devel |
| 终端二维码（分享链接，可选） | qrencode | qrencode |

两点说明：

- 清单**不含 `socat`**：它只在 acme.sh 的 standalone 模式（自己监听 80 端口）下需要，而本项目的证书签发固定走 `--webroot`（见 `service/ssl.sh`），从不使用 standalone，故新机不再安装该包。
- `qrencode` 缺失**只影响**分享链接的终端二维码展示（缺失时仅告警、不中断），因此列为可选依赖；菜单 10「一键全量体检」的依赖分区会把它纳入可选依赖检查。

*此脚本仅供交流学习使用，请勿使用此脚本行违法之事。网络非法外之地，行非法之事，必将接受法律制裁。*
