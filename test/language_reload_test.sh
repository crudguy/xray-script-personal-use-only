#!/usr/bin/env bash
# shellcheck disable=SC2034  # ROOT/MAIN 等仅用于装配测试, 断言走返回值/日志。
# =============================================================================
# 回归守卫: 设置语言改为「同进程内重载 i18n」, 不再 re-launch 子进程
#
# 背景: 旧实现改完语言后 `bash "${CUR_DIR}/${CUR_FILE}.sh" --menu ...` 重新拉起
#       子进程以重载 i18n, 带来两个致命问题:
#         (1) 父进程持单实例锁 (fd 9), 子进程再次 _acquire_lock 冲突 -> lock_busy 误报;
#         (2) 子进程继承父进程 TTY stdin, 交互态下读不到正确输入 -> 卡死 (光标不动)。
#
# 修复: processes_language 改为同进程内 `I18N_MAP=(); load_i18n`, 立即生效。
#
# 本测试覆盖:
#   静态契约: 函数体内 (a) 不再 re-launch (`bash main.sh`)；(b) 不再调用 _release_lock；
#             (c) 清空 I18N_MAP；(d) 调用 load_i18n 重载。
#   行为: 用真实 load_i18n / _i18n + 真实 i18n JSON 驱动 processes_language, 断言
#         - 配置落盘语言正确 (zh/en)；
#         - 全程没有 re-launch 子进程 (bash 桩日志为空)；
#         - i18n 文案随选择真正翻转 (zh "配置" <-> en "Config")。
# 纯 bash + 系统 jq (无 jq 时整体 SKIP)。
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/core/main.sh"
BASH_BIN="$(command -v bash)"

PASS=0
FAIL=0
SKIP=0

ok()   { PASS=$((PASS+1)); printf '  ok   %-48s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %-48s %s\n' "$1" "$2"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %-48s %s\n' "$1" "$2"; }

if ! command -v jq >/dev/null 2>&1; then
    echo "== 环境无 jq, 跳过语言重载测试 =="
    echo; echo "==== PASS=$PASS FAIL=$FAIL SKIP=$SKIP ===="
    exit 0
fi

# ---- 抽取真实函数体 ----
FN_LANG="$(awk '/^function processes_language\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$MAIN")"
FN_LOAD="$(awk '/^function load_i18n\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$ROOT/core/_common.sh")"
FN_I18N="$(awk '/^function _i18n\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$ROOT/core/_common.sh")"

[[ -n "$FN_LANG" ]] || { bad "extract processes_language" "空"; echo; echo "==== PASS=$PASS FAIL=$FAIL SKIP=$SKIP ===="; exit 1; }
[[ -n "$FN_LOAD" ]] || { bad "extract load_i18n" "空";        echo; echo "==== PASS=$PASS FAIL=$FAIL SKIP=$SKIP ===="; exit 1; }
[[ -n "$FN_I18N" ]] || { bad "extract _i18n" "空";           echo; echo "==== PASS=$PASS FAIL=$FAIL SKIP=$SKIP ===="; exit 1; }

echo "== 静态契约: core/main.sh :: processes_language =="
if printf '%s\n' "$FN_LANG" | grep -q 'bash "${CUR_DIR}/${CUR_FILE}.sh"'; then
    bad "T1: 不再 re-launch 子进程" "$(printf '%s\n' "$FN_LANG" | grep -n 'bash "${CUR_DIR}/${CUR_FILE}.sh"')"
else
    ok "T1: 不再 re-launch 子进程 (无 bash main.sh)"
fi
if printf '%s\n' "$FN_LANG" | grep -q '_release_lock'; then
    bad "T2: 不再调用 _release_lock" "残留 _release_lock"
else
    ok "T2: 不再调用 _release_lock"
fi
if printf '%s\n' "$FN_LANG" | grep -q '^[[:space:]]*I18N_MAP=()'; then
    ok "T3: 清空 I18N_MAP (触发重载)"
else
    bad "T3: 未清空 I18N_MAP" "$(printf '%s\n' "$FN_LANG" | grep -n 'I18N_MAP' || echo '(无)')"
fi
if printf '%s\n' "$FN_LANG" | grep -q 'load_i18n'; then
    ok "T4: 调用 load_i18n 重载"
else
    bad "T4: 未调用 load_i18n" "(无)"
fi

# ---- 行为: 同进程内重载真的翻转文案 ----
# 注: 不用 mktemp -d —— Windows/Git-Bash 下可能返回 "C:/..." 风格路径, MSYS 无法解析。
TMPD="$ROOT/.workbuddy/tmp/lang_reload.$$"
rm -rf "$TMPD" 2>/dev/null || true
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT

CONFIG="$TMPD/config.json"
BASHLOG="$TMPD/bashlog"

# 行为 runner: 真实 load_i18n/_i18n + 桩件; 用真实 jq 在配置落盘后由 load_i18n 重新读取。
{
    printf '%s\n' 'set -uo pipefail'
    printf '%s\n' "ROOT='$ROOT'"
    printf '%s\n' "I18N_DIR='$ROOT/i18n'"
    printf '%s\n' "CONFIG='$CONFIG'"
    printf '%s\n' "BASHLOG='$BASHLOG'"
    printf '%s\n' 'declare -A I18N_MAP=()'
    printf '%s\n' 'LANG_PARAM=""'
    printf '%s\n' 'SCRIPT_CONFIG=""'
    printf '%s\n' 'SCRIPT_CONFIG_PATH="$CONFIG"'
    # 真实函数 (load_i18n 用 I18N_DIR/SCRIPT_CONFIG_PATH + 真实 jq)
    printf '%s\n' "$FN_LOAD"
    printf '%s\n' "$FN_I18N"
    # 真实被测函数 processes_language
    printf '%s\n' "$FN_LANG"
    # 桩: 原子写把 stdin 落盘到目标文件
    printf '%s\n' '_atomic_write() { cat > "$1"; }'
    # 桩: 语言菜单返回 $CHOOSE (1=zh, 2=en)
    printf '%s\n' 'exec_menu() { printf %s "$CHOOSE"; }'
    # 桩: 若有人 re-launch, 记下来 (断言应为空)
    printf '%s\n' 'bash() { printf "%s\n" "$*" >> "$BASHLOG"; }'
    # 预置 zh, 先加载
    printf '%s\n' 'printf %s '"'"'{"language":"zh"}'"'"' > "$CONFIG"'
    printf '%s\n' 'load_i18n'
    printf '%s\n' 'echo "BEFORE=$(_i18n ".title.config")"'
    # 切到 en
    printf '%s\n' 'CHOOSE=2 processes_language'
    printf '%s\n' 'echo "AFTER_EN=$(_i18n ".title.config")"'
    printf '%s\n' 'echo "CFG_EN=$(jq -r ".language" "$CONFIG")"'
    # 再切回 zh
    printf '%s\n' 'CHOOSE=1 processes_language'
    printf '%s\n' 'echo "AFTER_ZH=$(_i18n ".title.config")"'
    printf '%s\n' 'echo "CFG_ZH=$(jq -r ".language" "$CONFIG")"'
    printf '%s\n' 'echo "RELAUNCH_LOG<<$(cat "$BASHLOG")>>"'
} > "$TMPD/runner.sh"

OUT="$("$BASH_BIN" "$TMPD/runner.sh" 2>"$TMPD/err")"
RC=$?
[[ $RC -eq 0 ]] || { bad "T5: runner 退出码" "rc=$RC err=$(cat "$TMPD/err")"; }

echo "== 行为: 同进程内重载翻转文案 =="
get() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; }

BEFORE="$(get BEFORE)"; AFTER_EN="$(get AFTER_EN)"; AFTER_ZH="$(get AFTER_ZH)"
CFG_EN="$(get CFG_EN)";  CFG_ZH="$(get CFG_ZH)"
RELAUNCH="$(printf '%s\n' "$OUT" | sed -n 's/^RELAUNCH_LOG<<\(.*\)>>$/\1/p')"

[[ "$BEFORE" == "配置" ]]    && ok "T5: 预置 zh 文案=配置"    || bad "T5: 预置 zh 文案" "got=$BEFORE"
[[ "$AFTER_EN" == "Config" ]] && ok "T6: 切 en 后文案=Config"  || bad "T6: 切 en 文案" "got=$AFTER_EN"
[[ "$AFTER_ZH" == "配置" ]]   && ok "T7: 切回 zh 后文案=配置"  || bad "T7: 切回 zh 文案" "got=$AFTER_ZH"
[[ "$CFG_EN" == "en" ]] && ok "T8: 配置落盘 language=en" || bad "T8: 配置落盘 en" "got=$CFG_EN"
[[ "$CFG_ZH" == "zh" ]] && ok "T9: 配置落盘 language=zh" || bad "T9: 配置落盘 zh" "got=$CFG_ZH"
if [[ -z "$RELAUNCH" ]]; then
    ok "T10: 全程无 re-launch 子进程"
else
    bad "T10: 竟发生 re-launch" "log=$RELAUNCH"
fi

echo
echo "==== PASS=$PASS FAIL=$FAIL SKIP=$SKIP ===="
[[ "$FAIL" -eq 0 ]]
