#!/usr/bin/env bash
# systemctl_config_nginx 结构守卫测试 (纯 bash, 不写 /etc, 无副作用)
#
# 该函数把 Nginx 的 systemd 单元内容以 here-doc 形式生成到
# /etc/systemd/system/nginx.service —— 在 CI/沙箱里 /etc 只读, 无法真跑并落盘,
# 故改为"抽取生成产物并解析校验", 锁定单元文件契约不被误删/改错:
#   1. 三段齐全: [Unit] / [Service] / [Install];
#   2. 关键字段存在且取值正确 (Type=forking 与 PIDFile 配套, Exec* 命令齐全);
#   3. 产物是合法 INI 形态: 每个非空行只能是段头 `[x]` 或 `Key=Value`;
#   4. 字段归属正确 (Exec* 在 [Service], WantedBy 在 [Install]);
#   5. 副作用契约: 先建后清 /dev/shm/nginx (tcmalloc 共享内存), 且调 systemctl daemon-reload。
#
# 防回归: 误删 ExecStop/ExecStopPost (会导致服务停止后共享内存泄漏)、
#         把 Type 改成 simple (与 PIDFile 语义冲突)、漏 daemon-reload (配置不生效)。
# 运行: bash test/systemctl_config_nginx_test.sh
set -Eeuo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
# 断言整段函数体含某字面串
has() { if printf '%s' "$FUNC_SRC" | grep -qF -- "$1"; then ok; else bad "$2 (缺: $1)"; fi; }
# 断言产物(去掉注释/空行后)含某行
unit_has() { if printf '%s' "$UNIT" | grep -qxF -- "$1"; then ok; else bad "$2 (单元文件缺行: $1)"; fi; }

# --- 抽取函数体 (不加载整个 nginx.sh, 避免顶层副作用) ---
FUNC_SRC="$(awk '/^function systemctl_config_nginx\(\) \{/{f=1} f{print} f&&/^}/{exit}' service/nginx.sh)"
if [[ -z "$FUNC_SRC" ]]; then
    echo "  [FAIL] 无法从 service/nginx.sh 抽取 systemctl_config_nginx 函数体"
    exit 1
fi

# --- 抽取 here-doc 产物 (去掉行尾注释与空行, 便于按行精确比对) ---
UNIT="$(printf '%s\n' "$FUNC_SRC" | awk '
    /<<EOF/ { grab=1; next }
    grab && /^EOF[[:space:]]*$/ { grab=0; next }
    grab { sub(/[[:space:]]*#.*$/, ""); if ($0 != "") print }
')"
if [[ -z "$UNIT" ]]; then
    echo "  [FAIL] 未能从函数体中抽取 here-doc 单元产物"
    exit 1
fi

# ---- T1 三段齐全 ----
unit_has "[Unit]" "T1: 应有 [Unit] 段"
unit_has "[Service]" "T1: 应有 [Service] 段"
unit_has "[Install]" "T1: 应有 [Install] 段"

# ---- T2 启动类型与 PIDFile 配套 ----
unit_has "Type=forking" "T2: Type 应为 forking (与 PIDFile 配套)"
unit_has "PIDFile=/run/nginx.pid" "T2: 应声明 PIDFile=/run/nginx.pid"

# ---- T3 Exec* 命令齐全 ----
has "ExecStart=/usr/sbin/nginx" "T3: 应存在 ExecStart 启动命令"
has "ExecReload=/usr/sbin/nginx" "T3: 应存在 ExecReload 重载命令"
has "ExecStop=/bin/kill -s QUIT" "T3: 应存在 ExecStop 停止命令 (QUIT 优雅退出)"

# ---- T4 ExecStartPre 建共享内存目录并授权 ----
has "ExecStartPre=/bin/rm -rf /dev/shm/nginx" "T4: 启动前应清理旧共享内存目录"
has "ExecStartPre=/bin/mkdir /dev/shm/nginx" "T4: 启动前应创建共享内存目录"
has "ExecStartPre=/bin/chown nginx:nginx /dev/shm/nginx" "T4: 共享内存目录应授权给 nginx 用户"

# ---- T5 ExecStopPost 对称清理 (防共享内存泄漏) ----
has "ExecStopPost=/bin/rm -rf /dev/shm/nginx" "T5: 停止后应清理共享内存目录"

# ---- T6 运行隔离与超时 ----
unit_has "TimeoutStopSec=5" "T6: 应有停止超时 TimeoutStopSec"
unit_has "KillMode=mixed" "T6: 应有 KillMode=mixed"
unit_has "PrivateTmp=true" "T6: 应启用 PrivateTmp"

# ---- T7 安装目标 ----
unit_has "WantedBy=multi-user.target" "T7: [Install] 应声明 WantedBy=multi-user.target"

# ---- T8 写入路径正确 ----
has "/etc/systemd/system/nginx.service" "T8: 单元应写入 /etc/systemd/system/nginx.service"

# ---- T9 前置用户保障与生效动作 ----
has "_ensure_nginx_user" "T9: 写单元前应确保 nginx 用户存在"
has "systemctl daemon-reload" "T9: 写完单元应执行 systemctl daemon-reload"

# ---- T10 产物为合法 INI 形态: 每行只能是段头或 Key=Value ----
ini_bad="$(
    printf '%s\n' "$UNIT" | grep -vE '^(\[[A-Za-z]+\]|[A-Za-z][A-Za-z0-9]*=.*)$' || true
)"
if [[ -z "$ini_bad" ]]; then
    ok
else
    bad "T10: 单元产物含非 INI 行: $(printf '%s' "$ini_bad" | tr '\n' '|')"
fi

# ---- T11 字段归属: Exec* 必须落在 [Service]; WantedBy 必须落在 [Install] ----
section_of() { # $1=key -> 打印其所在段名
    printf '%s\n' "$UNIT" | awk -v k="$1" '
        /^\[/ { s=$0; gsub(/[][]/,"",s) }
        $0 ~ "^"k"=" { print s; exit }
    '
}
svc_exec="$(section_of "ExecStart")"
ins_want="$(section_of "WantedBy")"
if [[ "$svc_exec" == "Service" ]]; then ok; else bad "T11: ExecStart 应在 [Service] 段 (实际: ${svc_exec:-无})"; fi
if [[ "$ins_want" == "Install" ]]; then ok; else bad "T11: WantedBy 应在 [Install] 段 (实际: ${ins_want:-无})"; fi

echo
echo "==== systemctl_config_nginx_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
