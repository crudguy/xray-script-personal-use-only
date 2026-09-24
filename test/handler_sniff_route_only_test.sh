#!/usr/bin/env bash
# =============================================================================
# 测试名称: handler_sniff_route_only_test.sh
# 测试目标: sniffing.routeOnly 可选开关的行为回归 —— "_xray_apply_sniffing 的默认零改写
#           + 残留清理 + 只碰已启用嗅探的入站" 与 _xray_sniff_mode 的实测降级。
#
# 为什么需要本测试:
#   1) 该开关的**核心承诺是"默认关 = 与引入前逐字节一致"**。若关闭路径无条件改写配置,
#      所有未使用该功能的用户都会在下一次"更新配置"时拿到一份被重排/被重写的配置 ——
#      行为无差别、但产物有差别, 属"静默改变既有产出"。故必须锁住"无残留即零改写"。
#   2) routeOnly 写入必须限定在 `sniffing.enabled == true` 的入站上: 模板里 inbound[0]
#      的 sniffing 是 null, 另有无 sniffing 段的入站。对 null 做 .sniffing.routeOnly = true
#      会凭空造出 `{"sniffing":{"routeOnly":true}}` 这样的半残段。
#   3) 关闭方向要能清残留 —— 手工编辑过的运行配置 / 未来模板若带该字段, 关闭后必须消失,
#      否则开关"关不干净"。
#   4) 切换臂与 handler_warp 同序: **先写配置并复核, 成功后记状态**。写失败时状态不得改变,
#      否则界面显示"已开启"而配置没有, 用户无从察觉。
#
# 锁定不变量:
#   T1 默认关   —— 无残留时整份配置逐字节不变 (零改写), 且不触发探测
#   T2 清残留   —— 关 + 有残留 -> 残留被删, 同级/相邻字段无损
#   T3 边界     —— sniffing 为 null / 无 sniffing 段 / enabled:false 的入站一律不碰
#   T4 开启     —— 仅 enabled==true 的入站被加 routeOnly:true, destOverride 原样保留
#   T5 不支持   —— 探测失败时一字节不改, 并打出降级告警
#   T6 探测片段 —— 片段确实带上 routeOnly (锚在真实行为, 防"空探"假绿)
#   T7 切换臂   —— 未装 Xray / 缺运行配置 / 不支持 -> 非 0 且**不写配置**;
#                 关->开 / 开->关 -> 写配置 + 状态同步
#   T8 静态契约 —— 接入 handler_xray_config / CLI / 菜单 / reset 保留列表 / i18n
#
# 实现: 从 core/handler.sh 抽**真实函数体** eval 注入 (不另写实现, 避免漂移); 常量亦从
#   源码 grep 出来 eval, 测试里不写死数值。驱动跑在命令替换的子 shell 里, 结果经 stdout
#   传出 —— 副作用 (告警) 走 stderr 重定向到文件后断言。
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

SB="$REPO/.workbuddy/tmp/handler_sniff.$$"
rm -rf "$SB" 2>/dev/null || true
mkdir -p "$SB"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

extract_fn() { # $1=文件 $2=函数名
    awk -v fn="$2" '$0 ~ ("^function " fn "\\(\\) \\{") { g = 1 } g { print } g && /^\}$/ { exit }' "$1"
}

mode_fn="$(extract_fn core/handler.sh _xray_sniff_mode)"
apply_fn="$(extract_fn core/handler.sh _xray_apply_sniffing)"
toggle_fn="$(extract_fn core/handler.sh handler_toggle_sniff_route_only)"
is_en_fn="$(extract_fn core/_common.sh is_enabled)"
[[ -n "$mode_fn" ]] || bad "抽取 _xray_sniff_mode 失败"
[[ -n "$apply_fn" ]] || bad "抽取 _xray_apply_sniffing 失败"
[[ -n "$toggle_fn" ]] || bad "抽取 handler_toggle_sniff_route_only 失败"
[[ -n "$is_en_fn" ]] || bad "抽取 is_enabled 失败"
if [[ "$FAIL" -gt 0 ]]; then echo "==== handler_sniff_route_only_test: PASS=$PASS FAIL=$FAIL ===="; exit 1; fi

# 输入配置: 覆盖四种入站形态 —— sniffing 为 null / enabled:true / enabled:false / 无 sniffing 段。
# 另含 outbounds 与 log 段, 用于验证非 inbounds 内容无损。
IN_CFG='{"inbounds":[{"tag":"api","port":10085,"protocol":"dokodemo-door","sniffing":null,"settings":{"address":"127.0.0.1"}},{"tag":"vless-in","port":443,"protocol":"vless","sniffing":{"enabled":true,"destOverride":["http","tls","quic"]},"settings":{"clients":[{"id":"u1"}],"decryption":"none"}},{"tag":"tunnel","port":8443,"protocol":"vless","sniffing":{"enabled":false,"destOverride":["http","tls"]},"settings":{}},{"tag":"plain","port":9000,"protocol":"vmess","settings":{}}],"outbounds":[{"tag":"direct","protocol":"freedom","sockopt":{"tcpFastOpen":true}},{"tag":"block","protocol":"blackhole"}],"log":{"loglevel":"warning"}}'
# 带残留的输入 (模拟手工编辑过 / 旧版模板): 关闭方向必须把它清掉
IN_CFG_RESIDUAL='{"inbounds":[{"tag":"api","port":10085,"protocol":"dokodemo-door","sniffing":null,"settings":{"address":"127.0.0.1"}},{"tag":"vless-in","port":443,"protocol":"vless","sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true},"settings":{"clients":[{"id":"u1"}],"decryption":"none"}}],"outbounds":[{"tag":"direct","protocol":"freedom","sockopt":{"tcpFastOpen":true}}],"log":{"loglevel":"warning"}}'

# ---------------------------------------------------------------------------
# 驱动: 命令替换自带子 shell, 故 eval 注入的函数与桩件都不会污染本进程。
#   SNIFF_ON    -> 开关状态 (1 开 / 0 关)
#   PROBE_OK    -> 实测探测是否成功
#   FRAG_LOG    -> 每次探测收到的片段逐行留痕 (T6 用)
# ---------------------------------------------------------------------------
run_apply() {
    # 常量与源码同源 (readonly 行), 避免测试里写死数值造成漂移
    eval "$(grep -E '^readonly XRAY_SNIFF_PROBE_PORT=' core/handler.sh)"
    local _XRAY_SNIFF_MODE=''
    _XRAY_PROBE_ERR=''
    local _PROBE_N=0
    _xray_config_probe() {
        _PROBE_N=$((_PROBE_N + 1))
        printf 'PROBE%d:%s\n' "${_PROBE_N}" "${1:-}" >> "${FRAG_LOG:-/dev/null}"
        [[ "${PROBE_OK:-0}" == '1' ]]
    }
    _xray_probe_error_hint() { :; }
    print_warn() { printf 'WARN:%s\n' "$*" >&2; }
    _i18n() { printf '%s' "${1#.}"; }
    eval "${is_en_fn}"
    eval "${mode_fn}"
    eval "${apply_fn}"
    # 注: 刻意不加 local —— 该变量以动态作用域注入给 eval 进来的 _xray_apply_sniffing。
    # shellcheck disable=SC2034  # 由 eval 注入的被测函数体读取 (shellcheck 数据流不跨 eval)
    XRAY_SNIFF_ROUTE_ONLY="${SNIFF_ON:-0}"
    XRAY_CONFIG="${IN_CFG_SEL:-$IN_CFG}"
    _xray_apply_sniffing
    printf '%s' "${XRAY_CONFIG}"
}

FRAG_OFF="${SB}/frag_off.log"
FRAG_ON="${SB}/frag_on.log"
# 赋值前缀与命令替换同处一行时, bash 先做命令替换再应用赋值 —— 桩件读不到这些值。
# 必须先单独赋值, 再在下一行跑驱动 (子 shell 会继承已赋值的普通变量)。
# 注: IN_CFG_SEL 与 FRAG_LOG 每段都要显式重置 —— 前者是普通变量, 一旦指向 residual
#     版, 后续用例的 inbound 下标就会越界; 后者是累积日志, 不隔离则"关档不探测"
#     的断言会被后面开档的探测记录污染 (实测踩到过一次)。
SNIFF_ON=0 PROBE_OK=0 IN_CFG_SEL="$IN_CFG" FRAG_LOG="$FRAG_OFF"
out_off="$(run_apply 2>"${SB}/warn_off")"
SNIFF_ON=0 PROBE_OK=0 IN_CFG_SEL="$IN_CFG_RESIDUAL" FRAG_LOG="${SB}/frag_off_res.log"
out_off_res="$(run_apply 2>"${SB}/warn_off_res")"
SNIFF_ON=1 PROBE_OK=1 IN_CFG_SEL="$IN_CFG" FRAG_LOG="$FRAG_ON"
out_on="$(run_apply 2>"${SB}/warn_on")"
SNIFF_ON=1 PROBE_OK=0 IN_CFG_SEL="$IN_CFG" FRAG_LOG="${SB}/frag_unsup.log"
out_unsup="$(run_apply 2>"${SB}/warn_unsup")"
# 幂等: 开启再来一次
SNIFF_ON=1 PROBE_OK=1 IN_CFG_SEL="$IN_CFG" FRAG_LOG="${SB}/frag_on2.log"
out_on2="$(run_apply 2>/dev/null)"

# ---------------------------------------------------------------------------
echo "== T1 默认关: 无残留时逐字节零改写 =="
assert_eq "T1a 关档配置一字节不变" "$out_off" "$IN_CFG"
assert_eq "T1b 关档不打任何告警" "$(cat "${SB}/warn_off")" ""
assert_eq "T1c 关档不触发探测 (省一次 xray -test)" "$(cat "$FRAG_OFF" 2>/dev/null || true)" ""

echo "== T2 关档清残留 =="
assert_eq "T2a 残留 routeOnly 被删除" \
    "$(printf '%s' "$out_off_res" | jq -r '.inbounds[1].sniffing | has("routeOnly")')" "false"
assert_eq "T2b 同级 destOverride 无损" \
    "$(printf '%s' "$out_off_res" | jq -r -c '.inbounds[1].sniffing.destOverride')" '["http","tls","quic"]'
assert_eq "T2c enabled 无损" \
    "$(printf '%s' "$out_off_res" | jq -r '.inbounds[1].sniffing.enabled')" "true"
assert_eq "T2d 其余 inbound 不被增删" \
    "$(printf '%s' "$out_off_res" | jq -r '.inbounds | length')" "2"

echo "== T3 边界: 只碰已启用嗅探的入站 =="
assert_eq "T3a sniffing 为 null 的入站保持 null (未被注入半残段)" \
    "$(printf '%s' "$out_on" | jq -r '.inbounds[0].sniffing')" "null"
assert_eq "T3b enabled:false 的入站不加 routeOnly" \
    "$(printf '%s' "$out_on" | jq -r '.inbounds[2].sniffing | has("routeOnly")')" "false"
assert_eq "T3c 无 sniffing 段的入站不产生该段" \
    "$(printf '%s' "$out_on" | jq -r '.inbounds[3] | has("sniffing")')" "false"

echo "== T4 开启: 只加 routeOnly, 其余原样 =="
assert_eq "T4a enabled:true 的入站写入 routeOnly" \
    "$(printf '%s' "$out_on" | jq -r '.inbounds[1].sniffing.routeOnly')" "true"
assert_eq "T4b destOverride 原样保留" \
    "$(printf '%s' "$out_on" | jq -r -c '.inbounds[1].sniffing.destOverride')" '["http","tls","quic"]'
assert_eq "T4c sniffing 键集合 (只多 routeOnly)" \
    "$(printf '%s' "$out_on" | jq -r -c '.inbounds[1].sniffing | keys | sort | join(",")')" \
    "destOverride,enabled,routeOnly"
assert_eq "T4d 非 inbounds 段无损" \
    "$(printf '%s' "$out_on" | jq -r '.log.loglevel')" "warning"
assert_eq "T4e 出站 sockopt 无损" \
    "$(printf '%s' "$out_on" | jq -r '.outbounds[0].sockopt.tcpFastOpen')" "true"
assert_eq "T4f 开启且支持时不打降级告警" "$(cat "${SB}/warn_on")" ""

echo "== T5 本机不支持时一字节不改 =="
assert_eq "T5a 不支持档配置逐字节不变" "$out_unsup" "$IN_CFG"
assert_contains "T5b 打出降级告警 (i18n 键)" "$(cat "${SB}/warn_unsup")" "handler.sniffing.unsupported"

echo "== T6 探测片段确实带上 routeOnly =="
assert_contains "T6a 片段含 routeOnly" "$(cat "$FRAG_ON")" 'routeOnly'
assert_contains "T6b 片段含 destOverride (贴近真实形态)" "$(cat "$FRAG_ON")" 'destOverride'

echo "== T7 开启幂等 =="
assert_eq "T7a 连跑两次结果一致" "$out_on2" "$out_on"

# ---------------------------------------------------------------------------
# T8: 切换臂 —— 状态/配置写入与"失败不留脏状态"
# ---------------------------------------------------------------------------
echo "== T8 切换臂: 状态与配置写入 =="
run_toggle() {
    eval "$(grep -E '^readonly XRAY_SNIFF_PROBE_PORT=' core/handler.sh)"
    # 同上: 不以 local 声明, 由 eval 注入的 handler_toggle_sniff_route_only 读取
    # shellcheck disable=SC2034  # 由 eval 注入的被测函数体读取 (shellcheck 数据流不跨 eval)
    XRAY_CONFIG_PATH="${SB}/xray.json"
    local _XRAY_SNIFF_MODE=''
    _XRAY_PROBE_ERR=''
    _xray_config_probe() { [[ "${PROBE_OK:-0}" == '1' ]]; }
    _xray_probe_error_hint() { :; }
    print_warn() { printf 'WARN:%s\n' "$*" >&2; }
    print_info() { printf 'INFO:%s\n' "$*" >&2; }
    _i18n() { printf '%s' "${1#.}"; }
    # 桩: 把落盘动作换成写沙箱文件, 便于断言"到底有没有写"
    persist_xray_config() { printf '%s' "${XRAY_CONFIG}" > "${PERSIST_LOG}"; return "${PERSIST_RC:-0}"; }
    persist_script_config() { printf '%s' "${SCRIPT_CONFIG}" > "${SC_LOG}"; return 0; }
    eval "${is_en_fn}"
    eval "${mode_fn}"
    eval "${apply_fn}"
    eval "${toggle_fn}"
    SCRIPT_CONFIG="${IN_SC}"
    local rc=0
    handler_toggle_sniff_route_only || rc=$?
    printf 'RC=%s\n' "${rc}"
}

# 场景一: 未装 Xray (.xray.version 为空)
IN_SC='{"xray":{"version":"","sniffRouteOnly":0}}'
rm -f "${SB}/p1" "${SB}/s1"
PERSIST_LOG="${SB}/p1" SC_LOG="${SB}/s1"
t1="$(run_toggle 2>"${SB}/w_t1")"
assert_eq "T8a 未装 Xray 返回非 0" "$t1" "RC=1"
assert_contains "T8b 未装 Xray 提示 (i18n 键)" "$(cat "${SB}/w_t1")" "handler.sniffing.not_installed"
assert_eq "T8c 未装 Xray 不写运行配置" "$([[ -f "${SB}/p1" ]] && echo yes || echo no)" "no"
assert_eq "T8d 未装 Xray 不写脚本配置" "$([[ -f "${SB}/s1" ]] && echo yes || echo no)" "no"

# 场景二: 已装但缺运行配置
IN_SC='{"xray":{"version":"1.0.0","sniffRouteOnly":0}}'
rm -f "${SB}/p2" "${SB}/s2" "${SB}/xray.json"
PERSIST_LOG="${SB}/p2" SC_LOG="${SB}/s2"
t2="$(run_toggle 2>"${SB}/w_t2")"
assert_eq "T8e 缺运行配置返回非 0" "$t2" "RC=1"
assert_contains "T8f 缺运行配置提示 (i18n 键)" "$(cat "${SB}/w_t2")" "handler.sniffing.no_config"
assert_eq "T8g 缺运行配置不写任何东西" "$([[ -f "${SB}/p2" ]] && echo yes || echo no)" "no"

# 场景三: 关 -> 开 (支持)
printf '%s' "$IN_CFG" >"${SB}/xray.json"
IN_SC='{"xray":{"version":"1.0.0","sniffRouteOnly":0}}'
rm -f "${SB}/p3" "${SB}/s3"
PERSIST_LOG="${SB}/p3" SC_LOG="${SB}/s3" PROBE_OK=1
t3="$(run_toggle 2>"${SB}/w_t3")"
assert_eq "T8h 关->开 返回 0" "$t3" "RC=0"
assert_contains "T8i 关->开 提示已开启 (i18n 键)" "$(cat "${SB}/w_t3")" "handler.sniffing.enabled"
assert_eq "T8j 运行配置被写入 routeOnly" \
    "$(jq -r '.inbounds[1].sniffing.routeOnly' "${SB}/p3")" "true"
assert_eq "T8k 脚本配置状态置 1" "$(jq -r '.xray.sniffRouteOnly' "${SB}/s3")" "1"

# 场景四: 开 -> 关 (清残留)
printf '%s' "$IN_CFG_RESIDUAL" >"${SB}/xray.json"
IN_SC='{"xray":{"version":"1.0.0","sniffRouteOnly":1}}'
rm -f "${SB}/p4" "${SB}/s4"
PERSIST_LOG="${SB}/p4" SC_LOG="${SB}/s4" PROBE_OK=1
t4="$(run_toggle 2>"${SB}/w_t4")"
assert_eq "T8l 开->关 返回 0" "$t4" "RC=0"
assert_contains "T8m 开->关 提示已关闭 (i18n 键)" "$(cat "${SB}/w_t4")" "handler.sniffing.disabled"
assert_eq "T8n 关闭后残留被清掉" \
    "$(jq -r '.inbounds[1].sniffing | has("routeOnly")' "${SB}/p4")" "false"
assert_eq "T8o 脚本配置状态置 0" "$(jq -r '.xray.sniffRouteOnly' "${SB}/s4")" "0"

# 场景五: 开方向但本机不支持 -> 不留半开状态
printf '%s' "$IN_CFG" >"${SB}/xray.json"
IN_SC='{"xray":{"version":"1.0.0","sniffRouteOnly":0}}'
rm -f "${SB}/p5" "${SB}/s5"
PERSIST_LOG="${SB}/p5" SC_LOG="${SB}/s5" PROBE_OK=0
t5="$(run_toggle 2>"${SB}/w_t5")"
assert_eq "T8p 不支持时返回非 0" "$t5" "RC=1"
assert_eq "T8q 不支持时不写运行配置" "$([[ -f "${SB}/p5" ]] && echo yes || echo no)" "no"
assert_eq "T8r 不支持时不写状态 (不留半开)" "$([[ -f "${SB}/s5" ]] && echo yes || echo no)" "no"
assert_contains "T8s 不支持时提示降级原因" "$(cat "${SB}/w_t5")" "handler.sniffing.unsupported"

# 场景六: 落盘复核失败 -> 状态不得改变
printf '%s' "$IN_CFG" >"${SB}/xray.json"
IN_SC='{"xray":{"version":"1.0.0","sniffRouteOnly":0}}'
rm -f "${SB}/p6" "${SB}/s6"
PERSIST_LOG="${SB}/p6" SC_LOG="${SB}/s6" PROBE_OK=1 PERSIST_RC=1
t6="$(run_toggle 2>/dev/null)"
assert_eq "T8t 落盘失败返回非 0" "$t6" "RC=1"
assert_eq "T8u 落盘失败不写状态 (界面不会谎报已开启)" \
    "$([[ -f "${SB}/s6" ]] && echo yes || echo no)" "no"
PROBE_OK=0 PERSIST_RC=0

# ---------------------------------------------------------------------------
echo "== T9 静态契约 (锚在真实调用行, 防注释误命中) =="
assert_contains "T9a 关闭路径先判残留才改写 (保默认零改写)" "$apply_fn" 'has_residual'
assert_contains "T9b 关闭路径删除字段" "$apply_fn" 'del(.sniffing.routeOnly)'
assert_contains "T9c 判据锚在 enabled" "$apply_fn" '.sniffing.enabled == true'
assert_contains "T9d 走 _xray_config_probe 实测" "$mode_fn" '_xray_config_probe'
assert_contains "T9e 探测片段带 routeOnly" "$mode_fn" 'routeOnly: true'
assert_contains "T9f toggle 先写配置成功后才记状态" "$toggle_fn" 'if ! persist_xray_config; then'
assert_contains "T9g handler_xray_config 接入生成流程" \
    "$(grep -cE '^[[:space:]]*_xray_apply_sniffing([[:space:]]|$)' core/handler.sh || true)" "2"
assert_contains "T9h reset 保留列表含 sniffRouteOnly" \
    "$(extract_fn core/handler.sh handler_reset_script_config)" "'version' 'warp' 'rules' 'sniffRouteOnly'"
assert_contains "T9i CLI 分派存在" \
    "$(grep -cE '^[[:space:]]*--sniff-route-only\)' core/handler.sh || true)" "1"
assert_contains "T9j 菜单项存在" "$(grep -c 'config_management.option9' core/menu.sh || true)" "1"
assert_contains "T9k 菜单分派存在" "$(grep -c "'--sniff-route-only'" core/main.sh || true)" "1"
assert_contains "T9l zh i18n 键存在" \
    "$(python3 -c "import json;d=json.load(open('i18n/zh.json',encoding='utf-8'));print('ok' if 'option9' in d['menu']['config_management'] and 'unsupported' in d['handler']['sniffing'] else 'missing')")" "ok"
assert_contains "T9m en i18n 键存在" \
    "$(python3 -c "import json;d=json.load(open('i18n/en.json',encoding='utf-8'));print('ok' if 'option9' in d['menu']['config_management'] and 'unsupported' in d['handler']['sniffing'] else 'missing')")" "ok"
# 官方文档: routeOnly "需要开启 destOverride 使用"。作用域判据只圈 enabled 而不检查
# destOverride, 其前提是**模板的 sniffing 恒带非空 destOverride** —— 若将来有人把它删了,
# 开关会静默失效 (写入的 routeOnly 不再起作用), 这条断言就是那个报警器。
assert_eq "T9n 所有模板的启用嗅探入站都带非空 destOverride" \
    "$(for f in config/xray/*.json; do jq -r '[.inbounds[]? | select(.sniffing.enabled == true) | ((.sniffing.destOverride // []) | length > 0)] | all' "$f"; done | sort -u | tr '\n' ' ')" \
    "true "

# ---------------------------------------------------------------------------
echo "== NEG: 负向校验 (只在副本里改坏, 确认断言真能捕获) =="
SHA_BEFORE="$(sha256sum core/handler.sh | awk '{print $1}')"

# NEG1: 去掉"先判残留"的短路 —— 默认关路径会无条件改写, T1a 应变红
python3 - "$SB/broken_res.sh" <<'PY'
import sys
src = open('core/handler.sh', encoding='utf-8').read()
old = 'if [[ "${has_residual}" == \'true\' ]]; then'
assert old in src, 'NEG1 锚点未命中: has_residual 判据已变'
open(sys.argv[1], 'w', encoding='utf-8').write(src.replace(old, 'if true; then'))
PY
b_apply="$(extract_fn "$SB/broken_res.sh" _xray_apply_sniffing)"
assert_not_contains "NEG1 改坏后残留判据消失 (故 T1a 判据有效)" "$b_apply" "has_residual\" == 'true'"
apply_fn_save="$apply_fn"
apply_fn="$b_apply"
SNIFF_ON=0 PROBE_OK=0 IN_CFG_SEL="$IN_CFG" FRAG_LOG="${SB}/frag_neg1.log"
neg1="$(run_apply 2>/dev/null)"
apply_fn="$apply_fn_save"
# 无条件改写会把配置交给 jq 重新序列化, 产物不再与原始紧凑串逐字节相同
assert_eq "NEG1 改坏后产物真的变了 (故 T1a 判据有效)" \
    "$([[ "$neg1" == "$IN_CFG" ]] && echo same || echo diff)" "diff"

# NEG2: 把 enabled 判据改成"总是真" —— null 入站会被注入半残 sniffing, T3a 应变红
python3 - "$SB/broken_scope.sh" <<'PY'
import sys
src = open('core/handler.sh', encoding='utf-8').read()
old = 'if .sniffing.enabled == true'
assert old in src, 'NEG2 锚点未命中: enabled 判据已变'
open(sys.argv[1], 'w', encoding='utf-8').write(src.replace(old, 'if true'))
PY
b_apply2="$(extract_fn "$SB/broken_scope.sh" _xray_apply_sniffing)"
apply_fn="$b_apply2"
SNIFF_ON=1 PROBE_OK=1 IN_CFG_SEL="$IN_CFG" FRAG_LOG="${SB}/frag_neg2.log"
neg2="$(run_apply 2>/dev/null)"
apply_fn="$apply_fn_save"
assert_eq "NEG2 改坏后 null 入站真的被造出 sniffing 段" \
    "$(printf '%s' "$neg2" | jq -r '.inbounds[0].sniffing.routeOnly')" "true"

# NEG3: 把 toggle 的顺序倒过来 (先记状态再写配置) —— PERSIST_RC=1 时 T8u 应变红
python3 - "$SB/broken_order.sh" <<'PY'
import sys
src = open('core/handler.sh', encoding='utf-8').read()
old = """    if ! persist_xray_config; then
        return 1
    fi
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --argjson v "${next}" '.xray.sniffRouteOnly = $v')"
    persist_script_config"""
assert old in src, 'NEG3 锚点未命中: toggle 顺序已变'
new = """    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --argjson v "${next}" '.xray.sniffRouteOnly = $v')"
    persist_script_config
    if ! persist_xray_config; then
        return 1
    fi"""
open(sys.argv[1], 'w', encoding='utf-8').write(src.replace(old, new))
PY
b_toggle="$(extract_fn "$SB/broken_order.sh" handler_toggle_sniff_route_only)"
toggle_fn_save="$toggle_fn"
toggle_fn="$b_toggle"
printf '%s' "$IN_CFG" >"${SB}/xray.json"
IN_SC='{"xray":{"version":"1.0.0","sniffRouteOnly":0}}'
rm -f "${SB}/p7" "${SB}/s7"
PERSIST_LOG="${SB}/p7" SC_LOG="${SB}/s7" PROBE_OK=1 PERSIST_RC=1
neg3t="$(run_toggle 2>/dev/null)"
toggle_fn="$toggle_fn_save"
PROBE_OK=0 PERSIST_RC=0
assert_eq "NEG3 改坏后仍返回非 0 (剧本确实跑到了)" "$neg3t" "RC=1"
assert_eq "NEG3 改坏后落盘失败仍写了状态 (故 T8u 判据有效)" \
    "$([[ -f "${SB}/s7" ]] && echo yes || echo no)" "yes"

SHA_AFTER="$(sha256sum core/handler.sh | awk '{print $1}')"
assert_eq "NEG 复核: 工作区 core/handler.sh 未被改动" "$SHA_AFTER" "$SHA_BEFORE"

echo "---"
echo "==== handler_sniff_route_only_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
