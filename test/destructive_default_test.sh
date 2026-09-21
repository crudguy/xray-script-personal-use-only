#!/usr/bin/env bash
# =============================================================================
# P2-4 子项① 回归守卫: 破坏性默认项 (一键安装) 的二次确认
#
# 背景: core/main.sh 的 processes_full_installation 原实现中, 菜单项 1 与"其他情况"
#       共用 `*)` 分支 -> 空回车会**静默执行不可逆的快速安装** (exec_handler --quick Vision)。
#       界面虽以「默认」(menu.status.default) 标注该默认项, 但"敲个回车就把服务装了"
#       与用户预期不符, 且不可逆。
#
# 修复: 拆出显式 `1)` 分支(直装); `*)`(空回车/默认项) 改为二次确认, 仅 y/yes 才安装,
#       无输入源(EOF, 如 cron/管道)时保守取消并返回主菜单。
#
# 本测试抽取 core/main.sh **真实函数体** + 桩件驱动, 覆盖:
#   显式 1 / 显式 2 / 空回车 + y / Y / n / EOF / 无效值。
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
assert_contains "refs confirm_default key" "$MAIN_SRC" 'confirm_default'
assert_contains "has read confirm" "$MAIN_SRC" 'read -r reply'
assert_contains "confirms on y | yes" "$MAIN_SRC" 'y | yes'
assert_not_contains "no silent default install" "$MAIN_SRC" '其他情况 (包括 1 和默认)：执行快速安装 Vision'

FN="$(awk '/^function processes_full_installation\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$MAIN")"
assert_contains "fn extracted" "$FN" 'processes_full_installation'
assert_contains "fn has read confirm" "$FN" 'read -r reply'
assert_contains "fn installs only on y" "$FN" 'y | yes) exec_handler'

# 注: 不用裸 mktemp -d —— Windows/Git-Bash 下可能返回 "C:/..." 风格路径, MSYS 无法解析。
#     改用项目内固定目录(约定 test/.tmp/)。
TMPD="$ROOT/test/.tmp/destructive_default.$$"
rm -rf "$TMPD" 2>/dev/null || true
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT
BASH_BIN="$(command -v bash)"
printf '%s\n' "$FN" > "$TMPD/fn.sh"

# 组装 runner: 桩件 + 真实函数体
{
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'trap "echo TRAP_HIT >&2" ERR'
    printf '%s\n' 'CUR_FILE="main"'
    printf '%s\n' '_i18n() { case "$1" in'
    printf '%s\n' '  *confirm_default) printf "%s" "CONFIRM? ";;'
    printf '%s\n' '  *) printf "%s" "";;'
    printf '%s\n' 'esac; }'
    printf '%s\n' 'exec_menu() { cat "${CHFILE}"; }'
    printf '%s\n' 'exec_handler() { printf "HANDLER %s\n" "$*"; }'
    printf '%s\n' 'processes_xray() { printf "XRAY %s\n" "$*"; }'
    cat "$TMPD/fn.sh"
    printf '%s\n' 'processes_full_installation'
    printf '%s\n' 'echo "RC=$?"'
} > "$TMPD/runner.sh"

run() { # $1=choose值  $2=stdin内容(可空 -> EOF)
    printf '%s' "$1" > "$TMPD/ch"
    printf '%s' "${2-}" | CHFILE="$TMPD/ch" "$BASH_BIN" "$TMPD/runner.sh" 2>&1
}

echo "== 行为: 显式选择 =="
out1="$(run 1 '')"
assert_contains "1 -> install" "$out1" "HANDLER --quick Vision"
assert_not_contains "1 -> no confirm prompt" "$out1" "CONFIRM?"
out2="$(run 2 '')"
assert_contains "2 -> xray flow" "$out2" "XRAY n"
assert_not_contains "2 -> no install" "$out2" "HANDLER"

echo "== 行为: 空回车 + 确认 =="
out0y="$(run 0 $'y\n')"
assert_contains "empty + y -> prompt" "$out0y" "CONFIRM?"
assert_contains "empty + y -> install" "$out0y" "HANDLER --quick Vision"
out0Y="$(run 0 $'Y\n')"
assert_contains "empty + Y -> install" "$out0Y" "HANDLER --quick Vision"
out0n="$(run 0 $'n\n')"
assert_contains "empty + n -> prompt" "$out0n" "CONFIRM?"
assert_not_contains "empty + n -> no install" "$out0n" "HANDLER"
out0eof="$(run 0 '')"
assert_contains "empty + EOF -> prompt" "$out0eof" "CONFIRM?"
assert_not_contains "empty + EOF -> no install" "$out0eof" "HANDLER"
assert_not_contains "empty + EOF -> no ERR trap" "$out0eof" "TRAP_HIT"

echo "== 行为: 无效值 (保守) =="
out9="$(run 9 $'n\n')"
assert_not_contains "9 + n -> no install" "$out9" "HANDLER"

echo
echo "==== PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
