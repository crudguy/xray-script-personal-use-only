#!/usr/bin/env bash
# =============================================================================
# 完整安装子菜单 "默认/空回车" 行为守卫
#
# 背景: 此前 (P2-4) 把"菜单项 1(显式直装)"与"默认/空回车(*)"拆分, 默认项进入二次确认,
#       需再输 y 才装。但提示文案自相矛盾 —— 写着"直接回车将执行一键安装", 代码却是
#       "回车 = 取消"。于是用户敲回车 (想用默认项) 反而被导向一个需再输 y 的确认,
#       再敲回车即取消、退回主菜单, 体感"光标不动且没装上"。
#
# 修复 (用户选定 "回车即装"): 默认/空回车与显式选 1 都直接执行一键安装, 与菜单
#       "1. 一键安装 (默认)" 标注一致, 移除误导性的二次确认。
#
# 本测试抽取 core/main.sh 真实函数体 + 桩件驱动, 覆盖: 显式 1 / 空回车(0) / 选 2 / 无效值(9)。
# 纯 bash, 不依赖 jq。
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/core/main.sh"

PASS=0
FAIL=0

assert() {
    local name="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        PASS=$((PASS + 1)); printf '  ok   %-32s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %-32s got=%q want=%q\n' "$name" "$got" "$want"
    fi
}
assert_contains() {
    local name="$1" hay="$2" needle="$3"
    if [[ "$hay" == *"$needle"* ]]; then
        PASS=$((PASS + 1)); printf '  ok   %-32s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %-32s (missing %q)\n' "$name" "$needle"
    fi
}
assert_not_contains() {
    local name="$1" hay="$2" needle="$3"
    if [[ "$hay" != *"$needle"* ]]; then
        PASS=$((PASS + 1)); printf '  ok   %-32s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %-32s (unexpected %q)\n' "$name" "$needle"
    fi
}

echo "== 静态守卫: core/main.sh =="
MAIN_SRC="$(cat "$MAIN")"
assert_not_contains "no confirm_default key" "$MAIN_SRC" 'confirm_default'
assert_not_contains "no read reply confirm" "$MAIN_SRC" 'read -r reply'
assert_contains "has explicit 1 branch" "$MAIN_SRC" '1)'
assert_contains "has detailed 2 branch" "$MAIN_SRC" '2)'
assert_contains "has default * branch" "$MAIN_SRC" '*)'
assert_contains "default install target" "$MAIN_SRC" "exec_handler '--quick' 'Vision'"
assert_contains "has explicit 0->return (255) branch" "$MAIN_SRC" '255)'

FN="$(awk '/^function processes_full_installation\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$MAIN")"
assert_contains "fn extracted" "$FN" 'processes_full_installation'
assert_not_contains "fn no read reply" "$FN" 'read -r reply'

# 注: 不用裸 mktemp -d —— Windows/Git-Bash 下可能返回 "C:/..." 风格路径, MSYS 无法解析。
#     改用项目内固定目录(约定 test/.tmp/)。
TMPD="$ROOT/test/.tmp/destructive_default.$$"
rm -rf "$TMPD" 2>/dev/null || true
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT
BASH_BIN="$(command -v bash)"
printf '%s\n' "$FN" > "$TMPD/fn.sh"

# 组装 runner: 桩件 + 真实函数体 (无 confirm 相关桩件)
{
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'CUR_FILE="main"'
    printf '%s\n' '_i18n() { printf "%s" ""; }'
    printf '%s\n' 'exec_menu() { cat "${CHFILE}"; }'
    printf '%s\n' 'exec_handler() { printf "HANDLER %s\n" "$*"; }'
    printf '%s\n' 'processes_xray() { printf "XRAY %s\n" "$*"; }'
    cat "$TMPD/fn.sh"
    printf '%s\n' 'processes_full_installation'
    printf '%s\n' 'echo "RC=$?"'
} > "$TMPD/runner.sh"

run() { # $1=choose值 (exec_menu 桩件回显)
    printf '%s' "$1" > "$TMPD/ch"
    CHFILE="$TMPD/ch" "$BASH_BIN" "$TMPD/runner.sh" 2>&1
}

echo "== 行为: 显式选择 =="
out1="$(run 1)"
assert_contains "1 -> install" "$out1" "HANDLER --quick Vision"
assert_not_contains "1 -> no confirm prompt" "$out1" "CONFIRM?"
out2="$(run 2)"
assert_contains "2 -> xray flow" "$out2" "XRAY n"
assert_not_contains "2 -> no install" "$out2" "HANDLER"

echo "== 行为: 空回车 (默认) =="
out0="$(run 0)"
assert_contains "empty -> install" "$out0" "HANDLER --quick Vision"
assert_not_contains "empty -> no confirm prompt" "$out0" "CONFIRM?"

echo "== 行为: 无效值 (回车即装, 与默认一致) =="
out9="$(run 9)"
assert_contains "9 -> install" "$out9" "HANDLER --quick Vision"

echo "== 行为: 显式 0 (返回主菜单, get_choose 映射为 255) =="
out255="$(run 255)"
assert_not_contains "explicit 0 -> no install" "$out255" "HANDLER"

echo
echo "==== PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
