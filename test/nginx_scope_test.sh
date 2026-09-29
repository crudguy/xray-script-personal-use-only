#!/usr/bin/env bash
# =============================================================================
# 测试名称: nginx_scope_test.sh
# 测试目标: 锁定"Nginx 只在 SNI 模式下安装"这条边界 —— 六种 REALITY 系配置
#           (Vision / mKCP / XHTTP / Trojan / Fallback 与一键安装) 全程不碰 Nginx。
#
# 为什么需要: REALITY 由 Xray 自己握 TLS, 不需要反代、也不需要证书终结 (这正是本仓库
#   刻意不引入 Caddy 的原因)。Nginx 只服务 SNI 模式下的伪装站点 / CDN 域名 / 自定义
#   反代。这条边界一旦被打破 —— 例如有人往 REALITY 分支里顺手加一行 --nginx-install,
#   或在重构时把 SNI 分支与公共分支合并 —— 后果是白装一套 nginx (源码编译, 数分钟)、
#   多占一个 443 监听, 而且**没有任何现有用例会变红**: 其它用例只验证"该装的时候装上了",
#   没验证"不该装的时候没装"。属于典型的静默越界。
#
# 覆盖:
#   S1 静态 —— handler_quick_install (一键安装) 的调用链里不含 nginx;
#   S2 静态 —— processes_xray_config 的 SNI 分支经 processes_web_config 引入 nginx,
#             非 SNI (else) 分支两者都不含;
#   S3 静态 —— processes_web_config 里的 --nginx-install 落在"完整安装"分支
#             (is_change != 'y'), 不在"仅改 web 配置"那条上;
#   B1 行为 —— 驱动真实 handler_quick_install (桩掉全部被调), 断言实际调用序列无 nginx;
#   NEG 负向 —— 两处分别注入 nginx 调用, 对应判据必须变红; 每条都用 cmp 校验变异真落地。
#
# 运行: bash test/nginx_scope_test.sh
# =============================================================================
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s%s\n' "$1" "${2:+ ($2)}"; }
assert_contains() {
    if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing $(printf '%q' "$3")"; fi
}
assert_not_contains() {
    if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "unexpected $(printf '%q' "$3")"; fi
}
assert_ne() {
    if [[ "$2" != "$3" ]]; then ok "$1"; else bad "$1" "should not be $(printf '%q' "$3")"; fi
}

SB="$ROOT/.workbuddy/tmp/nginx_scope.$$"
rm -rf "$SB" 2>/dev/null || true
mkdir -p "$SB"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

# 抽某文件里的真实函数体 (测真实实现, 不另写近似版)
fn_of() { # $1=文件 $2=函数名
    awk -v fn="$2" '$0 == "function " fn "() {" { f=1 } f { print } f && /^}$/ { exit }' "$1"
}
# 剥掉整行注释再判定 —— 这些函数体的注释里大量出现 "nginx" 字样 (解释为什么不用它),
# 不剥离会把注释误判成调用, 断言恒红。
strip_comments() { sed -E 's/^[[:space:]]*#.*$//' <<<"$1"; }

# ---------------------------------------------------------------------------
echo "[S1] 一键安装 (handler_quick_install) 不得引入 Nginx"
# ---------------------------------------------------------------------------
q_fn="$(fn_of core/handler.sh handler_quick_install)"
[[ -n "$q_fn" ]] && ok "S1: 抽取到 handler_quick_install" || bad "S1: 抽取 handler_quick_install"
assert_not_contains "S1: 一键安装链不含 nginx" "$(strip_comments "$q_fn")" 'nginx'

# ---------------------------------------------------------------------------
echo "[S2] 只有 SNI 分支引入 Nginx, REALITY 系分支不得引入"
# ---------------------------------------------------------------------------
x_fn="$(fn_of core/main.sh processes_xray_config)"
[[ -n "$x_fn" ]] && ok "S2: 抽取到 processes_xray_config" || bad "S2: 抽取 processes_xray_config"
# 用 if 与 else/fi 切分两条分支
x_sni="$(awk '/== .SNI. \]\]; then/ { f=1 } f && /^    else$/ { exit } f' <<<"$x_fn")"
x_else="$(awk '/^    else$/ { f=1 } f && /^    fi$/ { exit } f' <<<"$x_fn")"
# 先证明抽取本身有效 —— 两边都空时后面的 assert_not_contains 会恒真 (假绿)
assert_ne "S2: 抽到 SNI 分支 (非空)" "$x_sni" ""
assert_ne "S2: 抽到 else 分支 (非空)" "$x_else" ""

assert_contains "S2a: SNI 分支经 processes_web_config 'n' 引入 Nginx" "$x_sni" "processes_web_config 'n'"
assert_not_contains "S2b: 非 SNI (REALITY 系) 分支不含 nginx" "$(strip_comments "$x_else")" 'nginx'
assert_not_contains "S2c: 非 SNI 分支也不进 processes_web_config" "$x_else" 'processes_web_config'

# ---------------------------------------------------------------------------
echo "[S3] processes_web_config 里 --nginx-install 只属于完整安装分支"
# ---------------------------------------------------------------------------
w_fn="$(fn_of core/main.sh processes_web_config)"
[[ -n "$w_fn" ]] && ok "S3: 抽取到 processes_web_config" || bad "S3: 抽取 processes_web_config"
w_code="$(strip_comments "$w_fn")"
# 注: -e 是必需的 —— 模式以 -- 开头, 不加会被 grep 当成选项解析
nginx_ln="$(grep -n -e '--nginx-install' <<<"$w_code" | head -1 | cut -d: -f1 || true)"
else_ln="$(grep -n '^    else$' <<<"$w_code" | head -1 | cut -d: -f1 || true)"
if [[ -n "$nginx_ln" && -n "$else_ln" && "$nginx_ln" -gt "$else_ln" ]]; then
    ok "S3: --nginx-install 落在完整安装分支 (nginx@${nginx_ln} > else@${else_ln})"
else
    bad "S3: --nginx-install 位置不对" "nginx=${nginx_ln:-空} else=${else_ln:-空}"
fi

# ---------------------------------------------------------------------------
echo "[B1] 行为: 驱动真实一键安装, 记录实际调用序列"
# ---------------------------------------------------------------------------
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'TRACE="${TRACE_FILE:?}"'
    # 桩掉一键安装依赖的全部被调函数, 只记录"被调用过"
    for d in handler_script_config handler_install handler_x25519_config handler_xray_config \
        handler_geodata_cron handler_restart handler_share handler_subscription add_rule; do
        printf '%s\n' "${d}() { printf 'C:%s\\n' '${d}' >> \"\$TRACE\"; }"
    done
    printf '%s\n' "$q_fn"
    printf '%s\n' 'handler_quick_install'
} > "$SB/quick_runner.sh"

: > "$SB/quick.trace"
if TRACE_FILE="$SB/quick.trace" bash "$SB/quick_runner.sh" >/dev/null 2>&1; then
    ok "B1: 一键安装 runner 正常跑完"
else
    bad "B1: 一键安装 runner 非 0 退出"
fi
q_trace="$(cat "$SB/quick.trace")"
assert_contains "B1: 驱动确实跑起来了 (有调用记录)" "$q_trace" 'C:handler_install'
assert_not_contains "B1: 实际调用序列里没有 nginx" "$q_trace" 'nginx'
assert_not_contains "B1: 实际调用序列里没有 nginx_install" "$q_trace" 'nginx_install'

# ---------------------------------------------------------------------------
echo "[NEG] 注入越界调用, 确认两条判据真的会红"
# ---------------------------------------------------------------------------
# NEG1: 往一键安装链里塞一行 nginx 安装 -> S1 与 B1 必须报出 nginx
awk -v ins='    handler_nginx_install' '
    /^function handler_quick_install\(\) \{/ { f=1 }
    f && /^    handler_restart$/ && !done { done=1; print; print ins; next }
    { print }
' core/handler.sh > "$SB/handler_neg.sh"
if cmp -s core/handler.sh "$SB/handler_neg.sh"; then
    bad "NEG1: 变异未落地 (awk 没匹配到插入点)"
else
    ok "NEG1: 变异已落地"
    qn_fn="$(fn_of "$SB/handler_neg.sh" handler_quick_install)"
    assert_contains "NEG1: 注入后 S1 判据报出 nginx" "$(strip_comments "$qn_fn")" 'nginx'
fi

# NEG2: 往 REALITY (else) 分支里塞一行 nginx 安装 -> S2b 必须报出 nginx
awk -v ins="        exec_handler '--nginx-install'" '
    /^function processes_xray_config\(\) \{/ { infn=1 }
    infn && /^    else$/ { inelse=1 }
    infn && inelse && /exec_handler .--script-config/ && !done { done=1; print ins }
    { print }
' core/main.sh > "$SB/main_neg.sh"
if cmp -s core/main.sh "$SB/main_neg.sh"; then
    bad "NEG2: 变异未落地 (awk 没匹配到插入点)"
else
    ok "NEG2: 变异已落地"
    xn_fn="$(fn_of "$SB/main_neg.sh" processes_xray_config)"
    xn_else="$(awk '/^    else$/ { f=1 } f && /^    fi$/ { exit } f' <<<"$xn_fn")"
    xn_sni="$(awk '/== .SNI. \]\]; then/ { f=1 } f && /^    else$/ { exit } f' <<<"$xn_fn")"
    assert_contains "NEG2: 注入后 S2b 判据报出 nginx" "$(strip_comments "$xn_else")" 'nginx'
    assert_contains "NEG2: 同一副本里 SNI 分支未被误伤" "$xn_sni" "processes_web_config 'n'"
fi

echo
echo "==== nginx_scope_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
