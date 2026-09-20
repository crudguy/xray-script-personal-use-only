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
- **kcp seed / trojan 密码**：随机生成或自定义
- **Reality target**：从 serverNames 列表随机取，也支持自填并校验其 TLSv1.3 与 H2 可用性
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

- 装载管理：完整安装 / 仅安装更新 / 卸载（可分别卸载 Xray 与 Nginx）
- 操作管理：启动 / 停止 / 重启
- 分享链接与二维码、信息统计
- BBR 与内核网络加速：开启或修复 BBR（幂等）、只读网络体检、内核网络高并发调优、文件句柄上限
- 一键全量体检：八个分区全程只读，退出码 `0`/`1` 可直接用于告警，含订阅新鲜度检查
- 订阅生成：base64 / Clash / sing-box 三种格式写入 `~/.xray-script-personal-use-only/`，权限 `0600`；配置变更后自动重建

### 备份与迁移

导出 / 导入归档，含 Xray 配置、Nginx 站点与证书、脚本配置，可选带上容器数据；导入前自动生成回退点，失败自动回退。

### 界面语言

中文 / 英文双语，菜单「管理配置 → 设置语言」或 `--lang=zh` / `--lang=en`。

### 附带组件

- Cloudflare WARP Proxy：Docker 部署，启用时自动安装 Docker，支持重置

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
| `--bbr` | 启用 / 修复 BBR，幂等可重复执行 |
| `--net-tune` | 内核网络高并发调优 |
| `--nofile-limit` | 提升进程文件句柄上限 |
| `--export-config [--with-docker] [--yes]` | 导出配置与证书归档 |
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

# 导出配置归档（含 docker、非交互确认）
bash ~/xray-script-personal-use-only.sh --export-config --with-docker --yes
```

> **注意**：改端口（`change-port`）、切换 CA（`ca-server`）等仍为**交互菜单项**，公开入口暂未提供非交互参数；如需 `bash ... --change-port` 形式的调用可继续补转发。其它高频运维动作（体检 / 启停 / 分享 / 订阅 / 导出导入）均已支持非交互。

## 支持的客户端

本脚本生成三种订阅格式，分别适配不同客户端。安装完成后通过菜单「分享链接与二维码 / 生成订阅」或 `--subscription` 生成，文件写入 `~/.xray-script-personal-use-only/`，权限 `0600`（含 uuid / 密码 / 公钥等敏感信息，请妥善保管、勿外泄）。

### 按系统选择客户端

| 系统 | 推荐客户端 | 适用订阅格式 |
| --- | --- | --- |
| Windows | **v2rayN** 或 **Clash Verge Rev**（备选 NekoBox） | base64 / Clash |
| macOS | **NekoBox** 或 **Clash Verge Rev**（备选 v2rayN 跨平台版） | base64 / Clash |
| Linux | **v2rayN** 或 **NekoBox**（备选 Clash Verge Rev） | base64 / Clash |
| Android | **v2rayNG** 或 **NekoBox**（备选 Clash for Android / sing-box） | base64 / Clash / sing-box |
| iOS | **FoXray** 或 **Shadowrocket / Stash**（备选 NekoBox / sing-box） | base64 / Clash / sing-box |

### 三种订阅格式

| 文件 | 格式 | 适用客户端 |
| --- | --- | --- |
| `subscription-base64.txt` | v2rayN 风格 base64 订阅（含全部节点与 XHTTP extra） | v2rayN（全平台）/ NekoBox / FoXray |
| `subscription-clash.yaml` | Clash 订阅（YAML） | Clash Verge Rev / Clash for Windows / Clash for Android / Stash / NekoBox（Clash 模式） |
| `subscription-singbox.json` | sing-box 订阅（JSON） | sing-box（全平台，含 SFA / 桌面版） |

### 使用要点

- **导入方式**：在客户端中选择「订阅 / 从链接导入 / 从文件导入」，粘贴分享链接或直接导入上述文件即可。
- **XHTTP 模式特别注意**：若服务端使用 `VLESS + XHTTP + REALITY`，客户端**必须关闭全局 mux.cool**（v2rayN 与 v2rayNG 均有此设置），否则无法连上新版 Xray 服务端。
- **sing-box 不支持 mKCP**：若你启用了 mKCP 配置，sing-box 订阅会自动跳过这些节点（其余节点正常）。
- **Clash / sing-box 仅含主连接**：XHTTP 下行加速（extra）是 Xray 专有特性，仅保留在 base64 链接中；使用 Clash / sing-box 时 XHTTP 的下行加速不生效。
- 配置变更后订阅会**自动重建**，无需手动重新生成；也可随时执行 `--subscription` 或菜单项手动刷新。

## 安装位置

| 组件 | 路径 |
| --- | --- |
| xray-script-personal-use-only | `/usr/local/xray-script-personal-use-only` |
| Nginx | `/usr/local/nginx` |
| Cloudflare WARP | `~/.xray-script-personal-use-only/docker/warp` |
| 脚本状态 | `~/.xray-script-personal-use-only/{config.json, commit}` |

*此脚本仅供交流学习使用，请勿使用此脚本行违法之事。网络非法外之地，行非法之事，必将接受法律制裁。*
