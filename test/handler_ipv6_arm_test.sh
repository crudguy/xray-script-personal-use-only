#!/usr/bin/env bash
# =============================================================================
# 测试名称: handler_ipv6_arm_test.sh
# 测试目标: IPv6 启停臂 handler_ipv6 (enable / disable=软 / disable-hard=硬)、
#           handler_ipv6_status, 以及它们依赖的 _ipv6_iface_list /
#           _ipv6_soft_pending_ifaces / _ipv6_sysctl_body。
#
# 为什么需要本测试 (审计背景):
#   这是本项目第一条**会改内核开关**的臂 (BBR 只改拥塞控制算法, 影响面窄且可逆;
#   IPv6 开关会直接决定接口上有没有地址)。它的失败方式不是"报错", 而是
#   "当场看起来成功了, 重启后才变样" —— 所以本测试的重点**不是 rc**, 而是
#   落盘内容的语义与顺序:
#
#   [1] 顺序即语义 (最核心的一条不变量):
#       写 net.ipv6.conf.all.disable_ipv6 会让内核遍历并重置**所有**接口。所以软禁用
#       的持久化文件里, all 行**必须**排在逐接口行之前。反过来的话, 刚设好的
#       eth0=1 会被随后的 all=0 抹掉 —— 而 sysctl -p 照样返回 0、rc 也是 0,
#       只有**重启后**才表现为"IPv6 又回来了"。
#       本测试用一个会**按行序真的应用状态**的 sysctl shim 来抓它: 断言的是
#       "应用完之后 eth0 的值", 而不是"文件里有几行" —— 后者对顺序完全无感。
#
#   [2] 幂等必须"内核值 + 持久化文件"双查:
#       只比内核当前值, 会漏掉"当前生效但重启就失效"的情形 (BBR 那条
#       "生效 != 持久" 铁律的同类)。断言两条腿: 值对但文件缺 -> 仍要写盘;
#       值与文件都对 -> 零写盘。
#
#   [3] 危险操作的默认答案是"不做":
#       非 y 的一切输入 (含无 TTY 时的 EOF) 都必须走取消分支, 且**不写盘**。
#
#   [4] nginx 联动风险以**实测**为准, 不以推断为准:
#       本机 (内核 6.12) 实测: all/default/lo 的 disable_ipv6 全为 1、接口上一个
#       IPv6 地址都没有时, bind(::) 依然成功 —— 即 sysctl 关 IPv6 **不会**让
#       nginx 的 listen [::]:443 失败。所以告警只在"实测不可监听"时出现。
#       两个方向都要测, 防止有人改回"看到 nginx 有 [::] 就报警"的推断式实现
#       (那会天天误报, 狼来了之后真故障也没人看)。
#
# 锁定不变量:
#   [A] _ipv6_iface_list —— 接口名解析
#     T1  eth0 被识别
#     T2  veth0@if3 去掉 @ifN 后缀 (sysctl 键里没有这个后缀)
#     T3  lo 被排除
#     T4  输出以空格分隔, 无前导/尾随空格
#   [B] _ipv6_sysctl_body —— 落盘内容
#     T5  soft: all 行排在逐接口行**之前** (顺序契约, 文本层面)
#     T6  soft: 含 lo=0 与 default=1
#     T7  soft: 每个非 lo 接口各一行 =1
#     T8  hard: all=1 + default=1, 且不含任何逐接口行
#     T9  enable: 三个 0, 不含任何 =1
#   [C] handler_ipv6 软禁用 (disable)
#     T10 落盘后 sysctl -p 作用于**同一个**文件
#     T11 shim 应用后 eth0.disable_ipv6 == 1 (顺序正确性的**行为**断言)
#     T12 all.disable_ipv6 == 0 (协议栈保留, nginx 才可能 bind [::])
#     T13 default.disable_ipv6 == 1
#     T14 rc 0 且打印 done_soft
#     T15 非 y 输入 -> 取消, 且完全不写盘
#     T16 幂等: 值与文件都对 -> 不写盘不应用
#     T17 值对但持久化文件缺 -> 仍写盘 (生效 != 持久)
#     T18 复核值与目标不符 -> _error
#   [D] handler_ipv6 硬禁用 (disable-hard)
#     T19 all=1 + default=1
#     T20 打印 done_hard
#     T21 实测**可**监听时不打印 nginx 告警 (防推断式误报)
#     T22 实测**不可**监听 + nginx 配置有 [::] -> 打印告警
#   [E] handler_ipv6 启用 (enable)
#     T23 三个 0
#     T24 打印 done_enable
#     T25 未知模式 -> _error, 不写盘
#   [F] handler_ipv6_status
#     T26 转发 check.sh 并带上 --ipv6-status
#     T27 rc 0 -> 留痕 'ok or explicitly disabled'
#     T28 rc 1 -> 留痕 'half-broken / undetermined (see report)'
#
# 未覆盖 (诚实记录):
#   - "无 sysctl"与"无 /proc/sys/net/ipv6"两条早退分支**无法构造**: 前者要造出
#     "命令不存在"却仍保留 mktemp/grep 等命令的 PATH (做不到, 除非把 PATH 砍到
#     只剩内建); 后者要改 /proc 的目录结构。强行构造只会得到一个不真实的用例。
#     这两条属于"环境不具备"而非"逻辑复杂", 风险低。
#
# 负向校验 (NEG): 见文件末尾 —— 逐条把源码改坏, 确认上面的断言真的会红。
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
count_lines() { # $1=pattern (允许以 - 开头) $2=文件
    if [[ -f "$2" ]]; then
        grep -c -- "$1" "$2" || true
    else
        printf '0'
    fi
}
line_of() { # $1=文件 $2=pattern -> 行号 (无则 0)
    if [[ -f "$1" ]]; then
        grep -n -- "$2" "$1" | sed -n '1p' | cut -d: -f1 || true
    else
        printf '0'
    fi
}
getfile() { if [[ -f "$1" ]]; then cat "$1"; else printf ''; fi; }

SB=".workbuddy/tmp/ipv6arm.$$"
CFG="$SB/etc-sysctl.d/99-xray-script-personal-use-only-ipv6.conf"

# ---------------------------------------------------------------------------
# 沙箱: 把 sysctl / ip / python3 三条外部依赖换成可控 shim。
#   - sysctl shim 是**有状态**的: 每个键一个文件, `-p <file>` 时按**文件行序**
#     依次写入 —— 顺序错了最终状态就错, 这是 T11 能抓住顺序 bug 的原因。
#   - ip shim 只回放一份固定接口表, 用于验证接口名解析 (@ifN / lo)。
#   - python3 shim 让 _ipv6_listen_probe 的结果可控 (ok / no), 用于测 nginx 告警
#     的两个方向。
# ---------------------------------------------------------------------------
mk_sandbox() {
    rm -rf "$SB"
    mkdir -p "$SB/bin" "$SB/etc-sysctl.d" "$SB/state" "$SB/nginx-conf/sites-available"

    cat >"$SB/bin/sysctl" <<SHIM
#!/usr/bin/env bash
LOG="$PWD/$SB/sysctl.log"
STATE="$PWD/$SB/state"
case "\${1:-}" in
-n)
    k="\${2:-}"
    printf 'READ:%s\n' "\$k" >>"\$LOG"
    if [[ -f "\$STATE/\$k" ]]; then
        cat "\$STATE/\$k"
        exit 0
    fi
    exit 1
    ;;
-p)
    f="\${2:-}"
    printf 'APPLY:%s\n' "\$f" >>"\$LOG"
    # IPV6_SYSCTL_NOOP=1 用于模拟"写进去了但内核没接受": 只记录不应用,
    # 于是复核读到旧值 -> 应走 _error (T18)
    if [[ "\${IPV6_SYSCTL_NOOP:-}" == '1' ]]; then
        exit 0
    fi
    [[ -f "\$f" ]] || exit 1
    while IFS= read -r line; do
        case "\$line" in ''|'#'*) continue ;; esac
        k="\${line%% = *}"
        v="\${line##* = }"
        if [[ -z "\$k" || "\$k" == "\$line" ]]; then
            continue
        fi
        printf '%s\n' "\$v" >"\$STATE/\$k"
        printf 'SET:%s=%s\n' "\$k" "\$v" >>"\$LOG"
    done <"\$f"
    exit 0
    ;;
esac
exit 0
SHIM

    cat >"$SB/bin/ip" <<SHIM
#!/usr/bin/env bash
if [[ "\${1:-}" == '-o' && "\${2:-}" == 'link' && "\${3:-}" == 'show' ]]; then
    cat "$PWD/$SB/ip-link.txt"
    exit 0
fi
exit 0
SHIM

    cat >"$SB/bin/python3" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\${IPV6_PROBE_RESULT:-ok}"
SHIM

    chmod +x "$SB/bin/sysctl" "$SB/bin/ip" "$SB/bin/python3"

    # 接口表: lo 必须被排除; veth0@if3 必须去掉 @if3 (sysctl 键里没有后缀)
    cat >"$SB/ip-link.txt" <<'EOF'
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq state UP mode DEFAULT group default qlen 1000
6: veth0@if3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default qlen 1000
EOF

    # 假 check.sh: 记录调用参数并回放指定退出码
    cat >"$SB/bin/fake-check.sh" <<SHIM
#!/usr/bin/env bash
printf 'CHECK:%s\n' "\$*" >>"$PWD/$SB/check.log"
exit "\${FAKE_CHECK_RC:-0}"
SHIM
    chmod +x "$SB/bin/fake-check.sh"

    cat >"$SB/nginx-conf/sites-available/site.conf" <<'EOF'
server {
    listen [::]:443 ssl;
    server_name a.example.com;
}
EOF

    rm -f "$SB/sysctl.log" "$SB/check.log" "$SB/plog" "$SB/out" "$SB/rc"
    mkdir -p "$SB/state"
}

set_state() { printf '%s\n' "$2" >"$SB/state/$1"; }
state_of() { if [[ -f "$SB/state/$1" ]]; then cat "$SB/state/$1"; else printf '(无)'; fi; }
lg() { getfile "$SB/plog"; }
slog() { getfile "$SB/sysctl.log"; }
outp() { getfile "$SB/out"; }
rc() { getfile "$SB/rc"; }

# ---------------------------------------------------------------------------
# 抽取真函数体 (不 source 整个文件: handler.sh 末尾会 main "$@")
# ---------------------------------------------------------------------------
extract_fn() { awk -v fn="$2" '$0 ~ ("^function " fn "\\(\\) \\{") { g = 1 } g { print } g && /^\}$/ { exit }' "$1"; }

ipv6_fn="$(extract_fn core/handler.sh handler_ipv6)"
ipv6_status_fn="$(extract_fn core/handler.sh handler_ipv6_status)"
iface_fn="$(extract_fn core/handler.sh _ipv6_iface_list)"
pending_fn="$(extract_fn core/handler.sh _ipv6_soft_pending_ifaces)"
body_fn="$(extract_fn core/handler.sh _ipv6_sysctl_body)"
probe_fn="$(extract_fn core/_common.sh _ipv6_listen_probe)"
atomic_fn="$(extract_fn core/_common.sh _atomic_write)"
cmd_exists_fn="$(extract_fn core/_common.sh cmd_exists)"

for pair in "ipv6_fn:handler_ipv6" "iface_fn:_ipv6_iface_list" "pending_fn:_ipv6_soft_pending_ifaces" \
    "body_fn:_ipv6_sysctl_body" "probe_fn:_ipv6_listen_probe" "atomic_fn:_atomic_write" "cmd_exists_fn:cmd_exists"; do
    v="${pair%%:*}"
    n="${pair#*:}"
    if [[ -z "${!v}" ]]; then
        echo "SKIP: 抽取 ${n} 失败 (源码结构变了?)"
        exit 0
    fi
done

# 颜色常量: 被抽取的函数会引用 ${GREEN} 等; set -u 下未定义会让子 shell 直接崩掉
# (症状是所有用例的 rc 文件为空、plog 里只有一条 "XXX: 未绑定的变量")。
# shellcheck disable=SC2034
GREEN='' RED='' YELLOW='' NC=''

# ---------------------------------------------------------------------------
# 驱动 1: 直接跑 _ipv6_sysctl_body (只测内容生成, 不碰文件)
# ---------------------------------------------------------------------------
run_body() {
    (
        _i18n() { printf '%s' "${1#.}"; }
        PATH="$PWD/$SB/bin:$PATH"
        eval "$cmd_exists_fn"
        eval "$iface_fn"
        eval "$body_fn"
        _ipv6_sysctl_body "$1"
    )
}

# ---------------------------------------------------------------------------
# 驱动 2: 跑 handler_ipv6。
#   失败路径靠 _error **exit 1**, 故整体放子 shell, 退出码/日志经文件回传。
#   注: 不用 `( ... ) || true` 兜 errexit —— handler_ipv6 的失败是显式 exit,
#       不依赖 set -e, 所以这里子 shell 足够; 也正因如此, 本测试不受
#       "errexit 在 || 里失效" 那条坑影响。
# ---------------------------------------------------------------------------
run_ipv6() { # $1=mode; env: IPV6_CONFIRM / IPV6_PROBE_RESULT / IPV6_SYSCTL_NOOP / IPV6_CFG_MISSING
    rm -f "$SB/plog" "$SB/out" "$SB/rc"
    if [[ "${IPV6_CFG_MISSING:-}" == '1' ]]; then
        rm -f "$CFG"
    fi
    (
        # shellcheck disable=SC2034
        CUR_FILE='handler'
        _i18n() { printf '%s' "${1#.}"; }
        _error() { printf 'ERROR:%s\n' "$*" >>"$PWD/$SB/plog"; exit 1; }
        PATH="$PWD/$SB/bin:$PATH"
        eval "$cmd_exists_fn"
        eval "$atomic_fn"
        eval "$probe_fn"
        eval "$iface_fn"
        eval "$pending_fn"
        eval "$body_fn"
        eval "$ipv6_fn"
        # 用 ${IPV6_CONFIRM-y} 而非 ${...:-y}: 后者会把"显式空串"也回落成 y,
        # 于是 EOF/空输入用例永远走不到取消分支 (断言恒绿)。
        handler_ipv6 "$1" "$PWD/$CFG" "${IPV6_NGX_DIR:-}" <<<"${IPV6_CONFIRM-y}" >"$PWD/$SB/out" 2>&1
        printf '0' >"$PWD/$SB/rc"
    ) || true
}

# ---------------------------------------------------------------------------
# 驱动 3: 跑 handler_ipv6_status
# ---------------------------------------------------------------------------
run_status() {
    rm -f "$SB/plog" "$SB/out" "$SB/rc" "$SB/check.log"
    (
        # shellcheck disable=SC2034
        CUR_FILE='handler'
        # shellcheck disable=SC2034
        CHECK_PATH="$PWD/$SB/bin/fake-check.sh"
        _i18n() { printf '%s' "${1#.}"; }
        _error() { printf 'ERROR:%s\n' "$*" >>"$PWD/$SB/plog"; exit 1; }
        _audit_log() { printf 'AUDIT:%s|%s\n' "${1:-}" "${2:-}" >>"$PWD/$SB/plog"; }
        eval "$ipv6_status_fn"
        handler_ipv6_status >"$PWD/$SB/out" 2>&1
        printf '0' >"$PWD/$SB/rc"
    ) || true
}

# ===========================================================================
# [A] _ipv6_iface_list
# ===========================================================================
mk_sandbox
ifaces="$(
    _i18n() { printf '%s' "${1#.}"; }
    PATH="$PWD/$SB/bin:$PATH"
    eval "$cmd_exists_fn"
    eval "$iface_fn"
    _ipv6_iface_list
)"
assert_contains "T1 接口解析: eth0 在列" "${ifaces}" 'eth0'
assert_contains "T2 接口解析: veth0@if3 去掉 @ifN 后缀" "${ifaces}" 'veth0'
assert_not_contains "T2 接口解析: 不得带 @ifN" "${ifaces}" '@'
assert_not_contains "T3 接口解析: lo 被排除" "${ifaces}" 'lo'
assert_eq "T4 接口解析: 无前导/尾随空格" "${ifaces}" 'eth0 veth0'

# ===========================================================================
# [B] _ipv6_sysctl_body
# ===========================================================================
mk_sandbox
body_soft="$(run_body 'disable')"
body_hard="$(run_body 'disable-hard')"
body_enable="$(run_body 'enable')"

all_line="$(printf '%s\n' "${body_soft}" | grep -n '^net\.ipv6\.conf\.all\.disable_ipv6 = 0$' | cut -d: -f1 || true)"
iface_line="$(printf '%s\n' "${body_soft}" | grep -n '^net\.ipv6\.conf\.eth0\.disable_ipv6 = 1$' | cut -d: -f1 || true)"
assert_eq "T5 软禁用: 含 all=0 行" "$([[ -n "${all_line}" ]] && echo yes || echo no)" 'yes'
assert_eq "T5 软禁用: 含 eth0=1 行" "$([[ -n "${iface_line}" ]] && echo yes || echo no)" 'yes'
assert_eq "T5 软禁用: all 必须排在逐接口之前" \
    "$([[ -n "${all_line}" && -n "${iface_line}" && "${all_line}" -lt "${iface_line}" ]] && echo yes || echo no)" 'yes'
assert_contains "T6 软禁用: 含 lo=0 (回环始终保留)" "${body_soft}" 'net.ipv6.conf.lo.disable_ipv6 = 0'
assert_contains "T6 软禁用: 含 default=1" "${body_soft}" 'net.ipv6.conf.default.disable_ipv6 = 1'
assert_contains "T7 软禁用: eth0 一行" "${body_soft}" 'net.ipv6.conf.eth0.disable_ipv6 = 1'
assert_contains "T7 软禁用: veth0 一行" "${body_soft}" 'net.ipv6.conf.veth0.disable_ipv6 = 1'
assert_eq "T8 硬禁用: all=1" "$(printf '%s\n' "${body_hard}" | grep -c '^net\.ipv6\.conf\.all\.disable_ipv6 = 1$' || true)" '1'
assert_eq "T8 硬禁用: default=1" "$(printf '%s\n' "${body_hard}" | grep -c '^net\.ipv6\.conf\.default\.disable_ipv6 = 1$' || true)" '1'
assert_not_contains "T8 硬禁用: 不含逐接口行" "${body_hard}" 'net.ipv6.conf.eth0.'
assert_eq "T9 启用: all=0" "$(printf '%s\n' "${body_enable}" | grep -c '^net\.ipv6\.conf\.all\.disable_ipv6 = 0$' || true)" '1'
assert_eq "T9 启用: default=0" "$(printf '%s\n' "${body_enable}" | grep -c '^net\.ipv6\.conf\.default\.disable_ipv6 = 0$' || true)" '1'
assert_eq "T9 启用: lo=0" "$(printf '%s\n' "${body_enable}" | grep -c '^net\.ipv6\.conf\.lo\.disable_ipv6 = 0$' || true)" '1'
assert_not_contains "T9 启用: 不含任何 =1" "${body_enable}" 'disable_ipv6 = 1'

# ===========================================================================
# [C] handler_ipv6 软禁用
# ===========================================================================
mk_sandbox
set_state 'net.ipv6.conf.all.disable_ipv6' '0'
set_state 'net.ipv6.conf.default.disable_ipv6' '0'
set_state 'net.ipv6.conf.eth0.disable_ipv6' '0'
set_state 'net.ipv6.conf.veth0.disable_ipv6' '0'
IPV6_CONFIRM='y' IPV6_PROBE_RESULT='ok' run_ipv6 'disable'

assert_eq "T10 soft: 调用 sysctl -p" "$(count_lines 'APPLY:' "$SB/sysctl.log")" '1'
assert_contains "T10 soft: -p 作用于同一文件" "$(slog)" "APPLY:$PWD/$CFG"
assert_eq "T11 soft: 应用后 eth0 被关闭 (顺序正确才成立)" "$(state_of 'net.ipv6.conf.eth0.disable_ipv6')" '1'
assert_eq "T11 soft: 应用后 veth0 被关闭" "$(state_of 'net.ipv6.conf.veth0.disable_ipv6')" '1'
assert_eq "T12 soft: all 保持 0 (协议栈开启)" "$(state_of 'net.ipv6.conf.all.disable_ipv6')" '0'
assert_eq "T13 soft: default == 1" "$(state_of 'net.ipv6.conf.default.disable_ipv6')" '1'
assert_eq "T14 soft: rc 0" "$(rc)" '0'
assert_contains "T14 soft: 打印 done_soft" "$(outp)" 'ipv6.done_soft'
assert_not_contains "T14 soft: 无 ERROR" "$(lg)" 'ERROR:'

# T15 取消: 非 y 输入不得写盘
mk_sandbox
set_state 'net.ipv6.conf.all.disable_ipv6' '0'
set_state 'net.ipv6.conf.default.disable_ipv6' '0'
IPV6_CONFIRM='n' run_ipv6 'disable'
assert_eq "T15 取消: 不产生持久化文件" "$([[ -e "$CFG" ]] && echo yes || echo no)" 'no'
assert_eq "T15 取消: 不调用 sysctl -p" "$(count_lines 'APPLY:' "$SB/sysctl.log")" '0'
assert_contains "T15 取消: 提示 cancelled" "$(outp)" 'ipv6.cancelled'
assert_eq "T15 取消: rc 0" "$(rc)" '0'

# T15b EOF (无 TTY) 也必须走取消
mk_sandbox
set_state 'net.ipv6.conf.all.disable_ipv6' '0'
set_state 'net.ipv6.conf.default.disable_ipv6' '0'
IPV6_CONFIRM='' run_ipv6 'disable'
assert_eq "T15b EOF: 不写盘" "$([[ -e "$CFG" ]] && echo yes || echo no)" 'no'

# T16 幂等: 值与文件都对 -> 零写盘
mk_sandbox
set_state 'net.ipv6.conf.all.disable_ipv6' '0'
set_state 'net.ipv6.conf.default.disable_ipv6' '1'
set_state 'net.ipv6.conf.eth0.disable_ipv6' '1'
set_state 'net.ipv6.conf.veth0.disable_ipv6' '1'
printf 'net.ipv6.conf.all.disable_ipv6 = 0\n' >"$CFG"
IPV6_CONFIRM='y' run_ipv6 'disable'
assert_eq "T16 幂等: 不调用 sysctl -p" "$(count_lines 'APPLY:' "$SB/sysctl.log")" '0'
assert_contains "T16 幂等: 提示 already" "$(outp)" 'ipv6.already'
assert_eq "T16 幂等: rc 0" "$(rc)" '0'

# T17 值对但文件缺 -> 仍要写盘并应用 (生效 != 持久)
mk_sandbox
set_state 'net.ipv6.conf.all.disable_ipv6' '0'
set_state 'net.ipv6.conf.default.disable_ipv6' '1'
set_state 'net.ipv6.conf.eth0.disable_ipv6' '1'
set_state 'net.ipv6.conf.veth0.disable_ipv6' '1'
IPV6_CFG_MISSING='1' IPV6_CONFIRM='y' run_ipv6 'disable'
assert_eq "T17 未持久化: 重新写盘" "$([[ -e "$CFG" ]] && echo yes || echo no)" 'yes'
assert_eq "T17 未持久化: 调用 sysctl -p" "$(count_lines 'APPLY:' "$SB/sysctl.log")" '1'

# T18 复核不过 -> _error
mk_sandbox
set_state 'net.ipv6.conf.all.disable_ipv6' '0'
set_state 'net.ipv6.conf.default.disable_ipv6' '0'
set_state 'net.ipv6.conf.eth0.disable_ipv6' '0'
set_state 'net.ipv6.conf.veth0.disable_ipv6' '0'
IPV6_CONFIRM='y' IPV6_SYSCTL_NOOP='1' run_ipv6 'disable'
assert_contains "T18 复核失败: 记录 ERROR" "$(lg)" 'ERROR:'
assert_contains "T18 复核失败: 提示 verify_failed" "$(lg)" 'ipv6.verify_failed'

# ===========================================================================
# [D] handler_ipv6 硬禁用
# ===========================================================================
mk_sandbox
set_state 'net.ipv6.conf.all.disable_ipv6' '0'
set_state 'net.ipv6.conf.default.disable_ipv6' '0'
IPV6_CONFIRM='y' IPV6_PROBE_RESULT='ok' run_ipv6 'disable-hard'
assert_eq "T19 hard: all 被置 1" "$(state_of 'net.ipv6.conf.all.disable_ipv6')" '1'
assert_eq "T19 hard: default 被置 1" "$(state_of 'net.ipv6.conf.default.disable_ipv6')" '1'
assert_contains "T20 hard: 打印 done_hard" "$(outp)" 'ipv6.done_hard'
assert_eq "T20 hard: rc 0" "$(rc)" '0'
# T21 实测**可**监听 -> 不得因"nginx 有 [::]"而告警 (防推断式误报)
assert_not_contains "T21 实测可监听: 不打印 nginx 告警" "$(outp)" 'ipv6.nginx_risk'

# T22 实测不可监听 + nginx 有 [::] -> 告警
mk_sandbox
set_state 'net.ipv6.conf.all.disable_ipv6' '0'
set_state 'net.ipv6.conf.default.disable_ipv6' '0'
IPV6_CONFIRM='n' IPV6_PROBE_RESULT='no' run_ipv6 'disable-hard'
# 说明: nginx 配置目录在 handler_ipv6 里是硬编码的 (/usr/local/nginx/conf, /etc/nginx),
# 本测试**不**去构造它 —— 那要么往系统目录写文件, 要么依赖跑测试的机器恰好装了 nginx,
# 两种都不可接受 (测试绝不该碰 /etc)。所以这里改测告警的**触发条件**本身:
# _ipv6_listen_probe 在两个方向上是否如实反映 shim 的结果。
# 至于"条件成立时确实打印告警"由 NEG 的 warn_on_nginx_only 反向守护。
# 注: shim 读的是**环境变量**, 所以这里必须 export —— 普通赋值只在当前 shell 有效,
#     不会进 python3 子进程的环境 (踩过: 断言拿到的是 shim 的默认值)。
probe_no="$(
    PATH="$PWD/$SB/bin:$PATH"
    export IPV6_PROBE_RESULT='no'
    eval "$cmd_exists_fn"
    eval "$probe_fn"
    _ipv6_listen_probe
)"
probe_ok="$(
    PATH="$PWD/$SB/bin:$PATH"
    export IPV6_PROBE_RESULT='ok'
    eval "$cmd_exists_fn"
    eval "$probe_fn"
    _ipv6_listen_probe
)"
assert_eq "T22 探测: no 时返回 no" "${probe_no}" 'no'
assert_eq "T22 探测: ok 时返回 ok" "${probe_ok}" 'ok'

# T22b 告警必须真的出现: 注入一份含 listen [::] 的配置目录 + 让探测返回 no。
# 这条是"用户安全提示", 不能只靠读代码确认 —— 没有 nginx 的机器上改坏它,
# 行为一模一样, 测试会照样全绿 (NEG 已经暴露过这一点)。
mk_sandbox
set_state 'net.ipv6.conf.all.disable_ipv6' '0'
set_state 'net.ipv6.conf.default.disable_ipv6' '0'
# 沙箱里只放*用户站点*目录, 模拟真实布局的一角
mkdir -p "$SB/ngx/sites-available"
printf 'server {\n    listen [::]:443 ssl;\n}\n' >"$SB/ngx/sites-available/a.conf"
IPV6_NGX_DIR="$PWD/$SB/ngx" IPV6_CONFIRM='n' IPV6_PROBE_RESULT='no' run_ipv6 'disable-hard'
assert_contains "T22b 实测不可监听 + [::] 配置: 打印 nginx 告警" "$(outp)" 'ipv6.nginx_risk'
# 同样的目录, 探测说"能监听" -> 不得告警 (防推断式误报)
IPV6_NGX_DIR="$PWD/$SB/ngx" IPV6_CONFIRM='n' IPV6_PROBE_RESULT='ok' run_ipv6 'disable-hard'
assert_not_contains "T22c 实测可监听 + [::] 配置: 不告警" "$(outp)" 'ipv6.nginx_risk'

# ===========================================================================
# [E] handler_ipv6 启用
# ===========================================================================
mk_sandbox
set_state 'net.ipv6.conf.all.disable_ipv6' '1'
set_state 'net.ipv6.conf.default.disable_ipv6' '1'
set_state 'net.ipv6.conf.lo.disable_ipv6' '1'
IPV6_CONFIRM='y' run_ipv6 'enable'
assert_eq "T23 enable: all 置 0" "$(state_of 'net.ipv6.conf.all.disable_ipv6')" '0'
assert_eq "T23 enable: default 置 0" "$(state_of 'net.ipv6.conf.default.disable_ipv6')" '0'
assert_eq "T23 enable: lo 置 0" "$(state_of 'net.ipv6.conf.lo.disable_ipv6')" '0'
assert_contains "T24 enable: 打印 done_enable" "$(outp)" 'ipv6.done_enable'
assert_eq "T24 enable: rc 0" "$(rc)" '0'

# T25 未知模式 -> _error 且不写盘
mk_sandbox
set_state 'net.ipv6.conf.all.disable_ipv6' '0'
set_state 'net.ipv6.conf.default.disable_ipv6' '0'
IPV6_CONFIRM='y' run_ipv6 'nonsense'
assert_contains "T25 未知模式: 记录 ERROR" "$(lg)" 'ERROR:'
assert_contains "T25 未知模式: 提示 bad_mode" "$(lg)" 'ipv6.bad_mode'
assert_eq "T25 未知模式: 不写盘" "$([[ -e "$CFG" ]] && echo yes || echo no)" 'no'

# ===========================================================================
# [F] handler_ipv6_status
# ===========================================================================
mk_sandbox
FAKE_CHECK_RC=0 run_status
assert_contains "T26 status: 转发到 check.sh" "$(getfile "$SB/check.log")" 'CHECK:--ipv6-status'
assert_contains "T27 status: rc 0 留痕 ok" "$(getfile "$SB/plog")" 'AUDIT:ipv6-status|ok or explicitly disabled'
assert_eq "T27 status: rc 0" "$(rc)" '0'
FAKE_CHECK_RC=1 run_status
assert_contains "T28 status: rc 1 留痕 half-broken" "$(getfile "$SB/plog")" 'AUDIT:ipv6-status|half-broken / undetermined (see report)'
assert_eq "T28 status: 仍然 rc 0 (不把用户踢出菜单)" "$(rc)" '0'

# ===========================================================================
# 负向校验 (NEG): 把源码改坏, 确认上面的断言真的会红
# ---------------------------------------------------------------------------
if [[ -z "${SKIP_NEG:-}" ]]; then
    gen_neg() { # $1=变异名
        python3 - "$1" <<'PY'
import sys
import pathlib

# 每条变异落在哪个函数上 —— 用于确认改的是它, 而不是全仓同名的另一处
TARGET = {
    'soft_all_after_ifaces': '_ipv6_sysctl_body',
    'soft_no_lo': '_ipv6_sysctl_body',
    'soft_no_ifaces': '_ipv6_sysctl_body',
    'hard_no_default': '_ipv6_sysctl_body',
    'enable_nonzero': '_ipv6_sysctl_body',
    'no_confirm': 'handler_ipv6',
    'idempotent_value_only': 'handler_ipv6',
    'no_verify': 'handler_ipv6',
    'warn_on_nginx_only': 'handler_ipv6',
    'bad_mode_no_error': 'handler_ipv6',
}


def fn_body(text, name):
    out, g = [], False
    for line in text.splitlines():
        if line.startswith('function %s() {' % name):
            g = True
        if g:
            out.append(line)
        if g and line == '}':
            break
    return '\n'.join(out)


src = pathlib.Path('core/handler.sh').read_text()
mode = sys.argv[1]
s = src
if mode == 'soft_all_after_ifaces':
    # 把 all 行挪到逐接口之后 —— 这正是"顺序反了"的写法
    s = s.replace("""        printf 'net.ipv6.conf.all.disable_ipv6 = 0\\n'
        printf 'net.ipv6.conf.lo.disable_ipv6 = 0\\n'
        printf 'net.ipv6.conf.default.disable_ipv6 = 1\\n'
        list="$(_ipv6_iface_list)\"""",
                  """        printf 'net.ipv6.conf.lo.disable_ipv6 = 0\\n'
        printf 'net.ipv6.conf.default.disable_ipv6 = 1\\n'
        list="$(_ipv6_iface_list)\"""", 1)
    s = s.replace("""                printf 'net.ipv6.conf.%s.disable_ipv6 = 1\\n' "${iface}"
            done
        fi
        ;;""",
                  """                printf 'net.ipv6.conf.%s.disable_ipv6 = 1\\n' "${iface}"
            done
        fi
        printf 'net.ipv6.conf.all.disable_ipv6 = 0\\n'
        ;;""", 1)
elif mode == 'soft_no_lo':
    s = s.replace("""        printf 'net.ipv6.conf.lo.disable_ipv6 = 0\\n'
        printf 'net.ipv6.conf.default.disable_ipv6 = 1\\n'
        list="$(_ipv6_iface_list)\"""",
                  """        printf 'net.ipv6.conf.default.disable_ipv6 = 1\\n'
        list="$(_ipv6_iface_list)\"""", 1)
elif mode == 'soft_no_ifaces':
    s = s.replace("""        list="$(_ipv6_iface_list)\"""", """        list=''""", 1)
elif mode == 'hard_no_default':
    s = s.replace("""        printf 'net.ipv6.conf.all.disable_ipv6 = 1\\n'
        printf 'net.ipv6.conf.default.disable_ipv6 = 1\\n'""",
                  """        printf 'net.ipv6.conf.all.disable_ipv6 = 1\\n'""", 1)
elif mode == 'enable_nonzero':
    s = s.replace("""        printf 'net.ipv6.conf.all.disable_ipv6 = 0\\n'
        printf 'net.ipv6.conf.default.disable_ipv6 = 0\\n'
        printf 'net.ipv6.conf.lo.disable_ipv6 = 0\\n'""",
                  """        printf 'net.ipv6.conf.all.disable_ipv6 = 1\\n'
        printf 'net.ipv6.conf.default.disable_ipv6 = 0\\n'
        printf 'net.ipv6.conf.lo.disable_ipv6 = 0\\n'""", 1)
elif mode == 'no_confirm':
    s = s.replace("""    case "${confirm,,}" in
    y | yes) ;;
    *)
        echo -e "${YELLOW}[$(_i18n '.title.tip')]${NC} $(_i18n ".${CUR_FILE}.ipv6.cancelled")" >&2
        return 0
        ;;
    esac""", """    : "${confirm}\"""", 1)
elif mode == 'idempotent_value_only':
    s = s.replace("""    if [[ "${cur_all}" == "${tgt_all}" && "${cur_def}" == "${tgt_def}" && -e "${sysctl_file}" ]]; then""",
                  """    if [[ "${cur_all}" == "${tgt_all}" && "${cur_def}" == "${tgt_def}" ]]; then""", 1)
elif mode == 'no_verify':
    s = s.replace("""    if [[ "${cur_all}" != "${tgt_all}" || "${cur_def}" != "${tgt_def}" ]]; then
        _error "$(_i18n ".${CUR_FILE}.ipv6.verify_failed")"
    fi""", """    :""", 1)
elif mode == 'warn_on_nginx_only':
    s = s.replace("""    if [[ "${nginx6}" -eq 1 && "${probe}" == 'no' ]]; then""",
                  """    if [[ "${nginx6}" -eq 1 ]]; then""", 1)
elif mode == 'bad_mode_no_error':
    s = s.replace("""    *)
        _error "$(_i18n ".${CUR_FILE}.ipv6.bad_mode")"
        ;;
    esac

    if ! cmd_exists 'sysctl'; then""", """    *)
        :
        ;;
    esac

    if ! cmd_exists 'sysctl'; then""", 1)
else:
    raise SystemExit('unknown mode: ' + mode)
if s == src:
    raise SystemExit('改写未生效 (原文未命中): ' + mode)
tgt = TARGET[mode]
if fn_body(s, tgt) == fn_body(src, tgt):
    raise SystemExit('改写未落在 %s 上 (锚点命中了别处): %s' % (tgt, mode))
pathlib.Path('core/_neg_handler.sh').write_text(s)
PY
        sed 's#core/handler.sh#core/_neg_handler.sh#g' test/handler_ipv6_arm_test.sh >test/neg_tmp_ipv6_arm_test.sh
    }

    neg_run() { # $1=说明
        local out n
        out="$(cd "$REPO" && SKIP_NEG=1 bash "test/neg_tmp_ipv6_arm_test.sh" 2>&1 || true)"
        n="$(printf '%s\n' "$out" | grep -c '\[FAIL\]' || true)"
        if [[ "$n" != '0' ]]; then
            ok
        else
            bad "NEG $1 应检出失败, 实际 0 条 (断言恒绿!)"
        fi
    }

    for spec in \
        'soft_all_after_ifaces|软禁用把 all 行排到逐接口之后 (顺序反了)' \
        'soft_no_lo|软禁用不保留回环' \
        'soft_no_ifaces|软禁用不枚举接口' \
        'hard_no_default|硬禁用漏掉 default' \
        'enable_nonzero|启用时把 all 写成 1' \
        'no_confirm|去掉危险操作二次确认' \
        'idempotent_value_only|幂等只比值不看持久化文件' \
        'no_verify|去掉写后复核' \
        'warn_on_nginx_only|nginx 告警改回推断式(不看实测)' \
        'bad_mode_no_error|未知模式不报错'; do
        m="${spec%%|*}"
        d="${spec#*|}"
        if gen_neg "$m" 2>/dev/null; then neg_run "$d"; else bad "NEG 改写未生效: $m"; fi
    done

    rm -f core/_neg_handler.sh test/neg_tmp_ipv6_arm_test.sh
fi

rm -rf "$SB"

echo "---"
echo "==== handler_ipv6_arm_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" == '0' ]]
