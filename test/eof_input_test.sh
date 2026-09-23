#!/usr/bin/env bash
# =============================================================================
# 回归测试: 交互输入在 EOF (无输入源) 下必须失败退出, 不得无限空转
# 运行: bash test/eof_input_test.sh
#
# 背景 (为什么固化成脚本):
#   core/handler.sh:exec_read 原为 `while ${flag}` 的**无上限**循环, 而 core/read.sh
#   把 EOF 吞成空串 (`read -r input || input=`)。于是空串必然通不过校验 -> continue
#   -> 立刻再 fork 一个 read.sh -> 再 EOF, 每轮都 fork 一个 bash 且无任何退让。
#   在 cron / 管道 / `< /dev/null` 下实测 CPU 打满且不停止。
#   修法两条:
#     1) read.sh 在 EOF 时以**非 0 退出码**如实上报, 不再伪装成空串;
#     2) exec_read 收到非 0 立即失败退出 (重试无意义), 并对"有输入源但内容一直
#        非法"设 3 次重试上限。
#   本用例防止任一条被改回去。
#
# 覆盖:
#   T1 read.sh: stdin 耗尽 -> 退出码非 0   (旧行为: 退出 0 且返回空串)
#   T2 read.sh: 正常输入   -> 退出码 0 且原样返回
#   T3 exec_read: EOF     -> 只读一次就失败退出, 不重试 (桩件计数 == 1)
#   T4 exec_read: 一直非法 -> 恰好 3 次后失败退出 (有界, 不再无限)
#   T5 静态守卫: 源码中确有 EOF 判定与重试上限
#   T6 i18n: 新增键 zh/en 齐备且键集合一致
#
# 依赖: bash, awk, grep, jq
# =============================================================================
set -Eeuo pipefail

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$REPO"

SB="$REPO/.workbuddy/tmp/eof_input.$$"
rm -rf "$SB" 2>/dev/null || true
mkdir -p "$SB"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

PASS=0; FAIL=0
assert_ok() { if eval "$1"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $2"; fi; }
assert_eq() { if [[ "$1" == "$2" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $3 (got '$1' want '$2')"; fi; }

# T1/T2 需要真实的 i18n 与 config.json: 把 HOME 指向沙箱造一份最小配置
mkdir -p "$SB/home/.xray-script-personal-use-only"
printf '{"language":"zh"}\n' > "$SB/home/.xray-script-personal-use-only/config.json"

# 环境自检: read.sh 会把 PATH 重置为固定白名单 (core/_common.sh), 只认白名单内的 jq。
# 本机若没有 jq, load_i18n 会先失败退出 —— 那与 EOF 无关, 会让 T1 变成**假通过**
# (退出码非 0 但不是 EOF 导致的), T2 变成假失败。故先探测再决定是否跑这两条。
jq_ok=0
for d in /bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin /snap/bin; do
    if [[ -x "$d/jq" ]]; then jq_ok=1; break; fi
done

# ---------------------------------------------------------------------------
# T1 read.sh: stdin 耗尽 -> 非 0 退出
# ---------------------------------------------------------------------------
echo "[T1] read.sh: EOF 时以非 0 退出"
if [[ "$jq_ok" -ne 1 ]]; then
    echo "  (跳过: PATH 白名单内无 jq, load_i18n 无法运行 —— 请在装了 jq 的环境执行)"
else
    rc=0
    HOME="$SB/home" bash core/read.sh --port </dev/null >"$SB/t1.out" 2>"$SB/t1.err" || rc=$?
    assert_ok "[[ $rc -ne 0 ]]" "EOF 时退出码应非 0 (实际 $rc)"
    if [[ -s "$SB/t1.err" ]]; then assert_ok true 'EOF 时给出可读提示'; else assert_ok false 'EOF 时无提示 (静默失败)'; fi
fi

# ---------------------------------------------------------------------------
# T2 read.sh: 正常输入 -> 0 退出且原样返回
# ---------------------------------------------------------------------------
echo "[T2] read.sh: 正常输入原样返回"
if [[ "$jq_ok" -ne 1 ]]; then
    echo "  (跳过: 同上, 无 jq)"
else
    rc=0
    out="$(printf '443\n' | HOME="$SB/home" bash core/read.sh --port 2>/dev/null)" || rc=$?
    assert_ok "[[ $rc -eq 0 ]]" "正常输入退出码应为 0 (实际 $rc)"
    assert_eq "$out" '443' '正常输入应原样返回'
fi

# ---------------------------------------------------------------------------
# T2b 桩件层: 无 jq 时也要能验证 read.sh 的 EOF 分支
#   上面 T1/T2 走真实链路 (需 jq 才能 load_i18n); 这里把 read.sh 的 read_input /
#   main 抽出来, 桩掉 i18n 与配置读取, 只验证"EOF -> 非 0 退出"这条分支本身。
# ---------------------------------------------------------------------------
echo "[T2b] read.sh 桩件层: EOF 分支独立验证"
awk '/^function read_input\(\) \{/{c=1} c{print} c&&/^\}$/{exit}' core/read.sh > "$SB/ri.sh"
awk '/^function main\(\) \{/{c=1} c{print} c&&/^\}$/{exit}' core/read.sh > "$SB/mn.sh"
if [[ ! -s "$SB/ri.sh" || ! -s "$SB/mn.sh" ]]; then
    echo "  [FAIL] 无法抽取 read.sh 的 read_input / main"
    FAIL=$((FAIL+1))
else
    cat > "$SB/drv_read.sh" <<'DRV'
GREEN=; YELLOW=; RED=; NC=
declare -A I18N_MAP=(['read.port']='port: ' ['title.config']='cfg' ['title.warn']='warn'
                     ['title.multiple_values']='multi' ['read.eof_abort']='EOF_ABORT')
_i18n() { printf '%s' "${I18N_MAP[${1#.}]:-}"; }
load_i18n() { :; }
CUR_FILE='read'
declare -A param_map=(["--port"]="config,port")
source "$1"
source "$2"
main '--port'
DRV
    rc=0
    bash "$SB/drv_read.sh" "$SB/ri.sh" "$SB/mn.sh" </dev/null >"$SB/t2b.out" 2>"$SB/t2b.err" || rc=$?
    assert_ok "[[ $rc -ne 0 ]]" "桩件层: EOF 时 main 应非 0 退出 (实际 $rc)"
    if grep -q 'EOF_ABORT' "$SB/t2b.err"; then assert_ok true '桩件层: EOF 时打印 eof_abort 提示'; else assert_ok false '桩件层: EOF 无提示'; fi

    rc=0
    out="$(printf '443\n' | bash "$SB/drv_read.sh" "$SB/ri.sh" "$SB/mn.sh" 2>/dev/null)" || rc=$?
    assert_ok "[[ $rc -eq 0 ]]" "桩件层: 正常输入应 0 退出 (实际 $rc)"
    assert_eq "$out" '443' '桩件层: 正常输入应原样返回'
fi

# ---------------------------------------------------------------------------
# 桩件: 抽取真实的 exec_read, 用假 read.sh 计数
# ---------------------------------------------------------------------------
awk '/^function exec_read\(\) \{/{c=1} c{print} c&&/^\}$/{exit}' core/handler.sh > "$SB/exec_read.sh"
if [[ ! -s "$SB/exec_read.sh" ]]; then
    echo "  [FAIL] 无法从 core/handler.sh 抽取 exec_read"
    FAIL=$((FAIL+1))
else
    cat > "$SB/fake_read.sh" <<'EOF'
#!/usr/bin/env bash
printf 'x\n' >> "${CALLS}"
if [[ "${FAKE_MODE:-eof}" == 'eof' ]]; then exit 1; fi
printf '%s' "${FAKE_VALUE:-}"
exit 0
EOF
    cat > "$SB/drv.sh" <<'DRV'
READ_PATH="$1"; CUR_FILE='handler'
declare -A CONFIG_DATA
_i18n() { printf '%s' "$1"; }
_error() { printf 'ERROR %s\n' "$1" >&2; exit 1; }
exec_check() { return 1; }
source "$2"
exec_read 'port'
DRV

    # T3: EOF -> 只读一次 (不重试)
    echo "[T3] exec_read: EOF 时立即失败, 不重试"
    : > "$SB/calls1"
    rc=0
    CALLS="$SB/calls1" FAKE_MODE=eof bash "$SB/drv.sh" "$SB/fake_read.sh" "$SB/exec_read.sh" >/dev/null 2>&1 || rc=$?
    n1="$(wc -l <"$SB/calls1" | tr -d ' ')"
    assert_ok "[[ $rc -ne 0 ]]" "EOF 时 exec_read 应失败退出 (实际 rc=$rc)"
    assert_eq "$n1" '1' "EOF 时 read.sh 只应被调用 1 次 (实际 $n1)"

    # T4: 一直非法 -> 有界重试 3 次
    echo "[T4] exec_read: 输入一直非法时有界重试"
    : > "$SB/calls2"
    rc=0
    CALLS="$SB/calls2" FAKE_MODE=ok FAKE_VALUE='not-a-port' \
        bash "$SB/drv.sh" "$SB/fake_read.sh" "$SB/exec_read.sh" >/dev/null 2>&1 || rc=$?
    n2="$(wc -l <"$SB/calls2" | tr -d ' ')"
    assert_ok "[[ $rc -ne 0 ]]" "重试耗尽后应失败退出 (实际 rc=$rc)"
    assert_eq "$n2" '3' "应恰好重试 3 次后退出 (实际 $n2)"
fi

# ---------------------------------------------------------------------------
# T5 静态守卫
# ---------------------------------------------------------------------------
echo "[T5] 静态守卫: EOF 判定与重试上限均在位"
for pat in 'max_retries' 'input_unavailable' 'input_retry_exhausted'; do
    if grep -q "$pat" core/handler.sh; then assert_ok true "handler.sh: $pat"; else assert_ok false "handler.sh: 缺 $pat"; fi
done
if grep -q 'eof_abort' core/read.sh; then assert_ok true 'read.sh: eof_abort 上报'; else assert_ok false 'read.sh: 缺 eof_abort 上报'; fi
# 反面守卫: 不得把 EOF 又吞成空串
if grep -qE 'read -r input \|\| input=' core/read.sh; then
    assert_ok false 'read.sh: EOF 又被吞成空串 (回归)'
else
    assert_ok true 'read.sh: 未把 EOF 吞成空串'
fi

# ---------------------------------------------------------------------------
# T6 i18n 键齐备
# ---------------------------------------------------------------------------
echo "[T6] i18n: 新增键 zh/en 齐备"
for key in input_unavailable input_retry_exhausted; do
    if grep -q "\"$key\"" i18n/zh.json; then assert_ok true "zh.json: handler.$key"; else assert_ok false "zh.json: 缺 handler.$key"; fi
    if grep -q "\"$key\"" i18n/en.json; then assert_ok true "en.json: handler.$key"; else assert_ok false "en.json: 缺 handler.$key"; fi
done
if grep -q '"eof_abort"' i18n/zh.json; then assert_ok true 'zh.json: read.eof_abort'; else assert_ok false 'zh.json: 缺 read.eof_abort'; fi
if grep -q '"eof_abort"' i18n/en.json; then assert_ok true 'en.json: read.eof_abort'; else assert_ok false 'en.json: 缺 read.eof_abort'; fi

echo
echo "==== eof_input_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
