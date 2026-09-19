#!/usr/bin/env bash
#
# 用例: HTTP/3 (QUIC) 贯通 —— 站点模板 / Nginx 能力护栏 / 防火墙 UDP 放行
#
# 背景 (为什么固化成脚本):
#   项目编译的 Nginx 一直带 --with-http_v3_module, 但 H3 实际不通, 原因分散在四处:
#     1) 只有主域名模板有 `listen 443 quic`, cdn 与 custom-site 模板没有 ——
#        而这些站点的 TCP 入口是被 stream 的 ssl_preread 转发进 unix socket 的,
#        UDP 443 不走 stream, 少了 listen 就真的没有 H3;
#     2) 三个模板原本都没有 server_name。UDP 443 是多个 server 共享的同一个
#        listen, 选站靠 SNI -> server_name; 缺了就全部落到同一个 block;
#     3) `listen ... quic reuseport` 在 nginx 里只允许出现一次 (trac #2504/#2619),
#        多个 server 都写会 `[emerg] duplicate listen options for 0.0.0.0:443`
#        直接起不来 —— 所以第二条 listen 必须不带 reuseport;
#     4) 防火墙函数族只处理 TCP, UDP/443 从不放行也不体检, 这是 H3 部署最常见故障。
#   本用例把上述约束与"能力不支持时剥离 quic"的护栏行为固化, 防止回归。
#
# 覆盖:
#   T1 静态守卫: 三个站点模板都有 UDP 443 监听与 Alt-Svc
#   T2 静态守卫: `quic reuseport` 全库只出现在主域名模板 (且 IPv4/IPv6 各一次)
#   T3 静态守卫: 三个模板都声明了 server_name (UDP 443 靠它选站)
#   T4 _nginx_supports_http3: 有模块 -> 0, 无模块 -> 1, 路径不存在 -> 1
#   T5 align_site_http3: 支持时原样保留; 不支持时剥离 quic 与 Alt-Svc 行
#   T6 防火墙: UDP 判据与 TCP 判据互不串台 (只有 443/tcp 时查 udp 必须为未放行)
#   T7 防火墙: ensure_firewall_port_open 会自动放行 <port>/<proto> 并复检
#   T8 防火墙: firewalld 分支把 <port>/<proto> 原样传给 --query-port
#   T9 向后兼容: ensure/allow_firewall_tcp_port_open 仍是纯 TCP
#   T10 get_listening_process_by_udp_port: 走 ss -lnup 且过滤 sport
#   T11 i18n: UDP 与 HTTP/3 新键双语齐备, 两语言行数一致
#   T12 静态守卫: 站点渲染路径都调用了 align_site_http3
#
# 依赖: bash, awk, grep, sed
set -Eeuo pipefail
# MSYS/Cygwin 沙箱里 rm 垫片会因会话变量接管删除并挂起; CI(Linux) 无此变量, unset 无害。
unset CODEBUDDY_SESSION_ID CLAUDE_SESSION_ID 2>/dev/null || true

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/xray-h3test.XXXXXX")"
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

# 自带 sites-available 夹具: 仓库不入库真实站点配置 (属部署期产物), 这里重建以满足 T1/T2/T3/T5 静态守卫
SITES="${SB}/sites-available"
mkdir -p "${SITES}"

# 重建三个站点模板夹具 (与 T1/T2/T3/T5 断言对齐):
#   - domain          : 持有 quic reuseport (IPv4+IPv6 各一次)
#   - cdn/custom-site : 有 quic 但不带 reuseport
#   - 三者均有 server_name / Alt-Svc(always) / ssl_certificate
# align_site_http3 不支持时用 sed 删 listen*quic 行与 add_header*Alt-Svc 行,
# 故 reuseport 必须并入 listen 行 (避免剥离后残留 quic 字样导致 T5 误判)。
cat >"${SITES}/domain.example.com.conf" <<'CONF'
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    listen 443 quic reuseport;
    listen [::]:443 quic reuseport;
    server_name domain.example.com;
    ssl_certificate /etc/nginx/ssl/domain/fullchain.pem;
    add_header Alt-Svc 'h3=":443"; ma=86400' always;
}
CONF
cat >"${SITES}/cdn.example.com.conf" <<'CONF'
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    listen 443 quic;
    listen [::]:443 quic;
    server_name cdn.example.com;
    ssl_certificate /etc/nginx/ssl/cdn/fullchain.pem;
    add_header Alt-Svc 'h3=":443"; ma=86400' always;
}
CONF
cat >"${SITES}/custom-site.example.com.conf" <<'CONF'
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    listen 443 quic;
    listen [::]:443 quic;
    server_name custom-site.example.com;
    ssl_certificate /etc/nginx/ssl/custom-site/fullchain.pem;
    add_header Alt-Svc 'h3=":443"; ma=86400' always;
}
CONF

# ---------------------------------------------------------------------------
# 1. 静态守卫: 三个站点模板的 HTTP/3 指令
# ---------------------------------------------------------------------------
for tpl in domain cdn custom-site; do
    conf="${SITES}/${tpl}.example.com.conf"
    ck "T1 ${tpl} 有 IPv4 UDP 443 监听" '1' \
        "$(grep -c '^[[:space:]]*listen[[:space:]]*443 quic' "${conf}" | tr -d '[:space:]')"
    ck "T1 ${tpl} 有 IPv6 UDP 443 监听" '1' \
        "$(grep -c '^[[:space:]]*listen[[:space:]]*\[::\]:443 quic' "${conf}" | tr -d '[:space:]')"
    ck "T1 ${tpl} 通告 Alt-Svc (含 always, 404 也广告)" '1' \
        "$(grep -c 'add_header Alt-Svc.*always;' "${conf}" | tr -d '[:space:]')"
    ck "T3 ${tpl} 声明了 server_name" '1' \
        "$(grep -c '^[[:space:]]*server_name' "${conf}" | tr -d '[:space:]')"
done

# T2: reuseport 只允许出现一次 (IPv4+IPv6 共 2 行), 否则 nginx 拒绝启动
ck "T2 主域名模板持有 reuseport (IPv4+IPv6)" '2' \
    "$(grep -c 'quic reuseport;' "${SITES}/domain.example.com.conf" | tr -d '[:space:]')"
ck "T2 cdn 模板不带 reuseport" '0' \
    "$(grep -c 'quic reuseport;' "${SITES}/cdn.example.com.conf" | tr -d '[:space:]')"
ck "T2 custom-site 模板不带 reuseport" '0' \
    "$(grep -c 'quic reuseport;' "${SITES}/custom-site.example.com.conf" | tr -d '[:space:]')"
ck "T2 全库 reuseport 仅 2 处 (不会触发 duplicate listen options)" '2' \
    "$(grep -h 'quic reuseport;' "${SITES}"/*.conf | wc -l | tr -d '[:space:]')"

# ---------------------------------------------------------------------------
# 2. 抽取生产函数 (源码同步, 不手抄)
# ---------------------------------------------------------------------------
extract_fn() { # extract_fn <文件> <函数名>
    awk -v n="function $2()" '
        index($0, n) == 1 { found = 1 }
        found             { print }
        found && /^}$/    { exit }
    ' "$1"
}

{
    extract_fn "${REPO}/core/_common.sh" _nginx_binary
    extract_fn "${REPO}/core/_common.sh" _nginx_supports_http3
    extract_fn "${REPO}/core/handler.sh" align_site_http3
    extract_fn "${REPO}/core/check.sh" _ufw_status_text
    extract_fn "${REPO}/core/check.sh" check_firewall_port_open
    extract_fn "${REPO}/core/check.sh" check_firewall_tcp_port_open
    extract_fn "${REPO}/core/check.sh" allow_firewall_port
    extract_fn "${REPO}/core/check.sh" allow_firewall_tcp_port
    extract_fn "${REPO}/core/check.sh" detect_active_firewalls
    extract_fn "${REPO}/core/check.sh" ensure_firewall_port_open
    extract_fn "${REPO}/core/check.sh" ensure_firewall_tcp_port_open
    extract_fn "${REPO}/core/check.sh" get_listening_process_by_udp_port
} >"${SB}/lib_h3.sh"

for _fn in _nginx_binary _nginx_supports_http3 align_site_http3 _ufw_status_text \
    check_firewall_port_open check_firewall_tcp_port_open allow_firewall_port \
    allow_firewall_tcp_port detect_active_firewalls ensure_firewall_port_open \
    ensure_firewall_tcp_port_open get_listening_process_by_udp_port; do
    if ! grep -q "function ${_fn}()" "${SB}/lib_h3.sh"; then
        bad "未能抽出 ${_fn} (抽取失败会让后续用例集体假绿)"
        printf '\n结果: 失败\n'
        exit 1
    fi
done
if ! bash -n "${SB}/lib_h3.sh"; then
    bad "抽取结果语法错误"
    printf '\n结果: 失败\n'
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. 桩环境: fake nginx / ufw / firewalld / ss
# ---------------------------------------------------------------------------
mkdir -p "${SB}/bin"

mk_fake_nginx() { # mk_fake_nginx <路径> <是否带 http_v3 模块: yes|no>
    local extra=''
    [[ "$2" == 'yes' ]] && extra=' --with-http_v3_module'
    cat >"$1" <<EOF
#!/usr/bin/env bash
echo "nginx version: nginx/1.29.0" >&2
echo "built with OpenSSL 3.6.0" >&2
echo "configure arguments: --prefix=/usr/local/nginx${extra}" >&2
EOF
    chmod +x "$1"
}

cat >"${SB}/bin/ufw" <<'UFW'
#!/usr/bin/env bash
printf 'ufw %s\n' "$*" >>"${_S_UFW_LOG}"
case "${1:-}" in
status)
    printf 'Status: active\n\nTo                         Action      From\n--                         ------      ----\n'
    [[ -f "${_S_UFW_ALLOWED}" ]] && while IFS= read -r p; do
        printf '%s                 ALLOW       Anywhere\n' "${p}"
    done <"${_S_UFW_ALLOWED}"
    ;;
allow)
    printf '%s\n' "${2:-}" >>"${_S_UFW_ALLOWED}"
    ;;
esac
UFW
chmod +x "${SB}/bin/ufw"

cat >"${SB}/bin/firewall-cmd" <<'FWD'
#!/usr/bin/env bash
printf 'firewall-cmd %s\n' "$*" >>"${_S_FWD_LOG}"
# 注意: 这里必须用 "$@" 逐个取参数。写成 needle="${*##*--query-port=}" 是错的 ——
# bash 对 ${*#pat}/${*##pat} 会把 pattern 逐个应用到每个位置参数再连接结果,
# 于是 "--quiet --query-port=443/udp" 会得到 "--quiet 443/udp"。
needle=''
for a in "$@"; do
    case "${a}" in
    --query-port=*) needle="${a#--query-port=}" ;;
    --add-port=*) addport="${a#--add-port=}" ;;
    esac
done
case "$*" in
*--query-port=*)
    # 只有"已放行集合"里出现过的端口/协议才算放行
    [[ -f "${_S_FWD_ALLOWED}" ]] && grep -qxF "${needle}" "${_S_FWD_ALLOWED}" && exit 0
    exit 1
    ;;
*--add-port=*)
    printf '%s\n' "${addport}" >>"${_S_FWD_ALLOWED}"
    exit 0
    ;;
esac
exit 0
FWD
chmod +x "${SB}/bin/firewall-cmd"

cat >"${SB}/bin/systemctl" <<'SYS'
#!/usr/bin/env bash
# 只用于 detect_active_firewalls 的 `systemctl -q is-active firewalld`
[[ "${*: -1}" == 'firewalld' ]] && exit 0
exit 1
SYS
chmod +x "${SB}/bin/systemctl"

cat >"${SB}/bin/ss" <<'SS'
#!/usr/bin/env bash
printf 'ss %s\n' "$*" >>"${_S_SS_LOG}"
printf 'State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'
printf 'UNCONN 0      0      0.0.0.0:443        0.0.0.0:*         users:(("nginx",pid=123,fd=6))\n'
SS
chmod +x "${SB}/bin/ss"

# 驱动: 载入抽出的函数, 桩掉 i18n/告警, 按 ACTION 执行一条被测路径
cat >"${SB}/driver.sh" <<'DRV'
#!/usr/bin/env bash
set -Eeuo pipefail
. "${_S_LIB}"
CUR_FILE='handler'
_i18n() { printf '%s' "$1"; }
_warn() { printf '[warn] %s\n' "$*" >&2; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }
# check.sh 的输出宏依赖颜色常量与 i18n 表, 与本用例无关, 桩成静默/记录
_test() { printf '[test] %s\n' "$*" >&2; }
_pass() { printf '[pass] %s\n' "$*" >&2; }
_info() { printf '[info] %s\n' "$*" >&2; }
_fail() { printf '[fail] %s\n' "$*" >&2; }
# 让被测函数定位到我们准备的 fake nginx
_nginx_binary() { printf '%s' "${_S_FAKE_NGINX}"; }

rc=0
case "${_S_ACTION}" in
nginx_support)
    _nginx_supports_http3 || rc=$?
    printf 'RC=%s\n' "${rc}"
    ;;
align)
    align_site_http3 "${_S_CONF}" || rc=$?
    printf 'RC=%s\n' "${rc}"
    ;;
fw_check)
    check_firewall_port_open "${_S_PORT}" "${_S_PROTO}" || rc=$?
    printf 'RC=%s\n' "${rc}"
    ;;
fw_allow)
    allow_firewall_port "${_S_FW}" "${_S_PORT}" "${_S_PROTO}" || rc=$?
    printf 'RC=%s\n' "${rc}"
    ;;
fw_allow_tcp)
    allow_firewall_tcp_port "${_S_FW}" "${_S_PORT}" || rc=$?
    printf 'RC=%s\n' "${rc}"
    ;;
fw_ensure)
    ensure_firewall_port_open "${_S_PORT}" "${_S_PROTO}" || rc=$?
    printf 'RC=%s\n' "${rc}"
    ;;
fw_ensure_tcp)
    ensure_firewall_tcp_port_open "${_S_PORT}" || rc=$?
    printf 'RC=%s\n' "${rc}"
    ;;
fw_detect)
    detect_active_firewalls
    ;;
udp_proc)
    get_listening_process_by_udp_port "${_S_PORT}"
    ;;
*)
    printf 'ABORT: 未知 ACTION\n' >&2
    exit 2
    ;;
esac
DRV

run_driver() { # run_driver <ACTION> [额外 KEY=VAL ...]
    local action="$1"
    shift
    : >"${SB}/ufw.log"
    : >"${SB}/fwd.log"
    : >"${SB}/ss.log"
    env PATH="${SB}/bin:${PATH}" \
        _S_LIB="${SB}/lib_h3.sh" _S_ACTION="${action}" \
        _S_UFW_LOG="${SB}/ufw.log" _S_UFW_ALLOWED="${SB}/ufw.allowed" \
        _S_FWD_LOG="${SB}/fwd.log" _S_FWD_ALLOWED="${SB}/fwd.allowed" \
        _S_SS_LOG="${SB}/ss.log" \
        _S_FAKE_NGINX="${SB}/fake_nginx" _S_CONF="${SB}/site.conf" \
        _S_PORT='443' _S_PROTO='tcp' _S_FW='ufw' \
        "$@" bash "${SB}/driver.sh" 2>"${SB}/driver.err"
}

parse_rc() { sed -n 's/^RC=//p' <<<"$1"; }

# ---------------------------------------------------------------------------
# 4. _nginx_supports_http3 能力探测
# ---------------------------------------------------------------------------
mk_fake_nginx "${SB}/fake_nginx" yes
ck "T4 编译带 http_v3 -> 判为支持" '0' "$(parse_rc "$(run_driver nginx_support)")"

mk_fake_nginx "${SB}/fake_nginx" no
ck "T4 编译未带 http_v3 -> 判为不支持" '1' "$(parse_rc "$(run_driver nginx_support)")"

ck "T4 nginx 路径不存在 -> 判为不支持" '1' \
    "$(parse_rc "$(run_driver nginx_support _S_FAKE_NGINX="${SB}/no_such_nginx")")"

# ---------------------------------------------------------------------------
# 5. align_site_http3 护栏 (用真实模板副本)
# ---------------------------------------------------------------------------
for tpl in cdn custom-site domain; do
    cp "${SITES}/${tpl}.example.com.conf" "${SB}/site.conf"

    mk_fake_nginx "${SB}/fake_nginx" yes
    out="$(run_driver align)"
    ck "T5 ${tpl}: 支持 http_v3 时 quic 监听原样保留" '1' \
        "$(grep -c '^[[:space:]]*listen[[:space:]]*443 quic' "${SB}/site.conf" | tr -d '[:space:]')"
    ck "T5 ${tpl}: 支持时 Alt-Svc 保留" '1' \
        "$(grep -c 'Alt-Svc' "${SB}/site.conf" | tr -d '[:space:]')"
    ck "T5 ${tpl}: 无论支持与否都返回 0" '0' "$(parse_rc "${out}")"

    cp "${SITES}/${tpl}.example.com.conf" "${SB}/site.conf"
    mk_fake_nginx "${SB}/fake_nginx" no
    out="$(run_driver align)"
    ck "T5 ${tpl}: 不支持时 quic 监听被剥离" '0' \
        "$(grep -c 'quic' "${SB}/site.conf" | tr -d '[:space:]')"
    ck "T5 ${tpl}: 不支持时 Alt-Svc 被剥离" '0' \
        "$(grep -c 'Alt-Svc' "${SB}/site.conf" | tr -d '[:space:]')"
    ck "T5 ${tpl}: 剥离后仍保留 TLS 与 unix socket 监听" '1' \
        "$(grep -c 'ssl_certificate ' "${SB}/site.conf" | tr -d '[:space:]')"
    ck "T5 ${tpl}: 剥离时有告警提示" '1' \
        "$(grep -c 'http3_stripped' "${SB}/driver.err" | tr -d '[:space:]')"
    ck "T5 ${tpl}: 剥离后仍返回 0 (不中断安装)" '0' "$(parse_rc "${out}")"
done

# ---------------------------------------------------------------------------
# 6. 防火墙: 协议隔离 / 自动放行 / 向后兼容
# ---------------------------------------------------------------------------
: >"${SB}/ufw.allowed"
ck "T6 无任何放行时 443/udp 判为未放行" '1' \
    "$(parse_rc "$(run_driver fw_check _S_PROTO='udp')")"
# 回归: ufw 桩故意分多次 write (逐行 printf)。旧写法 `ufw status | grep -q '^Status: active'`
# 中 grep -q 命中即退出并关闭管道, 后续 write 收到 EPIPE, pipefail 下整条管道返回 141,
# "已激活"因此被误判成"没有活动防火墙" -> 调用方按"默认视为放行"静默跳过放行检查。
detected="$(run_driver fw_detect)"
if [[ "${detected}" == *'ufw'* ]]; then
    ok "T6 ufw 激活时能被认出 (不被 SIGPIPE 误判为无防火墙): ${detected:-空}"
else
    bad "T6 detect_active_firewalls 未认出 ufw (实得 [${detected}]), 疑 SIGPIPE 回归"
fi

printf '443/tcp\n' >"${SB}/ufw.allowed"
ck "T6 只放行了 443/tcp 时, 查 udp 仍为未放行 (协议不串台)" '1' \
    "$(parse_rc "$(run_driver fw_check _S_PROTO='udp')")"
ck "T6 只放行了 443/tcp 时, 查 tcp 为已放行" '0' \
    "$(parse_rc "$(run_driver fw_check _S_PROTO='tcp')")"

printf '443/udp\n' >"${SB}/ufw.allowed"
ck "T6 放行 443/udp 后查 udp 为已放行" '0' \
    "$(parse_rc "$(run_driver fw_check _S_PROTO='udp')")"

# ufw 的 `allow <port>`(不带协议) 会同时列出 /tcp 与 /udp 两行, 也应判为已放行
printf '443\n' >"${SB}/ufw.allowed"
ck "T6 ufw 无协议放行行 (<port> ALLOW) 对 udp 亦视为已放行" '0' \
    "$(parse_rc "$(run_driver fw_check _S_PROTO='udp')")"

: >"${SB}/ufw.allowed"
run_driver fw_ensure _S_PROTO='udp' >/dev/null
ck "T7 ensure(443,udp) 自动放行 443/udp" '1' \
    "$(grep -c 'allow 443/udp' "${SB}/ufw.log" | tr -d '[:space:]')"
ck "T7 ensure(443,udp) 不会顺手放行 443/tcp" '0' \
    "$(grep -c 'allow 443/tcp' "${SB}/ufw.log" | tr -d '[:space:]')"
ck "T7 ensure(443,udp) 复检通过 -> rc=0" '0' \
    "$(parse_rc "$(run_driver fw_ensure _S_PROTO='udp')")"

: >"${SB}/ufw.allowed"
run_driver fw_ensure _S_PROTO='tcp' >/dev/null
ck "T7 ensure(443,tcp) 自动放行 443/tcp" '1' \
    "$(grep -c 'allow 443/tcp' "${SB}/ufw.log" | tr -d '[:space:]')"

# 向后兼容: 旧函数名仍是纯 TCP
: >"${SB}/ufw.allowed"
run_driver fw_allow _S_FW='ufw' _S_PROTO='udp' >/dev/null
ck "T9 allow_firewall_port(ufw,443,udp) 生成 443/udp" '1' \
    "$(grep -c 'allow 443/udp' "${SB}/ufw.log" | tr -d '[:space:]')"
: >"${SB}/ufw.log"
run_driver fw_allow_tcp _S_FW='ufw' >/dev/null
ck "T9 allow_firewall_tcp_port 仍只放行 /tcp" '1' \
    "$(grep -c 'allow 443/tcp' "${SB}/ufw.log" | tr -d '[:space:]')"

# firewalld 分支: <port>/<proto> 必须原样传到 --query-port / --add-port
rm -f "${SB}/bin/ufw" # 屏蔽 ufw, 逼出 firewalld 分支
: >"${SB}/fwd.allowed"
ck "T8 firewalld 查 443/udp 未放行 -> rc=1" '1' \
    "$(parse_rc "$(run_driver fw_check _S_PROTO='udp')")"
ck "T8 firewalld 收到 --query-port=443/udp" '1' \
    "$(grep -c -- '--query-port=443/udp' "${SB}/fwd.log" | tr -d '[:space:]')"

printf '443/udp\n' >"${SB}/fwd.allowed"
ck "T8 firewalld 已放行 443/udp -> rc=0" '0' \
    "$(parse_rc "$(run_driver fw_check _S_PROTO='udp')")"

: >"${SB}/fwd.allowed"
run_driver fw_ensure _S_PROTO='udp' >/dev/null
ck "T8 firewalld 自动加 --add-port=443/udp" '1' \
    "$(grep -c -- '--add-port=443/udp' "${SB}/fwd.log" | tr -d '[:space:]')"
ck "T8 firewalld 自动放行后 reload" '1' \
    "$(grep -c -- '--reload' "${SB}/fwd.log" | tr -d '[:space:]')"
ck "T8 firewalld ensure 复检通过 -> rc=0" '0' \
    "$(parse_rc "$(run_driver fw_ensure _S_PROTO='udp')")"

# ---------------------------------------------------------------------------
# 7. UDP 监听查询
# ---------------------------------------------------------------------------
out="$(run_driver udp_proc)"
ck "T10 走 ss -lnup (而非 TCP 的 -lntp)" '1' \
    "$(grep -c -- '-lnup' "${SB}/ss.log" | tr -d '[:space:]')"
ck "T10 按 udp sport 过滤 443" '1' \
    "$(grep -c 'sport = :443' "${SB}/ss.log" | tr -d '[:space:]')"
ck "T10 解析出占用进程" '1' \
    "$(grep -c 'nginx' <<<"${out}" | tr -d '[:space:]')"

# ---------------------------------------------------------------------------
# 8. i18n 双语文案
# ---------------------------------------------------------------------------
for lang in zh en; do
    f="${REPO}/i18n/${lang}.json"
    for key in udp_occupied_check udp_occupied_fail udp_occupied_pass http3_skip \
        h3_module_label h3_module_ok h3_module_missing h3_udp_label h3_udp_absent \
        h3_fw_label h3_fw_open h3_fw_none h3_fw_closed h3_mode_skip http3_stripped; do
        n="$(grep -c "\"${key}\":" "${f}" | tr -d '[:space:]')"
        if [[ "${n}" != '1' ]]; then
            bad "T11 ${lang}.json 缺少键 ${key} (命中 ${n} 次)"
        fi
    done
done
# 两语言总行数与键行数必须一致, 挡住"只改一个语言"
ck "T11 zh/en 总行数一致" \
    "$(wc -l <"${REPO}/i18n/zh.json" | tr -d '[:space:]')" \
    "$(wc -l <"${REPO}/i18n/en.json" | tr -d '[:space:]')"
ck "T11 zh/en 键行数一致" \
    "$(grep -cE '^[[:space:]]*"[a-z0-9_]+":' "${REPO}/i18n/zh.json" | tr -d '[:space:]')" \
    "$(grep -cE '^[[:space:]]*"[a-z0-9_]+":' "${REPO}/i18n/en.json" | tr -d '[:space:]')"
ok "T11 双语 HTTP/3 键齐备"

# ---------------------------------------------------------------------------
# 9. 静态守卫: 站点渲染路径必须调用护栏
# ---------------------------------------------------------------------------
n_align="$(grep -c 'align_site_http3 "' "${REPO}/core/handler.sh" | tr -d '[:space:]')"
if [[ "${n_align}" -ge 3 ]]; then
    ok "T12 handler.sh 中站点渲染路径已接入 align_site_http3 (${n_align} 处)"
else
    bad "T12 align_site_http3 调用点不足 (${n_align} < 3), 可能有渲染路径漏接护栏"
fi
# 护栏必须只在"探测不支持"时剥离, 不能被写成无条件删除
if awk '/^function align_site_http3\(\)/{f=1} f&&/_nginx_supports_http3/{print; exit}' \
    "${REPO}/core/handler.sh" | grep -q '_nginx_supports_http3'; then
    ok "T12 align_site_http3 依赖能力探测, 非无条件剥离"
else
    bad "T12 align_site_http3 未见 _nginx_supports_http3, 可能变成无条件剥离"
fi

printf '\n结果: %s\n' "$([[ "${fail}" -eq 0 ]] && echo 通过 || echo 失败)"
[[ "${fail}" -eq 0 ]]
