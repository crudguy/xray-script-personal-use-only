# 更新日志 / Changelog

本文件记录 xray-script-personal-use-only 的所有重要变更。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号沿用本项目既有的日期版本方案（`vYYYY-MM-DD`，同日多次发布加 `.N` 后缀）；
每次发布都会 bump `config.json` 的 `version`，存量机器的自动更新以此为准。

All notable changes to xray-script-personal-use-only are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Version numbers follow this project's date-based scheme (`vYYYY-MM-DD`, with a `.N`
suffix for additional releases on the same day).

分类含义 / Change types：

- **新增 Added** —— 新功能
- **变更 Changed** —— 既有行为调整
- **修复 Fixed** —— bug 修复
- **安全 Security** —— 安全加固与权限收紧
- **移除 Removed** —— 删除的功能或文件
- **文档 Docs** —— 文档与 CI 等非运行时改动

---

## [v2026-09-20.3]

### 文档 Docs

- **支持的客户端说明**：README（中英双语）新增「支持的客户端」章节，按 Windows / macOS / Linux / Android / iOS 给出推荐客户端与适用订阅格式，并列出三种订阅文件（`subscription-base64.txt` / `subscription-clash.yaml` / `subscription-singbox.json`）及导入要点。
  - 明确 XHTTP 模式需关闭客户端全局 mux.cool；
  - 说明 sing-box 不支持 mKCP（自动跳过）、Clash/sing-box 仅含主连接（XHTTP extra 仅保留在 base64 链接）。
- 修正英文 README 中过时的「start/stop/restart 仍为菜单项」说明，与其已支持非交互参数的现状一致。

---

## [v2026-09-20.2]

### 新增 Added

- **非交互服务参数**：公开入口新增 `--start` / `--stop` / `--restart` / `--share` 四个非交互参数，可直接脚本化 / 放入 cron 管理 Xray 服务与分享链接（此前这些动作仅为交互菜单项，公开入口未透传，调用会静默落回菜单）。
  - `install.sh` 的 DIRECT_ARGS 收集清单补充这 4 个参数；
  - `core/main.sh` 的 `_cmd` case 新增 4 个分支转发至 `exec_handler`（`--share` 经 `shift` + `"$@"` 透传 `--save` / `--no-qr` 等附加参数）；
  - 底层 `core/handler.sh` 早已实现的 `handler_start/stop/restart/share` 现可通过单一入口文件直接调用。
- 新增回归测试 `test/cli_service_test.sh`，静态锁定转发链三处落点，防回退。

### 文档 Docs

- `README.md` / `.github/README.en.md` 的「命令行参数」段补充 4 个非交互参数，并修正「启停仍为菜单项」的旧说明。

## [v2026-09-20.1]

### 安全 Security

- **证书私钥权限收紧**：签发成功后 `privkey.pem` 由 world-readable 的 `644` 改为
  `chown root:nginx` + `chmod 640`。nginx worker 以 `nginx` 身份运行
  （`config/nginx/conf/nginx.conf` 的 `user nginx;`），属组可读即够用，不再让所有本机用户
  可读，降低私钥被其它用户或被入侵进程读取的风险。`chown` 在主机无 `nginx` 组时会失败，
  此时回退 `644`，避免 nginx 因读不到私钥而启动失败。

### 变更 Changed

- **TCP Fast Open**：`config/xray/` 下 6 个模板的 `direct`(freedom) outbound 新增
  顶层 `sockopt.tcpFastOpen=true`；`handler.sh` 的 `handler_net_tune` 同步登记
  `net.ipv4.tcp_fastopen=3`（客户端+服务端均启用），二者配合可省一次 RTT，对服务器侧
  主动建连（出站到目标网站）收益明显。
- **nginx 服务自恢复**：`config/nginx/nginx.service` 的 `[Service]` 增加
  `Restart=on-failure`、`RestartSec=2s`、`LimitNOFILE=100000`。进程崩溃或被 OOM kill 后由
  systemd 自动拉起，避免 443 静默不通；FD 上限显式抬到 10 万，防高并发下 worker 耗尽。

### 修复 Fixed

- **REALITY `serverNames` 配置守卫**：`handler.sh` 在生成 xray 配置并注入
  `realitySettings.serverNames` 前，新增校验——非空、不得含占位符 `example.com`、
  且（非 `sni` 模板时）必须包含 `target` 域名，否则直接报错拦截。防手滑把模板占位符写进
  `config.json` 导致握手失败或把伪装目标暴露成 `example.com`。

### 文档 Docs

- 新增 4 个回归测试：`tfo_test.sh`（断言 freedom outbound 含 `tcpFastOpen` 且
  `handler_net_tune` 登记 `tcp_fastopen=3`）、`nginx_service_test.sh`（断言 `Restart` /
  `LimitNOFILE`）、`ssl_perms_test.sh`（断言私钥 640 收紧与 644 回退双分支齐全）、
  `reality_server_names_test.sh`（守卫三处 `_error` 文案 + 镜像判定逻辑对正反样例断言）。
  均不依赖 `jq`，CI 与沙箱均可跑。

---

## [v2026-09-20]

### 修复 Fixed

- **备份导入静默丢配置**：Windows/MSYS 下 `jq -r` 输出的是 CRLF，而 `while IFS= read -r`
  只按 LF 切行，导致 manifest 里的成员 id 尾部残留 `\r`，`_member_spec` 匹配不到后被判为
  "未知成员"跳过。表现为导出 3 个成员、**导入只还原最后 1 个**，`xray_config` 与
  `script_config` 无声丢失。现已在读取成员 id 与 ACME 域名后立即剥离 CR。
  （该缺陷隐蔽性强：日志只提示"未知成员，已跳过"，且仅最后一项看似还原成功。）
- **`check.sh` 未知参数静默成功**：本脚本 `main()` 的 `case` 缺少 `*)` 兜底分支，传入未知或
  拼错的参数时什么都不做就返回 0。而 README 与 `core/main.sh` 都推荐脚本化告警直接调用
  `core/check.sh --health`（0=无失败项 / 1=有失败项），cron 里把 `--health` 误写成 `--heath`
  会让监控**永远假绿**。现改为打印用法并以退出码 2 结束（与 `handler.sh` 一致：
  2=用法错误 / 0=正常 / 1=真实故障）。
- **CI ShellCheck 门禁告警清零**（25 → 0）：含 `core/menu.sh` 一处死赋值、6 个用例因向 `eval`
  注入桩件变量而引发的误报，以及一处双引号内反引号被当作命令替换。
  债务棘轮（SC2155 / SC2034 / SC2154）保持 0。
- **用例可移植性**：`backup_test.sh` 原硬编码 `python` 命令，而 ubuntu-latest 只有 `python3`，
  缺失时会在 `set -e` 下以 127 直接崩溃；现改为探测 `python3` / `python`，缺失则跳过。

## [初始化]

- 重置变更记录，从此版本起重新开始按 Keep a Changelog 规范记录。
