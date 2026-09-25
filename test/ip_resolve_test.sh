#!/usr/bin/env bash
#
# 用例: core/_common.sh 的公网 IP 探测/选取, 与 core/check.sh 的 DNS 匹配判据
#
# 背景 (为什么固化成脚本):
#   分享链接 (core/share.sh)、健康检查 (core/check.sh: dns_resolution) 原先各自
#   `curl ipv4.icanhazip.com`, 造成三类不一致:
#     1) 双栈主机只拿到 IPv4; 仅 IPv6 主机拿到空值 -> 生成 `vless://uuid@:443` 坏链;
#     2) 未 --noproxy, 经 http_proxy 时拿到的是代理回源地址而非真实出口;
#     3) dns_resolution 用 `[[ $actual =~ $expected ]]` 比较, '.' 被当通配
#        (1.2.3.4 会误中 1a2b3c4), 且 expected 为空时报 "invalid regular expression: empty"。
#   统一到 _resolve_public_ips 后, 又踩了一个 bash 语义坑: 消费方写 $( ) / <( ) ——
#   命令替换与进程替换都起子 shell, 函数内写入的缓存 (文件级变量) 不回传当前 shell,
#   于是"缓存"形同虚设: 订阅按 inbound 逐个调 get_common_config, 每个都重新探测。
#   本用例把"必须直调"的语义与取值策略固化为断言, 防止被改回去。
#
# 覆盖:
#   T1 直调两次      -> curl 恰好 2 次 (v4+v6 各一), 缓存哨兵置位
#   T2 反例: 探测放进 $( ) 两次 -> curl 4 次 (子 shell 丢缓存), 证明 T1 不是空跑
#   T3 双栈          -> 取 IPv4
#   T4 仅 IPv6       -> 取 [IPv6] (方括号包裹)
#   T5 双栈均失败    -> 空串, 不崩
#   T6 输出带 CR/LF  -> 清洗后无空白污染
#   T7 DNS 精确整行匹配: 1a2b3c4 不匹配 1.2.3.4 (原 =~ 会误判成功)
#   T8 DNS 本机缺该栈 (expected 空) -> 该栈不参与匹配, 且不报 empty regex
#   T9 静态守卫: share.sh / check.sh 的消费点确为"直调", 未被改回 $( ) / <( )
#
# 依赖: bash, awk, grep, tr
set -Eeuo pipefail
# MSYS/Cygwin 沙箱里 rm 垫片会因会话变量接管删除并挂起; CI(Linux) 无此变量, unset 无害。
unset CODEBUDDY_SESSION_ID CLAUDE_SESSION_ID 2>/dev/null || true

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/xray-iptest.XXXXXX")"
cleanup() {
    if [[ "${XRAY_TEST_KEEP:-0}" == '1' ]]; then
        printf '\n(已保留沙箱: %s)\n' "${SB}" >&2
        return 0
    fi
    rm -rf "${SB}"
}
trap cleanup EXIT

fail=0
ok() { printf '  ok   %s\n' "$1"; }
bad() {
    printf '  FAIL %s\n' "$1"
    fail=1
}
ck() { # ck <描述> <期望> <实得>
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (期望 [$2] 实得 [$3])"; fi
}

# ---------------------------------------------------------------------------
# 1. 抽取: 两个目标函数 + 它们的文件级变量 (源码同步, 不手抄)
# ---------------------------------------------------------------------------
extract_fn() { # extract_fn <文件> <函数名>
    awk -v n="function $2()" '
        index($0, n) == 1 { found = 1 }
        found             { print }
        found && /^}$/    { exit }
    ' "$1"
}

{
    # 常量桩: 被抽出的函数会引用 SCRIPT_NAME / SCRIPT_CONFIG_DIR, 而本用例只 source
    # 抽取片段 (不 source 整个 _common.sh), 须在此补齐, 否则 set -u 下直接崩。
    # SCRIPT_CONFIG_DIR 指向沙箱 —— 跨进程缓存就落在那里, 便于断言。
    printf 'SCRIPT_NAME="%s"\n' 'xray-script-personal-use-only'
    printf 'SCRIPT_CONFIG_DIR="%s"\n' "${SB}/cfg"
    grep -E '^_PUBLIC_IP(V4|V6|_PROBED)=""$' "${REPO}/core/_common.sh"
    extract_fn "${REPO}/core/_common.sh" _public_ip_cache_read
    extract_fn "${REPO}/core/_common.sh" _public_ip_cache_write
    extract_fn "${REPO}/core/_common.sh" _public_ip_has_v6_route
    extract_fn "${REPO}/core/_common.sh" _public_ip_probe_one
    extract_fn "${REPO}/core/_common.sh" _resolve_public_ips
    extract_fn "${REPO}/core/_common.sh" _preferred_remote_host
    extract_fn "${REPO}/core/_common.sh" cmd_exists
    extract_fn "${REPO}/core/_common.sh" _atomic_write
    extract_fn "${REPO}/core/check.sh" dns_resolution
} >"${SB}/lib_ip.sh"

# 抽取体检: 缺一样就 ABORT (抽空会导致后续用例集体假绿)
[[ "$(wc -l <"${SB}/lib_ip.sh" | tr -d '[:space:]')" -gt 20 ]] || {
    bad "lib_ip.sh 过短, 抽取失败"
    printf '\n结果: 失败\n'
    exit 1
}
for _fn in _public_ip_cache_read _public_ip_cache_write _public_ip_has_v6_route \
    _public_ip_probe_one _resolve_public_ips _preferred_remote_host dns_resolution; do
    grep -q "function ${_fn}()" "${SB}/lib_ip.sh" || {
        bad "未能抽出 ${_fn}"
        printf '\n结果: 失败\n'
        exit 1
    }
done
grep -qc '^_PUBLIC_IP_PROBED=""$' "${SB}/lib_ip.sh" || {
    bad "未能抽出缓存哨兵变量"
    printf '\n结果: 失败\n'
    exit 1
}
if ! bash -n "${SB}/lib_ip.sh"; then
    bad "抽取结果语法错误"
    printf '\n结果: 失败\n'
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. 探测驱动器: 桩 curl 计数, 按栈应答
# ---------------------------------------------------------------------------
cat >"${SB}/probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${_S_LIB:?}"; : "${_S_CALLS:?}"; : "${_S_MODE:?}"
. "${_S_LIB}"
_S_IV4="${_S_IV4:-}"
_S_IV6="${_S_IV6:-}"
# 由用例置位: 模拟"用户要求立刻拿实时值"的逃生口
[[ "${_S_NOCACHE:-0}" == '1' ]] && export XRAY_SKIP_IP_CACHE=1

# 桩: 按请求的栈返回地址, 并记录一次"外网请求" (带栈标记, 便于断言"v6 到底问没问")
curl() {
    case "$*" in
    *ipv4.icanhazip.com*)
        printf '%s' "${_S_IV4}"
        printf 'call ipv4\n' >>"${_S_CALLS}"
        ;;
    *ipv6.icanhazip.com*)
        printf '%s' "${_S_IV6}"
        printf 'call ipv6\n' >>"${_S_CALLS}"
        ;;
    esac
}

# 桩: IPv6 默认路由是否存在 (决定"值不值得问 ipv6"), 由 _S_V6ROUTE 控制
ip() {
    if [[ "${_S_V6ROUTE:-1}" == '1' ]]; then
        printf 'default via fe80::1 dev eth0 proto ra metric 1024\n'
    fi
    return 0
}
# 覆盖抽取来的 cmd_exists: 保证 _public_ip_has_v6_route 一定走上面的 ip 桩,
# 而不是去问宿主机上真实的 ip (沙箱里结果不可控, 会让"跳过 v6"的断言时绿时红)。
cmd_exists() { return 0; }

hosts=()
case "${_S_MODE}" in
direct)
    # 修复姿势: 直调探测 (缓存写回当前 shell), 再用纯函数取值
    _resolve_public_ips >/dev/null
    hosts+=("$(_preferred_remote_host)")
    _resolve_public_ips >/dev/null
    hosts+=("$(_preferred_remote_host)")
    ;;
replace)
    # 反例: 把探测塞进命令替换 (子 shell) —— 缓存丢在子 shell, 每次重新探测
    hosts+=("$(_resolve_public_ips >/dev/null; _preferred_remote_host)")
    hosts+=("$(_resolve_public_ips >/dev/null; _preferred_remote_host)")
    ;;
*)
    printf 'ABORT: 未知 MODE\n' >&2
    exit 2
    ;;
esac

printf 'H1=%s\nH2=%s\nCALLS=%s\nPROBED=%s\n' \
    "${hosts[0]:-}" "${hosts[1]:-}" \
    "$(wc -l <"${_S_CALLS}" | tr -d '[:space:]')" "${_PUBLIC_IP_PROBED:-}"
PROBE

parse() { # parse <多行输出> <键> -> 取 "键=值" 的值
    local line
    while IFS= read -r line; do
        case "${line}" in
        "$2="*)
            printf '%s' "${line#"$2"=}"
            return 0
            ;;
        esac
    done <<<"$1"
}

run_probe() { # run_probe <mode> <iv4> <iv6>
    # 环境变量开关 (跨进程缓存让"每次调用是否复用"变成被测项, 需由用例显式控制):
    #   RP_KEEP_CACHE=1 不清空缓存目录 (跨进程用例用)
    #   RP_KEEP_CALLS=1 不清空外网请求计数 (累计断言用)
    #   RP_NOCACHE=1    置 XRAY_SKIP_IP_CACHE=1 (强制刷新)
    #   RP_V6=0/1       桩 ip 是否报出 IPv6 默认路由
    #   RP_LIB=<文件>   用另一份 lib (NEG 用)
    [[ "${RP_KEEP_CALLS:-0}" == '1' ]] || : >"${SB}/calls.txt"
    if [[ "${RP_KEEP_CACHE:-0}" != '1' ]]; then
        rm -rf "${SB}/cfg"
    fi
    mkdir -p "${SB}/cfg"
    _S_LIB="${RP_LIB:-${SB}/lib_ip.sh}" _S_CALLS="${SB}/calls.txt" _S_MODE="$1" \
        _S_IV4="$2" _S_IV6="$3" _S_NOCACHE="${RP_NOCACHE:-0}" _S_V6ROUTE="${RP_V6:-1}" \
        bash "${SB}/probe.sh"
}

# ---------------------------------------------------------------------------
# 3. 探测/选取用例
# ---------------------------------------------------------------------------
out="$(run_probe direct 203.0.113.10 '2001:db8::1')"
ck "T1 直调两次仅探测 2 次 (缓存生效)" '2' "$(parse "${out}" CALLS)"
ck "T1 缓存哨兵已置位" '1' "$(parse "${out}" PROBED)"

# (T2 反例见 T6 之后 —— 它必须在禁用跨进程缓存的条件下跑, 理由见那里)

out="$(run_probe direct 203.0.113.10 '2001:db8::1')"
ck "T3 双栈取 IPv4" '203.0.113.10' "$(parse "${out}" H1)"

out="$(run_probe direct '' '2001:db8::1')"
ck "T4 仅 IPv6 取 [IPv6]" '[2001:db8::1]' "$(parse "${out}" H1)"

out="$(run_probe direct '' '')"
ck "T5 双栈均失败取空串" '' "$(parse "${out}" H1)"

# T6: curl 返回带 \r\n (Windows 源/异常响应), 需清洗
out="$(run_probe direct $'203.0.113.10\r' $'2001:db8::1\r\n')"
ck "T6 CR/LF 被清洗" '203.0.113.10' "$(parse "${out}" H1)"

# T2 必须在"禁用缓存"下跑: 加了跨进程缓存后, 子 shell 也会命中落盘缓存 (0 次请求),
# 于是这条反例会退化成 2 次 —— 它要证明的是"进程内缓存被子 shell 丢弃"这一层,
# 故用 XRAY_SKIP_IP_CACHE=1 把跨进程那层关掉, 只留进程内语义。
out="$(RP_NOCACHE=1 run_probe replace 203.0.113.10 '2001:db8::1')"
ck "T2 反例: 探测放进 \$( ) 两次共 4 次 (子 shell 丢缓存)" '4' "$(parse "${out}" CALLS)"
ck "T2 反例: 地址仍能取到, 但外网请求翻倍" '203.0.113.10' "$(parse "${out}" H1)"
ck "T2 反例: 缓存哨兵未置位" '' "$(parse "${out}" PROBED)"

# ---------------------------------------------------------------------------
# 3b. 跨进程缓存 (菜单每点一次都是新进程, 这层缓存才是"生成分享不再慢"的关键)
# ---------------------------------------------------------------------------
fresh_cache() { # 重置缓存目录与计数
    rm -rf "${SB}/cfg"
    mkdir -p "${SB}/cfg"
    : >"${SB}/calls.txt"
}

fresh_cache
o1="$(RP_KEEP_CACHE=1 run_probe direct 203.0.113.10 '')"
ck "T10 冷启动: 首个进程探测 2 次" '2' "$(parse "${o1}" CALLS)"
o2="$(RP_KEEP_CACHE=1 RP_KEEP_CALLS=1 run_probe direct 203.0.113.10 '')"
ck "T10 第二个进程命中落盘缓存 -> 累计仍是 2 次 (零外网请求)" '2' "$(parse "${o2}" CALLS)"
ck "T10 命中缓存后取值不变" '203.0.113.10' "$(parse "${o2}" H1)"

# T11 TTL 过期 -> 必须重新探测 (缓存不能变成改不了的值)
touch -d '2 hours ago' "${SB}/cfg/.public-ip.cache"
o3="$(RP_KEEP_CACHE=1 RP_KEEP_CALLS=1 run_probe direct 203.0.113.10 '')"
ck "T11 缓存过期后重新探测 (累计 4 次)" '4' "$(parse "${o3}" CALLS)"

# T12 XRAY_SKIP_IP_CACHE=1 是逃生口: 强制刷新, 不看缓存
o4="$(RP_KEEP_CACHE=1 RP_KEEP_CALLS=1 RP_NOCACHE=1 run_probe direct 203.0.113.10 '')"
ck "T12 XRAY_SKIP_IP_CACHE=1 强制刷新 (累计 6 次)" '6' "$(parse "${o4}" CALLS)"

# T13 探测结果全空时不落缓存: 否则一次网络抖动会让分享链接长时间拿不到地址
fresh_cache
o5="$(RP_KEEP_CACHE=1 run_probe direct '' '')"
ck "T13 空结果首次仍探测 2 次" '2' "$(parse "${o5}" CALLS)"
o6="$(RP_KEEP_CACHE=1 RP_KEEP_CALLS=1 run_probe direct '' '')"
ck "T13 空结果不写缓存 -> 第二个进程重新探测 (累计 4 次)" '4' "$(parse "${o6}" CALLS)"

# T14 无 IPv6 默认路由时跳过 v6 探测 (这段原先必然等满超时, 是"慢"的最大头)
fresh_cache
o7="$(RP_KEEP_CACHE=1 RP_V6=0 run_probe direct 203.0.113.10 '')"
ck "T14 无 IPv6 路由 -> 只问 ipv4 (1 次)" '1' "$(parse "${o7}" CALLS)"
ck "T14 确实问了 ipv4" '1' "$(grep -c 'call ipv4' "${SB}/calls.txt")"
ck "T14 未问 ipv6" '0' "$(grep -c 'call ipv6' "${SB}/calls.txt")"
fresh_cache
o8="$(RP_KEEP_CACHE=1 RP_V6=1 run_probe direct 203.0.113.10 '2001:db8::1')"
ck "T14b 有 IPv6 路由 -> 两栈都问 (2 次)" '2' "$(parse "${o8}" CALLS)"

ck "T15 缓存文件权限 0600 (含公网地址, 不应对同机其它用户可读)" '600' \
    "$(stat -c %a "${SB}/cfg/.public-ip.cache" 2>/dev/null)"

# T16 (NEG) 守卫自证: 让 _public_ip_cache_read 恒 miss, T10 的"命中"必须消失。
#   否则"第二个进程零请求"可能来自别的原因 (例如压根没调探测), 断言形同虚设。
python3 - "${SB}/lib_ip.sh" "${SB}/lib_neg.sh" <<'PY'
import pathlib
import sys

src = pathlib.Path(sys.argv[1]).read_text()
start = src.index('function _public_ip_cache_read() {')
end = src.index('\n}\n', start) + 3
body = src[start:end]
assert 'return 1' in body, '抽取异常'
neg = src[:end] + '\n# NEG: 恒 miss\n' + src[end:]
# 在函数体首行后插入短路 return
head, rest = src[:start], src[start:]
first_nl = rest.index('\n') + 1
pathlib.Path(sys.argv[2]).write_text(head + rest[:first_nl] + '    return 1\n' + rest[first_nl:])
PY
fresh_cache
RP_LIB="${SB}/lib_neg.sh" RP_KEEP_CACHE=1 run_probe direct 203.0.113.10 '' >/dev/null
n2="$(RP_LIB="${SB}/lib_neg.sh" RP_KEEP_CACHE=1 RP_KEEP_CALLS=1 run_probe direct 203.0.113.10 '' || true)"
ck "T16(NEG) 缓存恒 miss 时第二个进程会重新探测 (累计 4 次, 不是 2 次)" '4' "$(parse "${n2}" CALLS)"

# ---------------------------------------------------------------------------
# 4. DNS 匹配判据用例 (桩 dig)
# ---------------------------------------------------------------------------
cat >"${SB}/dns.sh" <<'DNS'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${_S_LIB:?}"; : "${_S_CALLS:?}"; : "${_S_DOMAIN:?}"
. "${_S_LIB}"
curl() {
    case "$*" in
    *ipv4.icanhazip.com*) printf '%s' "${_S_IV4:-}" ;;
    *ipv6.icanhazip.com*) printf '%s' "${_S_IV6:-}" ;;
    esac
    printf 'call\n' >>"${_S_CALLS}"
}
# 桩: 保证双栈都会被探测。新增的"无 IPv6 默认路由就跳过 v6"优化会让沙箱 (无 v6) 只探
#   v4, 于是 T7/T8 里"IPv6 那条匹配"的断言必然失败 —— 那不是本段要测的东西, 故钉住。
ip() { printf 'default via fe80::1 dev eth0 proto ra metric 1024\n'; }
cmd_exists() { return 0; }
dig() {
    case "$*" in
    *AAAA*) printf '%s\n' "${_S_DIGV6:-}" ;;
    *) printf '%s\n' "${_S_DIGV4:-}" ;;
    esac
}
rc=0
dns_resolution "${_S_DOMAIN}" || rc=$?
printf 'RC=%s\n' "${rc}"
DNS

run_dns() { # run_dns <iv4> <iv6> <digv4> <digv6> <domain>  -> stdout, stderr 落文件
    : >"${SB}/calls.txt"
    : >"${SB}/dns.err"
    # 必须清掉跨进程缓存: 否则上一段用例落盘的公网 IP 会被本段命中, 于是"本机 IP"变成
    # 上一段的值 —— dig 桩喂的 IP 对不上, T7/T8 集体假红 (实测踩到)。
    rm -rf "${SB}/cfg"
    mkdir -p "${SB}/cfg"
    _S_LIB="${SB}/lib_ip.sh" _S_CALLS="${SB}/calls.txt" _S_DOMAIN="$5" \
        _S_IV4="$1" _S_IV6="$2" _S_DIGV4="$3" _S_DIGV6="$4" \
        bash "${SB}/dns.sh" 2>"${SB}/dns.err"
}

out="$(run_dns '1.2.3.4' '' '1.2.3.4' '' 'a.example.com')"
ck "T7 DNS 完全一致判为匹配" 'RC=0' "${out}"

out="$(run_dns '1.2.3.4' '' '1a2b3c4' '' 'a.example.com')"
ck "T7 DNS 1a2b3c4 不误匹配 1.2.3.4 (原 =~ 会误判)" 'RC=1' "${out}"

out="$(run_dns '1.2.3.4' '' '10.0.0.9' '' 'a.example.com')"
ck "T7 DNS 不同 IP 判为不匹配" 'RC=1' "${out}"

# T8: 本机无 IPv4 (expected 空) —— 该栈不参与匹配, 且不得报 empty regex
out="$(run_dns '' '2001:db8::1' '10.0.0.9' '2001:db8::1' 'a.example.com')"
ck "T8 缺栈时该栈不参与匹配, 另一栈可命中" 'RC=0' "${out}"
if grep -qi 'invalid regular expression' "${SB}/dns.err"; then
    bad "T8 出现 empty regex 报错 (应为空值跳过)"
else
    ok "T8 空 expected 未触发 empty regex 报错"
fi

# ---------------------------------------------------------------------------
# 5. 静态守卫: 消费点必须是"直调", 不能被改回 $( ) / <( )
# ---------------------------------------------------------------------------
# 断言的是"存在直调消费点", 而不是"恰好一处": 直调点会随功能增加 (IPv6 检测就
# 新增了一处), 用 ==1 会把合理的新增判成回归。真正要禁的是 $( ) / <( ) 形式 ——
# 那是下面这条独立守卫的职责。两者合起来才完整: 有直调 + 无子 shell 形式。
ck "T9 share.sh 消费点为直调" '1' \
    "$(grep -c '_resolve_public_ips >/dev/null' "${REPO}/core/share.sh" | tr -d '[:space:]')"
n_check="$(grep -c '_resolve_public_ips >/dev/null' "${REPO}/core/check.sh" | tr -d '[:space:]' || true)"
if [[ "${n_check:-0}" -ge 1 ]]; then
    ok "T9 check.sh 消费点为直调 (${n_check} 处, 只需 >=1)"
else
    bad "T9 check.sh 无直调消费点 (改成 \$( ) 会丢缓存)"
fi
# 注意: 源码注释里会写 $(_resolve_public_ips) 作反例, 先剔除注释行再判, 避免误报
if grep -E '\$\([^)]*_resolve_public_ips|<\(_resolve_public_ips' \
    "${REPO}/core/share.sh" "${REPO}/core/check.sh" | grep -vE ':[[:space:]]*#' >/dev/null; then
    bad "T9 仍有 \$( ) / <( ) 形式的探测调用 (会丢缓存)"
else
    ok "T9 无 \$( ) / <( ) 形式的探测调用"
fi

printf '\n结果: %s\n' "$([[ "${fail}" -eq 0 ]] && echo 通过 || echo 失败)"
[[ "${fail}" -eq 0 ]]
