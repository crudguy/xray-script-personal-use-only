#!/usr/bin/env bash
# =============================================================================
# 测试名称: handler_change_xray_port_arm_test.sh
# 测试目标: 换端口这条链路的**决策层**回归 —— mkcp/其它 tag 的分支选择、空输入回落、
#           大小写不敏感、随机端口生成失败时的兜底, 以及 CLI 侧"改完必须跟着收口"。
#
# 为什么需要本测试 (审计背景):
#   handler_change_xray_port 属"改配置即改现场"的臂: 它写进 SCRIPT_CONFIG, 而后续
#   的 handler_xray_config / restart / share 都以这份快照为准。此前在全仓零覆盖。
#   它的分支全部由 `.xray.tag` 驱动 (mkcp 走随机端口, 其它走默认 443), **没有 GUI 可
#   见的中间产物**, 走错分支的表现只是"端口不对", 看一眼分享链接才会发现。
#
#   另一处是 spec313 在追的现实路径: mkcp 下用户直接回车 -> 由 generate.sh 现算端口。
#   若 generate.sh 没能算出值 (od/shuf 缺失、脚本异常), 旧写法会把**空串**直接喂给
#   `jq --argjson port ""` —— jq 报错 -> 赋值失败 -> set -e 把整个人机交互脚本带走,
#   用户看到的是"脚本在第 N 行意外失败"这类和自己操作毫无关系的提示。已改为回落到
#   默认端口 (见 core/handler.sh 内注释), 本测试把两种情形都钉住。
#
# 锁定不变量:
#   T1 mkcp + 有输入   -> 用用户输入, **不调** generate
#   T2 mkcp + 空输入   -> 调 generate, 用其返回值
#   T3 其它 tag + 空   -> 回落 443
#   T4 其它 tag + 有   -> 用用户输入
#   T5 tag 大小写不敏感 (MKCP / Mkcp 同算 mkcp)
#   T6 tag 缺失/为空   -> 回落 443
#   T7 写出的是 JSON number (不是字符串 —— 下游 jq 比较与模板插值类型敏感)
#   T8 persist 恰好一次; 同层其它字段无损
#   T9 generate 返回空 -> 回落 443, 不得让 jq 把脚本带走
#   T10 CLI 契约     -- --change-port 必须串起 "改端口 -> 更新配置 -> 重启 -> 分享链接"
#
# 实现: 从 core/handler.sh 抽**真实函数体** eval 注入; 桩只替换外边界
#   (exec_read / exec_generate / persist_script_config)。被 eval 的函数体经 ( ) 子 shell
#   调用 —— jq 失败会带 set -e 直接终止进程, 不隔离就没法断言"确实崩了"。
# =============================================================================
set -Eeuo pipefail

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$REPO"

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not available in this environment"
    exit 0
fi

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1 (期望 [$3] 实际 [$2])"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok; else bad "$1 (未包含 [$3]，实际 [$2])"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok; else bad "$1 (不应包含 [$3]，实际 [$2])"; fi; }
# 计行 helper: 文件缺失记作 0 —— "不该有副作用"的场景本就不会生成该文件。
count_lines() { # $1=正则 $2=文件
    if [[ -f "$2" ]]; then
        grep -c "$1" "$2" || true
    else
        printf '0'
    fi
}

SB="$REPO/.workbuddy/tmp/handler_port.$$"
rm -rf "$SB" 2>/dev/null || true
mkdir -p "$SB"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

extract_fn() { # $1=文件 $2=函数名
    awk -v fn="$2" '$0 ~ ("^function " fn "\\(\\) \\{") { g = 1 } g { print } g && /^\}$/ { exit }' "$1"
}

port_fn="$(extract_fn core/handler.sh handler_change_xray_port)"
[[ -n "$port_fn" ]] || bad "抽取 handler_change_xray_port 失败"
if [[ "$FAIL" -gt 0 ]]; then echo "==== handler_change_xray_port_arm_test: PASS=$PASS FAIL=$FAIL ===="; exit 1; fi

SC_MKCP='{"xray":{"version":"v2026-01-01","tag":"mkcp","port":443,"uuid":"u-1","path":"/x"}}'
SC_VISION='{"xray":{"version":"v2026-01-01","tag":"vision","port":443,"uuid":"u-1","path":"/x"}}'
SC_NOTAG='{"xray":{"version":"v2026-01-01","tag":"","port":443,"uuid":"u-1","path":"/x"}}'
SC_UPPER='{"xray":{"version":"v2026-01-01","tag":"MKCP","port":443,"uuid":"u-1","path":"/x"}}'

# ---------------------------------------------------------------------------
# 驱动: 与 handler_routing 那套同理 —— 开关先单独赋值再跑 (赋值前缀会被命令替换吃掉),
# 轨迹文件每例独立。结果经文本文件回传 (子 shell 里 set-e 崩溃时, stdout 不可信)。
# ---------------------------------------------------------------------------
run_port() {
    declare -A CONFIG_DATA
    local plog="$PLOG" cfgout="$CFGOUT"
    local rc=0
    SCRIPT_CONFIG="${SC_SEL}"
    exec_read() {
        printf 'READ:%s\n' "${1:-}" >>"$plog"
        # 只被 eval 注入的被测函数体读取 —— shellcheck 数据流不跨 eval, 会报 SC2034。
        # shellcheck disable=SC2034
        CONFIG_DATA['port']="${PORT_IN:-}"
    }
    exec_generate() {
        printf 'GEN:%s\n' "${1:-}" >>"$plog"
        printf '%s' "${GEN_PORT:-}"
    }
    persist_script_config() {
        printf 'PERSIST\n' >>"$plog"
        printf '%s' "${SCRIPT_CONFIG}" >"$cfgout"
    }
    eval "$port_fn"
    (handler_change_xray_port) || rc=$?
    printf 'RC=%s\n' "$rc"
    # 压缩成一行输出 —— jq 默认是 pretty print, 多行的配置会让上层的"取第 2 行"错位。
    if [[ -s "$cfgout" ]]; then jq -c . "$cfgout"; fi
    if [[ -f "$plog" ]]; then cat "$plog"; fi
    return 0
}

# helper: 从一次运行的输出里取 .xray.port
port_of() { printf '%s' "$1" | sed -n '2p' | jq -r '.xray.port // empty'; }

echo "== T1 mkcp + 有输入 -> 用输入, 不调 generate =="
SC_SEL="$SC_MKCP" PORT_IN='8443' GEN_PORT='41234' PLOG="$SB/t1.log" CFGOUT="$SB/t1.json"
out="$(run_port 2>"$SB/t1.err")"
assert_contains "T1a rc=0" "$out" 'RC=0'
assert_eq "T1b 端口 = 用户输入" "$(port_of "$out")" '8443'
assert_not_contains "T1c 有输入时不劳 generate" "$out" 'GEN:'

echo "== T2 mkcp + 空输入 -> 调 generate 并取其值 =="
SC_SEL="$SC_MKCP" PORT_IN='' GEN_PORT='41234' PLOG="$SB/t2.log" CFGOUT="$SB/t2.json"
out="$(run_port 2>"$SB/t2.err")"
assert_contains "T2a rc=0" "$out" 'RC=0'
assert_contains "T2b 确实调了 generate --port" "$out" 'GEN:--port'
assert_eq "T2c 端口 = generate 返回值" "$(port_of "$out")" '41234'

echo "== T3 其它 tag + 空输入 -> 回落 443 =="
SC_SEL="$SC_VISION" PORT_IN='' GEN_PORT='41234' PLOG="$SB/t3.log" CFGOUT="$SB/t3.json"
out="$(run_port 2>"$SB/t3.err")"
assert_eq "T3a 端口 = 443" "$(port_of "$out")" '443'
assert_not_contains "T3b 非 mkcp 不调 generate" "$out" 'GEN:'

echo "== T4 其它 tag + 有输入 -> 用输入 =="
SC_SEL="$SC_VISION" PORT_IN='8443' GEN_PORT='41234' PLOG="$SB/t4.log" CFGOUT="$SB/t4.json"
out="$(run_port 2>"$SB/t4.err")"
assert_eq "T4a 端口 = 用户输入" "$(port_of "$out")" '8443'

echo "== T5 tag 大小写不敏感 =="
SC_SEL="$SC_UPPER" PORT_IN='' GEN_PORT='40001' PLOG="$SB/t5.log" CFGOUT="$SB/t5.json"
out="$(run_port 2>"$SB/t5.err")"
assert_contains "T5a 大写 MKCP 也算 mkcp" "$out" 'GEN:--port'
assert_eq "T5b 端口 = generate 返回值" "$(port_of "$out")" '40001'

echo "== T6 tag 缺失/空 -> 回落 443 =="
SC_SEL="$SC_NOTAG" PORT_IN='' GEN_PORT='41234' PLOG="$SB/t6.log" CFGOUT="$SB/t6.json"
out="$(run_port 2>"$SB/t6.err")"
assert_eq "T6a 端口 = 443" "$(port_of "$out")" '443'
assert_not_contains "T6b 不调 generate" "$out" 'GEN:'

echo "== T7 写出的是 JSON number (下游按数值比较) =="
SC_SEL="$SC_VISION" PORT_IN='8443' GEN_PORT='' PLOG="$SB/t7.log" CFGOUT="$SB/t7.json"
out="$(run_port 2>"$SB/t7.err")"
assert_eq "T7a 类型是 number" "$(jq -r '.xray.port | type' "$SB/t7.json")" 'number'
assert_eq "T7b 值正确" "$(jq -r '.xray.port' "$SB/t7.json")" '8443'

echo "== T8 persist 恰好一次; 同层其它字段无损 =="
assert_eq "T8a persist 恰好一次" "$(count_lines '^PERSIST$' "$SB/t7.log")" '1'
assert_eq "T8b xray.uuid 无损" "$(jq -r '.xray.uuid' "$SB/t7.json")" 'u-1'
assert_eq "T8c xray.version 无损" "$(jq -r '.xray.version' "$SB/t7.json")" 'v2026-01-01'
assert_eq "T8d xray.path 无损" "$(jq -r '.xray.path' "$SB/t7.json")" '/x'
assert_eq "T8e tag 未被改写" "$(jq -r '.xray.tag' "$SB/t7.json")" 'vision'

echo "== T9 generate 返回空 -> 回落默认端口, 不得让 jq 带走脚本 =="
# generate.sh 没算出值 (依赖的 od/shuf 缺失、脚本异常) 时, 旧写法把空串喂给
# jq --argjson -> "invalid JSON text" -> 赋值失败 -> set -e 终止整个人机交互脚本。
SC_SEL="$SC_MKCP" PORT_IN='' GEN_PORT='' PLOG="$SB/t9.log" CFGOUT="$SB/t9.json"
out="$(run_port 2>"$SB/t9.err")"
assert_contains "T9a rc=0 (脚本继续活着)" "$out" 'RC=0'
assert_eq "T9b 回落到 443" "$(port_of "$out")" '443'
assert_not_contains "T9c 没有 jq 的 argjson 报错" "$(cat "$SB/t9.err")" 'invalid JSON text'

echo "== T10 CLI 契约: --change-port 必须连着后续的收口动作 =="
# 只改 SCRIPT_CONFIG 而不重新生成 Xray 配置/重启/出分享链接 == 改了个寂寞。
# 抓取时遇到下一个 `^    --xxx)` 就收手 —— change-port 块自身的 `;;` 行挂着尾注释
# (不合 ^        ;;$), 只按 ;; 收手会把后面十几个 option 一起卷进来。
blk="$(awk '/^    --change-port\)/{f=1;print;next} f{ if (/^    --/) exit; print }' core/handler.sh || true)"
assert_contains "T10a 调用了 handler_change_xray_port" "$blk" 'handler_change_xray_port'
assert_contains "T10b 随后更新 Xray 配置" "$blk" 'handler_xray_config'
assert_contains "T10c 随后重启 Xray" "$blk" 'handler_restart'
assert_contains "T10d 随后重新出分享链接" "$blk" 'handler_share'
# 顺序: change -> config -> restart -> share (乱序则改完的配置还没落盘就重启)
order="$(printf '%s\n' "$blk" | grep -oE 'handler_(change_xray_port|xray_config|restart|share)' | tr '\n' '>' || true)"
assert_eq "T10e 四个动作顺序正确" "$order" 'handler_change_xray_port>handler_xray_config>handler_restart>handler_share>'

echo "---"
echo "==== handler_change_xray_port_arm_test: PASS=$PASS FAIL=$FAIL ===="
[[ $FAIL -eq 0 ]]
