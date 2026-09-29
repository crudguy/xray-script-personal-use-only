# 测试套件说明

本目录是可一键运行的行为测试套件。它跑的是**真实业务代码**（抽函数体 / 起子进程），
只替换"读盘"与"网络"，因此**完全离线**、不写宿主机、跑完自清理。

## 一键运行

```bash
bash test/run_tests.sh              # 全量（约 8 分钟，建议放后台）
bash test/run_tests.sh <关键字>      # 只跑文件名含关键字的用例，如 ssl / menu / handler
TEST_REPORT=/tmp/r.txt bash test/run_tests.sh   # 指定报告落点
```

退出码：`0` 全部通过；`1` 有用例失败或未匹配到用例。`ci-local.sh` 与 GitHub CI 均只依赖此语义。

推荐本地复现用 `bash ci-local.sh`（五个阶段：语法 → 行尾 → ShellCheck → 行为测试 → 债务棘轮）；
本机"有 docker CLI 但连不上 socket"时加 `--no-shellcheck` 跳过第 3 阶段。

## 目录结构

```
test/
├── run_tests.sh            # 入口：逐个执行 *_test.sh，计时、汇总、出报告
├── _harness.sh             # 共享工具库（断言/沙箱/计时/桩件），被新增用例 source
├── config.env              # 集中配置：路径、地址、账号夹具、超时（唯一改环境的地方）
├── README.md               # 本文件
└── *_test.sh               # 用例，一个文件 = 一个模块/场景（80 个）
```

命名约定：`*_test.sh` 才会被 `run_tests.sh` 发现。`_harness.sh`、`config.env`、
`target_probe.sh`（需真实网络的探测脚本，刻意不进 CI）都不匹配该 glob。

用例按模块分组，从文件名可直接看出归属：

| 前缀 / 关键字 | 覆盖对象 |
|---|---|
| `handler_*` | `core/handler.sh` 的分派臂（本套件重点，51 条臂已基本覆盖） |
| `menu_*` | 菜单渲染、编号、返回项、循环与跳转（界面交互） |
| `nginx_*` / `ssl_*` | `service/nginx.sh`、`service/ssl.sh` |
| `*_arm_test` | 单条 handler 臂的行为回归 |
| `i18n_*` | 中英文案键一致性与占位符替换 |
| `share_*` / `subscription_*` | 分享链接与订阅产物 |
| `install_*` / `target_*` | 安装器与 target 预设 |

## 环境依赖

必需（Linux CI 通常自带）：

| 依赖 | 用途 | 安装 |
|---|---|---|
| `bash` ≥ 5.0 | 执行用例；`EPOCHREALTIME` 用于计时（老版本退化为 0，不影响正确性） | 系统自带 |
| `jq` | 构造与校验配置 JSON；大量用例直接比对 jq 输出 | `apt-get install -y jq` / `yum install -y jq` |
| `awk` / `sed` / `grep` | 抽真实函数体、文本断言 | 系统自带 |
| `base64` | 订阅产物的编解码断言 | `coreutils` 自带 |

可选（仅门禁用，不跑行为测试也行）：

| 依赖 | 用途 | 安装 |
|---|---|---|
| `shellcheck` v0.10.0 | 静态门禁（`-S warning`）与债务棘轮 | `docker run koalaman/shellcheck:v0.10.0`，或下载 release 二进制 |
| `docker` | `ci-local.sh` 第 3 阶段用 CI 同镜像跑 ShellCheck | 见官方文档 |

**不依赖网络**：所有网络行为都用桩件（curl / systemctl / ip 等）替换。若某个用例真发了请求，
会导致 CI 随机飘红 —— 新增用例时请沿用 `h_stub` 或直接重定义命令函数。

## 配置集中管理

`test/config.env` 是**唯一**改环境的地方，被 `_harness.sh` 自动 source。覆盖优先级：
外部 `export` 的环境变量 > 文件内按 `TEST_PROFILE` 给的值。

```bash
TEST_PROFILE=ci bash test/run_tests.sh                  # 切换环境档位
TEST_XRAY_CONFIG_PATH=/path/c.json bash test/run_tests.sh share
```

主要配置项：

| 配置 | 含义 |
|---|---|
| `TEST_PROFILE` | 环境档位（`local` / `ci`），当前两者同为"沙箱 + 离线" |
| `TEST_TMP_DIR` | 临时产物根目录，默认 `.workbuddy/tmp/`（不污染项目根） |
| `TEST_XRAY_CONFIG_PATH`、`TEST_NGINX_*` | 业务安装路径，与 `core/handler.sh` 的 readonly 常量同名同义 |
| `TEST_WARP_API_URL`、`TEST_GITHUB_API_URL`、`TEST_ACME_SERVER_*` | 外部服务地址，**仅供比对/注入，不会真连** |
| `TEST_DOMAIN_*`、`TEST_ACME_EMAIL` | 域名与账号夹具，全部为 `example.com` / `.invalid` 保留域假值 |
| `TEST_TIMEOUT_SHORT` / `LONG` | 等待类超时，避免"本地快 CI 慢"造成偶发红 |
| `TEST_PUBLIC_IP_TTL` | 公网 IP 缓存 TTL；验证过期需显式调小，别干等 600s |

## 编写用例

**新增用例必须** source `_harness.sh`，复用断言与沙箱，不要各抄一份 `ok/bad/assert_eq`
（存量 81 个里有 37 处重复定义，历史上一处"期望/实际标反"排查方向被带偏过）。

### 存量 78 个为什么刻意不迁（以及什么时候才该迁）

当前 81 个用例里只有 3 个在用 harness（`handler_arms_coverage` / `heal_mkcp` /
`mkcp_finalmask`），其余 78 个各写一份断言助手。**这不是"漏做了"，是权衡后的选择**：

存量用例没有一个是抄来的样板 —— 各自带着为自己定制的桩件、负向校验与沙箱约定（不少是
针对某个具体坑写的，比如"注释行不算定时任务就位"）。整批换到 harness 的**收益**只是少几
行重复定义，**风险**却是把已经稳定的断言语义动一遍；而负向校验最怕的失效方式恰好最难
发现：断言被改写成恒绿之后它**仍然绿着**，全量测试只能证明"没变红"，证明不了"没变恒绿"。

所以统一化停在"新增用例走 harness"这条线上。只有出现下面这些情况，才值得迁一个存量用例：

1. 这个用例**正在被大改**（改桩件 / 加场景 / 重写断言）—— 顺手迁，成本摊在大改里;
2. 它要**新接外部依赖或路径**，而 `config.env` 里已经有对应夹具 —— 迁了才真复用得上;
3. 重复定义**真的造成了问题**（如某处期望/实际又标反了）—— 定点修，不动其它。

**不要**为了"统一"而批量迁移：那是用可观测的收益（少几行重复）去换不可观测的风险
（守护静默失效）。

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=_harness.sh
source "$(dirname "$0")/_harness.sh"
h_init 'my_test'
h_sandbox >/dev/null
SB="${H_SANDBOX}"

h_case 'G1 正常流程'
# 意图: 说明这条断言在守护什么、为什么必须成立（写给人看，不是写给机器）
h_assert_eq 'T1 端口' "$(got)" '443'

h_finish   # 打印通过率与耗时；有失败则退出 1
```

断言参数顺序（**与全仓一致，不要改**）：`h_assert_eq <标签> <实际值> <期望值>`。
反着写也能跑通（值相等时不显形），但跨文件复制会静默反接，失败时才暴露，
而那时"期望/实际"的标注也是反的。

三条硬约定：

1. **抽真实函数体，不另写实现** —— `awk` 从源码抽出函数再 `eval` 注入，避免测试与源码漂移。
2. **必须做负向校验（NEG）** —— 把源码改坏，确认对应断言真的变红。全绿的用例未必在守护任何东西。
   注意校验"变异是否真落地"（用 `cmp` 比对副本与源文件），否则模式串写错时 NEG 会拿未改的源码去跑，
   结果既非红也非绿，而是**根本没验证**。
3. **不修改业务代码** —— 用例只观察与注入，不改 `core/`、`service/`、`tool/`。

## 报告

跑完默认生成 `.workbuddy/tmp/test-report.txt`，同时打印到终端。内容包含：
每个用例的输出与耗时、用例数/通过/失败、**用例通过率**、**总耗时**、**耗时最长 Top5**，
以及失败明细（用例名 + 期望值 + 实际值）。

通过率口径：**用例级**（一个文件成功即算通过）。断言级通过率由各用例自行汇总打印
（用 `_harness.sh` 的用例会在末尾打印"断言 N，通过 N，失败 N，通过率 X%"）。
两级分开是为了不让"某文件里断言多"扭曲整体结论。

## 接入持续集成

已接入：`.github/workflows/shellcheck.yml` 的"行为测试"步骤执行 `bash test/run_tests.sh`。

要接入其他 CI，只需保证：

1. 运行环境有 `bash` ≥ 5.0、`jq`、`awk`、`base64`（见"环境依赖"）。
2. 固定 UTF-8：`LC_ALL=C.UTF-8`。`menu_title_test` 用 `wc -L` 校验 CJK 双宽计算，
   在 C/POSIX locale 下会返回 0 从而产出假红。
3. 执行 `bash test/run_tests.sh`，按退出码判成败；报告文件可直接作为构建产物归档。
4. 需要区分环境时设置 `TEST_PROFILE` 与 `TEST_REPORT`，不必改用例。

建议的门禁顺序（与 `ci-local.sh` 一致）：`bash -n` → 行尾守卫 → ShellCheck → **行为测试** → 债务棘轮。
静态检查抓不到"取消却已经动手""非法入参却照常重置"这类语义错误，行为测试是唯一能发现它们的环节。
