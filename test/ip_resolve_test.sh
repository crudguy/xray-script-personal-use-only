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
    grep -E '^_PUBLIC_IP(V4|V6|_PROBED)=""$' "${REPO}/core/_common.sh"
    extract_fn "${REPO}/core/_common.sh" _resolve_public_ips
    extract_fn "${REPO}/core/_common.sh" _preferred_remote_host
    extract_fn "${REPO}/core/check.sh" dns_resolution
} >"${SB}/lib_ip.sh"

# 抽取体检: 缺一样就 ABORT (抽空会导致后续用例集体假绿)
[[ "$(wc -l <"${SB}/lib_ip.sh" | tr -d '[:space:]')" -gt 20 ]] || {
    bad "lib_ip.sh 过短, 抽取失败"
    printf '\n结果: 失败\n'
    exit 1
}
for _fn in _resolve_public_ips _preferred_remote_host dns_resolution; do
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

# 桩: 按请求的栈返回地址, 并记录一次"外网请求"
curl() {
    case "$*" in
    *ipv4.icanhazip.com*) printf '%s' "${_S_IV4}" ;;
    *ipv6.icanhazip.com*) printf '%s' "${_S_IV6}" ;;
    esac
    printf 'call\n' >>"${_S_CALLS}"
}

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
    : >"${SB}/calls.txt"
    _S_LIB="${SB}/lib_ip.sh" _S_CALLS="${SB}/calls.txt" _S_MODE="$1" \
        _S_IV4="$2" _S_IV6="$3" bash "${SB}/probe.sh"
}

# ---------------------------------------------------------------------------
# 3. 探测/选取用例
# ---------------------------------------------------------------------------
out="$(run_probe direct 203.0.113.10 '2001:db8::1')"
ck "T1 直调两次仅探测 2 次 (缓存生效)" '2' "$(parse "${out}" CALLS)"
ck "T1 缓存哨兵已置位" '1' "$(parse "${out}" PROBED)"

out="$(run_probe replace 203.0.113.10 '2001:db8::1')"
ck "T2 反例: 探测放进 \$( ) 两次共 4 次 (子 shell 丢缓存)" '4' "$(parse "${out}" CALLS)"
ck "T2 反例: 地址仍能取到, 但外网请求翻倍" '203.0.113.10' "$(parse "${out}" H1)"
ck "T2 反例: 缓存哨兵未置位" '' "$(parse "${out}" PROBED)"

out="$(run_probe direct 203.0.113.10 '2001:db8::1')"
ck "T3 双栈取 IPv4" '203.0.113.10' "$(parse "${out}" H1)"

out="$(run_probe direct '' '2001:db8::1')"
ck "T4 仅 IPv6 取 [IPv6]" '[2001:db8::1]' "$(parse "${out}" H1)"

out="$(run_probe direct '' '')"
ck "T5 双栈均失败取空串" '' "$(parse "${out}" H1)"

# T6: curl 返回带 \r\n (Windows 源/异常响应), 需清洗
out="$(run_probe direct $'203.0.113.10\r' $'2001:db8::1\r\n')"
ck "T6 CR/LF 被清洗" '203.0.113.10' "$(parse "${out}" H1)"

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
ck "T9 share.sh 消费点为直调" '1' \
    "$(grep -c '_resolve_public_ips >/dev/null' "${REPO}/core/share.sh" | tr -d '[:space:]')"
ck "T9 check.sh 消费点为直调" '1' \
    "$(grep -c '_resolve_public_ips >/dev/null' "${REPO}/core/check.sh" | tr -d '[:space:]')"
# 注意: 源码注释里会写 $(_resolve_public_ips) 作反例, 先剔除注释行再判, 避免误报
if grep -E '\$\([^)]*_resolve_public_ips|<\(_resolve_public_ips' \
    "${REPO}/core/share.sh" "${REPO}/core/check.sh" | grep -vE ':[[:space:]]*#' >/dev/null; then
    bad "T9 仍有 \$( ) / <( ) 形式的探测调用 (会丢缓存)"
else
    ok "T9 无 \$( ) / <( ) 形式的探测调用"
fi

printf '\n结果: %s\n' "$([[ "${fail}" -eq 0 ]] && echo 通过 || echo 失败)"
[[ "${fail}" -eq 0 ]]
