#!/usr/bin/env bash
# P2-4 子项⑤ 回归守卫: 错误提示附可执行建议 (纯 bash, 不依赖 jq / 真实环境)。
# 锁定:
#   (1) 3 个错误打印**实现**均支持可选第 2 参数 hint, 且 hint 走 stderr;
#       check.sh 的 _check_fail 是"体检项标记"必须不退出; 其余 2 个必须 exit 1。
#       注: 短名 _error 已下沉到 _common.sh, 且实现为 print_error 的**别名**
#           (main.sh / handler.sh 不再各自内联副本)。别名体只有 `print_error "$@"`,
#           不含 hint=... / exit 1 等字样, 套用本测试"抽函数体做静态断言"的范式会误报,
#           故不再列入下面的循环 —— 其等价性与 share.sh 子进程场景改由
#           test/output_helper_sink_test.sh 守护。
#   (2) i18n zh/en 双语均有 title.hint 与 8 组 *_hint 键 (键名唯一, 可 grep)。
#   (3) 行为: 有 hint → 先错误行再 [建议] 行; 无/空 hint → 只错误行; 不污染 stdout。
#   (4) 关键调用点均已接入第 2 实参 (check 5 / handler 4 / nginx 2)。
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1" >&2; }
assert_eq(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (期望 [$2] 实际 [$3])"; fi; }
assert_has(){ case "$2" in *"$3"*) ok "$1";; *) bad "$1 (未含 [$3], 实际 [$2])";; esac; }
assert_not(){ case "$2" in *"$3"*) bad "$1 (不应含 [$3], 实际 [$2])";; *) ok "$1";; esac; }

COMMON=core/_common.sh
CHECK=core/check.sh
HANDLER=core/handler.sh
BACKUP=tool/backup.sh
NGINX=service/nginx.sh
BASH_BIN="$(command -v bash)"
TMPD=".workbuddy/tmp/error_hint_$$"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

extract_fn(){ # $1=file $2=funcname
    awk -v fn="$2" '
        $0 ~ ("^function " fn "\\(\\) \\{") { grab=1 }
        grab { print }
        grab && /^\}$/ { exit }
    ' "$1"
}

echo "== T1: 静态契约 — 4 个错误函数支持可选 hint =="
for spec in "$COMMON:print_error" "$CHECK:_check_fail" "$BACKUP:_fail"; do
    f="${spec%%:*}"; fn="${spec##*:}"
    body="$(extract_fn "$f" "$fn")"
    if [[ -n "$body" ]]; then ok "$f:$fn 可抽取"; else bad "$f:$fn 抽取失败"; fi
    assert_has "$f:$fn 接收第2参数" "$body" 'hint="${2:-}"'
    assert_has "$f:$fn 引用 title.hint" "$body" ".title.hint"
done

echo "== T2: 终止性 — check._check_fail 不退出, 其余 exit 1 =="
case "$(extract_fn "$CHECK" _check_fail)" in
    *"exit 1"*) bad "check.sh _check_fail 不应 exit (会中断体检汇总)";;
    *) ok "check.sh _check_fail 不退出 (纯打印)";;
esac
for spec in "$COMMON:print_error" "$BACKUP:_fail"; do
    f="${spec%%:*}"; fn="${spec##*:}"
    assert_has "$f:$fn 为终止型" "$(extract_fn "$f" "$fn")" "exit 1"
done

echo "== T3: i18n zh/en 双语 hint 键在位 =="
for key in hint occupied_fail_hint udp_occupied_fail_hint resolve_fail_hint resolution_fail_hint not_exist_hint write_failed_hint unsupported_os_hint; do
    for lang in zh en; do
        n="$(grep -c "\"$key\":" "i18n/$lang.json" 2>/dev/null || true)"
        if [[ "${n:-0}" -ge 1 ]]; then ok "$lang.json 含 $key"; else bad "$lang.json 缺 $key"; fi
    done
done

echo "== T4: 行为 — 有/无 hint 与输出通道 (抽取真实函数 + 桩件) =="
STUB="$TMPD/stub.sh"
cat > "$STUB" <<'EOF'
_i18n(){ case "$1" in '.title.error') printf 'ERR';; '.title.fail') printf 'FAIL';; '.title.hint') printf 'HINT';; *) printf '';; esac; }
RED=''; YELLOW=''; NC=''
EOF

run_fn(){ # $1=file $2=fn $3=msg [ $4=hint ]
    local f="$1" fn="$2"
    local rf="$TMPD/run.sh"
    { printf 'source %q\n' "$STUB"; extract_fn "$f" "$fn"; printf '%s "$@"\n' "$fn"; } > "$rf"
    "$BASH_BIN" "$rf" "${@:3}" > "$TMPD/o" 2> "$TMPD/e"
    RC=$?
    OUT="$(cat "$TMPD/o")"
    ERR="$(cat "$TMPD/e")"
}

for spec in "$COMMON:print_error" "$CHECK:_check_fail" "$BACKUP:_fail"; do
    f="${spec%%:*}"; fn="${spec##*:}"
    # --- 有 hint ---
    run_fn "$f" "$fn" '出事了' '这样做可修复'
    assert_has "$f:$fn 含错误文本" "$ERR" '出事了'
    assert_has "$f:$fn 含建议文本" "$ERR" '这样做可修复'
    assert_has "$f:$fn 建议带前缀" "$ERR" 'HINT'
    assert_eq  "$f:$fn stdout 干净 (走 stderr)" "" "$OUT"
    case "$ERR" in
        *HINT*'这样做可修复'*) ok "$f:$fn 建议行在错误行之后";;
        *) bad "$f:$fn 建议顺序不对: [$ERR]";;
    esac
    # --- 无 hint (不传第 2 参数) ---
    run_fn "$f" "$fn" '出事了'
    assert_has "$f:$fn(无hint) 含错误文本" "$ERR" '出事了'
    assert_not "$f:$fn(无hint) 不打印建议行" "$ERR" 'HINT'
    assert_eq  "$f:$fn(无hint) stdout 干净" "" "$OUT"
    # --- 空 hint (显式传空串, 应与无 hint 等价) ---
    run_fn "$f" "$fn" '出事了' ''
    assert_not "$f:$fn(空hint) 不打印建议行" "$ERR" 'HINT'
done

echo "== T5: 退出码 — 终止型 rc=1; check._check_fail rc=0 =="
run_fn "$COMMON"  print_error 'x' 'y'; assert_eq "print_error rc=1"      "1" "$RC"
run_fn "$BACKUP"  _fail       'x' 'y'; assert_eq "backup._fail rc=1"     "1" "$RC"
run_fn "$CHECK"   _check_fail 'x' 'y'; assert_eq "check._check_fail rc=0(不退出)" "0" "$RC"

echo "== T6: 关键调用点已接入第 2 实参 =="
assert_eq "check.sh 接入 5 处"   "5" "$(grep -c '_hint")' "$CHECK" 2>/dev/null || true)"
assert_eq "handler.sh 接入 4 处" "4" "$(grep -c '_hint")' "$HANDLER" 2>/dev/null || true)"
# 用 'os_hint') 精确定位本轮新增键, 避免误匹配既有的 foreign_hint'
assert_eq "nginx.sh 接入 2 处"   "2" "$(grep -c "os_hint')" "$NGINX" 2>/dev/null || true)"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
