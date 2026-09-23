#!/usr/bin/env bash
# shellcheck disable=SC2034  # out_zh/out_none 仅用于吞掉 run_lang 的回显, 断言走 $TMPD 下的日志文件, 故取值未被读取。
# =============================================================================
# P2-4 子项② 回归守卫: 语言切换后回到原菜单层级
#
# 背景: core/main.sh 的 processes_language 改完语言后重启脚本
#       (`bash "${CUR_DIR}/${CUR_FILE}.sh" && exit 0`) 以重载 i18n。原实现重启时
#       不带任何参数 -> 新进程走到 processes_index, 用户被丢回主菜单, **丢失刚
#       才所在的层级** (例如从「配置管理」→「设置语言」切完, 却回不到配置管理)。
#
# 修复: processes_language 接收来源菜单名 $1, 重启时带 `--menu <名称>`;
#       main() 新增内部 `--menu` 分发给 _return_to_menu, 把名称映射回
#       processes_config 等入口 (缺省/未知 -> processes_index 主菜单)。
#
# 本测试抽取 core/main.sh **真实函数体** + 桩件驱动, 覆盖:
#   - 静态契约 (重启行带 --menu / 调用点传 'config' / --menu 分发给 _return_to_menu);
#   - 行为: 切换语言 (zh/en) 时重启命令确实带 `--menu config`;
#   - 行为: _return_to_menu 的名称映射 (config / index / 未知 / 缺省);
#   - 对照: 无目标时 (等价于旧实现) 落到主菜单 -> 说明本修复确有必要。
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
        PASS=$((PASS + 1)); printf '  ok   %-34s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %-34s got=%q want=%q\n' "$name" "$got" "$want"
    fi
}
assert_contains() {
    local name="$1" hay="$2" needle="$3"
    if [[ "$hay" == *"$needle"* ]]; then
        PASS=$((PASS + 1)); printf '  ok   %-34s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %-34s (missing %q)\n' "$name" "$needle"
    fi
}
assert_not_contains() {
    local name="$1" hay="$2" needle="$3"
    if [[ "$hay" != *"$needle"* ]]; then
        PASS=$((PASS + 1)); printf '  ok   %-34s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %-34s (unexpected %q)\n' "$name" "$needle"
    fi
}

echo "== 静态守卫: core/main.sh =="
MAIN_SRC="$(cat "$MAIN")"
assert_contains "restart carries --menu"    "$MAIN_SRC" 'bash "${CUR_DIR}/${CUR_FILE}.sh" --menu "${return_to}"'
assert_not_contains "old restart removed"   "$MAIN_SRC" 'bash "${CUR_DIR}/${CUR_FILE}.sh" && exit 0'
assert_contains "call site passes config"   "$MAIN_SRC" "processes_language 'config'"
assert_contains "main dispatches --menu"    "$MAIN_SRC" '--menu) _return_to_menu'
assert_contains "rtm maps config"           "$MAIN_SRC" 'config) processes_config'

# --menu 必须排在 main() 末尾 `*)` 之前, 否则会被当成未知参数落回主菜单
# 注: 用 main() 分支的精确字面串 (`${2:-}` 透传), 避免误匹配 _return_to_menu 内的 `*)`
LN_MENU="$(grep -nF -- '--menu) _return_to_menu' "$MAIN" | head -1 | cut -d: -f1)"
LN_STAR="$(grep -nF -- '*) processes_index "${2:-}"' "$MAIN" | head -1 | cut -d: -f1)"
if [[ -n "$LN_MENU" && -n "$LN_STAR" && "$LN_MENU" -lt "$LN_STAR" ]]; then
    PASS=$((PASS + 1)); printf '  ok   %-34s\n' "--menu before *)"
else
    FAIL=$((FAIL + 1)); printf '  FAIL %-34s (menu=%s star=%s)\n' "--menu before *)" "${LN_MENU:-?}" "${LN_STAR:-?}"
fi

# 内部选项不应出现在面向用户的用法说明里
assert_not_contains "usage hides --menu" "$(cat "$ROOT/i18n/zh.json")" '--menu'

FN_LANG="$(awk '/^function processes_language\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$MAIN")"
FN_RTM="$(awk '/^function _return_to_menu\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$MAIN")"
assert_contains "fn processes_language extracted" "$FN_LANG" 'processes_language'
assert_contains "fn _return_to_menu extracted"    "$FN_RTM" '_return_to_menu'
assert_contains "rtm enters main loop"            "$FN_RTM" 'processes_index'

# 注: 不用裸 mktemp -d —— Windows/Git-Bash 下可能返回 "C:/..." 风格路径, MSYS 无法解析。
#     改用项目内固定目录(约定 .workbuddy/tmp/)。
TMPD="$ROOT/.workbuddy/tmp/language_return.$$"
rm -rf "$TMPD" 2>/dev/null || true
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT
BASH_BIN="$(command -v bash)"

# ---- runner: 真实 processes_language + 桩件 -------------------------------
printf '%s\n' "$FN_LANG" > "$TMPD/fn_lang.sh"
{
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'trap "echo TRAP_HIT >&2" ERR'
    printf '%s\n' "CUR_DIR='$ROOT/core'"
    printf '%s\n' "CUR_FILE='main'"
    printf '%s\n' "SCRIPT_CONFIG_PATH='$TMPD/config.json'"
    printf '%s\n' 'LANG_PARAM=""'
    printf '%s\n' 'SCRIPT_CONFIG=""'
    # jq 桩: 模拟 `.language = $language` 的写入结果, 便于断言落盘语言
    printf '%s\n' 'jq() { if [[ "${1:-}" == "--arg" && "${2:-}" == "language" ]]; then'
    printf '%s\n' '           printf %s "{\"language\":\"$3\"}";'
    printf '%s\n' '       else cat "${5:-$(cat)}" 2>/dev/null || true; fi; }'
    printf '%s\n' '_atomic_write() { cat > "$1"; }'
    # _release_lock 在本测试里是 no-op: 不模拟父进程持锁, 只验证重启命令形态
    printf '%s\n' '_release_lock() { :; }'
    # bash 桩: 记下重启命令(参数), 不真正拉起新进程; 返回 0 以走到 `&& exit 0`
    printf '%s\n' 'bash() { printf "%s\n" "$*" >> "${BASHLOG}"; return 0; }'
    printf '%s\n' 'exec_menu() { cat "${CHFILE}"; }'
    cat "$TMPD/fn_lang.sh"
    printf '%s\n' 'processes_language "${1:-}"'
    printf '%s\n' 'echo "NO_EXIT"'
} > "$TMPD/runner_lang.sh"

run_lang() { # $1=choose值  $2=来源层级(可空)
    printf '%s' "$1" > "$TMPD/ch"
    printf '%s' '{"language":"zh"}' > "$TMPD/config.json"
    : > "$TMPD/bashlog"
    CHFILE="$TMPD/ch" BASHLOG="$TMPD/bashlog" "$BASH_BIN" "$TMPD/runner_lang.sh" "${2-}" 2>&1
}

echo "== 行为: 语言切换的重启命令 =="
out_en="$(run_lang 2 config)"
assert_not_contains "en: process exited (no fallthrough)" "$out_en" "NO_EXIT"
assert_not_contains "en: no ERR trap" "$out_en" "TRAP_HIT"
log_en="$(cat "$TMPD/bashlog")"
assert_contains "en: restart has --menu config" "$log_en" '--menu config'
assert_contains "en: restart runs main.sh"      "$log_en" '/main.sh'
assert_contains "en: language written"          "$(cat "$TMPD/config.json")" '"language":"en"'

out_zh="$(run_lang 1 config)"
log_zh="$(cat "$TMPD/bashlog")"
assert_contains "zh: restart has --menu config" "$log_zh" '--menu config'
assert_contains "zh: language written"          "$(cat "$TMPD/config.json")" '"language":"zh"'

# 无来源层级时 (理论上不该发生) 也应安全回落到主菜单, 而不是拼出空参数
out_none="$(run_lang 1 '')"
assert_contains "no-source: restart has --menu index" "$(cat "$TMPD/bashlog")" '--menu index'

# ---- runner: 真实 _return_to_menu ----------------------------------------
printf '%s\n' "$FN_RTM" > "$TMPD/fn_rtm.sh"
{
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'processes_config() { echo "CALLED_CONFIG"; }'
    printf '%s\n' 'processes_index()  { echo "CALLED_INDEX"; }'
    cat "$TMPD/fn_rtm.sh"
    printf '%s\n' '_return_to_menu "${1:-}"'
} > "$TMPD/runner_rtm.sh"

echo "== 行为: _return_to_menu 名称映射 =="
assert "config -> config 再进主菜单" "$("$BASH_BIN" "$TMPD/runner_rtm.sh" config)" "$(printf 'CALLED_CONFIG\nCALLED_INDEX')"
assert "index  -> 仅主菜单"          "$("$BASH_BIN" "$TMPD/runner_rtm.sh" index)"  "CALLED_INDEX"
assert "bogus  -> 仅主菜单"          "$("$BASH_BIN" "$TMPD/runner_rtm.sh" bogus)"  "CALLED_INDEX"
assert "absent -> 仅主菜单"          "$("$BASH_BIN" "$TMPD/runner_rtm.sh")"        "CALLED_INDEX"

echo "== 对照: 旧实现 (重启不带目标) 会丢层级 =="
# 旧实现等价于"新进程收不到任何菜单目标" -> 直接落回主菜单, 用户丢失所在层级。
assert "旧实现等价于回主菜单" "$("$BASH_BIN" "$TMPD/runner_rtm.sh")" "CALLED_INDEX"

echo
echo "==== PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
