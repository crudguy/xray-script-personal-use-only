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

## [v2026-09-21.1]

### 安全 Security

- **关闭 acme.sh 自动升级漂移（P0 残余）**：`service/ssl.sh` 的 `install_acme_sh` 末尾原先执行 `--upgrade --auto-upgrade`，会安装定时任务把上一版钉住的 `3.1.6` 漂回浮动版本，破坏供应链锁定。改为仅 `--upgrade`（同分支内升级，不漂走）；需要升级请显式运行 `ssl.sh --update`。`purge` 路径的 `--upgrade --auto-upgrade 0`（禁用语法）保留。
  - 补：`v2026-09-21` 第 41 行的「未改动」备注即指此条，现已于本版本落实；`ACME_SH_REF=3.1.6` 的钉死语义现在才真正闭环。
- **Nginx 版本号白名单校验（纵深防御）**：`service/nginx.sh` 的 `source_compile` 从 GitHub API 解析 `nginx_version` 后**无正则校验**就流入 `_error_detect` 的 `eval`（`curl -o ${nginx_version}...`），一旦 API 被劫持/返回异常可能注入命令。现加 `^nginx-[0-9]+\.[0-9]+\.[0-9]+$` 约束（与已有的 `openssl_version` 校验对齐），非法/空值直接 `print_error` 终止编译。配套在 `i18n/zh.json` / `i18n/en.json` 的 `.nginx.compile` 下新增 `bad_nginx_version` 键（中英同步，现各 703 键、键集合一致）。

### 修复 Fixed

- **签发证书时 Nginx 配置失败恢复（健壮性）**：`service/ssl.sh` 的 `issue_certificate` 在签发期间把线上 `nginx.conf` 改写为"仅 ACME 挑战"最小配置，此前**只在成功路径手动还原**；若中途任意 `print_error` 退出（如 `nginx -t`/reload 失败、签发失败），线上配置会停留在损坏态。现备份后挂 `EXIT` trap 兜底，无论成功/失败/被信号打断都先把原配置还原再退出；成功路径手动还原后显式 `trap - EXIT` 防止末尾重复触发。隔离脚本实测：中途 `exit 1` 后原 `nginx.conf` 完整还原（PASS）。

### 移除 Removed

- 删除 `core/_probe_tmp.sh`：上轮验证 `_download_verified` 摘要缺失告警机制时遗留的调试探针，混在 `core/` 源码树且引用了真实 acme.sh SHA，非产品代码。

---

## [v2026-09-21]

### 变更 Changed

- **安装完成后自动生成订阅**：安装成功即写入三份订阅文件（base64 / Clash / sing-box，权限 `0600`）并打印路径，屏幕同时保留原有的裸链接与二维码，一次拿到所有客户端可用的配置。
  - 落点：`core/handler.sh` 的 `handler_quick_install`（覆盖 `--vision` / `--xhttp` / `--fallback` 与菜单「完整安装」）在 `handler_share` 之后追加 `handler_subscription || true`；`core/main.sh` 的 `processes_xray_config`（自定义 Xray 安装）与 `processes_web_config`（SNI 安装分支）在 `--share` 之后追加 `bash share.sh --subscription || true`。
  - 根因：安装流程原先只调 `--share`；现成的「配置变更后重建订阅」机制以「订阅文件已存在」为前提，因此首次安装永远拿不到三件套 —— Clash / sing-box 用户只能自己发现菜单项 11 才有的用。
  - 三处均为 best-effort（`|| true`），订阅生成异常只告警，不中断已成功的安装。

### 安全 Security

- **修复 acme.sh 安装脚本缺失供应链校验（P0）**：`service/ssl.sh` 原先引用一个全项目从未定义的 `ACME_SH_INSTALL_SHA256`，因 `:-` 兜底恒为空，导致 `_download_verified` 的 SHA256 摘要体检被**静默跳过**，只剩「体积 ≥512B」与「`bash -n`」两道弱校验，而下载物随后以 root 身份执行。
  - 影响面：同为第三方安装脚本的 Xray（`core/handler.sh:83`）与 Docker（`service/docker.sh:54`）都内置了摘要常量，唯独 acme.sh 这一处绕开了项目在 `core/_common.sh:691` 自立的「三重体检」安全模型。
  - 修复：新增 `declare ACME_SH_INSTALL_SHA256`（实测值，同一 URL 三次独立拉取逐字节一致）与 `declare ACME_SH_REF=3.1.6`，调用点传入摘要并通过 `BRANCH=` 前缀钉住第二阶段地址（上游默认取浮动的 `master`）。两者沿用 `${VAR-default}` 约定，可用环境变量覆盖。
  - 实测验证：正确摘要通过 / 篡改摘要被拒绝并清理临时文件 / 留空摘要仍通过 —— 三条结果与预期一致，反证旧路径确实毫无摘要保护。
  - ⚠️ 残余风险：官方 bootstrap 内部执行 `$_get "$_url" | sh`，**第二阶段仍是「边下边执行」且无摘要校验**，属上游自带写法。本次修复保证第一阶段来源可信；彻底消除需改用离线安装方式（取 pinned tag 的 acme.sh 本体 + 校验摘要 + `--install`），未在本改动中实施。
  - 另注：`install_acme_sh` 末尾的 `--upgrade --auto-upgrade` 会把刚钉住的版本重新漂移到 `master`，与锁定语义冲突；本次**未改动**其运维行为，建议后续评估是否改为手动升级。

### 文档 Docs

- `README.md` / `.github/README.en.md` 同步订阅章节为「安装完成后自动生成」。
  - 修正英文版两条与新行为矛盾的旧说明：正文「users who never generated a subscription never get files created out of nowhere」及 Changelog 第 11 条第 5 点的同义表述。
  - 英文版 Changelog 追加第 12 条记录本次变更。
- **「分享链接 / 订阅文件 / 客户端怎么用」章节重写**（README 中英双语）：
  - 中文 `## 支持的客户端` → `## 分享链接、订阅文件与客户端使用`；英文 `## Supported Clients` → `## Share Links, Subscription Files & Clients`。两版均拆为四小节：屏幕输出（链接 / 二维码 / 各模式打印条数）、服务器上的三个订阅文件、各客户端导入方式、使用要点与已知限制。
  - 补上此前的实操空白：**怎么把订阅文件从服务器弄到设备上**（`cat` 复制单行 base64 / `scp` 下载 / 传到手机）—— 脚本不开放订阅 URL、不额外监听端口，文件只在服务器本机。
  - 厘清屏幕链接与订阅文件的差异：普通模式屏幕仅打印首个入站，订阅文件遍历全部入站；Fallback 打印 2 条、SNI 5 条。并写明 `--share --save`（写 `0600` 文件且屏幕不打印明文）与 `--share --no-qr` 的用途。
  - 英文版 `## Share Links`（链接规范）更名为 `## Share Link Format`，避免与新章节名混淆；并在 `## Subscription` 末尾加一条交叉引用。
- **CI 加固**（`.github/workflows/shellcheck.yml`）：
  - `runs-on` 由浮动标签 `ubuntu-latest` 钉为 `ubuntu-24.04`。官方公告 2026-10-19 起 `ubuntu-latest` 迁移至 Ubuntu 26，而本项目对 runner 镜像内容敏感 —— 曾因子标签变化使 runner 预装 nginx，导致 `backup_test` 的裸 `nginx -t` 测到系统配置而长期飘红。（ShellCheck 走 docker 官方镜像，不受 runner 换版影响。）
  - job 级固定 `LC_ALL` / `LANG` 为 `C.UTF-8`：`menu_title_test` 用 GNU `wc -L` 作独立基准校验 `_disp_width` 的 CJK 双宽计算，而 C/POSIX locale 下 `wc -L` 对多字节返回 0（中文测试：C locale=0 / C.UTF-8=8），会产出假红。设成 job 级可覆盖所有现有与未来的 step。
  - 修正第 91 行注释里遗留的 `ubuntu-latest` 字样。
- **测试临时目录治理**（`test/*.sh` 共 19 个文件 / 30 处 + `.gitignore`）：
  - 临时目录由 `.workbuddy/tmp/` 迁出到项目自有的 `test/.tmp/`（并加入 `.gitignore`）。原依赖 AI 工作区目录，属于外部依赖且可能被随时清空；迁出后归属明确。
  - **保留"仓库内固定目录"这一约定、不改用 `mktemp`** —— 这是项目的刻意选择而非疏漏：Windows/Git-Bash 下 `mktemp` 会返回 `C:\...` 反斜杠路径，既污染 `PATH` 又破坏 `awk -v` 转义与 `chmod +x` 的路径解析，会让"存在 qrencode"一类的场景假失败。该理由已写入 `.gitignore` 与相关注释。
  - 为 `i18n_parity_test.sh`、`menu_loop_test.sh`、`unknown_option_test.sh` 补 EXIT trap —— 这三个是唯一「创建了临时产物却没有清理兜底」的用例，断言失败提前退出时会把含 mock 密钥的沙箱留在磁盘上。
  - 验证：`.workbuddy/tmp` 引用归零；三个用例单跑 `rc=0` 且退出后残留为 0；完整套件 **34 用例 / 失败 0 / 全部通过**。
- **修复测试用例 locale 误判**（`test/menu_title_test.sh:44`）：`_HAS_WCL` 守卫原用纯 ASCII 的 `a` 探测 `wc -L` 可用性 —— 任何 locale 下 `a` 宽度都是 1，守卫恒真，于是 T2 拿着中文串去比对一个在非 UTF-8 环境下返回 0 的 oracle，产出 6 处假红。探测样本改为同类的 `中文`（期望 4），并修正跳过提示文案。双向验证：C locale 下正确跳过且全绿、UTF-8 下对照确实执行且全绿。

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
