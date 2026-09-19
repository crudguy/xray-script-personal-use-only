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

```sh
wget --no-check-certificate -O ${HOME}/xray-script-personal-use-only.sh https://raw.githubusercontent.com/crudguy/xray-script-personal-use-only/main/install.sh
bash ${HOME}/xray-script-personal-use-only.sh
```

## 命令行参数

| 参数 | 作用 |
| --- | --- |
| `--vision` / `--xhttp` / `--fallback` | 快速安装对应模式 |
| `--lang=zh` / `--lang=en` | 指定界面语言 |
| `--check-deps` | 强制重新检查并安装依赖 |
| `--force-update` | 跳过比对与询问，直接刷新到远端最新提交 |
| `--health` | 一键全量体检，退出码 `0` 无失败项 / `1` 有失败项 |
| `--net-status` | 只读查看内核网络与 BBR 状态 |
| `--bbr` | 启用 / 修复 BBR，幂等可重复执行 |
| `--net-tune` | 内核网络高并发调优 |
| `--nofile-limit` | 提升进程文件句柄上限 |
| `--export-config [--with-docker] [--yes]` | 导出配置与证书归档 |
| `--import-config <归档> [--yes]` | 从归档还原 |
| `--subscription` | 生成 base64 / Clash / sing-box 三种订阅 |

## 安装位置

| 组件 | 路径 |
| --- | --- |
| xray-script-personal-use-only | `/usr/local/xray-script-personal-use-only` |
| Nginx | `/usr/local/nginx` |
| Cloudflare WARP | `~/.xray-script-personal-use-only/docker/warp` |
| 脚本状态 | `~/.xray-script-personal-use-only/{config.json, commit}` |

*此脚本仅供交流学习使用，请勿使用此脚本行违法之事。网络非法外之地，行非法之事，必将接受法律制裁。*
