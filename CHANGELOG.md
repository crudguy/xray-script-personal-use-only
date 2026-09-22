# 更新日志 / Changelog

本文件记录 xray-script-personal-use-only 的所有重要变更。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号沿用本项目既有的日期版本方案（`vYYYY-MM-DD`，同日多次发布加 `.N` 后缀）。

关于 `config.json` 的 `version` 字段（勿照旧说法误解）：
它**仅用于界面展示** —— `install.sh` 的 `_sync_script_version_label` 会在安装/更新时
自动把它同步为仓库版本号，无需手工维护；而**判断"是否需要更新"以记录的 commit SHA
比对为准**（`read_local_commit_sha` vs `get_remote_commit_sha`），与版本号完全无关。
故发布时 bump 版本号只是为了让展示清晰，忘记 bump **不会**影响存量机器的自动更新。

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

## [v2026-09-22]

本版为 `v2026-09-21.1` 之后的累计批次：安全加固 + 多轮缺陷修复 + 巨型函数拆分与常量收敛 +
测试与 CI 门禁补齐（31 个文件，+1844 / −441 行）。

### 安全 Security

- **自更新固定名竞态加固（CWE-367）**：`install.sh` 的备份目录由 PID 可预测名 `${PROJECT_ROOT}.old.$$` 改为 `mktemp -u ...XXXXXX` 不可预测随机名，并在移动/删除前显式 `[[ -L ]]` 拒绝符号链接（防 root 下被预植链接穿透删除目标树）；安装器自身的原子替换由固定名改 `umask 077; mktemp ...XXXXXX`（0600）。
- **Nginx 编译期注入面收敛**：`service/nginx.sh` 的 `_error_detect` 受控 `eval` 入口保留，但把外部可控来源加白名单 —— `NGX_BROTLI_REF` 限 `^[A-Za-z0-9._/-]+$`（非法即中止 Brotli 安装）、`openssl_dir`（取自解包顶层名）限 `^[A-Za-z0-9._+-]+$`（非法回退源名并告警）。
- **规则写入杜绝字符串插值**：`core/handler.sh` 的 `add_rule` 改用 `jq -nc --arg/--argjson` 构造 JSON —— 规则含 `"`/`\`/换行时原字符串拼接会生成非法 JSON，致 jq 失败、persist 中断。
- **geodata 临时文件随机化**：`tool/geodata.sh` 的 `download_verified` 由固定名 `${dst}.new` / `${dst}.sha256sum` 改为 `mktemp --suffix` 随机名（保留后缀以兼容测试桩件；macOS 不支持 `--suffix` 时回退固定名），失败统一清理。
- **凭据不再落终端/日志**：`core/check.sh` 的 `check_password` 四处明文回显改掩码 `****(N 字符)`（Trojan 密码 / mKCP seed 不再进终端回滚、screen/tmux、录屏与 `2>log`）；`handler_x25519_config` 默认不回显 Reality 私钥，需显式 `SHOW_PRIVATE_KEY=1`。
- **去除可预测临时文件**：`tool/backup.sh` 还原流程的 `/tmp/bk_*_$$.log` 改为把 stderr 捕获进变量，消除 root 下 `/tmp` 符号链接截断覆盖竞态。
- **`share.sh --save` 拒绝写入符号链接**：root 下 `: >文件` 会**跟随**链接截断其指向的目标文件；改为显式拒绝，且保存目录按 `0700` 创建。

### 修复 Fixed

- **止血：三处崩溃/卡死** —— ①`handler_routing` 取错变量（`${XRAY_CONFIG[...]}` → `${CONFIG_DATA[...]}`），下标触发 bash 算术求值在 `set -u` 下 "unbound variable" 崩溃，致路由菜单 3/4/5/6 从未真正执行；②新增 `_common.sh:is_enabled` 统一开关归一化，修复 `jq -r` 输出的字面串 `"null"` 与用户输入的 `"Y"/"N"` 参与 `-eq` 算术比较在 `set -u` 下崩溃（主菜单状态栏 / WARP / 阻止规则）；③`test_tcp_connection` 与 `get_tls_info` 加 `timeout`，修复 DROP 目标下体检卡死约 2 分钟（`get_tls_info` 另补 `|| true`，否则 pipefail 下探测失败直接中断、走不到友好分支）。
- **体检汇总行渲染错位（ShellCheck SC2183）**：`core/check.sh` 的 `_health_summary` 在拆分时丢掉了格式串里的 `: `（10 个 `%s` 变 9 个，实参仍 10 个），printf 整体错位吃参 —— 标签与统计数字粘连，且**末尾 `${NC}` 被吞**，终端保持红色并渗染后续全部输出。
- **三处高优先级缺陷** —— ①`share.sh:cache_json_data` 未安装时给出可读提示（原本 jq 退出码 2 被 ERR trap 当成内部错误、打印陌生行号诊断），脚本配置兜底 `{}`；②`install.sh` 版本同步的**同文件管道写**改为"先取结果 → 判空 → 再写"，避免 jq 失败时把 `config.json` 覆盖成 0 字节；③换域名两条回滚路径的裸 `mv -f` 加存在性判断与容错，修复备份缺失时 `set -e` 中止导致新旧站点配置双失。
- **多项中优先级缺陷** —— `install.sh check_os` 加空值守卫（`_os_ver` 为空串时被算术上下文当成 0 → 恒成立 → 明明只是"识别不出版本"却报"版本过低"把用户拦在门外）；`nginx.sh` 的 `check_os` 改名 `check_os_nginx_build` 消除同名漂移（编译基线刻意高于通用基线，两者不应互相拉齐）；自更新由"先删后拷"改临时文件 + 原子 rename（原地覆写会让正在按偏移读取的 bash 读到新旧混杂内容），失败保留旧安装器并告警；默认配置下载失败不再静默跳过（原会写出空 `config.json`，致后续任何菜单崩溃而真因淹没）；`main.sh --health` CLI 直调 `check.sh` 并透传退出码，修复 cron 假绿；`check_xray_version_exists` 改走加速前缀并区分网络不可达（`000`）与版本不存在（404）；`ssl.sh` 私钥收紧失败不再静默回落 644，改为明确告警；geodata/nginx cron 未安装时补告警（原静默零反馈）；`share.sh` 两处 `--argjson port` 加数字守卫（空串/非数字会让 jq 报错并在 `set -e` 下中断整轮订阅生成）；英文 `ubuntu` 文案 "18+" 订正为 "16+"。
- **一键安装装完却没有分享链接**：`install.sh` 对第三方 `install-release.sh` 的可容忍非零退出码做容错（`rm` 删除不存在的 systemd drop-in 会使其非零退出，被 `set -Eeuo` 误当致命而中断），改用 xray 二进制产物做校验。
- **体检输出显示字面 `\033`**：颜色变量改用 ANSI-C 引号（`$'\033[...'`），修复查看体检结果时的转义乱码。
- **完整安装子菜单交互**：「默认 / 空回车」改为直接进入一键安装，移除与之矛盾的二次确认。
- **`source_update` 升级备份**：旧二进制缺失时跳过备份（原裸 `mv` 在 `set -e` 下会让刚完成的重编译半途而废）；备份名由天精度 `date +%F` 改秒精度 `%Y%m%d_%H%M%S`，防同日二次升级静默覆盖前次备份；缺失时 `print_warn`。
- **测试框架自身缺陷**：`menu_loop_test` ①桩件仍认 `exec_menu --index`，而产品早已改成单次 `--index-full`，导致队列永不消费、断言必挂；②结尾只打印 FAIL 却没有 `exit` 非零，而 `run_tests.sh`/CI 只按退出码计成败 —— 两者叠加使该失效用例长期静默假绿。

### 变更 Changed

- **主菜单读取性能**：主循环每轮 3 次 fork `menu.sh`（banner / status / index）合并为单次 `--index-full`，只加载一次 i18n —— 实测约 64ms 降至约 22ms；渲染 37 行与原先逐字一致，选择语义（`5→5` / `1→1` / `0→255`）端到端验证等价。
- **巨型函数拆分（可维护性，行为逐字符等价）**：`check_health_report`（539 行）→ 编排器 + 8 个 `_health_*` 分区 + `_health_summary`；`check_net_status`（163 行）→ 编排器 + `_net_collect`（只读采集）+ `_net_render`（渲染并算退出码）；`handler_xray_config`（140 行）→ 编排器 + 4 个 `_xray_*`；`handler_custom_site_update`（110 行）与 `handler_change_domain`（101 行）同样拆分；`show_sni_config`（48 行）→ 编排器 + 5 个 `_sni_block_*`。统一复用 bash 动态作用域做到零参数传递样板。
- **常量/正则单一来源**：`DOMAIN_REGEX`、`EMAIL_REGEX` 各两份副本收敛到 `core/_common.sh`（消除"改一处漏一处"的副本漂移）；用法错误退出码由散落 3 处的裸 `exit 2` 收口为 `readonly EXIT_USAGE=2`。
- **DRY**：新增 `_remove_site_conf <domain>` 收口散落的站点清理 `rm` 对；`nginx.sh` 抽取 `_fetch_github_tag` 收敛两处逐字重复的版本获取管道，并改为先把响应收进变量再处理（消除 `head -1` 让仍在写的 `wget` 收到 SIGPIPE 141、污染整条管道退出码）。
- **健壮性与体验**：`menu.sh` banner 在窄终端（<80 列）降级为单行标题，避免约 70 字符的 ASCII art 折行乱版；`_common.sh` 加 INT/TERM trap（明确提示并以 130 退出，便于区分"被中断"与"脚本出错"）；`check_port` 用 `10#${port}` 强制十进制，修复输入 `08` 时先甩出 bash 内部算术噪声；完整安装子菜单新增「0. 返回主菜单」；交互式一键安装完成后加过渡提示（行为不变，分享信息照常展示后回到管理菜单）。

### 移除 Removed

- 删除 `core/handler.sh` 中零调用的 `_sed_in_place`：它与 `_common.sh:_replace_in_file` 确立的"读-改-写"原子写方向相反，留着会诱导复发。
- 删除 `tool/backup.sh` 遗留的 `[debug]` echo。

### 文档 Docs

- **README 客户端对照表订正**：NekoBox 仅 Android、NekoRay 已停更、Clash for Android 已停更、补齐 Linux、补 Hiddify；v2rayN 标注为跨平台（v7.x 起 Avalonia 重写）并合并至桌面三平台行；补 v2rayNG 仅 Android。
- 补全 `XRAY_INSTALL_REF` 硬编码 commit 的自文档化注记（可核验的 commit URL + REF/SHA256 成对更新流程 + fail-closed 不变量）；订正 `CHANGELOG` 前言中已过时的"更新判据"说法（实际以 commit SHA 比对为准，版本号仅供展示）。
- **测试补齐**：新增 `valid_domain`、`clash_build_proxy`、`gen_cflags`、`systemctl_config_nginx`、`handler_net_tune`、`show_sni_config`、`health_summary` 单测，以及 `install.sh` / `_common.sh` 的 OS 检测防漂移同步守卫（均含负向校验）；修复 `menu_loop_test` 的两处既存缺陷（见「修复」末条）。
- **CI**：修复本批次引入的 8 处 ShellCheck `-S warning` 门禁回归（4×SC2155、2×SC2034、1×SC2154、1×SC2183），恢复主门禁 rc=0 与存量债务棘轮 0/0/0。

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
