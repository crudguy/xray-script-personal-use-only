#!/usr/bin/env bash
# shellcheck disable=SC2034  # BASH_BIN/CUR_* 等仅用于装配 runner, 断言走日志文件。
# =============================================================================
# 回归守卫: 设置语言 (processes_language) 重启脚本前必须先释放父进程的单实例锁
#
# 背景: core/main.sh 的 _acquire_lock 在 main() 启动时给当前进程上独占锁 (fd 9,
#       全程不释放)。processes_language 改完语言后用
#       `bash "${CUR_DIR}/${CUR_FILE}.sh" --menu "${return_to}"` 重新拉起一个
#       新的同脚本进程; 该子进程 main() 会再次 _acquire_lock -> 对同一文件 flock -n,
#       与**仍持有锁的父进程**冲突, 误报 "已有实例正在运行" 并退出 (见用户日志:
#       管理配置 -> 6 设置语言 -> 选完语言即报 lock_busy)。
#
# 修复: processes_language 在 re-launch 前调用 _release_lock (flock -u 9; exec 9>&-),
#       把锁干净交接给子进程。
#
# 本测试:
#   1. 在测试进程里像父进程一样 `exec 9>>LOCK; flock -n 9` 持锁 (模拟 main 已上锁);
#   2. 用桩 bash 模拟"子进程再次加锁": 真正拉起一个子 shell 对同一个锁文件
#      `flock -n`, 把 ACQUIRED / FAILED 写进日志;
#   3. 驱动真实 processes_language (+ 真实 _release_lock), 断言日志为 ACQUIRED;
#   4. 负向: 把 extracted 函数里的 _release_lock 调用删掉, 重跑, 断言日志为 FAILED
#      (证明测试非虚设, 真能抓到回归)。
#
# 纯 bash, 仅依赖系统 flock (无 flock 时本测试整体 SKIP, 不计入失败)。
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/core/main.sh"
BASH_BIN="$(command -v bash)"

PASS=0
FAIL=0
SKIP=0

ok()   { PASS=$((PASS+1)); printf '  ok   %-46s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %-46s %s\n' "$1" "$2"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %-46s %s\n' "$1" "$2"; }

# 无 flock 则跳过 (本 bug 仅在 flock 可用时存在)
if ! command -v flock >/dev/null 2>&1; then
    echo "== 环境无 flock, 跳过锁交接测试 =="
    echo; echo "==== PASS=$PASS FAIL=$FAIL SKIP=$SKIP ===="
    exit 0
fi

# 注: 不用 mktemp -d —— Windows/Git-Bash 下可能返回 "C:/..." 风格路径, MSYS 无法解析。
TMPD="$ROOT/.workbuddy/tmp/lang_lock.$$"
rm -rf "$TMPD" 2>/dev/null || true
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT

LOCK_FILE="$TMPD/instance.lock"
: >"$LOCK_FILE"

# ---- 抽取真实函数体 ----
FN_LANG="$(awk '/^function processes_language\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$MAIN")"
FN_REL="$(awk '/^function _release_lock\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$MAIN")"

if [[ -z "$FN_LANG" ]]; then
    bad "extract processes_language" "空"; echo; echo "==== PASS=$PASS FAIL=$FAIL SKIP=$SKIP ===="; exit 1
fi
if [[ -z "$FN_REL" ]]; then
    bad "extract _release_lock" "空"; echo; echo "==== PASS=$PASS FAIL=$FAIL SKIP=$SKIP ===="; exit 1
fi

# 断言提取到的 processes_language 确实调用了 _release_lock (静态契约)
if printf '%s\n' "$FN_LANG" | grep -q '^[[:space:]]*_release_lock$'; then
    ok "T1: processes_language 调用 _release_lock (静态契约)"
else
    bad "T1: processes_language 未调用 _release_lock" "$(printf '%s\n' "$FN_LANG" | grep -n '_release_lock' || echo '(无)')"
fi

# ---- 通用 runner 装配 (持锁 + 桩件) ----
# $1: 是否注入 _release_lock (fix=yes / no)
build_and_run() {
    local inject_rel="$1"
    local fn_lang="$FN_LANG"
    if [[ "$inject_rel" != "yes" ]]; then
        # 负向: 删除 _release_lock 调用, 模拟修复前
        fn_lang="$(printf '%s\n' "$fn_lang" | grep -v '^[[:space:]]*_release_lock$')"
    fi

    local runner="$TMPD/runner.sh"
    {
        printf '%s\n' 'set -Eeuo pipefail'
        printf '%s\n' 'trap "echo TRAP_HIT >&2" ERR'
        # 环境
        printf '%s\n' "CUR_DIR='$ROOT/core'"
        printf '%s\n' "CUR_FILE='main'"
        printf '%s\n' "TMPD='$TMPD'"
        printf '%s\n' "SCRIPT_CONFIG_PATH='$TMPD/config.json'"
        printf '%s\n' "LOCK_FILE='$TMPD/instance.lock'"
        printf '%s\n' "BASH_BIN='$BASH_BIN'"
        printf '%s\n' "LANG_PARAM=''"
        printf '%s\n' "SCRIPT_CONFIG=''"
        printf '%s\n' "BASHLOG='$TMPD/bashlog'"
        # jq 桩
        printf '%s\n' 'jq() { if [[ "${1:-}" == "--arg" && "${2:-}" == "language" ]]; then printf %s "{\"language\":\"$3\"}"; else cat "${5:-$(cat)}" 2>/dev/null || true; fi; }'
        printf '%s\n' '_atomic_write() { cat > "$1"; }'
        printf '%s\n' 'exec_menu() { cat "$CHFILE"; }'
        # 桩 bash: 模拟 re-launch 的子进程再次对同一个锁文件加锁
        #   返回 1 让 processes_language 的 `&& exit 0` 不触发, 便于检查日志。
        printf '%s\n' 'bash() {'
        printf '%s\n' '    "$BASH_BIN" -c "exec 8>>'"'"'$TMPD/instance.lock'"'"'; if flock -n 8; then echo ACQUIRED; else echo FAILED; fi" >> "$BASHLOG" 2>&1 || true'
        printf '%s\n' '    return 1'
        printf '%s\n' '}'
        # 真实 _release_lock (不论正负向都注入, 负向下不会被调用)
        printf '%s\n' "$FN_REL"
        # 注入的函数体
        printf '%s\n' "$fn_lang"
        # 主流程: 父进程先持锁, 再驱动 processes_language
        printf '%s\n' 'if ! exec 9>>"$LOCK_FILE"; then echo "PARENT_OPEN_FAIL" >&2; exit 1; fi'
        printf '%s\n' 'if ! flock -n 9; then echo "PARENT_LOCK_FAIL" >&2; exit 1; fi'
        printf '%s\n' 'processes_language "${1:-}"'
        printf '%s\n' 'echo "RUNNER_DONE"'
    } > "$runner"

    : > "$TMPD/bashlog"
    printf '%s' '1' > "$TMPD/ch"          # choose=1 -> zh
    printf '%s' '{"language":"zh"}' > "$TMPD/config.json"
    CHFILE="$TMPD/ch" "$BASH_BIN" "$runner" 'config' 2>"$TMPD/err" || true
    cat "$TMPD/bashlog"
}

echo "== 行为: 修复后父锁应释放, 子进程可再次加锁 =="
OUT_FIX="$(build_and_run yes)"
echo "$OUT_FIX" | grep -q 'ACQUIRED' && ok "T2: 修复后子进程再次加锁 ACQUIRED" || bad "T2: 修复后应 ACQUIRED" "(log: $(echo "$OUT_FIX" | tr '\n' ' '))"

echo "== 负向: 去掉 _release_lock 调用应重现锁冲突 =="
OUT_NEG="$(build_and_run no)"
echo "$OUT_NEG" | grep -q 'FAILED' && ok "T3: 负向回退后子进程加锁 FAILED (证明测试非虚设)" || bad "T3: 负向应 FAILED" "(log: $(echo "$OUT_NEG" | tr '\n' ' '))"

# 负向必须不是 ACQUIRED (否则测试没抓到回归)
if echo "$OUT_NEG" | grep -q 'ACQUIRED'; then
    bad "T3b: 负向竟为 ACQUIRED (回归未被捕获)" ""
else
    ok "T3b: 负向确非 ACQUIRED"
fi

echo
echo "==== PASS=$PASS FAIL=$FAIL SKIP=$SKIP ===="
[[ "$FAIL" -eq 0 ]]
