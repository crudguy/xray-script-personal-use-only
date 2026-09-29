#!/usr/bin/env bash
# =============================================================================
# 测试名称: handler_sockopt_test.sh
# 测试目标: _xray_apply_sockopt / _xray_sockopt_mode 的行为回归 —— 出站 sockopt
#           网络调优字段的"实测降级 + 只改 freedom + 合并而非覆盖"三条不变量。
#
# 为什么需要本测试:
#   1) sockopt 里的 tcpUserTimeout / tcpKeepAliveIdle / tcpKeepAliveInterval 属于
#      "低版本 Xray 不认识就拒绝整份配置"的字段, 写错版本会让配置加载失败 ——
#      所以必须逐档实测降级 (full -> minimal -> off), 且 off 档**一字节都不能改**。
#   2) 写入必须 merge 而非 replace: 模板里 direct 出站本来就有 "tcpFastOpen": true,
#      覆盖式赋值会把它悄悄抹掉 (等于回退一个既有优化), 静态检查抓不到这种语义退化。
#   3) 只允许改 protocol=="freedom" 的出站: 误改 wireguard(WARP) 出站会把隧道 socket
#      选项一起拖下水, 而 WARP 出站是路由规则直接引用的 tag, 改错后果由 xray 拒载兜底。
#
# 锁定不变量:
#   T1 full 档      —— 四个字段齐备 (tcpFastOpen/tcpUserTimeout/tcpKeepAlive*), 原字段保留
#   T2 作用域       —— blackhole / wireguard 出站未被写入 sockopt; 非 outbounds 段无损
#   T3 minimal 档   —— 只写最保守的 tcpUserTimeout, 不写 keep-alive 字段
#   T4 off 档       —— 整份配置**逐字节不变** (零操作), 且打出一条降级告警
#   T5 探测片段     —— 两次探测的片段确实带上了要验的字段 (锚在真实行为, 防"空探"假绿)
#   T6 full 幂等    —— 连跑两次结果一致 (merge 用 `+` 不会累积垃圾字段)
#   T7 静态契约     —— 刻意不写 tcpcongestion (内核依赖), 且不得出现 tcpNoDelay (该字段不存在)
#
# 实现: 从 core/handler.sh 抽**真实函数体** eval 注入 (不另写实现, 避免漂移);
#   常量亦从源码 grep 出来 eval, 测试里不写死数值。驱动跑在命令替换的子 shell 里,
#   结果经 stdout 传出 —— 副作用 (告警) 走 stderr 重定向到文件后断言。
# =============================================================================
set -Eeuo pipefail

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$REPO"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1 (期望 [$3] 实际 [$2])"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok; else bad "$1 (未包含 [$3]，实际 [$2])"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok; else bad "$1 (不应包含 [$3]，实际 [$2])"; fi; }

SB="$REPO/.workbuddy/tmp/handler_sockopt.$$"
rm -rf "$SB" 2>/dev/null || true
mkdir -p "$SB"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

extract_fn() { # $1=文件 $2=函数名
    awk -v fn="$2" '$0 ~ ("^function " fn "\\(\\) \\{") { g = 1 } g { print } g && /^\}$/ { exit }' "$1"
}

mode_fn="$(extract_fn core/handler.sh _xray_sockopt_mode)"
apply_fn="$(extract_fn core/handler.sh _xray_apply_sockopt)"
[[ -n "$mode_fn" ]] || bad "抽取 _xray_sockopt_mode 失败"
[[ -n "$apply_fn" ]] || bad "抽取 _xray_apply_sockopt 失败"
if [[ "$FAIL" -gt 0 ]]; then echo "==== handler_sockopt_test: PASS=$PASS FAIL=$FAIL ===="; exit 1; fi

# 输入配置: 模拟模板形态 —— direct 已自带 tcpFastOpen, 外加一个**调优片段之外**的字段
# tcpMaxSeg (merge 的真判据: 覆盖式赋值会把它抹掉, 而 so_json 里并不含它, 所以只有
# merge 才能保住)。另含 blackhole 与 WARP 出站, 两者都不该被碰。
IN_CFG='{"outbounds":[{"tag":"direct","protocol":"freedom","sockopt":{"tcpFastOpen":true,"tcpMaxSeg":1440}},{"tag":"block","protocol":"blackhole"},{"tag":"warp-out","protocol":"wireguard","settings":{"secretKey":"k"}}],"log":{"loglevel":"warning"}}'

# ---------------------------------------------------------------------------
# 驱动: 命令替换自带子 shell, 故 eval 注入的函数与桩件都不会污染本进程。
#   PROBE_FULL=1 -> 第一次(full)探测成功; PROBE_MIN=1 -> 第二次(minimal)探测成功
#   FRAG_LOG     -> 每次探测收到的片段逐行留痕 (T5 用)
# ---------------------------------------------------------------------------
run_sockopt() {
    # 常量与源码同源 (readonly 行), 避免测试里写死数值造成漂移
    eval "$(grep -E '^readonly XRAY_SOCKOPT_' core/handler.sh)"
    local _XRAY_SOCKOPT_MODE=''
    _XRAY_PROBE_ERR=''
    local _PROBE_N=0
    _xray_config_probe() {
        _PROBE_N=$((_PROBE_N + 1))
        printf 'PROBE%d:%s\n' "${_PROBE_N}" "${1:-}" >> "${FRAG_LOG:-/dev/null}"
        case "${_PROBE_N}" in
        1) [[ "${PROBE_FULL:-0}" == '1' ]] ;;
        2) [[ "${PROBE_MIN:-0}" == '1' ]] ;;
        *) return 1 ;;
        esac
    }
    _xray_probe_error_hint() { :; }
    print_warn() { printf '%s\n' "$*" >&2; }
    _i18n() { printf '%s' "${1#.}"; }
    eval "${mode_fn}"
    eval "${apply_fn}"
    XRAY_CONFIG="${IN_CFG}"
    _xray_apply_sockopt
    printf '%s' "${XRAY_CONFIG}"
}

FRAG_LOG="${SB}/frag.log"
# 赋值前缀与命令替换同处一行时, bash 先做命令替换再应用赋值 —— 桩件读不到这些值。
# 必须先单独赋值, 再在下一行跑驱动 (子 shell 会继承已赋值的普通变量)。
PROBE_FULL=1 PROBE_MIN=0
out_full="$(run_sockopt 2>"${SB}/warn_full")"
PROBE_FULL=0 PROBE_MIN=1
out_min="$(run_sockopt 2>"${SB}/warn_min")"
PROBE_FULL=0 PROBE_MIN=0
out_off="$(run_sockopt 2>"${SB}/warn_off")"
# 幂等: full 再来一次
PROBE_FULL=1 PROBE_MIN=0
out_full2="$(run_sockopt 2>/dev/null)"

# ---------------------------------------------------------------------------
echo "== T1 full 档: 字段齐备且原字段保留 =="
assert_eq "T1a 出站 sockopt 键集合" \
    "$(printf '%s' "$out_full" | jq -r -c '.outbounds[0].sockopt | keys | sort | join(",")')" \
    "tcpFastOpen,tcpKeepAliveIdle,tcpKeepAliveInterval,tcpMaxSeg,tcpUserTimeout"
assert_eq "T1b tcpFastOpen 原值保留" \
    "$(printf '%s' "$out_full" | jq -r '.outbounds[0].sockopt.tcpFastOpen')" "true"
assert_eq "T1c tcpUserTimeout 值" \
    "$(printf '%s' "$out_full" | jq -r '.outbounds[0].sockopt.tcpUserTimeout')" "10000"
assert_eq "T1d tcpKeepAliveInterval 值" \
    "$(printf '%s' "$out_full" | jq -r '.outbounds[0].sockopt.tcpKeepAliveInterval')" "15"
assert_eq "T1e full 档不打降级告警" "$(cat "${SB}/warn_full")" ""
assert_eq "T1f 调优片段之外的既有字段 (tcpMaxSeg) 被 merge 保住" \
    "$(printf '%s' "$out_full" | jq -r '.outbounds[0].sockopt.tcpMaxSeg')" "1440"

echo "== T2 作用域: 只改 freedom =="
assert_eq "T2a blackhole 未被写入 sockopt" \
    "$(printf '%s' "$out_full" | jq -r '.outbounds[1] | has("sockopt")')" "false"
assert_eq "T2b wireguard(WARP) 未被写入 sockopt" \
    "$(printf '%s' "$out_full" | jq -r '.outbounds[2] | has("sockopt")')" "false"
assert_eq "T2c wireguard settings 原样保留" \
    "$(printf '%s' "$out_full" | jq -r '.outbounds[2].settings.secretKey')" "k"
assert_eq "T2d 非 outbounds 段无损" \
    "$(printf '%s' "$out_full" | jq -r '.log.loglevel')" "warning"

echo "== T3 minimal 档: 只写最保守字段 =="
assert_eq "T3a minimal 键集合" \
    "$(printf '%s' "$out_min" | jq -r -c '.outbounds[0].sockopt | keys | sort | join(",")')" \
    "tcpFastOpen,tcpMaxSeg,tcpUserTimeout"
assert_not_contains "T3b minimal 不写 keep-alive" \
    "$(printf '%s' "$out_min" | jq -r -c '.outbounds[0].sockopt | keys | join(",")')" "tcpKeepAlive"
assert_eq "T3c minimal 仍不打降级告警" "$(cat "${SB}/warn_min")" ""

echo "== T4 off 档: 逐字节零操作 + 告警 =="
assert_eq "T4a off 档配置一字节不变" "$out_off" "$IN_CFG"
assert_contains "T4b off 档打出降级告警 (i18n 键)" \
    "$(cat "${SB}/warn_off")" "handler.sockopt.unsupported"

echo "== T5 探测片段确实带上了要验的字段 =="
assert_contains "T5a full 片段含 tcpUserTimeout" "$(cat "$FRAG_LOG")" 'tcpUserTimeout'
assert_contains "T5b full 片段含 tcpKeepAliveIdle" "$(cat "$FRAG_LOG")" 'tcpKeepAliveIdle'
assert_contains "T5c minimal 片段仅含 tcpUserTimeout" \
    "$(sed -n '2p' "$FRAG_LOG")" '"tcpUserTimeout"'

echo "== T6 full 幂等 =="
assert_eq "T6a 连跑两次结果一致" "$out_full2" "$out_full"

echo "== T7 静态契约 =="
assert_contains "T7a 用 + 合并而非覆盖" "$apply_fn" '((.sockopt // {}) + $so)'
assert_not_contains "T7b 刻意不写 tcpcongestion (内核依赖)" "$apply_fn" 'tcpcongestion'
assert_not_contains "T7c 不得出现 tcpNoDelay (该字段不存在于 sockopt)" "$apply_fn" 'tcpNoDelay'
assert_contains "T7d 只对 freedom 生效" "$apply_fn" '.protocol == "freedom"'
assert_contains "T7e 走 _xray_config_probe 实测" "$mode_fn" '_xray_config_probe'

# ---------------------------------------------------------------------------
echo "== NEG: 负向校验 (只在副本里改坏, 确认断言真能捕获) =="
SHA_BEFORE="$(sha256sum core/handler.sh | awk '{print $1}')"

# NEG1: 把 merge 改成 replace —— 应让 T1b (tcpFastOpen 保留) 变红
python3 - "$SB/broken_merge.sh" <<'PY'
import sys
src = open('core/handler.sh', encoding='utf-8').read()
old = '.sockopt = ((.sockopt // {}) + $so)'
assert old in src, 'NEG1 锚点未命中: merge 表达式已变'
open(sys.argv[1], 'w', encoding='utf-8').write(src.replace(old, '.sockopt = $so'))
PY
b_apply="$(extract_fn "$SB/broken_merge.sh" _xray_apply_sockopt)"
assert_not_contains "NEG1 改坏后 merge 表达式消失 (故 T1b 判据有效)" "$b_apply" '((.sockopt // {}) + $so)'
apply_fn_save="$apply_fn"
apply_fn="$b_apply"
neg1="$(run_sockopt 2>/dev/null)"
apply_fn="$apply_fn_save"
assert_not_contains "NEG1 改坏后 tcpMaxSeg 真的丢了 (故 T1f 判据有效)" "$neg1" '"tcpMaxSeg": 1440'

# NEG2: 去掉 freedom 过滤 —— 应让 T2a/T2b (作用域) 变红
python3 - "$SB/broken_scope.sh" <<'PY'
import sys
src = open('core/handler.sh', encoding='utf-8').read()
old = 'if .protocol == "freedom"'
assert old in src, 'NEG2 锚点未命中: freedom 过滤已变'
open(sys.argv[1], 'w', encoding='utf-8').write(src.replace(old, 'if true'))
PY
b_apply2="$(extract_fn "$SB/broken_scope.sh" _xray_apply_sockopt)"
apply_fn="$b_apply2"
neg2="$(run_sockopt 2>/dev/null)"
apply_fn="$apply_fn_save"
assert_eq "NEG2 改坏后 blackhole 真的被写入了" \
    "$(printf '%s' "$neg2" | jq -r '.outbounds[1] | has("sockopt")')" "true"

SHA_AFTER="$(sha256sum core/handler.sh | awk '{print $1}')"
assert_eq "NEG 复核: 工作区 core/handler.sh 未被改动" "$SHA_AFTER" "$SHA_BEFORE"

echo "---"
echo "==== handler_sockopt_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
