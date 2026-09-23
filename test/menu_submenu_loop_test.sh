#!/usr/bin/env bash
# =============================================================================
# 测试名称: menu_submenu_loop_test.sh
# 测试目标: 分治方案落地后的子菜单循环语义 ——
#   1) 多选项任务型子菜单 (routing / backup / config ...) 成功操作后"留在原菜单"
#      (循环重渲染), 选 0/EOF 才退回上级; 不再每次都弹回主菜单。
#   2) 守卫 (WARP 未开 / 备份空路径) 用 continue 留在原菜单, 便于改填/改选后重试,
#      而非一路退回主菜单。
#   3) 整菜单不适用型 (processes_sni_config 非 SNI) 保持一次性: 守卫 return 0 直接
#      退回上级, 不循环重渲染菜单。
#
# 设计: 桩件化 exec_menu (消费式队列文件, 读一项推进一项) / exec_handler (记录) /
#       _require_warp_enabled (可注入开关) / 其余子流程 no-op; 抽取真实 processes_*
#       函数体运行。消费式队列是必须的: 真实菜单每次迭代都从 TTY 读新输入, 固定输入
#       若被反复读取会死循环; 队列推进精确模拟"每次读一条新选择"。
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/core/main.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s%s\n' "$1" "${2:+ ($2)}"; }
assert_contains()     { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing $(printf '%q' "$3")"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "unexpected $(printf '%q' "$3")"; fi; }
assert_eq()           { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got '$2' want '$3'"; fi; }

TMPD="$ROOT/.workbuddy/tmp/menu_submenu_loop.$$"
rm -rf "$TMPD" 2>/dev/null || true
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT
BASH_BIN="$(command -v bash)"

extract() { awk -v fn="$1" '$0 == "function " fn "() {" {f=1} f {print} f && /^}$/ {exit}' "$MAIN"; }

FN_ROUTE="$(extract processes_routing)"
FN_BAK="$(extract processes_backup)"
FN_CFG="$(extract processes_config)"
FN_SNI="$(extract processes_sni_config)"

# 通用桩件 + 注入被测函数体, 生成 runner
build_runner() { # $1=输出文件 $2=入口调用 $3=warp_rc $4=函数体文件
    {
        printf '%s\n' 'set -Eeuo pipefail'
        printf '%s\n' 'CUR_FILE="main"'
        printf '%s\n' 'GREEN=""; NC=""; RED=""; YELLOW=""'
        printf '%s\n' '_i18n() { printf "%s" "$1"; }'
        printf '%s\n' 'print_warn() { printf "WARN %s\n" "$*" >&2; }'
        printf '%s\n' '_error() { printf "ERROR %s\n" "$*" >&2; exit 1; }'
        printf '%s\n' 'exec_handler() { printf "HANDLER %s\n" "$*" >&2; }'
        printf '%s\n' "_require_warp_enabled() { if [[ $3 -eq 0 ]]; then return 0; fi; print_warn \"warp disabled\"; return 1; }"
        # 消费式队列: 读 CHFILE 首行并推进, 模拟"每次迭代读一条新选择"
        printf '%s\n' 'exec_menu() { printf "MENUCALL %s\n" "$*" >&2; local f="${CHFILE:-/dev/null}"; local first rest; if [[ -s "$f" ]]; then first="$(head -n 1 "$f" 2>/dev/null)"; rest="$(tail -n +2 "$f" 2>/dev/null)"; printf %s\n "$rest" > "$f"; fi; printf %s "${first:-}"; }'
        # 其余子流程 no-op (被测函数内部调用时不应真正执行)
        printf '%s\n' 'processes_xray_config() { :; }'
        printf '%s\n' 'processes_language() { :; }'
        printf '%s\n' 'processes_bbr() { :; }'
        printf '%s\n' 'processes_backup() { :; }'
        printf '%s\n' 'processes_routing() { :; }'
        printf '%s\n' 'processes_sni_config() { :; }'
        printf '%s\n' 'processes_web_config() { :; }'
        printf '%s\n' 'processes_ca_vendor() { :; }'
        printf '%s\n' 'processes_custom_sites() { :; }'
        printf '%s\n' 'load_i18n() { :; }'
        printf '%s\n' "$4"                         # 注入真实被测函数体 (覆盖上方 no-op 桩)
        printf '%s\n' "$2"
        printf '%s\n' 'printf "RC=%s\n" "$?"'
    } > "$1"
}

# $1=函数体文件 $2=入口 $3=warp_rc $4=stdin(可选, 用于备份导入读取归档路径)
run_one() {
    build_runner "$TMPD/runner.sh" "$2" "$3" "$1"
    if [[ -n "${4:-}" ]]; then
        printf '%b' "$4" | CHFILE="$TMPD/q" SCRIPT_CONFIG_PATH="$TMPD/cfg.json" "$BASH_BIN" "$TMPD/runner.sh" 2>&1
    else
        CHFILE="$TMPD/q" SCRIPT_CONFIG_PATH="$TMPD/cfg.json" "$BASH_BIN" "$TMPD/runner.sh" 2>&1
    fi
}
# 把选择序列写入队列文件 (每行一个选择; 末位 0 = 退回上级)
set_queue() { : > "$TMPD/q"; printf '%s\n' "$1" >> "$TMPD/q"; }
count_menucall() { printf '%s' "$1" | grep -c "MENUCALL $2" 2>/dev/null || true; }

printf '{"xray":{"tag":"vision"}}\n' > "$TMPD/cfg.json"   # 默认非 SNI; 仅 sni 场景依赖

# ---------------------------------------------------------------------------
echo "[T1] routing 成功操作后留在原菜单 (循环重渲染), 选 0 才退出"
# ---------------------------------------------------------------------------
set_queue $'3\n0'                       # 选 3 添加 block-ip -> 留在路由菜单 -> 选 0 退出
out="$(run_one "$FN_ROUTE" 'processes_routing' 0)"
assert_eq     "T1: 路由菜单渲染次数=2 (成功后仍留菜单)" "$(count_menucall "$out" '--route')" "2"
assert_contains "T1: 执行了 block-ip 分流"            "$out" 'HANDLER --routing block ip'
assert_contains "T1: 成功后触发 Xray 重启"            "$out" 'HANDLER --restart'
assert_contains "T1: 正常返回 (RC=0)"                "$out" 'RC=0'

# ---------------------------------------------------------------------------
echo "[T2] routing WARP 守卫用 continue 留在原菜单 (不退出/不进 handler)"
# ---------------------------------------------------------------------------
set_queue $'5\n0'                       # 选 5 WARP-ip, 但 WARP 未开 -> 提示并留在菜单 -> 选 0 退出
out="$(run_one "$FN_ROUTE" 'processes_routing' 1)"   # warp_rc=1 模拟"未开启"
assert_eq     "T2: 路由菜单渲染次数=2 (守卫后仍留菜单)" "$(count_menucall "$out" '--route')" "2"
assert_contains "T2: 输出警告提示"                  "$out" 'WARN'
assert_not_contains "T2: 守卫未进 handler"          "$out" 'HANDLER'
assert_not_contains "T2: 守卫未触发重启"            "$out" '--restart'
assert_contains "T2: 正常返回 (RC=0)"              "$out" 'RC=0'

# ---------------------------------------------------------------------------
echo "[T3] backup 空路径守卫用 continue 留在原菜单 (便于改填路径重试)"
# ---------------------------------------------------------------------------
set_queue $'2\n0'                       # 选 2 导入 -> 空路径 -> 提示并留在菜单 -> 选 0 退出
out="$(run_one "$FN_BAK" 'processes_backup' 0 '\n')"  # stdin 空行 = 未填归档路径
assert_eq     "T3: 备份菜单渲染次数=2 (空路径后仍留菜单)" "$(count_menucall "$out" '--backup')" "2"
assert_contains "T3: 输出警告提示"                    "$out" 'WARN'
assert_not_contains "T3: 空路径未调用 handler"        "$out" 'HANDLER'
assert_contains "T3: 正常返回 (RC=0)"               "$out" 'RC=0'

# ---------------------------------------------------------------------------
echo "[T4] sni 非 SNI 保持一次性: 守卫 return 0 直接退回上级, 不循环重渲染"
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
    set_queue $'0'                       # 即便有输入, 守卫也应在进菜单前 return
    out="$(run_one "$FN_SNI" 'processes_sni_config' 0)"
    assert_eq     "T4: SNI 菜单渲染次数=0 (守卫在进菜单前 return, 不循环)" "$(count_menucall "$out" '--sni')" "0"
    assert_contains "T4: 输出 not_support 警告"     "$out" '.main.not_support'
    assert_not_contains "T4: 未进任何动作"          "$out" 'HANDLER'
    assert_contains "T4: 正常返回 (RC=0)"           "$out" 'RC=0'
else
    echo "  SKIP T4: 缺少 jq"
fi

# ---------------------------------------------------------------------------
echo "[T5] config 成功操作后留在原菜单 (循环重渲染), 选 0 才退回主菜单"
# ---------------------------------------------------------------------------
set_queue $'6\n0'                       # 选 6 设置语言 (no-op) -> 留在管理菜单 -> 选 0 退出
out="$(run_one "$FN_CFG" 'processes_config' 0)"
assert_eq     "T5: 管理菜单渲染次数=2 (成功后仍留菜单)" "$(count_menucall "$out" '--management')" "2"
assert_contains "T5: 正常返回 (RC=0)"                "$out" 'RC=0'

echo
echo "==== menu_submenu_loop_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
