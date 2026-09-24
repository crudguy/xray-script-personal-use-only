#!/usr/bin/env bash
# =============================================================================
# 测试名称: graceful_fail_test.sh
# 测试目标: 可恢复的失败 (配置复查未通过且已回滚 / handler 返回非 0) 必须**软失败回菜单**,
#           不得 _error 退出整个交互脚本。
#
# 背景: 一键安装 mKCP 时, Xray 26.3.27 不认 mkcp-legacy 且已移除 kcpSettings.seed,
#       配置复查 (_verify_xray_config) 失败并回滚到备份。旧的 persist_xray_config 在回滚后
#       调 _error, 一路冒泡成 install.sh trampoline 的"脚本在第 N 行意外失败", 并直接杀掉
#       整个脚本 —— 用户被迫重进菜单 (见 2026-09-24 用户反馈"还是没有优雅退出啊, 直接退出应用了")。
#       修复: persist_xray_config 回滚后 print_warn + return 1; exec_handler 接住非 0 并
#       print_warn + return 0 (因 main.sh 启用 set -e, 必须返回 0 才不被当脚本崩溃)。
#
# 覆盖:
#   T1 静态契约 —— exec_handler 体 / persist_xray_config 复查分支不得出现 _error;
#   T2 行为 —— 抽真实 exec_handler + 桩 HANDLER_PATH(exit 3): caller RC=0 + 有 handler_failed 警告;
#   T3 行为 —— 抽真实 persist_xray_config + 桩 _verify_xray_config(失败): RC=1 + 有 verify_failed 警告 + 不触发 _error(桩 _error 会 exit 99);
#   NEG 负向校验 —— 把 exec_handler 复原成 _error 版 / persist 复查分支复原成 _error, 确认
#       T2 的 caller 不再 RC=0、T3 的桩 _error 被触发 (exit 99), 证明契约断言非恒绿。
#
# 依赖: bash + awk (仅做函数抽取, 不需要 jq —— T3 用合法 JSON 字面量作为 XRAY_CONFIG)。
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/core/main.sh"
HANDLER="$ROOT/core/handler.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s%s\n' "$1" "${2:+ ($2)}"; }
assert_eq()       { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got $(printf '%q' "$2") want $(printf '%q' "$3")"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing $(printf '%q' "$3")"; fi; }

# 注: 不用裸 mktemp -d (Windows/Git-Bash 可能返回 C:/... 风格路径); 用项目内固定目录。
TMPD="$ROOT/.workbuddy/tmp/graceful_fail.$$"
rm -rf "$TMPD" 2>/dev/null || true
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT

# 抽 core/handler.sh 中某函数的真实函数体 (精确整行匹配定义行)
extract() { awk -v fn="$1" '
    $0 == "function " fn "() {" {f=1}
    f {print}
    f && /^}$/ {exit}
' "$2"; }

# 抽 core/main.sh 中某函数的真实函数体
extract_main() { awk -v fn="$1" '
    $0 == "function " fn "() {" {f=1}
    f {print}
    f && /^}$/ {exit}
' "$MAIN"; }

# 剥整行注释后判定 (保护性注释里必然出现 "_error" 字样, 不剥离会误判)。
strip_comments() { sed -E 's/^[[:space:]]*#.*$//' <<<"$1"; }

# ---------------------------------------------------------------------------
# T1 静态契约: 两处体不得含 _error 调用
# ---------------------------------------------------------------------------
exec_fn="$(extract_main 'exec_handler')"
persist_fn="$(extract 'persist_xray_config' "$HANDLER")"
if ! strip_comments "$exec_fn" | grep -qF '_error'; then
  ok   "T1: exec_handler 体内无 _error 调用"
else
  bad  "T1: exec_handler 体内仍含 _error" "$(strip_comments "$exec_fn" | grep -nF '_error')"
fi
if ! strip_comments "$persist_fn" | grep -qE '_error.*verify_failed'; then
  ok   "T1: persist_xray_config 复查分支(verify_failed)不再 _error"
else
  bad  "T1: persist_xray_config 复查分支仍含 _error+verify_failed" "$(strip_comments "$persist_fn" | grep -nE '_error.*verify_failed')"
fi

# ---------------------------------------------------------------------------
# T2 行为: exec_handler 软失败 (handler 退出码 3)
# ---------------------------------------------------------------------------
HSTUB="$TMPD/h_stub.sh"
cat > "$HSTUB" <<'STUB'
#!/usr/bin/env bash
exit 3
STUB
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -Eeuo pipefail\n'
  printf 'CUR_FILE="main"\n'
  printf '_i18n() { printf "%%s" "$1"; }\n'
  printf 'print_warn() { printf "WARN:%%s\\n" "$*" >&2; }\n'
  printf 'HANDLER_PATH="%s"\n' "$HSTUB"
  printf '%s\n' "$exec_fn"
  printf 'exec_handler --quick Vision\n'
  printf 'echo "CALLER_RC=$?"\n'
} > "$TMPD/run_exec.sh"
out_exec="$(bash "$TMPD/run_exec.sh" 2>&1)"
assert_eq       "T2: exec_handler 不因 handler 非 0 退出 (caller RC=0)" \
  "$(printf '%s' "$out_exec" | grep -oE 'CALLER_RC=[0-9]+' | tail -1)" 'CALLER_RC=0'
assert_contains "T2: exec_handler 打印 handler_failed 警告" "$out_exec" 'handler_failed'

# ---------------------------------------------------------------------------
# T3 行为: persist_xray_config 复查失败不 _error
# ---------------------------------------------------------------------------
atomic_fn="$(extract '_atomic_write' "$ROOT/core/_common.sh")"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -Eeuo pipefail\n'
  printf '_i18n() { printf "%%s" "$1"; }\n'
  printf 'print_warn() { printf "WARN:%%s\\n" "$*" >&2; }\n'
  printf '_error() { echo "ERR_FIRED" >&2; exit 99; }\n'   # 若被调用 -> exit 99, 测试会捕获
  printf '_verify_xray_config() { return 1; }\n'          # 强制复查失败
  printf '%s\n' "$atomic_fn"
  printf '%s\n' "$persist_fn"
  printf 'XRAY_CONFIG='"'"'{}'"'"'\n'
  printf 'XRAY_CONFIG_PATH="%s/xray.conf"\n' "$TMPD"
  printf 'rc=0; persist_xray_config || rc=$?\n'
  printf 'echo "PERSIST_RC=$rc"\n'
} > "$TMPD/run_persist.sh"
out_persist="$(bash "$TMPD/run_persist.sh" 2>&1)"
assert_eq       "T3: persist_xray_config 复查失败返回 RC=1 (非 _error)" \
  "$(printf '%s' "$out_persist" | grep -oE 'PERSIST_RC=[0-9]+' | tail -1)" 'PERSIST_RC=1'
assert_contains "T3: persist_xray_config 打印 verify_failed 警告" "$out_persist" 'verify_failed'
assert_eq       "T3: persist 复查失败未触发 _error (无 ERR_FIRED)" \
  "$(printf '%s' "$out_persist" | grep -c 'ERR_FIRED')" '0'

# ---------------------------------------------------------------------------
# NEG 负向校验: 复原成 _error 版, 确认 T2/T3 真能捕获回归
# ---------------------------------------------------------------------------
# NEG-2: exec_handler 复原成 _error 版
neg_exec="$(printf '%s' "$exec_fn" | sed 's/return 0/_error "$(_i18n ".".CUR_FILE".handler_failed")"/; s/print_warn "$(_i18n ".${CUR_FILE}.handler_failed")"//')"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -Eeuo pipefail\n'
  printf '_i18n() { printf "%%s" "$1"; }\n'
  printf 'print_warn() { :; }\n'
  printf 'trap '"'"'echo "TRAP_FIRED_L1" >&2; exit 1'"'"' ERR\n'   # 模拟 install.sh 的 ERR trap
  printf '_error() { exit 1; }\n'                                  # 模拟旧 _error (直接退出)
  printf 'HANDLER_PATH="%s"\n' "$HSTUB"
  printf '%s\n' "$neg_exec"
  printf 'exec_handler --quick Vision\n'
  printf 'echo "CALLER_RC=$?"\n'
} > "$TMPD/run_exec_neg.sh"
out_exec_neg="$(bash "$TMPD/run_exec_neg.sh" 2>&1 || true)"
# _error 版下: exec_handler 调 _error -> 进程退出, CALLER_RC 不应再是 0
if ! printf '%s' "$out_exec_neg" | grep -q 'CALLER_RC=0'; then
  ok   "NEG-2: 复原 _error 版后 caller 不再 RC=0 (契约非恒绿)"
else
  bad  "NEG-2: 复原 _error 版后仍 RC=0 (契约被绕过)"
fi

# NEG-3: persist 复查分支复原成 _error 版
# 复原成 _error 版: 复查分支的 `return 1` 改为 `_error` (该行在 verify 分支中唯一; 参数内容无关紧要)
neg_persist="$(printf '%s' "$persist_fn" | sed 's/return 1/_error "verify_failed"/')"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -Eeuo pipefail\n'
  printf '_i18n() { printf "%%s" "$1"; }\n'
  printf 'print_warn() { :; }\n'
  printf '_error() { echo "ERR_FIRED" >&2; exit 99; }\n'
  printf '_verify_xray_config() { return 1; }\n'
  printf '%s\n' "$atomic_fn"
  printf '%s\n' "$neg_persist"
  printf 'XRAY_CONFIG='"'"'{}'"'"'\n'
  printf 'XRAY_CONFIG_PATH="%s/xray2.conf"\n' "$TMPD"
  printf 'persist_xray_config\n'
  printf 'echo "PERSIST_RC=$?"\n'
} > "$TMPD/run_persist_neg.sh"
out_persist_neg="$(bash "$TMPD/run_persist_neg.sh" 2>&1 || true)"
if printf '%s' "$out_persist_neg" | grep -q 'ERR_FIRED'; then
  ok   "NEG-3: 复原 _error 版后桩 _error 被触发 (契约非恒绿)"
else
  bad  "NEG-3: 复原 _error 版后桩 _error 未被触发"
fi

# ---------------------------------------------------------------------------
echo "==== graceful_fail_test: PASS=$PASS FAIL=$FAIL ===="
[[ $FAIL -eq 0 ]]
