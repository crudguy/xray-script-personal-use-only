#!/usr/bin/env bash
#
# Copyright (C) 2026 crudguy
#
# xray-script-personal-use-only:
#   https://github.com/crudguy/xray-script-personal-use-only
# =============================================================================
# 脚本名称: check.sh
# 功能描述: 提供一系列验证函数，用于检查 IP、端口、UUID、密码、路径、Short ID、
#           域名安全性、DNS 解析、Xray 配置/版本以及邮箱地址的有效性。
#           主要用于在配置过程中验证用户输入或系统状态。
# 作者: crudguy
# 时间: 2026-09-19
# 版本: 1.0.0
# 依赖: bash, jq, dig, curl, openssl, stdbuf
# 配置:
#   - ${SCRIPT_CONFIG_DIR}/config.json: 用于读取语言设置 (language)
#   - ${I18N_DIR}/${lang}.json: 用于读取具体的提示文本 (i18n 数据文件)
# =============================================================================

# --- 共享头部: 严格模式 / ERR trap / PATH / 颜色 / 目录常量 / i18n 公共函数 ---
# 实际内容由 core/_common.sh 提供 (13 个脚本共用, 消除副本漂移); 设计取舍 (为何
# install.sh 不在此列, 为何用 $0 而非 BASH_SOURCE, 为何 PATH 是白名单而非追加) 见该文件。
# 注: 下面这行刻意留在每个脚本里 —— shellcheck 的 `set -e` 判定不跨 source,
#     移走会让本脚本内的 `cd` 全被误报 SC2164。
set -Eeuo pipefail

_XRAY_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
if [[ ! -f "${_XRAY_SCRIPT_DIR}/_common.sh" ]]; then
    printf '\033[31m[错误]\033[0m 脚本文件不完整: 缺少 %s\n' "_common.sh" >&2
    printf '        (请重新克隆仓库, 或运行 install.sh 重新下载)\n' >&2
    exit 1
fi
# shellcheck source=_common.sh
source "${_XRAY_SCRIPT_DIR}/_common.sh"

# 定义配置文件和相关目录的路径
readonly CONFIG_XRAY_DIR="${CONFIG_DIR}/xray"                  # Xray 配置文件目录

# --- 正则表达式常量 ---
# 定义各种数据格式的正则表达式，用于验证输入
# 注: DOMAIN_REGEX 已迁至 core/_common.sh 作为单一来源 (与 service/ssl.sh 共用), 此处不再重复定义。
readonly IPV4_REGEX='^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$' # IPv4
readonly IPV6_REGEX='^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$'                                            # IPv6 (简化版)
readonly HEX_REGEX='^[0-9a-fA-F]+$'                                                                         # 十六进制字符串
readonly UUID_REGEX='^[0-9a-fA-F]{8}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{12}$' # UUID
# 注: EMAIL_REGEX 已迁至 core/_common.sh 作为单一来源 (与 service/ssl.sh 共用), 此处不再重复定义。

# =============================================================================
# 函数名称: _check_info
# 功能描述: 打印信息级别的提示消息。
# 参数:
#   $1: 消息内容 (msg)
# 返回值: 无 (直接打印到标准错误输出 >&2)
# 注: 命名带 _check_ 前缀, 是为与本脚本 source 的 core/_common.sh 短名别名彻底分开 ——
#     不重名就不存在"同名不同行为"的遮蔽陷阱 (读者不会误以为二者是同一函数)。
# 注: 与 _common.sh 的 _info (绿色 + 取 $*) **行为刻意不同** —— 体检输出中"信息"(黄)
#     与"通过"(绿) 必须一眼可分, 故此处用黄色且只取首参。该刻意差异由
#     test/output_helper_sink_test.sh 守护 (有人误删本地定义或改回绿色即变红)。
# =============================================================================
function _check_info() {
    # 从 i18n 数据中读取 "信息" 标题，然后用黄色打印消息
    printf "${YELLOW}[%s]${NC} %s\n" "$(_i18n '.title.info')" "${1:-}" >&2
}

# =============================================================================
# 函数名称: _check_pass
# 功能描述: 打印成功/通过级别的提示消息。
# 参数:
#   $1: 消息内容 (msg)
# 返回值: 无 (直接打印到标准错误输出 >&2)
# 注: 同 _check_info —— 用 _check_ 前缀避开 _common.sh 的 _pass 同名遮蔽 (那版取 $*),
#     本函数只取首参, 与体检报告的单行语义一致。
# =============================================================================
function _check_pass() {
    # 从 i18n 数据中读取 "通过" 标题，然后用绿色打印消息
    printf "${GREEN}[%s]${NC} %s\n" "$(_i18n '.title.pass')" "${1:-}" >&2
}

# =============================================================================
# 函数名称: _check_fail
# 功能描述: 打印失败/错误级别的提示消息。
# 参数:
#   $1: 消息内容 (msg)
# 返回值: 无 (直接打印到标准错误输出 >&2)
# 注: 本函数与 tool/backup.sh 的 _fail **语义不同** —— backup.sh 的它会 exit 1,
#     本函数 (_check_fail) 只打印不退出 (体检流程需跑完全部检查项后再汇总), 故二者都未并入共享库。
#     (backup.sh 的 _fail 与 _common.sh 无重名, 属孤例; 本脚本用 _check_ 前缀后全仓不再有同名歧义。)
#     若有人给本函数加上 exit, 体检会在第一个失败项就中断 —— 见
#     test/error_hint_test.sh T2 与 test/output_helper_sink_test.sh 的双重守护。
# =============================================================================
function _check_fail() {
    # $1=失败消息; $2=可选的可执行建议 (非空时以 [建议] 追加一行到 stderr)
    # 注意: 本函数仅打印, 不退出 —— 体检流程需跑完全部检查项后再汇总。
    local msg="${1:-}" hint="${2:-}"
    printf "${RED}[%s]${NC} %s\n" "$(_i18n '.title.fail')" "${msg}" >&2
    if [[ -n "${hint}" ]]; then
        printf "${YELLOW}[%s]${NC} %s\n" "$(_i18n '.title.hint')" "${hint}" >&2
    fi
}

# =============================================================================
# 函数名称: _test
# 功能描述: 打印测试/检查过程中的提示消息。
# 参数:
#   $1: 消息内容 (msg)
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function _test() {
    # 从 i18n 数据中读取 "测试" 标题，然后用黄色打印消息
    printf "${YELLOW}[%s]${NC} %s\n" "$(_i18n '.title.test')" "${1:-}" >&2
}


# =============================================================================
# 函数名称: valid_domain
# 功能描述: 使用正则表达式检查给定字符串是否为有效的域名格式。
# 参数:
#   $1: 待检查的域名字符串 (domain)
# 返回值: 0-有效 1-无效 (直接由 [[ =~ ]] 命令的退出码决定)
# =============================================================================
function valid_domain() {
    local domain="${1:-}" # 获取域名参数

    # 使用正则表达式匹配域名格式，成功匹配返回 0，否则返回 1
    [[ "$domain" =~ $DOMAIN_REGEX ]] && return 0 || return 1
}

# =============================================================================
# 函数名称: check_domain_format
# 功能描述: 仅校验域名格式，不做 DNS 解析/TCP/TLS 探测。
#           用于"移除证书"等场景 —— 待移除证书的域名可能已经下线、无法解析，
#           但用户仍需要能精确移除它的证书 (此时要求可解析会误拒合法输入)。
# 参数:
#   $1: 待检查的域名 (domain)
# 返回值: 0-格式有效 1-格式无效 (并打印结果到 >&2)
# =============================================================================
function check_domain_format() {
    local domain="${1:-}" # 获取域名参数

    # 域名为空视为无效 (移除证书必须显式指定域名)
    if [[ -z "${domain}" ]]; then
        _check_fail "$(_i18n ".${CUR_FILE}.domain.empty")"
        return 1
    fi

    # 仅校验格式
    if ! valid_domain "$domain"; then
        _check_fail "$(_i18n ".${CUR_FILE}.domain.format_error")${domain}"
        return 1
    fi

    _check_pass "$(_i18n ".${CUR_FILE}.domain.format_ok")${domain}"
    return 0
}

# =============================================================================
# 函数名称: _rule_split_values
# 功能描述: 把"逗号分隔"的分流输入拆成一行一个值, 去首尾空白并丢弃空项。
#           与 core/handler.sh 的 add_rule 使用**同一套**归一化 (tr/sed/awk),
#           使"本处校验通过的集合"与"真正写入配置的集合"严格一致 —— 否则会出现
#           "校验放行 A、写入的却是 B"的裂缝。
# 参数:
#   $1: 原始输入 (可含逗号与空白)
# 返回值: 逐行打印归一化后的非空值 (无有效值时无输出)
# =============================================================================
function _rule_split_values() {
    printf '%s' "${1:-}" | tr ',' '\n' |
        sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
        awk 'NF'
}

# =============================================================================
# 函数名称: _rule_is_valid_ip
# 功能描述: 判断单个 ip 分流项是否为 xray 可接受的形态。
#           刻意"宁可放行也不误拒": 只拦明显非法者, 放行 geoip:xxx / ext:file:tag /
#           IPv4(含 CIDR) / IPv6(含 CIDR)。内容是否真实存在 (如 geoip 码是否有效)
#           不在本函数职责内 —— 那由后续 xray 校验兜底, 这里只挡"一眼假"的输入。
# 参数:
#   $1: 单个值
# 返回值: 0-合法 1-非法
# =============================================================================
function _rule_is_valid_ip() {
    local v="${1:-}"
    [[ -n "${v}" ]] || return 1
    # geoip / ext 前缀: 前缀后有非空值即放行 (具体码表由 geoip.dat / 外部列表决定)
    [[ "${v}" == geoip:?* || "${v}" == ext:?* ]] && return 0
    # IPv4 [可选 /前缀]: 逐段 <=255, 前缀 <=32
    if [[ "${v}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/([0-9]{1,3}))?$ ]]; then
        local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}" d="${BASH_REMATCH[4]}" p="${BASH_REMATCH[6]:-}"
        ((a <= 255 && b <= 255 && c <= 255 && d <= 255)) || return 1
        [[ -z "${p}" ]] || ((p <= 32)) || return 1
        return 0
    fi
    # IPv6 [可选 /前缀]: 合法 IPv6 至少含**两个**冒号 (::1 / 2001:db8::1 / 8 组全写皆是),
    # 借此把 "abc:def" 这类单冒号伪值挡在门外 (仅十六进制与冒号, 前缀 <=128)。
    if [[ "${v}" == *:*:* && "${v}" =~ ^[0-9A-Fa-f:]+(/[0-9]{1,3})?$ ]]; then
        local p6="${v##*/}"
        [[ "${v}" != */* ]] || ((p6 <= 128)) || return 1
        return 0
    fi
    return 1
}

# =============================================================================
# 函数名称: _rule_is_valid_domain
# 功能描述: 判断单个 domain 分流项是否为 xray 可接受的形态。
#           放行: geosite:/ext:/domain:/full:/keyword:/regexp: 前缀, 以及裸域名;
#           拦明显非法: 含空白、空标签、以点开头/结尾、非法字符、只有前缀没有值。
#           注: regexp: 是正则表达式, 允许任意字符 (含空格), 直接放行。
# 参数:
#   $1: 单个值
# 返回值: 0-合法 1-非法
# =============================================================================
function _rule_is_valid_domain() {
    local v="${1:-}"
    [[ -n "${v}" ]] || return 1
    [[ "${v}" == regexp:?* ]] && return 0 # 正则, 不限制字符集
    [[ "${v}" != *[[:space:]]* ]] || return 1
    case "${v}" in
    geosite:* | ext:* | domain:* | full:* | keyword:*)
        [[ -n "${v#*:}" ]] && return 0 || return 1 # 前缀后必须有值
        ;;
    *:) return 1 ;; # 只有前缀没有值
    esac
    # 裸域名: 字母/数字/下划线/连字符/星号 组成的标签, 以点分隔
    # (空标签与首尾点被正则自然排除: 每个标签至少 1 个字符)
    [[ "${v}" =~ ^[A-Za-z0-9_*-]+(\.[A-Za-z0-9_*-]+)*$ ]] && return 0
    return 1
}

# =============================================================================
# 函数名称: _rule_first_invalid
# 功能描述: 在逗号分隔的分流输入里找出**第一个**非法值并打印 (全部合法则不打印)。
#           校验与报错分离: 本函数只负责"找出是谁", 文案由调用方决定。
# 参数:
#   $1: 类型 ("ip" 或 "domain")
#   $2: 原始输入
# 返回值: 恒 0 (结果经 stdout 输出; 无非法值时输出为空)
# =============================================================================
function _rule_first_invalid() {
    local kind="${1:-}" raw="${2:-}" list='' v=''
    list="$(_rule_split_values "${raw}")"
    [[ -n "${list}" ]] || return 0
    while IFS= read -r v; do
        case "${kind}" in
        ip) _rule_is_valid_ip "${v}" || {
            printf '%s' "${v}"
            return 0
        } ;;
        domain) _rule_is_valid_domain "${v}" || {
            printf '%s' "${v}"
            return 0
        } ;;
        esac
    done <<<"${list}"
    return 0
}

# =============================================================================
# 函数名称: check_rule_ip / check_rule_domain
# 功能描述: 校验 "ip / domain 分流" 输入 (可含逗号分隔的多个值)。
#           供 core/handler.sh 的 exec_read 在**写盘前**调用, 使非法值"当场提示重输",
#           而不是先写进配置、再由 xray 语法校验失败回滚 (回滚虽安全, 但用户看到的是
#           一串报错 + 退出码 1, 体验差且掩盖了"其实就是值写错了")。
#           校验通过时**静默返回 0** (不打印 _check_pass): 这是交互输入的写前闸门,
#           不是体检报告, 成功路径保持安静更清爽。
#           空输入视为"取消", 直接放行 (告警与 no-op 由 add_rule 的 value_empty 守卫统一负责)。
# 参数: $1=原始输入
# 返回值: 0-全部合法 (或空输入) 1-存在非法值 (并打印原因到 >&2)
# =============================================================================
function check_rule_ip() {
    local bad=''
    bad="$(_rule_first_invalid 'ip' "${1:-}")"
    if [[ -n "${bad}" ]]; then
        _check_fail "$(_i18n_sub ".${CUR_FILE}.rule.invalid_ip" '${value}' "${bad}")"
        return 1
    fi
    return 0
}

function check_rule_domain() {
    local bad=''
    bad="$(_rule_first_invalid 'domain' "${1:-}")"
    if [[ -n "${bad}" ]]; then
        _check_fail "$(_i18n_sub ".${CUR_FILE}.rule.invalid_domain" '${value}' "${bad}")"
        return 1
    fi
    return 0
}

# =============================================================================
# 函数名称: resolve_domain
# 功能描述: 使用 dig 命令尝试解析域名，检查是否有有效的 IP 地址记录。
# 参数:
#   $1: 待解析的域名 (domain)
# 返回值: 0-解析成功 1-解析失败或无记录
# =============================================================================
function resolve_domain() {
    # 使用 dig +short 命令解析域名，并将输出通过管道传递给 grep
    # 如果 grep 能在输出中找到至少一个 '.' 字符（通常是 IP 地址的一部分），则返回 0
    # 否则返回 1
    if dig +short "${1:-}" | grep -q '.'; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# 函数名称: dns_resolution
# 功能描述: 检查给定域名是否解析为当前服务器的 IP 地址。
#           分别检查 IPv4 和 IPv6 地址。
# 参数:
#   $1: 待检查的域名 (domain)
# 返回值: 0-至少有一个 IP 匹配 1-都不匹配
# =============================================================================
function dns_resolution() {
    local domain=${1:-} # 获取域名参数

    # 统一探测服务器公网 IPv4/IPv6 (双栈, 绕过代理, 结果缓存, 见 _common.sh)。
    # 直调以复用进程内缓存 (dns_resolution 会被多个域名依次调用, 只探测一次);
    # 不用 < <(_resolve_public_ips): 进程替换同样是子 shell, 缓存写不回当前 shell。
    _resolve_public_ips >/dev/null
    local expected_ipv4="${_PUBLIC_IPV4}"
    local expected_ipv6="${_PUBLIC_IPV6}"

    local resolved=0 # 初始化标志变量，表示是否匹配

    # 解析域名的 IPv4 和 IPv6 记录
    local actual_ipv4
    actual_ipv4="$(dig +short "${domain}" || true)"
    local actual_ipv6
    actual_ipv6="$(dig +short AAAA "${domain}" || true)"

    # 精确整行匹配: 用 grep -F (固定串) -x (整行) 替代 [[ =~ ]],
    # 避免 expected 为空时 "invalid regular expression: empty"、'.' 被当通配、
    # 多行子串误判 (如 1.2.3.4 误中 1a2b3c4); expected 为空表示该栈不可用, 跳过。
    if [[ -n "${expected_ipv4}" ]] && printf '%s\n' "${actual_ipv4}" | grep -qxF "${expected_ipv4}"; then resolved=1; fi
    if [[ -n "${expected_ipv6}" ]] && printf '%s\n' "${actual_ipv6}" | grep -qxF "${expected_ipv6}"; then resolved=1; fi

    # 根据 resolved 标志返回结果
    [[ ${resolved} -eq 1 ]]
}

# =============================================================================
# 函数名称: test_tcp_connection
# 功能描述: 测试到指定主机和端口的 TCP 连接是否可达。
#           利用 bash 内建的 /dev/tcp 特性。
# 参数:
#   $1: 主机名或 IP 地址 (host)
#   $2: 端口号 (port)
# 返回值: 0-连接成功 1-连接失败 (由 /dev/tcp 操作的退出码决定)
# =============================================================================
function test_tcp_connection() {
    local host="${1:-}"
    local port="${2:-}"
    # 参数缺失时无需尝试连接: /dev/tcp//443 这类空 host 只会产生无意义的报错
    [[ -n "${host}" && -n "${port}" ]] || return 1
    # 尝试打开到 host:port 的 TCP 连接，将输出重定向到 /dev/null
    # 成功则返回 0，失败（如连接被拒绝、超时）则返回非 0
    # 以重定向本身是否成功作为连接成败依据。
    # 注: 原来写 `return $?`, 会被读成"echo 的返回值"(SC2320) 且语义含糊。
    #
    # 超时保护: bash 内建的 /dev/tcp **没有超时概念** —— 对端若直接 DROP 数据包
    #   (防火墙常见策略), connect 会一直阻塞到系统级 TCP 超时 (实测可达 ~2 分钟),
    #   期间 --domain 校验与体检整体卡死且无任何提示。
    #   这里用 coreutils 的 timeout 包一层子 shell 强制限时; 若系统没有 timeout
    #   (极简镜像) 则退回原行为 —— 宁可损失保底能力, 也不引入新的硬依赖。
    if cmd_exists 'timeout'; then
        # bash -c 的位置参数: $0 占位, $1=host, $2=port
        if timeout "${TCP_CONNECT_TIMEOUT:-5}" \
            bash -c 'echo >/dev/tcp/"$1"/"$2"' _ "${host}" "${port}" 2>/dev/null; then
            return 0
        fi
        return 1
    fi
    if echo >/dev/tcp/"${host}"/"${port}" 2>/dev/null; then
        return 0
    fi
    return 1
}

# =============================================================================
# 函数名称: get_listening_process_by_port
# 功能描述: 获取指定端口的监听进程标识（优先 ss，回退 lsof）。
# =============================================================================
function get_listening_process_by_port() {
    local port="${1:-}"
    local process=''
    if cmd_exists 'ss'; then
        process="$(ss -lntp "( sport = :${port} )" 2>/dev/null | awk 'NR > 1 {print $NF; exit}')"
    fi
    if [[ -z "${process}" ]] && cmd_exists 'lsof'; then
        process="$(lsof -nP -iTCP:${port} -sTCP:LISTEN 2>/dev/null | awk 'NR == 2 {print $1"/"$2; exit}')"
    fi
    [[ "${process}" == '-' ]] && process=''
    echo "${process}"
}

# =============================================================================
# 函数名称: get_listening_process_by_udp_port
# 功能描述: 获取指定 UDP 端口的监听进程标识（优先 ss，回退 lsof）。
#           与 TCP 版分开实现: ss 的 UDP 过滤用 -u、lsof 的过滤器是 -iUDP:<port>,
#           直接复用 TCP 版会静默查不到任何东西 (QUIC 端口"看起来没人占")。
# =============================================================================
function get_listening_process_by_udp_port() {
    local port="${1:-}"
    local process=''
    if cmd_exists 'ss'; then
        process="$(ss -lnup "( sport = :${port} )" 2>/dev/null | awk 'NR > 1 {print $NF; exit}')"
    fi
    if [[ -z "${process}" ]] && cmd_exists 'lsof'; then
        process="$(lsof -nP -iUDP:${port} 2>/dev/null | awk 'NR == 2 {print $1"/"$2; exit}')"
    fi
    [[ "${process}" == '-' ]] && process=''
    echo "${process}"
}

# =============================================================================
# 函数名称: _ufw_status_text
# 功能描述: 取 `ufw status` 的完整输出 (未安装时为空串)。
#           为什么要包一层: 原写法是 `ufw status | grep -q '^Status: active'`。
#           grep -q 命中后立即退出会关闭管道, 仍在写 stdout 的 ufw 收到 EPIPE;
#           在 `set -o pipefail` 下整条管道因此返回 141(失败), 于是"防火墙已激活"
#           被误判成"没有活动防火墙" —— 而调用方对该分支的处理是"默认视为放行",
#           结果是放行检查被静默跳过 (TCP 与 UDP 都受影响)。
#           先把输出整段收进变量, 再用内建字符串比较判定, 既消除该风险,
#           也少起一次进程。
# 参数: 无
# 返回值: 恒 0 (状态文本由 stdout 给出, 可能为空)
# =============================================================================
function _ufw_status_text() {
    cmd_exists 'ufw' || return 0
    ufw status 2>/dev/null || true
}

# =============================================================================
# 函数名称: check_firewall_port_open
# 功能描述: 检查活动防火墙（ufw/firewalld）是否已放行指定端口/协议。
#           泛化自原 check_firewall_tcp_port_open —— HTTP/3 (QUIC) 走 UDP/443,
#           只查 TCP 会让"TCP 通、UDP 被挡"这种最常见的 H3 故障躲过预检。
# 参数:
#   $1: port  - 端口号
#   $2: proto - 协议 (tcp / udp), 缺省 tcp
# 返回值: 0 已放行, 1 未放行, 2 未检测到活动防火墙
# =============================================================================
function check_firewall_port_open() {
    local port="${1:-}"
    local proto="${2:-tcp}"
    local ufw_status=''
    ufw_status="$(_ufw_status_text)"
    if [[ "${ufw_status}" == *'Status: active'* ]]; then
        # ufw 里 `allow <port>` 会展开成 <port>/tcp 与 <port>/udp 两行, 故协议段可选
        printf '%s\n' "${ufw_status}" | grep -Eiq "^${port}(/${proto})?[[:space:]]+ALLOW"
        return $?
    fi
    if cmd_exists 'firewall-cmd' && cmd_exists 'systemctl' && systemctl -q is-active firewalld; then
        firewall-cmd --quiet --query-port="${port}/${proto}"
        return $?
    fi
    return 2
}

# 仅检查 TCP 放行 (保留原函数名, 供既有调用点与外部沿用)
function check_firewall_tcp_port_open() {
    check_firewall_port_open "${1:-}" 'tcp'
}

# 检测当前已激活的防火墙名称（空格分隔）
function detect_active_firewalls() {
    local -a active_firewalls=()
    local ufw_status=''
    # 同 check_firewall_port_open: 不用 `ufw status | grep -q`, 见 _ufw_status_text
    ufw_status="$(_ufw_status_text)"
    if [[ "${ufw_status}" == *'Status: active'* ]]; then
        active_firewalls+=('ufw')
    fi
    if cmd_exists 'firewall-cmd' && cmd_exists 'systemctl' && systemctl -q is-active firewalld; then
        active_firewalls+=('firewalld')
    fi
    echo "${active_firewalls[*]}"
}

# 尝试放行指定端口/协议
function allow_firewall_port() {
    local firewall="${1:-}"
    local port="${2:-}"
    local proto="${3:-tcp}"
    case "${firewall}" in
    ufw)
        ufw allow "${port}/${proto}" >/dev/null 2>&1
        ;;
    firewalld)
        firewall-cmd --quiet --permanent --add-port="${port}/${proto}" && firewall-cmd --quiet --reload
        ;;
    *)
        return 1
        ;;
    esac
}

# 仅放行 TCP (保留原函数名, 供既有调用点与外部沿用)
# 注: 生产链路已不再调用它 (ensure_firewall_port_open 直接调 allow_firewall_port), 但它
#     并非死代码 —— test/http3_test.sh 的 T9 把它当作"纯 TCP 放行"的既有契约在驱动,
#     删掉会让该用例变红。后续审计勿据"生产无调用点"判为死代码而清理。
function allow_firewall_tcp_port() {
    allow_firewall_port "${1:-}" "${2:-}" 'tcp'
}

# =============================================================================
# 函数名称: ensure_firewall_port_open
# 功能描述: 确保指定端口/协议在活动防火墙中放行；若未放行则自动尝试放行。
# 参数:
#   $1: port  - 端口号
#   $2: proto - 协议 (tcp / udp), 缺省 tcp
# 返回值: 0 已放行或无需放行, 1 放行失败
# =============================================================================
function ensure_firewall_port_open() {
    local port="${1:-}"
    local proto="${2:-tcp}"
    local tag="${port}/${proto^^}"
    local firewall_check_rc=0
    local active_firewalls_raw=''
    local -a active_firewalls=()
    local firewall=''
    local allow_failed=0

    _test "$(_i18n ".${CUR_FILE}.sni_ports.open_check")${tag}"
    check_firewall_port_open "${port}" "${proto}"
    firewall_check_rc=$?
    if [[ ${firewall_check_rc} -eq 0 ]]; then
        _check_pass "$(_i18n ".${CUR_FILE}.sni_ports.open_pass")${tag}"
        return 0
    fi

    active_firewalls_raw="$(detect_active_firewalls)"
    if [[ -z "${active_firewalls_raw}" ]]; then
        _check_info "$(_i18n ".${CUR_FILE}.sni_ports.open_skip")${tag}"
        return 0
    fi
    read -r -a active_firewalls <<<"${active_firewalls_raw}"

    _check_info "$(_i18n ".${CUR_FILE}.sni_ports.firewall_active")${active_firewalls_raw}"
    _test "$(_i18n ".${CUR_FILE}.sni_ports.allow_try")${tag}"
    for firewall in "${active_firewalls[@]}"; do
        if ! allow_firewall_port "${firewall}" "${port}" "${proto}"; then
            allow_failed=1
        fi
    done

    check_firewall_port_open "${port}" "${proto}"
    firewall_check_rc=$?
    if [[ ${allow_failed} -eq 0 && ${firewall_check_rc} -eq 0 ]]; then
        _check_pass "$(_i18n ".${CUR_FILE}.sni_ports.allow_pass")${tag}"
        return 0
    fi

    _check_fail "$(_i18n ".${CUR_FILE}.sni_ports.allow_fail")${tag}"
    _check_info "$(_i18n ".${CUR_FILE}.sni_ports.manual_allow")${tag}"
    return 1
}

# 仅确保 TCP 放行 (保留原函数名, 供既有调用点与外部沿用)
function ensure_firewall_tcp_port_open() {
    ensure_firewall_port_open "${1:-}" 'tcp'
}

# =============================================================================
# 函数名称: check_sni_ports
# 功能描述: SNI 初始化前检查 80/443 端口是否被占用并确保防火墙放行。
# =============================================================================
function check_sni_ports() {
    local -a required_ports=(80 443)
    local port=''
    local occupied_by=''

    _check_info "$(_i18n ".${CUR_FILE}.sni_ports.start")"

    for port in "${required_ports[@]}"; do
        _test "$(_i18n ".${CUR_FILE}.sni_ports.occupied_check")${port}"
        occupied_by="$(get_listening_process_by_port "${port}")"
        if [[ -n "${occupied_by}" ]]; then
            _check_fail "$(_i18n ".${CUR_FILE}.sni_ports.occupied_fail")${port} (${occupied_by})" "$(_i18n ".${CUR_FILE}.sni_ports.occupied_fail_hint")"
            return 1
        fi
        _check_pass "$(_i18n ".${CUR_FILE}.sni_ports.occupied_pass")${port}"

        if ! ensure_firewall_tcp_port_open "${port}"; then
            return 1
        fi
    done

    # HTTP/3 (QUIC) 额外需要 UDP/443: 它与 TCP 443 是两个独立监听, 只放行 TCP
    # 是"H3 配好了却永远握手不上"的最常见原因 (nginx 官方 QUIC 文档专门点出这一条)。
    # 仅当本机 Nginx 编译了 http_v3 模块时才要求 —— 否则站点配置不会落 quic 指令,
    # 强行开 UDP 只是白白放宽防火墙。
    if _nginx_supports_http3; then
        if ! ensure_http3_udp_ready; then
            return 1
        fi
    else
        _check_info "$(_i18n ".${CUR_FILE}.sni_ports.http3_skip")"
    fi

    _check_pass "$(_i18n ".${CUR_FILE}.sni_ports.all_pass")"
    return 0
}

# =============================================================================
# 函数名称: ensure_http3_udp_ready
# 功能描述: HTTP/3 就绪检查 —— UDP/443 空闲且防火墙已放行。
#           占用检查与 TCP 侧同款严格度: 被占即失败, 因为此时 Nginx 起不来,
#           与"443/TCP 被别人占着"是同一类硬阻塞。
# 参数: 无
# 返回值: 0 就绪, 1 端口被占或防火墙放行失败
# =============================================================================
function ensure_http3_udp_ready() {
    local port=443
    local occupied_by=''

    _test "$(_i18n ".${CUR_FILE}.sni_ports.udp_occupied_check")${port}/UDP"
    occupied_by="$(get_listening_process_by_udp_port "${port}")"
    if [[ -n "${occupied_by}" ]]; then
        _check_fail "$(_i18n ".${CUR_FILE}.sni_ports.udp_occupied_fail")${port}/UDP (${occupied_by})" "$(_i18n ".${CUR_FILE}.sni_ports.udp_occupied_fail_hint")"
        return 1
    fi
    _check_pass "$(_i18n ".${CUR_FILE}.sni_ports.udp_occupied_pass")${port}/UDP"

    ensure_firewall_port_open "${port}" 'udp'
}

# =============================================================================
# 函数名称: get_tls_info
# 功能描述: 使用 openssl s_client 命令获取指定域名的 TLS 信息。
# 参数:
#   $1: 域名 (domain)
# 返回值: TLS 连接的详细信息 (echo 输出)
# 注意: 会过滤掉空字节 (\0)
# =============================================================================
function get_tls_info() {
    # 向域名的 443 端口发起 TLS 1.3 连接请求，并指定 ALPN 为 h2
    # 使用 echo QUIT 发送退出命令，stdbuf -oL 确保输出行缓冲
    # 2>&1 将错误输出合并到标准输出，tr -d '\0' 过滤掉空字节
    #
    # 超时保护: 与 test_tcp_connection 同理 —— 目标不可达/DROP 时 openssl s_client
    #   会长时间挂住。用 timeout 强制限时 (超时返回 124), 使调用方能及时给出
    #   "TLS 探测失败" 的结论, 而不是把整个体检拖成假死。
    #   系统无 timeout 时退回原行为。
    #
    # 必须带 -servername (SNI): 此前不带 SNI 握手, 于是**多租户/按 SNI 分流**的站点
    #   会拿不到对应证书而握手失败, 检测结论是"TLS 连接失败, 可能不支持 TLS 1.3",
    #   可该域名其实完全可用 —— 用户被误拒, 且改多少次名都一样。
    #   实测 (2026-09-23, 大陆网络): www.samsung.com / www.docker.com 不带 SNI 时
    #   取不到 X25519 (判 FAIL), 带上 SNI 后 TLS 1.3 + X25519 均正常。
    #   这也是与真实链路一致的做法: Reality 的 dest 收到的是**带 SNI** 的
    #   ClientHello (serverName 来自 serverNames), 探测就该照此发起。
    if cmd_exists 'timeout'; then
        echo QUIT | timeout "${TLS_PROBE_TIMEOUT:-10}" \
            stdbuf -oL openssl s_client -connect "${1:-}:443" -servername "${1:-}" -tls1_3 -alpn h2 2>&1 | tr -d '\0'
    else
        echo QUIT | stdbuf -oL openssl s_client -connect "${1:-}:443" -servername "${1:-}" -tls1_3 -alpn h2 2>&1 | tr -d '\0'
    fi
}

# =============================================================================
# 函数名称: check_ip
# 功能描述: 验证 IP 地址是否符合 IPv4 或 IPv6 格式。
# 参数:
#   $1: 待检查的 IP 地址 (ip)
# 返回值: 0-有效 1-无效 (并打印相应的提示信息到 >&2)
# =============================================================================
function check_ip() {
    local ip="${1:-}" # 获取 IP 地址参数

    # 打印正在检查的信息
    _check_info "$(_i18n ".${CUR_FILE}.ip.check")${ip}"

    # 使用正则表达式检查 IPv4 格式
    if [[ "$ip" =~ $IPV4_REGEX ]]; then
        _check_pass "$(_i18n ".${CUR_FILE}.ip.ipv4_valid")$ip"
        return 0
    # 使用正则表达式检查 IPv6 格式
    elif [[ "$ip" =~ $IPV6_REGEX ]]; then
        _check_pass "$(_i18n ".${CUR_FILE}.ip.ipv6_valid")$ip"
        return 0
    else
        # 如果都不匹配，则为无效 IP
        _check_fail "$(_i18n ".${CUR_FILE}.ip.invalid")$ip"
        return 1
    fi
}

# =============================================================================
# 函数名称: check_port
# 功能描述: 验证端口号是否在有效范围内 (1-65535)。
# 参数:
#   $1: 待检查的端口号 (port)
# 返回值: 0-有效或为空 1-无效 (并打印相应的提示信息到 >&2)
# =============================================================================
function check_port() {
    local port="${1:-}" # 获取端口号参数

    # 打印正在检查的信息
    _check_info "$(_i18n ".${CUR_FILE}.port.check")${port}"

    # 如果端口为空，则认为是有效的（可能表示使用默认值）
    if [[ -z "${port}" ]]; then
        _check_pass "$(_i18n ".${CUR_FILE}.port.empty")"
    # 检查端口号是否在 1-65535 范围内
    # 注: 必须写 10#${port} 强制十进制 —— bash 的算术上下文会把带前导 0 的
    #     字面量当八进制, 于是用户敲 "08" / "080" 这类补零写法时, 不是被正常
    #     判定为合法端口, 而是先甩出一行内部噪声
    #     `((: 08: value too great for base (error token is "08"))`
    #     再被当成非法端口, 用户完全看不懂自己错在哪。
    elif [[ "${port}" =~ ^[0-9]+$ ]] && ((10#${port} >= 1 && 10#${port} <= 65535)); then
        _check_pass "$(_i18n ".${CUR_FILE}.port.valid")$port"
    else
        # 如果超出范围，则为无效
        _check_fail "$(_i18n ".${CUR_FILE}.port.range_error")$port"
        return 1
    fi
    return 0
}

# =============================================================================
# 函数名称: check_uuid
# 功能描述: 验证 UUID 是否符合标准格式。
#   语义澄清 (此前注释自相矛盾, 说"似乎有出入", 实为**有意设计**):
#     1) 空值    -> 交给上层 exec_generate 自动生成 (见 i18n: uuid.empty);
#     2) 非标准格式 -> Xray 支持把任意字符串映射为 VLESS id (见 i18n: uuid.string);
#     3) 标准格式 -> 直接使用。
#   三种都是合法输入, 故恒返回 0 —— 这与 i18n 文案完全一致, 不是缺陷。
#   注意: 因此本函数**不做拦截**, 调用方若需强制标准 UUID 应另行校验。
# 参数:
#   $1: 待检查的 UUID 字符串 (uuid)
# 返回值: 总是返回 0 (并打印相应的提示信息到 >&2)
# =============================================================================
function check_uuid() {
    local uuid="${1:-}" # 获取 UUID 参数

    # 打印正在检查的信息
    # 注: UUID 属于**节点标识**而非口令, 且随后会以分享链接/二维码形式完整展示给用户,
    #     用户需要据此核对自己输入的是哪一份, 因此这里保留回显(与其它口令类字段不同)。
    _check_info "$(_i18n ".${CUR_FILE}.uuid.check")${uuid}"

    # 如果 UUID 为空，则认为是有效的（表示自动生成）
    if [[ -z "${uuid}" ]]; then
        _check_pass "$(_i18n ".${CUR_FILE}.uuid.empty")"
    # 如果 UUID 不符合标准格式，则认为是有效的字符串（可能表示使用普通字符串）
    elif ! [[ "$uuid" =~ $UUID_REGEX ]]; then
        _check_pass "$(_i18n ".${CUR_FILE}.uuid.string")$uuid"
    else
        # 如果符合标准格式，则为有效 UUID
        _check_pass "$(_i18n ".${CUR_FILE}.uuid.valid")$uuid"
    fi
    return 0
}

# =============================================================================
# 函数名称: check_password
# 功能描述: 验证密码是否符合基本安全要求（无空格、长度>=8）。
#   空值是**合法输入**: 表示"不指定, 由上层自动生成" (见 i18n: password.empty),
#   故走 _check_pass + return 0。此前注释写的"空则无效"与实现相反, 属注释错误, 已订正。
# 参数:
#   $1: 待检查的密码 (password)。同时用于 Trojan 密码与 mKCP seed —— 均为真实凭据。
# 返回值: 0-有效 1-无效 (并打印相应的提示信息到 >&2)
# 注: 本函数**不得回显明文**。此前的实现在 _check_info/_check_pass/_check_fail 四处把密码原样打到
#     stderr, 而 stderr 不随管道消失 —— 终端回滚、screen/tmux 日志、运维录屏、
#     `2>log` 重定向都会永久留存 Trojan 密码与 mKCP seed。现统一改为掩码+长度。
# =============================================================================
function check_password() {
    local password="${1:-}" # 获取密码参数
    # 掩码显示: 只暴露长度, 不暴露内容。用户仍可据此判断是否"填错成空/过短"。
    local masked="****"
    [[ -n "${password}" ]] && masked="****(${#password} 字符)"

    # 打印正在检查的信息
    _check_info "$(_i18n ".${CUR_FILE}.password.check")${masked}"

    # 如果密码为空，则视为"交由上层自动生成"，合法
    if [[ -z "${password}" ]]; then
        _check_pass "$(_i18n ".${CUR_FILE}.password.empty")"
        return 0
    fi

    # 检查密码中是否包含空格。
    # 注: 原写法 `=~ *\ *` 是非法 ERE, bash 会报 "invalid regular expression"
    #     且 [[ ]] 返回 2, 在 if 中恒为假 => 该校验此前从未生效 (SC2049)。
    if [[ "${password}" =~ [[:space:]] ]]; then
        _check_fail "$(_i18n ".${CUR_FILE}.password.space_error")${masked}"
        return 1
    fi

    # 检查密码长度是否小于 8
    if ((${#password} < 8)); then
        _check_fail "$(_i18n ".${CUR_FILE}.password.length_error")${masked}"
        return 1
    fi

    # 如果所有检查都通过，则密码有效
    _check_pass "$(_i18n ".${CUR_FILE}.password.valid")${masked}"
    return 0
}

# =============================================================================
# 函数名称: check_path
# 功能描述: 验证路径字符串是否符合 URL 路径格式要求。
# 参数:
#   $1: 待检查的路径字符串 (path)
# 返回值: 0-有效 1-无效 (并打印相应的提示信息到 >&2)
# =============================================================================
function check_path() {
    local path="${1:-}" # 获取路径参数

    # 打印正在检查的信息
    _check_info "$(_i18n ".${CUR_FILE}.path.check")${path}"

    # 如果路径为空，则认为是有效的（可能表示使用根路径）
    if [[ -z "${path}" ]]; then
        _check_pass "$(_i18n ".${CUR_FILE}.path.empty")"
        return 0
    fi

    # 检查路径中是否包含空格 (同上: 原 `=~ *\ *` 非法 ERE, 校验恒未生效)。
    if [[ "${path}" =~ [[:space:]] ]]; then
        _check_fail "$(_i18n ".${CUR_FILE}.path.space_error")$path"
        return 1
    fi

    # 检查路径长度是否超过 128
    if ((${#path} > 128)); then
        _check_fail "$(_i18n ".${CUR_FILE}.path.length_error")$path"
        return 1
    fi

    # 检查路径是否包含不允许的字符（只允许字母、数字、下划线、斜杠、点、连字符）
    if [[ "${path}" =~ [^a-zA-Z0-9_/.\-] ]]; then
        _check_fail "$(_i18n ".${CUR_FILE}.path.char_error")$path"
        return 1
    fi

    # 检查路径是否包含连续的斜杠
    if [[ "${path}" =~ // ]]; then
        _check_fail "$(_i18n ".${CUR_FILE}.path.double_slash_error")$path"
        return 1
    fi

    # 如果所有检查都通过，则路径有效
    _check_pass "$(_i18n ".${CUR_FILE}.path.valid")$path"
    return 0
}

# =============================================================================
# 函数名称: check_short_id
# 功能描述: 验证 Short ID 是否符合要求（空、单数字、或有效的十六进制字符串）。
# 参数:
#   $1: 待检查的 Short ID (short_id)
# 返回值: 0-有效 1-无效 (并打印相应的提示信息到 >&2)
# =============================================================================
function check_short_id() {
    local short_id="${1:-}" # 获取 Short ID 参数

    # 打印正在检查的信息
    _check_info "$(_i18n ".${CUR_FILE}.short.check")${short_id}"

    # 如果 Short ID 为空，则认为是有效的
    if [[ -z "${short_id}" ]]; then
        _check_pass "$(_i18n ".${CUR_FILE}.short.empty")"
        return 0
    fi

    # 如果 Short ID 是 0-8 的单个数字，则认为是有效的（表示生成指定长度的 ID）
    if [[ ${short_id} =~ ^[0-8]$ ]]; then
        _check_pass "$(_i18n ".${CUR_FILE}.short.digit")$short_id"
        return 0
    fi

    # 检查 Short ID 的长度是否为奇数或超过 16
    if ((${#short_id} % 2 != 0 || ${#short_id} > 16)); then
        _check_fail "$(_i18n ".${CUR_FILE}.short.length_error")$short_id"
        return 1
    fi

    # 检查 Short ID 是否为有效的十六进制字符串
    if ! [[ "${short_id}" =~ $HEX_REGEX ]]; then
        _check_fail "$(_i18n ".${CUR_FILE}.short.hex_error")$short_id"
        return 1
    fi

    # 如果所有检查都通过，则 Short ID 有效
    _check_pass "$(_i18n ".${CUR_FILE}.short.valid")$short_id"
    return 0
}

# =============================================================================
# 函数名称: check_domain_security
# 功能描述: 全面检查域名的安全性，包括格式、解析、TCP 连接和 TLS 信息。
# 参数:
#   $1: 待检查的域名 (domain)
# 返回值: 0-安全检查通过 1-安全检查失败 (并打印详细的检查过程和结果到 >&2)
# =============================================================================
function check_domain_security() {
    local domain="${1:-}" # 获取域名参数

    # 打印正在检查的信息
    _check_info "$(_i18n ".${CUR_FILE}.domain.security_check")${domain}"

    # 如果域名为空，则认为是有效的（可能表示不使用域名）
    if [[ -z "${domain}" ]]; then
        _check_pass "$(_i18n ".${CUR_FILE}.domain.empty")"
        return 0
    fi

    # 检查域名格式是否有效
    if ! valid_domain "$domain"; then
        _check_fail "$(_i18n ".${CUR_FILE}.domain.format_error")$domain"
        return 1
    fi

    # 测试域名解析
    _test "$(_i18n ".${CUR_FILE}.domain.resolve")${domain}"
    if ! resolve_domain "$domain"; then
        _check_fail "$(_i18n ".${CUR_FILE}.domain.resolve_fail")$domain" "$(_i18n ".${CUR_FILE}.domain.resolve_fail_hint")"
        return 1
    fi

    # 测试到域名 443 端口的 TCP 连接
    _test "$(_i18n ".${CUR_FILE}.tcp.connect_check"): ${domain}:443"
    if ! test_tcp_connection "$domain" 443; then
        _check_fail "$(_i18n_sub ".${CUR_FILE}.tcp.connect_fail" '${domain}' "${domain}")"
        return 1
    fi

    # 获取域名的 TLS 信息
    _test "$(_i18n ".${CUR_FILE}.tls.info"): ${domain}"
    local tls_info=''
    # 注: 必须 `|| true` —— 在 set -Eeuo pipefail 下, openssl 连接失败(或上面 timeout
    #   杀掉它)会让整条管道返回非 0, 赋值语句随即触发 ERR trap 中断整个体检,
    #   下面"取不到 TLS 信息就 _check_fail 提示"的分支**永远走不到**。
    #   接住后, 失败表现为 tls_info 为空串, 正常落到下方的 _check_fail, 给出可读提示。
    tls_info=$(get_tls_info "$domain" || true)

    # 检查是否支持 TLS 1.3
    if ! echo "$tls_info" | grep -q "TLSv1.3"; then
        _check_fail "$(_i18n ".${CUR_FILE}.tls.error")"
        return 1
    else
        _check_pass "$(_i18n ".${CUR_FILE}.tls.pass")"
    fi

    # 检查是否使用 X25519 密钥交换算法
    if echo "$tls_info" | grep -q "X25519"; then
        _check_pass "$(_i18n ".${CUR_FILE}.tls.key_exchange_pass")"
    else
        _check_fail "$(_i18n ".${CUR_FILE}.tls.key_exchange_warn")$domain"
        return 1
    fi

    # 如果所有检查都通过，则域名安全检查通过
    _check_pass "$(_i18n_sub ".${CUR_FILE}.domain.security_pass" '${domain}' "${domain}")"
    return 0
}

# =============================================================================
# 函数名称: check_dns_resolution
# 功能描述: 检查域名是否解析为当前服务器的 IP 地址。
# 参数:
#   $1: 待检查的域名 (domain)
# 返回值: 0-DNS 解析正确 1-DNS 解析错误 (并打印相应的提示信息到 >&2)
# =============================================================================
function check_dns_resolution() {
    local domain="${1:-}" # 获取域名参数

    # 打印正在检查的信息
    _check_info "$(_i18n ".${CUR_FILE}.dns.check_start")${domain}"

    # 检查域名格式是否有效
    if ! valid_domain "$domain"; then
        _check_fail "$(_i18n ".${CUR_FILE}.domain.format_error")$domain"
        return 1
    fi

    # 测试域名解析
    _test "$(_i18n ".${CUR_FILE}.domain.resolve"): ${domain}"
    if ! dns_resolution "$domain"; then
        _check_fail "$(_i18n ".${CUR_FILE}.dns.resolution_fail")$domain" "$(_i18n ".${CUR_FILE}.dns.resolution_fail_hint")"
        return 1
    fi

    # 如果解析正确，则检查通过
    _check_pass "$(_i18n_sub ".${CUR_FILE}.dns.check_pass" '${domain}' "${domain}")"
    return 0
}

# =============================================================================
# 函数名称: check_xray_config_exists
# 功能描述: 检查指定名称的 Xray 配置文件是否存在。
# 参数:
#   $1: 配置文件名（不含扩展名）(SCRIPT_FILE)
# 返回值: 0-文件存在 1-文件不存在 (并打印相应的提示信息到 >&2)
# =============================================================================
function check_xray_config_exists() {
    local SCRIPT_FILE="${1:-}" # 获取配置文件名参数
    # 构造完整的配置文件路径
    local CONFIG_FILE="${CONFIG_XRAY_DIR}/${SCRIPT_FILE}.json"

    # 打印正在检查的信息
    _check_info "$(_i18n ".${CUR_FILE}.config.check")${CONFIG_FILE}"

    # 检查文件是否存在
    if [[ -f "${CONFIG_FILE}" ]]; then
        _check_pass "$(_i18n ".${CUR_FILE}.config.exist")${CONFIG_FILE}"
        return 0
    else
        _check_fail "$(_i18n ".${CUR_FILE}.config.not_exist")${CONFIG_FILE}" "$(_i18n ".${CUR_FILE}.config.not_exist_hint")"
        return 1
    fi
}

# =============================================================================
# 函数名称: check_xray_version_exists
# 功能描述: 通过访问 GitHub Releases 页面检查指定的 Xray 版本是否存在。
# 参数:
#   $1: Xray 版本号 (version)
# 返回值: 0-版本存在 1-版本不存在 (并打印相应的提示信息到 >&2)
# =============================================================================
function check_xray_version_exists() {
    local version="${1:-}" # 获取版本号参数

    # 打印正在检查的信息
    _check_info "$(_i18n ".${CUR_FILE}.version.check")v${version}"

    # 构造 GitHub Releases 页面的 URL
    # 注: 必须经 _gh_url —— handler.sh 里取版本号的同类请求都走它, 而这里曾是裸域名。
    #     国内网络下 github.com 常被阻断, 一旦取不到 200 就会被下文判成"版本不存在",
    #     于是出现"安装能通(那边有加速)、版本校验必失败"的怪象。
    local version_url
    version_url="$(_gh_url "https://github.com/XTLS/Xray-core/releases/tag/v${version#*v}")"

    # 使用 curl 获取页面的 HTTP 状态码
    local status_code
    status_code=$(curl -L --connect-timeout 10 --max-time 20 --retry 2 -o /dev/null -s -w '%{http_code}\n' "$version_url" || true)

    # 网络不可达要单独识别: curl 连不上时 -w 打出的是 000, 与"版本真的不存在"(404)
    # 是两回事。混为一谈会把网络故障误报成"你填的版本号不对", 让用户白改一通配置。
    if [[ "$status_code" == "000" || -z "$status_code" ]]; then
        _check_fail "$(_i18n ".${CUR_FILE}.version.network_error")"
        return 1
    fi

    # 检查状态码是否为 200 (OK)
    if [[ "$status_code" == "200" ]]; then
        _check_pass "$(_i18n ".${CUR_FILE}.version.exist")${version}"
        return 0
    else
        _check_fail "$(_i18n ".${CUR_FILE}.version.not_exist")${version}"
        return 1
    fi
}

# =============================================================================
# 函数名称: validate_email
# 功能描述: 验证邮箱地址格式是否正确。
# 参数:
#   $1: 待验证的邮箱地址 (email)
# 返回值: 0-格式正确 1-格式错误或为空 (并打印相应的提示信息到 >&2)
# =============================================================================
function validate_email() {
    local email="${1:-}" # 获取邮箱地址参数

    # 打印正在检查的信息
    _check_info "$(_i18n ".${CUR_FILE}.email.check")${email}"

    # 如果邮箱地址为空，则认为无效
    if [[ -z "${email}" ]]; then
        _check_fail "$(_i18n ".${CUR_FILE}.email.empty")"
        return 1
    fi

    # 使用正则表达式检查邮箱格式
    if [[ "$email" =~ $EMAIL_REGEX ]]; then
        _check_pass "$(_i18n ".${CUR_FILE}.email.valid")$email"
        return 0
    else
        _check_fail "$(_i18n ".${CUR_FILE}.email.format_error")$email"
        return 1
    fi
}

# =============================================================================
# 函数名称: check_proxy_target
# 功能描述: 解析并校验自定义站点的反代目标。
#           支持仅输入端口时自动规范化为 http://127.0.0.1:<port>。
# 参数:
#   $1: 原始反代目标
# 返回值: 0-合法并将规范化结果输出到 stdout；1-非法
# =============================================================================
function check_proxy_target() {
    local raw_target="${1:-}"
    local normalized_target="${raw_target}"
    local scheme=''
    local authority=''
    local host=''
    local port=''

    _check_info "$(_i18n ".${CUR_FILE}.proxy_target.check")${raw_target}"

    if [[ -z "${raw_target}" ]]; then
        _check_fail "$(_i18n ".${CUR_FILE}.proxy_target.empty")"
        return 1
    fi

    if [[ "${raw_target}" =~ ^[0-9]+$ ]]; then
        normalized_target="http://127.0.0.1:${raw_target}"
        _check_info "$(_i18n ".${CUR_FILE}.proxy_target.normalized")${normalized_target}"
    fi

    if [[ "${normalized_target}" =~ [[:space:]] ]]; then
        _check_fail "$(_i18n ".${CUR_FILE}.proxy_target.format_error")${normalized_target}"
        return 1
    fi

    if [[ "${normalized_target}" == *'?'* || "${normalized_target}" == *'#'* ]]; then
        _check_fail "$(_i18n ".${CUR_FILE}.proxy_target.path_error")${normalized_target}"
        return 1
    fi

    if [[ "${normalized_target}" =~ ^https?://[^/]+/ ]]; then
        _check_fail "$(_i18n ".${CUR_FILE}.proxy_target.path_error")${normalized_target}"
        return 1
    fi

    if ! [[ "${normalized_target}" =~ ^(https?)://([^/]+)$ ]]; then
        _check_fail "$(_i18n ".${CUR_FILE}.proxy_target.format_error")${normalized_target}"
        return 1
    fi
    scheme="${BASH_REMATCH[1]}"
    authority="${BASH_REMATCH[2]}"

    if [[ "${scheme}" != 'http' && "${scheme}" != 'https' ]]; then
        _check_fail "$(_i18n ".${CUR_FILE}.proxy_target.scheme_error")${normalized_target}"
        return 1
    fi

    if ! [[ "${authority}" =~ ^([^:]+):([0-9]+)$ ]]; then
        _check_fail "$(_i18n ".${CUR_FILE}.proxy_target.format_error")${normalized_target}"
        return 1
    fi
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"

    if [[ "${host}" != 'localhost' ]] && ! [[ "${host}" =~ ${IPV4_REGEX} ]] && ! valid_domain "${host}"; then
        _check_fail "$(_i18n ".${CUR_FILE}.proxy_target.host_error")${host}"
        return 1
    fi

    check_port "${port}" || return 1
    _check_pass "$(_i18n ".${CUR_FILE}.proxy_target.valid")${normalized_target}"
    echo "${normalized_target}"
    return 0
}

# =============================================================================
# 函数名称: check_custom_site_domain
# 功能描述: 校验自定义站点域名，确保解析到本机且不与现有域名冲突。
# 参数:
#   $1: 待校验域名
#   $2: 编辑场景下可忽略的旧域名
# 返回值: 0-合法 1-非法
# =============================================================================
function check_custom_site_domain() {
    local domain="${1:-}"
    local ignore_domain="${2:-}"
    local primary_domain=''
    local cdn_domain=''

    _check_info "$(_i18n ".${CUR_FILE}.custom_domain.check")${domain}"

    if [[ -z "${domain}" ]]; then
        _check_fail "$(_i18n ".${CUR_FILE}.custom_domain.empty")"
        return 1
    fi

    check_dns_resolution "${domain}" || return 1

    primary_domain="$(jq -r '.nginx.domain' "${SCRIPT_CONFIG_PATH}")"
    cdn_domain="$(jq -r '.nginx.cdn' "${SCRIPT_CONFIG_PATH}")"

    if [[ -n "${primary_domain}" && "${primary_domain}" != 'null' && "${domain}" == "${primary_domain}" && "${domain}" != "${ignore_domain}" ]]; then
        _check_fail "$(_i18n ".${CUR_FILE}.custom_domain.duplicate_domain")${domain}"
        return 1
    fi

    if [[ -n "${cdn_domain}" && "${cdn_domain}" != 'null' && "${domain}" == "${cdn_domain}" && "${domain}" != "${ignore_domain}" ]]; then
        _check_fail "$(_i18n ".${CUR_FILE}.custom_domain.duplicate_cdn")${domain}"
        return 1
    fi

    if jq -e --arg domain "${domain}" --arg ignore "${ignore_domain}" '.nginx.custom_sites // [] | any(.domain == $domain and .domain != $ignore)' "${SCRIPT_CONFIG_PATH}" >/dev/null; then
        _check_fail "$(_i18n ".${CUR_FILE}.custom_domain.duplicate_custom")${domain}"
        return 1
    fi

    _check_pass "$(_i18n ".${CUR_FILE}.custom_domain.valid")${domain}"
    return 0
}

# =============================================================================
# 函数名称: check_list_index
# 功能描述: 校验列表索引输入是否合法。
# 参数:
#   $1: 用户输入索引
#   $2: 列表总数
# 返回值: 0-合法 1-非法
# =============================================================================
function check_list_index() {
    local index="${1:-}"
    local total="${2:-0}"

    _check_info "$(_i18n ".${CUR_FILE}.list_index.check")${index}"

    if ! [[ "${total}" =~ ^[0-9]+$ ]] || ((total < 1)); then
        _check_fail "$(_i18n ".${CUR_FILE}.list_index.empty_list")"
        return 1
    fi

    if ! [[ "${index}" =~ ^[0-9]+$ ]]; then
        _check_fail "$(_i18n ".${CUR_FILE}.list_index.format_error")${index}"
        return 1
    fi

    if ((index < 1 || index > total)); then
        _check_fail "$(_i18n_sub ".${CUR_FILE}.list_index.range_error" '${total}' "${total}")${index}"
        return 1
    fi

    _check_pass "$(_i18n ".${CUR_FILE}.list_index.valid")${index}"
    return 0
}

# =============================================================================
# 函数名称: check_net_status
# 功能描述: 只读体检内核网络与 BBR 状态, 打印可读报告。
#           与 handler_bbr 的分工是"看改分离": handler_bbr 负责写入并持久化,
#           本函数只负责观察 —— 不加载模块、不写任何文件、不改任何参数。
# 检查项:
#   1. 内核版本, 以及 tcp_bbr 模块当前是否已加载;
#   2. 当前拥塞控制算法与默认 qdisc 是否已是 bbr / fq;
#   3. 内核实际可用的算法列表 (用于区分"内核不支持"与"参数没写对");
#   4. 持久化文件是否存在 —— 区分"当前生效"与"重启后仍生效";
#   5. 实时连接采样: 从 ss -tin 看已建立连接是否真的走 BBR。静态读 sysctl 只能
#      证明"参数写对了", 证明不了"流量真走了 BBR", 这一项补的正是这个盲区。
# 实现注意: 全程不用"管道 + grep -q / head" —— 项目 set -o pipefail 下, grep -q
#   一命中就退出会让上游收 SIGPIPE(141), 于是 `lsmod | grep -q tcp_bbr` 会被
#   误判成"模块未加载"。故一律先整段落变量, 再用 bash 内建比对与 [[ =~ ]] 解析。
# 参数: 无
# 返回值: 0-拥塞控制/qdisc/持久化三项均达标 1-存在未达标项
# =============================================================================
function check_net_status() {
    # 所有采集/渲染共享变量集中声明, 供 _net_collect / _net_render 经 bash 动态作用域读写
    local bbr_module_file='/etc/modules-load.d/xray-script-personal-use-only-bbr.conf'
    local bbr_sysctl_file='/etc/sysctl.d/99-xray-script-personal-use-only-bbr.conf'
    local net_tune_file='/etc/sysctl.d/99-xray-script-personal-use-only-net.conf'

    local kver='' mods='' mod_state='no' cc='' qdisc='' avail=''
    local raw='' line='' first='' hit_sample='' miss_sample='' detail=''
    local total=0 hits=0 walked=0
    local persist_mod=0 persist_sysctl=0 persist_tune=0
    local ok_persist=0 rc=0

    _net_collect
    _net_render
    return "${rc}"
}

# =============================================================================
# 函数名称: _net_collect
# 功能描述: 采集网络优化状态 (只读), 结果写入 check_net_status 的共享 local 变量。
#           分为: 内核版本 / BBR 模块状态 / 拥塞控制 / qdisc / 可用算法 /
#           持久化标记 / 实时 BBR 采样。子函数不重复声明共享变量, 经由动态作用域回写父函数。
# =============================================================================
function _net_collect() {
    kver="$(uname -r 2>/dev/null || true)"
    [[ -z "${kver}" ]] && kver='?'

    if cmd_exists 'lsmod'; then
        # 整段落变量再比对, 不用 `lsmod | grep -q` (见函数头 SIGPIPE 说明)
        mods="$(lsmod 2>/dev/null || true)"
        [[ "${mods}" == *'tcp_bbr'* ]] && mod_state='yes'
    else
        mod_state='unknown'
    fi

    if cmd_exists 'sysctl'; then
        cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
        qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
        avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    fi

    [[ -e "${bbr_module_file}" ]] && persist_mod=1
    [[ -e "${bbr_sysctl_file}" ]] && persist_sysctl=1
    [[ -e "${net_tune_file}" ]] && persist_tune=1
    # 持久化达标 = 模块自加载 + 内核参数两份都落盘
    [[ "${persist_mod}" -eq 1 && "${persist_sysctl}" -eq 1 ]] && ok_persist=1

    # 实时连接采样
    # 用 sed -n '1,Np' 而不是 head: head 读够行数即退出, 上游 ss 收 SIGPIPE(141),
    # 在 pipefail 下整条管道被判失败 (head 是本项目已登记的坑)。
    if cmd_exists 'ss'; then
        raw="$(ss -tin state established 2>/dev/null | sed -n '1,30p' || true)"
        # here-string 遍历而非管道 —— 管道会让循环跑在子 shell 里, 计数全丢
        while IFS= read -r line; do
            [[ -n "${line}" ]] || continue
            if [[ "${line}" == ESTAB* ]]; then
                total=$((total + 1))
                continue
            fi
            # 只有信息行带前导空白 (表头行与 ESTAB 行顶格)
            [[ "${line}" != ' '* && "${line}" != $'\t'* ]] && continue
            walked=$((walked + 1))
            ((walked <= 24)) || continue
            first=''
            [[ "${line}" =~ ^[[:space:]]*([^[:space:]]+) ]] && first="${BASH_REMATCH[1]}"
            [[ -n "${first}" ]] || continue
            # 信息行首个字段即该连接的拥塞控制算法名
            if [[ "${first}" == 'bbr' ]]; then
                hits=$((hits + 1))
                [[ -z "${hit_sample}" ]] && hit_sample="${line}"
            elif [[ -z "${miss_sample}" ]]; then
                miss_sample="${line}"
            fi
        done <<<"${raw}"
    fi

    # 从命中样例里挑几个能直接说明"真在走 BBR"的字段
    if [[ -n "${hit_sample}" ]]; then
        [[ "${hit_sample}" =~ pacing_gain:([0-9.]+) ]] && detail="${detail} pacing_gain=${BASH_REMATCH[1]}"
        [[ "${hit_sample}" =~ (cwnd:[0-9]+) ]] && detail="${detail} ${BASH_REMATCH[1]}"
        [[ "${hit_sample}" =~ (rtt:[0-9.]+/[0-9.]+) ]] && detail="${detail} ${BASH_REMATCH[1]}"
    fi
}

# =============================================================================
# 函数名称: _net_render
# 功能描述: 渲染网络优化状态报告 (写 >&2), 并据 cc/qdisc/持久化 计算退出码 rc。
#           仅读取共享变量; rc 写回父函数共享 local (不在此处声明 local rc)。
# =============================================================================
function _net_render() {
    local txt_mod='' txt_cc='' txt_qdisc='' txt_avail=''

    printf '\n%s\n' '======================================================' >&2
    printf '%s%s%s\n' "${GREEN}" "$(_i18n ".${CUR_FILE}.net_status.title")" "${NC}" >&2
    printf '%s\n' '======================================================' >&2

    case "${mod_state}" in
    yes) txt_mod="${GREEN}$(_i18n ".${CUR_FILE}.net_status.mod_yes")${NC}" ;;
    no) txt_mod="${RED}$(_i18n ".${CUR_FILE}.net_status.mod_no")${NC}" ;;
    *) txt_mod="${YELLOW}$(_i18n ".${CUR_FILE}.net_status.mod_unknown")${NC}" ;;
    esac

    if [[ "${cc}" == 'bbr' ]]; then
        txt_cc="${GREEN}${cc}${NC} ($(_i18n ".${CUR_FILE}.net_status.cc_yes"))"
    else
        txt_cc="${RED}${cc:-?}${NC} ($(_i18n ".${CUR_FILE}.net_status.cc_no"))"
    fi

    if [[ "${qdisc}" == 'fq' ]]; then
        txt_qdisc="${GREEN}${qdisc}${NC} ($(_i18n ".${CUR_FILE}.net_status.qdisc_yes"))"
    else
        txt_qdisc="${RED}${qdisc:-?}${NC} ($(_i18n ".${CUR_FILE}.net_status.qdisc_no"))"
    fi

    if [[ -n "${avail}" ]]; then
        txt_avail="${avail}"
    else
        txt_avail="${YELLOW}$(_i18n ".${CUR_FILE}.net_status.unsupported_unknown")${NC}"
    fi

    printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.net_status.kernel_label")" "${kver}" >&2
    printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.net_status.mod_label")" "${txt_mod}" >&2
    printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.net_status.cc_label")" "${txt_cc}" >&2
    printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.net_status.qdisc_label")" "${txt_qdisc}" >&2
    printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.net_status.avail_label")" "${txt_avail}" >&2

    printf '\n  %s\n' "$(_i18n ".${CUR_FILE}.net_status.persist_title")" >&2
    if [[ "${persist_mod}" -eq 1 ]]; then
        printf '    %s\n' "${GREEN}$(_i18n ".${CUR_FILE}.net_status.persist_mod_yes")${NC}" >&2
    else
        printf '    %s\n' "${RED}$(_i18n ".${CUR_FILE}.net_status.persist_mod_no")${NC}" >&2
    fi
    if [[ "${persist_sysctl}" -eq 1 ]]; then
        printf '    %s\n' "${GREEN}$(_i18n ".${CUR_FILE}.net_status.persist_sysctl_yes")${NC}" >&2
    else
        printf '    %s\n' "${RED}$(_i18n ".${CUR_FILE}.net_status.persist_sysctl_no")${NC}" >&2
    fi
    if [[ "${persist_tune}" -eq 1 ]]; then
        printf '    %s\n' "${GREEN}$(_i18n ".${CUR_FILE}.net_status.persist_tune_yes")${NC}" >&2
    else
        printf '    %s\n' "${YELLOW}$(_i18n ".${CUR_FILE}.net_status.persist_tune_no")${NC}" >&2
    fi

    printf '\n  %s\n' "$(_i18n ".${CUR_FILE}.net_status.live_title")" >&2
    if ! cmd_exists 'ss'; then
        printf '    %s\n' "${YELLOW}$(_i18n ".${CUR_FILE}.net_status.live_no_ss")${NC}" >&2
    elif [[ "${total}" -eq 0 ]]; then
        printf '    %s\n' "${YELLOW}$(_i18n ".${CUR_FILE}.net_status.live_none")${NC}" >&2
    else
        printf '    %s%s/%s\n' "$(_i18n ".${CUR_FILE}.net_status.live_ratio")" "${hits}" "${total}" >&2
        if [[ "${hits}" -gt 0 ]]; then
            printf '    %s%s%s%s\n' "${GREEN}" "$(_i18n ".${CUR_FILE}.net_status.live_hit")" \
                "${detail}" "${NC}" >&2
        else
            printf '    %s%s%s\n' "${RED}" "$(_i18n ".${CUR_FILE}.net_status.live_miss")" "${NC}" >&2
        fi
    fi

    printf '\n' >&2
    if [[ "${cc}" == 'bbr' && "${qdisc}" == 'fq' ]]; then
        if [[ "${ok_persist}" -eq 1 ]]; then
            printf '%s%s%s\n' "${GREEN}" "$(_i18n ".${CUR_FILE}.net_status.done_ok")" "${NC}" >&2
        else
            rc=1
            printf '%s%s%s\n' "${YELLOW}" "$(_i18n ".${CUR_FILE}.net_status.done_no_persist")" "${NC}" >&2
        fi
    else
        rc=1
        printf '%s%s%s\n' "${RED}" "$(_i18n ".${CUR_FILE}.net_status.done_bad")" "${NC}" >&2
    fi
    printf '\n' >&2
}

# =============================================================================
# 函数名称: check_ipv6_status
# 功能描述: 只读检测主机 IPv6 栈状态 (CLI: --ipv6-status)。
#           与 check_net_status 同一取舍 —— 只采集与渲染, 不做任何写操作。
#
#           采集结果写入 _IPV6_* 全局变量, 而非经动态作用域回写父函数的 local:
#           体检的内核网络分区也要复用同一份采集, 且只需其中几项, 若走动态作用域,
#           _health_kernel 就得为十几个共享变量各写一行 local。这与 _common.sh 里
#           _PUBLIC_IPV4 / _PUBLIC_IP_PROBED 的缓存范式一致。
#
#           判定分档 (_IPV6_MODE):
#             grub       内核命令行 ipv6.disable=1 —— GRUB 级硬禁用, sysctl 改不回来
#             no_stack   内核无 IPv6 栈 (/proc/sys/net/ipv6 不存在)
#             off        net.ipv6.conf.all.disable_ipv6=1, 协议栈关闭
#             soft_off   本项目软禁用: all=0 (栈仍在, nginx 的 [::] 仍能 bind),
#                        但 default=1 且非 lo 接口已无 global 地址
#             no_addr    栈启用但没有任何 global 地址
#             partial    **半残**: 有 global 地址, 但无默认路由 / 出站不通
#             ok         栈启用 + 有 global 地址 + 有默认路由 + (已探测)能出网
#             unknown    读不到内核开关 (无 sysctl 或无权限)
#
#           为什么必须单独判"半残": IPv6 半残时 glibc 的 getaddrinfo 照样返回
#           AAAA, 客户端优先连 IPv6 然后超时 —— 表现为"某些网站莫名变慢/失败"
#           而 v4 侧一切正常。这正是用户想禁用 IPv6 最常见的动机, 也是本命令
#           最该一眼看出的结论; 笼统报一句"IPv6 已启用"等于没说。
#
#           另有两项联动检查 (回答"禁用会不会打爆别的服务"):
#             - nginx 配置里是否有 listen [::] —— 本项目 nginx 资产 (redirect.conf /
#               stream.conf) 与生成的站点 conf 都写了 [::]:80/443。硬禁用 IPv6 后
#               这些 bind 会失败, 而 `nginx -t` 只查语法仍会通过, 于是 reload/重启
#               才崩, 机器重启后 nginx 直接起不来。
#             - IPv6 socket 能否真的创建 (python3 实测 AF_INET6; 无 python3 时退化
#               为按 all.disable_ipv6 推断**并标注来源**) —— 这是"软禁用会不会打断
#               nginx"的唯一可靠依据, 不靠对内核语义的假设。
# 参数:
#   $1: 可选 '--no-probe' —— 跳过出站连通性探测 (体检用; 探测含 curl, 最长约 45s)
# 返回值: 0-状态明确 (正常 / 已禁用) 1-半残 / 无地址 / 未知
# =============================================================================
function check_ipv6_status() {
    local no_probe=0
    if [[ "${1:-}" == '--no-probe' ]]; then
        no_probe=1
    fi
    _ipv6_collect "${no_probe}"
    _ipv6_render
    return "${_IPV6_RC}"
}

# =============================================================================
# 函数名称: _ipv6_collect
# 功能描述: 采集 IPv6 状态 (只读), 结果写入 _IPV6_* 全局变量。
#           每次调用都重新采集 (不像 _resolve_public_ips 那样缓存): 状态会被
#           禁用/启用操作立即改变, 缓存只会给出过期结论。
# 参数:
#   $1: 1 = 跳过出站探测, 0/空 = 探测
# 返回值: 无 (结论写入 _IPV6_MODE / _IPV6_RC)
# =============================================================================
function _ipv6_collect() {
    local no_probe="${1:-0}"
    local persist_file='/etc/sysctl.d/99-xray-script-personal-use-only-ipv6.conf'
    local ngx_confs=('/usr/local/nginx/conf' '/etc/nginx')
    local dir='' tmp=''

    # 全部显式初始化 —— set -u 下不能留空洞, 且本函数会被重复调用
    _IPV6_MODE='unknown'
    _IPV6_GRUB_OFF=0
    _IPV6_STACK=0
    _IPV6_ALL=''
    _IPV6_DEF=''
    _IPV6_ADDRS=''
    _IPV6_DEFROUTE=''
    _IPV6_PUB=''
    _IPV6_PROBED=0
    _IPV6_PERSIST=0
    _IPV6_PERSIST_MODE=''
    _IPV6_SOCK='unknown'
    _IPV6_SOCK_SRC=''
    _IPV6_NGINX6=0
    _IPV6_OTHERS=0
    _IPV6_RC=1

    # GRUB 级硬禁用: 命令行带 ipv6.disable=1 时整个 IPv6 栈不会初始化,
    # 此时写任何 net.ipv6.* 都是无效操作 (sysctl 里根本没这些键)
    tmp="$(cat /proc/cmdline 2>/dev/null || true)"
    if [[ "${tmp}" == *'ipv6.disable=1'* ]]; then
        _IPV6_GRUB_OFF=1
    fi

    if [[ -d '/proc/sys/net/ipv6' ]]; then
        _IPV6_STACK=1
    fi

    if cmd_exists 'sysctl'; then
        _IPV6_ALL="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || true)"
        _IPV6_DEF="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || true)"
    fi

    # 非 lo 接口的 global 地址。lo 的 ::1 是 scope host, 天然被 scope 过滤排除 ——
    # 这正是"软禁用"的判据: 外网侧地址没了, 回环仍在。
    # 用 sed -n '1,Np' 而非 head: head 读够行数即退出, 上游 ip 收 SIGPIPE(141),
    # pipefail 下整条管道被判失败 (本项目已登记的坑)。
    tmp="$(ip -6 addr show scope global 2>/dev/null || true)"
    _IPV6_ADDRS="$(printf '%s\n' "${tmp}" | sed -n 's/.*inet6 \([0-9A-Fa-f:]*\)\/.*/\1/p' | sed -n '1,3p' || true)"

    _IPV6_DEFROUTE="$(ip -6 route show default 2>/dev/null | sed -n '1,2p' || true)"

    # 本项目写入的持久化文件 + 从内容反推模式 (重启后靠它恢复, 见 handler_ipv6)
    if [[ -e "${persist_file}" ]]; then
        _IPV6_PERSIST=1
        tmp="$(cat "${persist_file}" 2>/dev/null || true)"
        if [[ "${tmp}" == *'all.disable_ipv6 = 1'* ]]; then
            _IPV6_PERSIST_MODE='hard'
        elif [[ "${tmp}" == *'default.disable_ipv6 = 1'* ]]; then
            _IPV6_PERSIST_MODE='soft'
        else
            _IPV6_PERSIST_MODE='enable'
        fi
    fi

    # 除本项目外还有谁在写 disable_ipv6: 用户手改 / 云镜像预置的文件会与本脚本
    # 互相覆盖 (sysctl.d 按文件名排序应用, 99- 能压住多数; 但 /etc/sysctl.conf
    # 最后读, 会反过来压住我们)。只报数量, 不猜谁赢。
    tmp="$(grep -rl 'disable_ipv6' '/etc/sysctl.d' '/etc/sysctl.conf' 2>/dev/null || true)"
    if [[ -n "${tmp}" ]]; then
        _IPV6_OTHERS="$(printf '%s\n' "${tmp}" | grep -vc '99-xray-script-personal-use-only-ipv6' || true)"
        [[ "${_IPV6_OTHERS}" =~ ^[0-9]+$ ]] || _IPV6_OTHERS=0
    fi

    # nginx 是否在监听 IPv6 通配地址
    for dir in "${ngx_confs[@]}"; do
        [[ -d "${dir}" ]] || continue
        tmp="$(grep -rl 'listen[[:space:]]*\[::\]' "${dir}" 2>/dev/null || true)"
        if [[ -n "${tmp}" ]]; then
            _IPV6_NGINX6=1
            break
        fi
    done
    # 提示: 这里刻意只扫配置文件, 不跑 `nginx -T` —— 后者要求 nginx 可执行且
    # 配置无语法错, 在"就是要排查网络问题"的场景下反而不该成为前置依赖。

    # IPv6 监听能力: 复用 _common.sh 的实测 (与 handler 启停前的风险提示同源)。
    # 判据与取舍 (为何测 bind(::) 而非仅 socket()、为何无 python3 时不做推断)
    # 见 _ipv6_listen_probe 的函数头。
    tmp="$(_ipv6_listen_probe)"
    case "${tmp}" in
    ok | no)
        _IPV6_SOCK="${tmp}"
        _IPV6_SOCK_SRC='probe'
        ;;
    *)
        _IPV6_SOCK='unknown'
        _IPV6_SOCK_SRC='no_probe'
        ;;
    esac

    if [[ "${no_probe}" != '1' ]]; then
        # 直调以复用进程内缓存; 不能写 < <(_resolve_public_ips): 进程替换同样是
        # 子 shell, 缓存写不回当前 shell (见该函数注释)
        _resolve_public_ips >/dev/null
        _IPV6_PUB="${_PUBLIC_IPV6}"
        _IPV6_PROBED=1
    fi

    # ---- 分档 (顺序即优先级) ----
    if [[ "${_IPV6_GRUB_OFF}" -eq 1 ]]; then
        _IPV6_MODE='grub'
    elif [[ "${_IPV6_STACK}" -eq 0 ]]; then
        _IPV6_MODE='no_stack'
    elif [[ "${_IPV6_ALL}" == '1' ]]; then
        _IPV6_MODE='off'
    elif [[ "${_IPV6_ALL}" != '0' ]]; then
        _IPV6_MODE='unknown'
    elif [[ -z "${_IPV6_ADDRS}" && "${_IPV6_DEF}" == '1' ]]; then
        _IPV6_MODE='soft_off'
    elif [[ -z "${_IPV6_ADDRS}" ]]; then
        _IPV6_MODE='no_addr'
    elif [[ -z "${_IPV6_DEFROUTE}" ]]; then
        _IPV6_MODE='partial'
    elif [[ "${_IPV6_PROBED}" -eq 1 && -z "${_IPV6_PUB}" ]]; then
        _IPV6_MODE='partial'
    else
        _IPV6_MODE='ok'
    fi

    # "正常"与"已明确禁用"都算健康结论; 半残/无地址/未知才返回 1
    case "${_IPV6_MODE}" in
    ok | off | soft_off | grub | no_stack) _IPV6_RC=0 ;;
    *) _IPV6_RC=1 ;;
    esac
}

# =============================================================================
# 函数名称: _ipv6_render
# 功能描述: 渲染 _ipv6_collect 的采集结果为只读报告 (样式与 _net_render 一致)。
# 参数: 无
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function _ipv6_render() {
    local txt_mode='' txt_stack='' txt_switch='' txt_addr='' txt_route='' txt_pub=''
    local txt_sock='' txt_persist='' txt_nginx=''

    printf '\n%s\n' '======================================================' >&2
    printf '%s%s%s\n' "${GREEN}" "$(_i18n ".${CUR_FILE}.ipv6.title")" "${NC}" >&2
    printf '%s\n' '======================================================' >&2

    case "${_IPV6_MODE}" in
    ok) txt_mode="${GREEN}$(_i18n ".${CUR_FILE}.ipv6.mode_ok")${NC}" ;;
    partial) txt_mode="${YELLOW}$(_i18n ".${CUR_FILE}.ipv6.mode_partial")${NC}" ;;
    off) txt_mode="${YELLOW}$(_i18n ".${CUR_FILE}.ipv6.mode_off")${NC}" ;;
    soft_off) txt_mode="${YELLOW}$(_i18n ".${CUR_FILE}.ipv6.mode_soft_off")${NC}" ;;
    grub) txt_mode="${YELLOW}$(_i18n ".${CUR_FILE}.ipv6.mode_grub")${NC}" ;;
    no_stack) txt_mode="${YELLOW}$(_i18n ".${CUR_FILE}.ipv6.mode_no_stack")${NC}" ;;
    no_addr) txt_mode="${YELLOW}$(_i18n ".${CUR_FILE}.ipv6.mode_no_addr")${NC}" ;;
    *) txt_mode="${YELLOW}$(_i18n ".${CUR_FILE}.health.unknown")${NC}" ;;
    esac
    printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.ipv6.mode_label")" "${txt_mode}" >&2

    # 内核支持 (有无 IPv6 协议栈) 与内核开关 (disable_ipv6) 分开报 —— 二者独立:
    # 无协议栈时读不到开关; 有协议栈而开关为 1 时, 接口上不会有任何 IPv6 地址。
    if [[ "${_IPV6_STACK}" -eq 1 ]]; then
        txt_stack="${GREEN}$(_i18n ".${CUR_FILE}.ipv6.present")${NC}"
    else
        txt_stack="${RED}$(_i18n ".${CUR_FILE}.ipv6.absent")${NC}"
    fi
    printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.ipv6.stack_label")" "${txt_stack}" >&2

    if [[ -z "${_IPV6_ALL}" ]]; then
        txt_switch="${YELLOW}$(_i18n ".${CUR_FILE}.health.unknown")${NC}"
    elif [[ "${_IPV6_ALL}" == '1' ]]; then
        txt_switch="${YELLOW}$(_i18n ".${CUR_FILE}.ipv6.switch_off")${NC}"
    else
        txt_switch="${GREEN}$(_i18n ".${CUR_FILE}.ipv6.switch_on")${NC}"
    fi
    txt_switch="${txt_switch} (all=${_IPV6_ALL:-?}, default=${_IPV6_DEF:-?})"
    printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.ipv6.switch_label")" "${txt_switch}" >&2

    if [[ "${_IPV6_GRUB_OFF}" -eq 1 ]]; then
        printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.ipv6.cmdline_label")" \
            "${RED}$(_i18n ".${CUR_FILE}.ipv6.cmdline_off")${NC}" >&2
    else
        printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.ipv6.cmdline_label")" \
            "${GREEN}$(_i18n ".${CUR_FILE}.ipv6.cmdline_ok")${NC}" >&2
    fi

    # global 地址
    if [[ -n "${_IPV6_ADDRS}" ]]; then
        txt_addr="${GREEN}$(printf '%s' "${_IPV6_ADDRS}" | tr '\n' ' ')${NC}"
    else
        txt_addr="${YELLOW}$(_i18n ".${CUR_FILE}.ipv6.addr_none")${NC}"
    fi
    printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.ipv6.addr_label")" "${txt_addr}" >&2

    # 默认路由
    if [[ -n "${_IPV6_DEFROUTE}" ]]; then
        txt_route="${GREEN}$(printf '%s' "${_IPV6_DEFROUTE}" | tr '\n' ' ')${NC}"
    else
        txt_route="${YELLOW}$(_i18n ".${CUR_FILE}.ipv6.route_none")${NC}"
    fi
    printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.ipv6.route_label")" "${txt_route}" >&2

    # 出站连通性 (仅 --ipv6-status 探测)
    if [[ "${_IPV6_PROBED}" -eq 0 ]]; then
        txt_pub="${YELLOW}$(_i18n ".${CUR_FILE}.ipv6.pub_skipped")${NC}"
    elif [[ -n "${_IPV6_PUB}" ]]; then
        txt_pub="${GREEN}${_IPV6_PUB}${NC}"
    else
        txt_pub="${YELLOW}$(_i18n ".${CUR_FILE}.ipv6.pub_fail")${NC}"
    fi
    printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.ipv6.pub_label")" "${txt_pub}" >&2

    # IPv6 socket 可用性 (实测 / 推断)
    case "${_IPV6_SOCK}" in
    ok) txt_sock="${GREEN}$(_i18n ".${CUR_FILE}.ipv6.sock_ok")${NC}" ;;
    no) txt_sock="${YELLOW}$(_i18n ".${CUR_FILE}.ipv6.sock_no")${NC}" ;;
    *) txt_sock="${YELLOW}$(_i18n ".${CUR_FILE}.health.unknown")${NC}" ;;
    esac
    case "${_IPV6_SOCK_SRC}" in
    probe) txt_sock="${txt_sock} $(_i18n ".${CUR_FILE}.ipv6.src_probe")" ;;
    no_probe) txt_sock="${txt_sock} $(_i18n ".${CUR_FILE}.ipv6.src_no_probe")" ;;
    esac
    printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.ipv6.sock_label")" "${txt_sock}" >&2

    # 本项目持久化文件
    if [[ "${_IPV6_PERSIST}" -eq 1 ]]; then
        txt_persist="${GREEN}$(_i18n ".${CUR_FILE}.ipv6.persist_yes")${NC}"
        case "${_IPV6_PERSIST_MODE}" in
        soft) txt_persist="${txt_persist} ($(_i18n ".${CUR_FILE}.ipv6.persist_mode_soft"))" ;;
        hard) txt_persist="${txt_persist} ($(_i18n ".${CUR_FILE}.ipv6.persist_mode_hard"))" ;;
        enable) txt_persist="${txt_persist} ($(_i18n ".${CUR_FILE}.ipv6.persist_mode_enable"))" ;;
        esac
    else
        txt_persist="${YELLOW}$(_i18n ".${CUR_FILE}.ipv6.persist_no")${NC}"
    fi
    printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.ipv6.persist_label")" "${txt_persist}" >&2

    # nginx 联动风险
    if [[ "${_IPV6_NGINX6}" -eq 1 ]]; then
        txt_nginx="${YELLOW}$(_i18n ".${CUR_FILE}.ipv6.nginx_yes")${NC}"
    else
        txt_nginx="${GREEN}$(_i18n ".${CUR_FILE}.ipv6.nginx_no")${NC}"
    fi
    printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.ipv6.nginx_label")" "${txt_nginx}" >&2

    if [[ "${_IPV6_OTHERS}" -gt 0 ]]; then
        printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.ipv6.others_label")" \
            "${YELLOW}${_IPV6_OTHERS}${NC}" >&2
    fi

    printf '\n' >&2
    case "${_IPV6_MODE}" in
    ok)
        printf '%s%s%s\n' "${GREEN}" "$(_i18n ".${CUR_FILE}.ipv6.done_ok")" "${NC}" >&2
        ;;
    off | soft_off)
        printf '%s%s%s\n' "${YELLOW}" "$(_i18n ".${CUR_FILE}.ipv6.done_off")" "${NC}" >&2
        ;;
    partial)
        printf '%s%s%s\n' "${YELLOW}" "$(_i18n ".${CUR_FILE}.ipv6.done_partial")" "${NC}" >&2
        ;;
    *)
        printf '%s%s%s\n' "${YELLOW}" "$(_i18n ".${CUR_FILE}.ipv6.done_other")" "${NC}" >&2
        ;;
    esac
    printf '\n' >&2
}

# =============================================================================
# 函数名称: _health_item
# 功能描述: 记录并打印一条体检结论, 并把级别累积到 _HEALTH_ITEMS 供末尾统计。
#           用数组而非"多个全局计数器"的原因: 计数器要在 30+ 处自增, 而本函数
#           是唯一自增点; 数组只需 append, 且天然规避"命令替换里改全局不回传"
#           这一本项目已登记过的坑 (见 tool/backup.sh 的 _make_stage 注释)。
# 参数:
#   $1: 级别 (pass|warn|fail|skip) —— skip 只打印、不计数
#   $2: 结论文本 (由调用方拼接好, 本函数不做 i18n 拼接)
# 返回值: 无 (累计结果写入全局数组 _HEALTH_ITEMS)
# =============================================================================
function _health_item() {
    local level="${1:-pass}"
    local text="${2:-}"
    # skip 表示"本机不适用该检查项", 既不算通过也不算失败, 避免污染结论
    if [[ "${level}" == 'skip' ]]; then
        printf '  %s%s%s %s\n' "${YELLOW}" "$(_i18n ".${CUR_FILE}.health.tag_skip")" "${NC}" "${text}" >&2
        return 0
    fi
    _HEALTH_ITEMS+=("${level}|${text}")
    case "${level}" in
    pass) printf '  %s%s%s %s\n' "${GREEN}" "$(_i18n ".${CUR_FILE}.health.tag_pass")" "${NC}" "${text}" >&2 ;;
    warn) printf '  %s%s%s %s\n' "${YELLOW}" "$(_i18n ".${CUR_FILE}.health.tag_warn")" "${NC}" "${text}" >&2 ;;
    *) printf '  %s%s%s %s\n' "${RED}" "$(_i18n ".${CUR_FILE}.health.tag_fail")" "${NC}" "${text}" >&2 ;;
    esac
    return 0
}

# =============================================================================
# 函数名称: _health_section
# 功能描述: 打印体检报告的分区标题。
# 参数:
#   $1: 分区名 (由调用方取 i18n 文案)
# 返回值: 无
# =============================================================================
function _health_section() {
    printf '\n%s%s%s\n' "${GREEN}" "${1:-}" "${NC}" >&2
    return 0
}

# =============================================================================
# 函数名称: _human_size
# 功能描述: 把字节数折算成便于阅读的 K/M/G 形式。
# 参数:
#   $1: 字节数 (非纯数字时返回 '?')
# 返回值: 通过 stdout 返回折算结果 (纯函数, 可安全用于命令替换)
# 实现注意: 一律用 10# 前缀强制十进制 —— (( )) 会把 0755 这类值当八进制解析。
# =============================================================================
function _human_size() {
    local bytes="${1:-}"
    local out=''
    if [[ "${bytes}" =~ ^[0-9]+$ ]]; then
        if ((10#${bytes} >= 1073741824)); then
            out="$(((10#${bytes}) / 1073741824))G"
        elif ((10#${bytes} >= 1048576)); then
            out="$(((10#${bytes}) / 1048576))M"
        elif ((10#${bytes} >= 1024)); then
            out="$(((10#${bytes}) / 1024))K"
        else
            out="${bytes}B"
        fi
    else
        out='?'
    fi
    printf '%s' "${out}"
    return 0
}

# =============================================================================
# 函数名称: _file_bytes
# 功能描述: 取文件的字节数 (文件不存在或 stat 不可用时返回空串)。
# 参数:
#   $1: 文件路径
# 返回值: 通过 stdout 返回字节数或空串
# =============================================================================
function _file_bytes() {
    local f="${1:-}"
    local out=''
    if [[ -f "${f}" ]] && cmd_exists 'stat'; then
        out="$(stat -c '%s' "${f}" 2>/dev/null || true)"
    fi
    printf '%s' "${out}"
    return 0
}

# =============================================================================
# 函数名称: _file_mtime
# 功能描述: 取文件的修改时间 (Unix 秒)。文件不存在或 stat 不可用时返回空串 ——
#           调用方必须按"拿不到时间"处理, 不要拿空串去比大小。
# 参数:
#   $1: 文件路径
# 返回值: 通过 stdout 返回秒级时间戳或空串
# =============================================================================
function _file_mtime() {
    local f="${1:-}"
    local out=''
    if [[ -f "${f}" ]] && cmd_exists 'stat'; then
        out="$(stat -c '%Y' "${f}" 2>/dev/null || true)"
    fi
    printf '%s' "${out}"
    return 0
}

# =============================================================================
# 函数名称: check_health_report
# 功能描述: 一键全量体检 —— 只读巡检本机与 xray-script-personal-use-only 的运行状态, 分区输出
#           通过/警告/失败三档结论, 末尾给出合计与总体判断。
#
# 划分依据 (为什么是这八个分区):
#   1. 系统资源 —— 磁盘/内存不足是"服务跑着跑着自己挂"的最常见底层原因;
#   2. 依赖命令 —— install.sh 的依赖清单与脚本实际用到的命令之间容易漂移 (traffic.sh
#      就曾依赖未登记的 column/numfmt, 现已改为纯 awk), 缺必需命令会让核心功能不可用;
#   3. Xray 服务 —— 单元/进程/二进制/配置四件套, 任一缺失都不是"能跑"的状态;
#   4. Nginx 服务 —— 仅 SNI 场景存在, 故用 skip 语义而非硬判失败;
#   5. 端口归属 —— SNI 下 443 归 nginx、直连下归 xray, 归属错了会"看着在跑但连不上";
#   6. TLS 证书 —— 到期是最典型的"某天突然不能用", 必须提前看剩余天数;
#   7. 内核网络 —— 复用 check_net_status 的判据, 但只出结论不重印整段报告;
#   8. 脚本配置与日志 —— config.json 可解析性 + path 一致性 + 日志体积 + 订阅新鲜度。
#
# 严重度口径 (刻意如此, 避免"处处是红灯"导致体检被无视):
#   FAIL = 明确坏了: 必需命令缺失 / xray 单元缺失 / xray 未运行 / 配置无法解析 /
#          证书缺失或过期 / 脚本配置无法解析;
#   WARN = 需要留意但不等于坏: 可选命令缺失 / 443 无监听 / 端口归属与模式不符 /
#          证书 7 天内到期 / BBR 未开 / 持久化文件缺失 / 磁盘内存偏紧 / 日志偏大 /
#          订阅产物早于配置修改时间。
#
# 设计取舍: 全程只读, 且刻意不做外网探测 (DNS/TCP/HTTPS 连通性)。原因是连通性
#   探测耗时且受对端影响, 会让"体检"变成一个不确定要等多久的操作; 该类检查已有
#   check_ip / dns_resolution / test_tcp_connection 供按需调用, 不重复。
# 实现注意: 同 check_net_status —— 不用"管道 + grep -q / head", 避免 pipefail
#   下上游收 SIGPIPE(141) 被误判; 一律整段落变量后用 bash 内建比对。
# 参数: 无
# 返回值: 0-无 FAIL 项 1-存在 FAIL 项
# =============================================================================
function check_health_report() {
    # ---------- 常量与阈值 ----------
    local os_release='/etc/os-release'
    local meminfo='/proc/meminfo'
    local xray_config_path='/usr/local/etc/xray/config.json'
    local xray_bin='/usr/local/bin/xray'
    local ngx_prefix='/usr/local/nginx'
    local ngx_config_dir='/usr/local/nginx/conf'
    local cert_dir='/usr/local/nginx/conf/certs'
    local audit_log="${SCRIPT_CONFIG_DIR}/audit.log"
    local xray_access_log='/var/log/xray/access.log'
    local disk_warn_kb=1048576    # 根分区可用 < 1GB 告警
    local mem_warn_kb=65536       # 可用内存 < 64MB 告警
    local cert_warn_days=7        # 证书剩余 < 7 天告警
    local log_warn_bytes=104857600 # 单个日志 > 100MB 告警

    # ---------- 采集变量 (全部显式初始化, 兼容 set -u) ----------
    local os_name='' kver=''
    local mem_total_kb='' mem_avail_kb='' mem_total_mb='' mem_avail_mb=''
    local disk_line='' disk_total_kb='' disk_avail_kb=''
    local missing_req='' missing_opt='' has_systemctl=0
    local xray_unit_ok=0 xray_active='' xray_ver=''
    local ngx_present=0 ngx_unit_ok=0 ngx_active='' ngx_test_rc=0
    local port443='' port80='' port443_name='' port80_name=''
    local port443udp='' port443udp_name='' fw_udp_rc=0
    local sni_mode=0 cfg_domain='' cfg_cdn='' custom_doms=''
    local cert_file='' cert_days='' cert_raw='' cert_ts='' now_ts=''
    local cc='' qdisc='' persist_mod=0 persist_sysctl=0
    local cfg_ok=0 cfg_ver='' cfg_tag='' cfg_path=''
    local audit_bytes='' xraylog_bytes=''
    local sub_count=0 sub_newest='' cfg_mtime=''
    local out='' line='' tmp='' tmp2=''
    local pass=0 warn=0 fail=0 item='' lvl=''

    # 每次调用都重置累计数组 —— 否则重复调用 (如测试里连续跑) 会叠加历史结论
    _HEALTH_ITEMS=()

    printf '\n%s\n' '======================================================' >&2
    printf '%s%s%s\n' "${GREEN}" "$(_i18n ".${CUR_FILE}.health.title")" "${NC}" >&2
    printf '%s\n' '======================================================' >&2

    # 八个分区逐项巡检 —— 各自封装为 _health_* 子函数, 共享上面声明的采集变量
    # (bash 动态作用域: 父函数 local 对调用的子函数可见), 既拆分巨型单函数、
    # 又不引入参数传递样板。每节只负责往 _HEALTH_ITEMS 追加结论后由 _health_summary 汇总。
    _health_system
    _health_deps
    _health_xray
    _health_nginx
    _health_ports
    _health_certs
    _health_kernel
    _health_script

    _health_summary
    if [[ "${fail}" -gt 0 ]]; then return 1; fi
    return 0
}

# =============================================================================
# 函数名称: _health_system
# 功能描述: 体检分区 1 —— 系统资源 (OS 版本 / 内核 / 可用内存 / 根分区可用空间)。
#   磁盘/内存不足是"服务跑着跑着自己挂"的最常见底层原因。
# 参数: 无 (读写 check_health_report 的采集变量)
# 返回值: 无 (结论通过 _health_item 追加)
# =============================================================================
function _health_system() {
    _health_section "$(_i18n ".${CUR_FILE}.health.sec_system")"

    kver="$(uname -r 2>/dev/null || true)"
    if [[ -r "${os_release}" ]]; then
        out="$(cat "${os_release}" 2>/dev/null || true)"
        # here-string 遍历 (非管道) —— 管道会让循环跑在子 shell 里, 赋值全丢
        while IFS= read -r line; do
            case "${line}" in
            PRETTY_NAME=*)
                os_name="${line#PRETTY_NAME=}"
                os_name="${os_name%\"}"
                os_name="${os_name#\"}"
                break
                ;;
            esac
        done <<<"${out}"
    fi
    [[ -n "${os_name}" ]] || os_name='?'
    _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.os_label")${os_name} / $(_i18n ".${CUR_FILE}.health.kernel_label")${kver:-?}"

    if [[ -r "${meminfo}" ]]; then
        out="$(cat "${meminfo}" 2>/dev/null || true)"
        while IFS= read -r line; do
            case "${line}" in
            MemTotal:*) read -r _ tmp _ <<<"${line}"; mem_total_kb="${tmp}" ;;
            MemAvailable:*) read -r _ tmp _ <<<"${line}"; mem_avail_kb="${tmp}" ;;
            esac
        done <<<"${out}"
    fi
    if [[ "${mem_total_kb}" =~ ^[0-9]+$ && "${mem_avail_kb}" =~ ^[0-9]+$ ]]; then
        mem_total_mb="$((10#${mem_total_kb} / 1024))"
        mem_avail_mb="$((10#${mem_avail_kb} / 1024))"
        if ((10#${mem_avail_kb} < mem_warn_kb)); then
            _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.mem_label")${mem_avail_mb}MB / ${mem_total_mb}MB —— $(_i18n ".${CUR_FILE}.health.mem_low")"
        else
            _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.mem_label")${mem_avail_mb}MB / ${mem_total_mb}MB"
        fi
    else
        _health_item 'skip' "$(_i18n ".${CUR_FILE}.health.mem_label")$(_i18n ".${CUR_FILE}.health.unknown")"
    fi

    # df 用 -Pk (POSIX 输出 + 1K 块), 不依赖 column / numfmt 等非必需命令
    out="$(df -Pk / 2>/dev/null || true)"
    disk_line=''
    if [[ -n "${out}" ]]; then
        # 跳过表头行: 先砍掉第一行, 再取剩下的第一行
        tmp="${out#*$'\n'}"
        disk_line="${tmp%%$'\n'*}"
    fi
    if [[ -n "${disk_line}" ]]; then
        # 重复用 _ 接住不需要的字段 (Filesystem/Used/Capacity/Mounted)
        read -r _ disk_total_kb _ disk_avail_kb _ _ <<<"${disk_line}"
        if [[ "${disk_total_kb}" =~ ^[0-9]+$ && "${disk_avail_kb}" =~ ^[0-9]+$ ]]; then
            if ((10#${disk_avail_kb} < disk_warn_kb)); then
                _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.disk_label")$(_human_size "$((10#${disk_avail_kb} * 1024))") / $(_human_size "$((10#${disk_total_kb} * 1024))") —— $(_i18n ".${CUR_FILE}.health.disk_low")"
            else
                _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.disk_label")$(_human_size "$((10#${disk_avail_kb} * 1024))") / $(_human_size "$((10#${disk_total_kb} * 1024))")"
            fi
        else
            _health_item 'skip' "$(_i18n ".${CUR_FILE}.health.disk_label")$(_i18n ".${CUR_FILE}.health.unknown")"
        fi
    else
        _health_item 'skip' "$(_i18n ".${CUR_FILE}.health.disk_label")$(_i18n ".${CUR_FILE}.health.unknown")"
    fi
}

# =============================================================================
# 函数名称: _health_deps
# 功能描述: 体检分区 2 —— 依赖命令。必需命令缺失会让核心流程直接不可用 (FAIL),
#   可选命令缺失只影响个别功能 (WARN)。
# 参数: 无
# 返回值: 无
# =============================================================================
function _health_deps() {
    _health_section "$(_i18n ".${CUR_FILE}.health.sec_deps")"

    if cmd_exists 'systemctl'; then has_systemctl=1; fi

    # 必需: 缺了脚本核心流程直接不可用
    missing_req=''
    for tmp in jq curl openssl; do
        if ! cmd_exists "${tmp}"; then missing_req="${missing_req} ${tmp}"; fi
    done
    missing_req="${missing_req# }"
    if [[ -n "${missing_req}" ]]; then
        _health_item 'fail' "$(_i18n ".${CUR_FILE}.health.deps_req_label")${missing_req} —— $(_i18n ".${CUR_FILE}.health.deps_req_missing")"
    else
        _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.deps_req_label")$(_i18n ".${CUR_FILE}.health.deps_ok")"
    fi

    # 可选: 缺了只影响个别功能 (stat 影响体积/新鲜度计量, ss 影响端口检查,
    #       qrencode 影响分享链接的终端二维码展示等)
    # 注: numfmt/column 曾是 traffic.sh 的隐式依赖 —— 未登记在 install.sh 清单里,
    #     最小化系统上会静默失败; 现已改为纯 awk 实现, 故从这里移除。
    missing_opt=''
    for tmp in dig ss sysctl lsmod stat unzip tar base64 flock qrencode; do
        if ! cmd_exists "${tmp}"; then missing_opt="${missing_opt} ${tmp}"; fi
    done
    missing_opt="${missing_opt# }"
    if [[ -n "${missing_opt}" ]]; then
        _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.deps_opt_label")${missing_opt} —— $(_i18n ".${CUR_FILE}.health.deps_opt_missing")"
    else
        _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.deps_opt_label")$(_i18n ".${CUR_FILE}.health.deps_ok")"
    fi
}

# =============================================================================
# 函数名称: _health_xray
# 功能描述: 体检分区 3 —— Xray 服务。单元 / 进程 / 二进制 / 配置四件套 + 访问日志目录权限。
# 参数: 无
# 返回值: 无
# =============================================================================
function _health_xray() {
    _health_section "$(_i18n ".${CUR_FILE}.health.sec_xray")"

    if [[ "${has_systemctl}" -eq 1 ]]; then
        if systemctl cat 'xray' >/dev/null 2>&1; then xray_unit_ok=1; fi
        xray_active="$(systemctl is-active 'xray' 2>/dev/null || true)"
    fi
    if [[ "${xray_unit_ok}" -eq 1 ]]; then
        _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.svc_unit_label")$(_i18n ".${CUR_FILE}.health.present")"
    else
        _health_item 'fail' "$(_i18n ".${CUR_FILE}.health.svc_unit_label")$(_i18n ".${CUR_FILE}.health.svc_unit_missing")"
    fi
    if [[ "${xray_active}" == 'active' ]]; then
        _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.svc_active_label")active"
    elif [[ -z "${xray_active}" ]]; then
        _health_item 'fail' "$(_i18n ".${CUR_FILE}.health.svc_active_label")$(_i18n ".${CUR_FILE}.health.unknown")"
    else
        _health_item 'fail' "$(_i18n ".${CUR_FILE}.health.svc_active_label")${xray_active}"
    fi

    # 开机自启 (systemd enable) —— 这才是"重启后自动拉起 xray"的那一项, 与
    # 「内核网络」分区里的 "BBR 持久化" 是两码事, 别混 (二者判据完全不同)。
    # 单元不存在时不判: 上面已出 fail, 这里再叠一条只是噪音。
    local xray_enabled=''
    if [[ "${has_systemctl}" -eq 1 && "${xray_unit_ok}" -eq 1 ]]; then
        # 写成 if 而不是 `[[ ]] && x=1`: 后者条件为假时整条返回 1, 会被 set -e 判失败
        if systemctl -q is-enabled 'xray' >/dev/null 2>&1; then xray_enabled='yes'; fi
        if [[ "${xray_enabled}" == 'yes' ]]; then
            _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.svc_enabled_label")$(_i18n ".${CUR_FILE}.health.present")"
        else
            _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.svc_enabled_label")$(_i18n ".${CUR_FILE}.health.svc_disabled")"
        fi
    fi

    xray_ver=''
    if [[ -x "${xray_bin}" ]]; then
        out="$("${xray_bin}" version 2>/dev/null || true)"
        tmp="${out%%$'\n'*}"
        # 首行形如 "Xray 1.8.24 (Xray, Penetrates Everything.) ..." —— 第 2 字段是版本
        read -r _ tmp2 _ <<<"${tmp}"
        xray_ver="${tmp2}"
    fi
    if [[ -n "${xray_ver}" ]]; then
        _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.xray_bin_label")${xray_ver}"
    else
        _health_item 'fail' "$(_i18n ".${CUR_FILE}.health.xray_bin_label")$(_i18n ".${CUR_FILE}.health.xray_bin_missing")"
    fi

    if [[ ! -f "${xray_config_path}" ]]; then
        _health_item 'fail' "$(_i18n ".${CUR_FILE}.health.xray_conf_label")$(_i18n ".${CUR_FILE}.health.xray_conf_missing")"
    elif cmd_exists 'jq' && ! jq -e '.' "${xray_config_path}" >/dev/null 2>&1; then
        _health_item 'fail' "$(_i18n ".${CUR_FILE}.health.xray_conf_label")$(_i18n ".${CUR_FILE}.health.xray_conf_bad")"
    else
        _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.xray_conf_label")$(_i18n ".${CUR_FILE}.health.xray_conf_ok")"
    fi

    # Xray 访问日志目录权限: 非 SNI 模式下会记录真实客户端 IP, 需收紧为 700 仅 root 可读
    if [[ -d /var/log/xray ]]; then
        xray_log_mode="$(stat -c '%a' /var/log/xray 2>/dev/null || true)"
        case "${xray_log_mode}" in
            700|750|710) _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.xray_log_label")$(_i18n ".${CUR_FILE}.health.xray_log_ok")" ;;
            *) _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.xray_log_label")$(_i18n ".${CUR_FILE}.health.xray_log_open")" ;;
        esac
    else
        _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.xray_log_label")$(_i18n ".${CUR_FILE}.health.xray_log_open")"
    fi
}

# =============================================================================
# 函数名称: _health_nginx
# 功能描述: 体检分区 4 —— Nginx 服务。仅 SNI 场景存在, 故用 skip 语义而非硬判失败。
#   检查单元 / 进程 / 配置语法 (-t) / HTTP3 模块 / worker 是否降权。
# 参数: 无
# 返回值: 无
# =============================================================================
function _health_nginx() {
    _health_section "$(_i18n ".${CUR_FILE}.health.sec_nginx")"

    if [[ -x "${ngx_prefix}/sbin/nginx" ]]; then ngx_present=1; fi
    if [[ -f "${ngx_config_dir}/nginx.conf" ]]; then ngx_present=1; fi
    if [[ "${has_systemctl}" -eq 1 ]]; then
        if systemctl cat 'nginx' >/dev/null 2>&1; then ngx_present=1; fi
    fi

    if [[ "${ngx_present}" -eq 0 ]]; then
        _health_item 'skip' "$(_i18n ".${CUR_FILE}.health.nginx_absent")"
    else
        local ngx_pid='' ngx_user=''
        ngx_unit_ok=0 ngx_active=''
        if [[ "${has_systemctl}" -eq 1 ]]; then
            if systemctl cat 'nginx' >/dev/null 2>&1; then ngx_unit_ok=1; fi
            ngx_active="$(systemctl is-active 'nginx' 2>/dev/null || true)"
        fi
        if [[ "${ngx_unit_ok}" -eq 1 ]]; then
            _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.svc_unit_label")$(_i18n ".${CUR_FILE}.health.present")"
        else
            _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.svc_unit_label")$(_i18n ".${CUR_FILE}.health.svc_unit_missing")"
        fi
        if [[ "${ngx_active}" == 'active' ]]; then
            _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.svc_active_label")active"
        else
            _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.svc_active_label")${ngx_active:-$(_i18n ".${CUR_FILE}.health.unknown")}"
        fi
        # nginx -t 只校验配置语法, 不监听端口, 属只读操作
        if [[ -x "${ngx_prefix}/sbin/nginx" ]]; then
            ngx_test_rc=0
            out="$("${ngx_prefix}/sbin/nginx" -t 2>&1)" || ngx_test_rc=$?
            if [[ "${ngx_test_rc}" -eq 0 ]]; then
                _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.nginx_test_label")$(_i18n ".${CUR_FILE}.health.nginx_test_ok")"
            else
                _health_item 'fail' "$(_i18n ".${CUR_FILE}.health.nginx_test_label")$(_i18n ".${CUR_FILE}.health.nginx_test_bad")"
            fi
            # HTTP/3 支持是编译期决定: 缺模块时站点配置里的 quic 指令会被
            # handler.sh:align_site_http3 剥离, 即 H3 静默降级 —— 这里显式告知
            if _nginx_supports_http3; then
                _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.h3_module_label")$(_i18n ".${CUR_FILE}.health.h3_module_ok")"
            else
                _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.h3_module_label")$(_i18n ".${CUR_FILE}.health.h3_module_missing")"
            fi
            # Worker 用户是否仍为 root: 主配置 user nginx; 后, worker 应已降权
            ngx_pid="$(cat /run/nginx.pid 2>/dev/null || true)"
            if [[ -n "${ngx_pid}" && -r "/proc/${ngx_pid}/status" ]]; then
                ngx_user="$(awk -F': ' '/^Uid:/{print $2; exit}' "/proc/${ngx_pid}/status" 2>/dev/null | awk '{print $1}')"
            fi
            if [[ "${ngx_user}" == '0' ]]; then
                _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.nginx_user_label")$(_i18n ".${CUR_FILE}.health.nginx_user_root")"
            elif [[ -n "${ngx_user}" ]]; then
                _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.nginx_user_label")$(_i18n ".${CUR_FILE}.health.nginx_user_ok")"
            fi
        fi
    fi
}

# =============================================================================
# 函数名称: _health_ports
# 功能描述: 体检分区 5 —— 端口归属。SNI 下 443 归 nginx、直连下归 xray, 归属错了会
#   "看着在跑但连不上"; 顺带查 H3(UDP/443) 监听与防火墙放行、80 端口。
# 参数: 无
# 返回值: 无
# =============================================================================
function _health_ports() {
    _health_section "$(_i18n ".${CUR_FILE}.health.sec_port")"

    # SNI 模式判据: 配了主域名即认为走 SNI (与 backup.sh 的 _domains_in_use 同源)
    cfg_domain=''
    if cmd_exists 'jq' && [[ -f "${SCRIPT_CONFIG_PATH}" ]]; then
        cfg_domain="$(jq -r '.nginx.domain // empty' "${SCRIPT_CONFIG_PATH}" 2>/dev/null || true)"
    fi
    if [[ -n "${cfg_domain}" ]]; then sni_mode=1; fi

    port443="$(get_listening_process_by_port '443' 2>/dev/null || true)"
    port80="$(get_listening_process_by_port '80' 2>/dev/null || true)"
    # 从 ss 的 users:(("nginx",pid=1,fd=6)) 里取进程名
    port443_name="${port443}"
    port80_name="${port80}"
    if [[ "${port443_name}" == *'("'* ]]; then
        port443_name="${port443_name#*(\"}"
        port443_name="${port443_name%%\"*}"
    fi
    if [[ "${port80_name}" == *'("'* ]]; then
        port80_name="${port80_name#*(\"}"
        port80_name="${port80_name%%\"*}"
    fi

    if [[ -z "${port443_name}" ]]; then
        _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.port443_label")$(_i18n ".${CUR_FILE}.health.port_none")"
    else
        # 归属与模式一致性: SNI 期望 nginx, 直连期望 xray
        local expect_name='xray'
        if [[ "${sni_mode}" -eq 1 ]]; then expect_name='nginx'; fi
        if [[ "${port443_name}" == "${expect_name}" ]]; then
            _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.port443_label")${port443_name} ($(_i18n ".${CUR_FILE}.health.port_expect_ok"))"
        else
            _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.port443_label")${port443_name} —— $(_i18n ".${CUR_FILE}.health.port_mismatch")${expect_name}"
        fi
    fi

    # HTTP/3 (QUIC) 走 UDP/443, 与 TCP 443 是两个独立监听 —— 只看 TCP 会漏报。
    # 只有 SNI 模式才该由 Nginx 提供 H3 (站点模板带 quic 监听, 见 sites-available/*)。
    if [[ "${sni_mode}" -eq 1 ]]; then
        port443udp="$(get_listening_process_by_udp_port '443' 2>/dev/null || true)"
        port443udp_name="${port443udp}"
        if [[ "${port443udp_name}" == *'("'* ]]; then
            port443udp_name="${port443udp_name#*(\"}"
            port443udp_name="${port443udp_name%%\"*}"
        fi
        if [[ -n "${port443udp_name}" ]]; then
            _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.h3_udp_label")${port443udp_name}"
        elif _nginx_supports_http3; then
            _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.h3_udp_label")$(_i18n ".${CUR_FILE}.health.h3_udp_absent")"
        else
            _health_item 'skip' "$(_i18n ".${CUR_FILE}.health.h3_udp_label")$(_i18n ".${CUR_FILE}.health.h3_module_missing")"
        fi
        # 服务端在听但 UDP 没放行 = 客户端永远握不上手 (H3 部署最常见故障)
        fw_udp_rc=0
        check_firewall_port_open '443' 'udp' || fw_udp_rc=$?
        case "${fw_udp_rc}" in
        0) _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.h3_fw_label")$(_i18n ".${CUR_FILE}.health.h3_fw_open")" ;;
        2) _health_item 'skip' "$(_i18n ".${CUR_FILE}.health.h3_fw_label")$(_i18n ".${CUR_FILE}.health.h3_fw_none")" ;;
        *) _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.h3_fw_label")$(_i18n ".${CUR_FILE}.health.h3_fw_closed")" ;;
        esac
    else
        _health_item 'skip' "$(_i18n ".${CUR_FILE}.health.h3_mode_skip")"
    fi

    # 80 只在 SNI 下必需 (证书 HTTP 验证 + 跳转), 直连模式不监听属正常
    if [[ -z "${port80_name}" ]]; then
        if [[ "${sni_mode}" -eq 1 ]]; then
            _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.port80_label")$(_i18n ".${CUR_FILE}.health.port_none")"
        else
            _health_item 'skip' "$(_i18n ".${CUR_FILE}.health.port80_label")$(_i18n ".${CUR_FILE}.health.port_none")"
        fi
    else
        _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.port80_label")${port80_name}"
    fi
}

# =============================================================================
# 函数名称: _health_certs
# 功能描述: 体检分区 6 —— TLS 证书。对主域名 / CDN 域名 / 自定义站点域名去重后逐个查
#   证书文件是否存在、剩余天数, 提前暴露"某天突然不能用"的到期问题。
# 参数: 无
# 返回值: 无
# =============================================================================
function _health_certs() {
    _health_section "$(_i18n ".${CUR_FILE}.health.sec_cert")"

    custom_doms=''
    if cmd_exists 'jq' && [[ -f "${SCRIPT_CONFIG_PATH}" ]]; then
        cfg_cdn="$(jq -r '.nginx.cdn // empty' "${SCRIPT_CONFIG_PATH}" 2>/dev/null || true)"
        custom_doms="$(jq -r '.nginx.custom_sites[]?.domain // empty' "${SCRIPT_CONFIG_PATH}" 2>/dev/null || true)"
    else
        cfg_cdn=''
    fi

    # 去重后逐个域名查证书 (关联数组去重; 读下标必须带 :- 兜底, 见 set -u)
    local -A h_seen=()
    local -a h_doms=()
    for tmp in "${cfg_domain}" "${cfg_cdn}" ${custom_doms}; do
        [[ -n "${tmp}" ]] || continue
        [[ -z "${h_seen[${tmp}]:-}" ]] || continue
        h_seen["${tmp}"]=1
        h_doms+=("${tmp}")
    done

    if [[ "${#h_doms[@]}" -eq 0 ]]; then
        _health_item 'skip' "$(_i18n ".${CUR_FILE}.health.cert_no_domain")"
    elif ! cmd_exists 'openssl'; then
        _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.cert_label")$(_i18n ".${CUR_FILE}.health.deps_req_missing") openssl"
    else
        now_ts="$(date '+%s' 2>/dev/null || true)"
        for tmp in "${h_doms[@]}"; do
            cert_file="${cert_dir}/${tmp}/fullchain.pem"
            if [[ ! -f "${cert_file}" ]]; then
                _health_item 'fail' "$(_i18n ".${CUR_FILE}.health.cert_label")${tmp} —— $(_i18n ".${CUR_FILE}.health.cert_missing")"
                continue
            fi
            cert_days=''
            cert_raw="$(openssl x509 -enddate -noout -in "${cert_file}" 2>/dev/null || true)"
            cert_raw="${cert_raw#notAfter=}"
            cert_ts=''
            if [[ -n "${cert_raw}" ]]; then
                cert_ts="$(date -d "${cert_raw}" '+%s' 2>/dev/null || true)"
            fi
            if [[ "${cert_ts}" =~ ^[0-9]+$ && "${now_ts}" =~ ^[0-9]+$ ]]; then
                cert_days="$(((10#${cert_ts} - 10#${now_ts}) / 86400))"
            fi
            if [[ -z "${cert_days}" ]]; then
                _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.cert_label")${tmp} —— $(_i18n ".${CUR_FILE}.health.unknown")"
            elif ((cert_days < 0)); then
                _health_item 'fail' "$(_i18n ".${CUR_FILE}.health.cert_label")${tmp} —— $(_i18n ".${CUR_FILE}.health.cert_expired")"
            elif ((cert_days < cert_warn_days)); then
                _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.cert_label")${tmp} —— $(_i18n ".${CUR_FILE}.health.cert_days")${cert_days} —— $(_i18n ".${CUR_FILE}.health.cert_expiring")"
            else
                _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.cert_label")${tmp} —— $(_i18n ".${CUR_FILE}.health.cert_days")${cert_days}"
            fi
        done
    fi
}

# =============================================================================
# 函数名称: _health_kernel
# 功能描述: 体检分区 7 —— 内核网络。复用 check_net_status 的判据, 但只出结论不重印整段报告。
# 参数: 无
# 返回值: 无
# =============================================================================
function _health_kernel() {
    _health_section "$(_i18n ".${CUR_FILE}.health.sec_net")"

    cc='' qdisc=''
    if cmd_exists 'sysctl'; then
        cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
        qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    fi
    if [[ "${cc}" == 'bbr' ]]; then
        _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.net_cc_label")bbr"
    else
        _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.net_cc_label")${cc:-$(_i18n ".${CUR_FILE}.health.unknown")}"
    fi
    if [[ "${qdisc}" == 'fq' ]]; then
        _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.net_qdisc_label")fq"
    else
        _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.net_qdisc_label")${qdisc:-$(_i18n ".${CUR_FILE}.health.unknown")}"
    fi

    persist_mod=0 persist_sysctl=0
    # 刻意写成 if 而不是 `[[ ]] && x=1`: 后者在条件为假时整条语句返回 1,
    # 会被 set -e 判为失败而中断体检 (本项目已登记的坑)。
    if [[ -e '/etc/modules-load.d/xray-script-personal-use-only-bbr.conf' ]]; then persist_mod=1; fi
    if [[ -e '/etc/sysctl.d/99-xray-script-personal-use-only-bbr.conf' ]]; then persist_sysctl=1; fi
    if [[ "${persist_mod}" -eq 1 && "${persist_sysctl}" -eq 1 ]]; then
        _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.net_persist_label")$(_i18n ".${CUR_FILE}.health.present")"
    else
        _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.net_persist_label")$(_i18n ".${CUR_FILE}.health.net_persist_missing")"
    fi

    # IPv6 栈状态: 复用 check_ipv6_status 的采集, 但传 1 跳过出站探测 ——
    # 体检要快速返回, 而那次探测含两次 curl (最长约 45s)。代价是"半残"判定在
    # 体检里只看"有无默认路由", 出站不通需 `--ipv6-status` 才能确认。
    _ipv6_collect 1
    case "${_IPV6_MODE}" in
    ok)
        _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.ipv6_label")$(_i18n ".${CUR_FILE}.health.ipv6_ok")"
        ;;
    off)
        _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.ipv6_label")$(_i18n ".${CUR_FILE}.health.ipv6_off")"
        ;;
    soft_off)
        _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.ipv6_label")$(_i18n ".${CUR_FILE}.health.ipv6_soft_off")"
        ;;
    partial)
        _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.ipv6_label")$(_i18n ".${CUR_FILE}.health.ipv6_partial")"
        ;;
    no_addr)
        _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.ipv6_label")$(_i18n ".${CUR_FILE}.health.ipv6_no_addr")"
        ;;
    grub | no_stack)
        # 这两种是"本机根本没有可用的 IPv6 栈", 不属于本脚本能管的状态,
        # 记 skip 而不记 pass —— 否则体检全绿会掩盖"这台机器没有 IPv6"这一事实。
        _health_item 'skip' "$(_i18n ".${CUR_FILE}.health.ipv6_label")$(_i18n ".${CUR_FILE}.health.ipv6_absent")"
        ;;
    *)
        _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.ipv6_label")$(_i18n ".${CUR_FILE}.health.unknown")"
        ;;
    esac

    # 硬禁用 IPv6 会让 nginx 的 listen [::] bind 失败 (nginx -t 查不出来),
    # 这里只在"确实有人在监听 IPv6"且"IPv6 socket 已不可创建"时告警。
    if [[ "${_IPV6_NGINX6}" -eq 1 && "${_IPV6_SOCK}" == 'no' ]]; then
        _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.ipv6_nginx_risk")"
    fi
}

# =============================================================================
# 函数名称: _health_script
# 功能描述: 体检分区 8 —— 脚本配置与日志。config.json 可解析性 + version/tag/path 一致性
#   + 日志体积 + 日志轮转 + 订阅产物新鲜度。
# 参数: 无
# 返回值: 无
# =============================================================================
function _health_script() {
    _health_section "$(_i18n ".${CUR_FILE}.health.sec_script")"

    cfg_ok=0
    if [[ ! -f "${SCRIPT_CONFIG_PATH}" ]]; then
        _health_item 'fail' "$(_i18n ".${CUR_FILE}.health.script_conf_label")$(_i18n ".${CUR_FILE}.health.script_conf_missing")"
    elif cmd_exists 'jq' && ! jq -e '.' "${SCRIPT_CONFIG_PATH}" >/dev/null 2>&1; then
        _health_item 'fail' "$(_i18n ".${CUR_FILE}.health.script_conf_label")$(_i18n ".${CUR_FILE}.health.script_conf_bad")"
    else
        cfg_ok=1
        _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.script_conf_label")$(_i18n ".${CUR_FILE}.health.xray_conf_ok")"
    fi

    if [[ "${cfg_ok}" -eq 1 ]] && cmd_exists 'jq'; then
        cfg_ver="$(jq -r '.version // empty' "${SCRIPT_CONFIG_PATH}" 2>/dev/null || true)"
        cfg_tag="$(jq -r '.xray.tag // empty' "${SCRIPT_CONFIG_PATH}" 2>/dev/null || true)"
        cfg_path="$(jq -r '.path // empty' "${SCRIPT_CONFIG_PATH}" 2>/dev/null || true)"
        _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.script_ver_label")${cfg_ver:-?} / $(_i18n ".${CUR_FILE}.health.script_tag_label")${cfg_tag:-$(_i18n ".${CUR_FILE}.health.not_configured")}"
        # path 与当前运行目录不一致 = 脚本被移动过或装了两份, 会导致读旧配置
        if [[ -n "${cfg_path}" && "${cfg_path}" != "${PROJECT_ROOT}" ]]; then
            _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.script_path_label")${cfg_path} —— $(_i18n ".${CUR_FILE}.health.script_path_mismatch")"
        else
            _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.script_path_label")${cfg_path:-$(_i18n ".${CUR_FILE}.health.not_configured")}"
        fi
    fi

    audit_bytes="$(_file_bytes "${audit_log}")"
    xraylog_bytes="$(_file_bytes "${xray_access_log}")"
    if [[ -z "${audit_bytes}" && -z "${xraylog_bytes}" ]]; then
        _health_item 'skip' "$(_i18n ".${CUR_FILE}.health.log_label")$(_i18n ".${CUR_FILE}.health.unknown")"
    else
        lvl='pass'
        if [[ "${audit_bytes}" =~ ^[0-9]+$ ]] && ((10#${audit_bytes} > log_warn_bytes)); then lvl='warn'; fi
        if [[ "${xraylog_bytes}" =~ ^[0-9]+$ ]] && ((10#${xraylog_bytes} > log_warn_bytes)); then lvl='warn'; fi
        tmp="$(_i18n ".${CUR_FILE}.health.log_audit_label")$(_human_size "${audit_bytes:-0}") / $(_i18n ".${CUR_FILE}.health.log_access_label")$(_human_size "${xraylog_bytes:-0}")"
        if [[ "${lvl}" == 'warn' ]]; then
            tmp="${tmp} —— $(_i18n ".${CUR_FILE}.health.log_large")"
        fi
        _health_item "${lvl}" "$(_i18n ".${CUR_FILE}.health.log_label")${tmp}"
    fi

    # 日志轮转: 只有"体积告警"没有"轮转兜底"是治标不治本 —— 老版本装机没有
    # /etc/logrotate.d/xray-script-personal-use-only, 日志会一直涨到撑满磁盘。这里显式检查配置是否存在,
    # 缺失即 WARN(不是 FAIL): 不影响当前服务可用性, 但迟早出问题, 属"该修但没坏"。
    # 非 Linux / 无 logrotate 的环境 (如 MSYS 测试机) 判为 skip, 避免误报。
    if ! cmd_exists 'logrotate'; then
        _health_item 'skip' "$(_i18n ".${CUR_FILE}.health.rotate_label")$(_i18n ".${CUR_FILE}.health.rotate_absent")"
    elif [[ -f '/etc/logrotate.d/xray-script-personal-use-only' ]]; then
        _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.rotate_label")$(_i18n ".${CUR_FILE}.health.rotate_ok")"
    else
        _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.rotate_label")$(_i18n ".${CUR_FILE}.health.rotate_missing")"
    fi

    # 订阅新鲜度: 订阅产物是配置的"派生快照" —— 配置改了而订阅没重生成, 客户端仍指向
    # 旧参数。正常路径由 handler_refresh_subscription 在配置写入后自动重生成, 这里兜住
    # 异常情况 (手动改过配置 / 重生成失败 / 从旧版本升级上来)。没订阅文件则跳过不计分。
    for tmp in "${SCRIPT_CONFIG_DIR}"/subscription-*; do
        [[ -f "${tmp}" ]] || continue
        sub_count=$((sub_count + 1))
        tmp2="$(_file_mtime "${tmp}")"
        if [[ -n "${tmp2}" ]] && { [[ -z "${sub_newest}" ]] || ((10#${tmp2} > 10#${sub_newest})); }; then
            sub_newest="${tmp2}"
        fi
    done
    if [[ "${sub_count}" -eq 0 ]]; then
        _health_item 'skip' "$(_i18n ".${CUR_FILE}.health.sub_label")$(_i18n ".${CUR_FILE}.health.sub_absent")"
    else
        cfg_mtime="$(_file_mtime "${SCRIPT_CONFIG_PATH}")"
        # 订阅由"脚本配置 config.json"与"Xray 服务端配置"共同决定 —— 任一变更都会让订阅
        # 里写死的入站参数失效, 故取两者中较新的时间做比对; 只看 config.json 会漏报
        # "只改了 Xray 配置"这一类。
        tmp2="$(_file_mtime "${xray_config_path}")"
        if [[ -n "${tmp2}" ]] && { [[ -z "${cfg_mtime}" ]] || ((10#${tmp2} > 10#${cfg_mtime})); }; then
            cfg_mtime="${tmp2}"
        fi
        if [[ -n "${sub_newest}" && -n "${cfg_mtime}" ]] && ((10#${cfg_mtime} > 10#${sub_newest})); then
            _health_item 'warn' "$(_i18n ".${CUR_FILE}.health.sub_label")${sub_count}$(_i18n ".${CUR_FILE}.health.sub_unit")$(_i18n ".${CUR_FILE}.health.sub_stale")"
        else
            _health_item 'pass' "$(_i18n ".${CUR_FILE}.health.sub_label")${sub_count}$(_i18n ".${CUR_FILE}.health.sub_unit")$(_i18n ".${CUR_FILE}.health.sub_sync")"
        fi
    fi
}

# =============================================================================
# 函数名称: _health_summary
# 功能描述: 汇总 _HEALTH_ITEMS 的三档结论, 打印合计与总体判断。
# 参数: 无 (读写 check_health_report 的 pass/warn/fail 计数器与 _HEALTH_ITEMS)
# 返回值: 无 (计数结果留在父函数的 pass/warn/fail 局部变量供 return 使用)
# =============================================================================
function _health_summary() {
    if [[ "${#_HEALTH_ITEMS[@]}" -gt 0 ]]; then
        for item in "${_HEALTH_ITEMS[@]}"; do
            lvl="${item%%|*}"
            case "${lvl}" in
            pass) pass=$((pass + 1)) ;;
            warn) warn=$((warn + 1)) ;;
            *) fail=$((fail + 1)) ;;
            esac
        done
    fi

    printf '\n%s\n' '------------------------------------------------------' >&2
    # 标签 + ": " + 三档各 (颜色, 文本, 复位) —— 共 10 个 %s, 与下方 10 个实参严格一一对应。
    # 格式符与实参个数必须相等: 少一个 %s 会让 printf 吃错参数 (末尾 ${NC} 被吞掉, 终端颜色
    # 渗染后续输出), 多一个 %s 同样错位 —— 由 shellcheck SC2183 与 CI 门禁兜底。
    printf '  %s: %s%s%s  %s%s%s  %s%s%s\n' \
        "$(_i18n ".${CUR_FILE}.health.summary")" \
        "${GREEN}" "$(_i18n ".${CUR_FILE}.health.summary_pass") ${pass}" "${NC}" \
        "${YELLOW}" "$(_i18n ".${CUR_FILE}.health.summary_warn") ${warn}" "${NC}" \
        "${RED}" "$(_i18n ".${CUR_FILE}.health.summary_fail") ${fail}" "${NC}" >&2
    if [[ "${fail}" -gt 0 ]]; then
        printf '  %s%s%s\n' "${RED}" "$(_i18n ".${CUR_FILE}.health.done_fail")" "${NC}" >&2
    elif [[ "${warn}" -gt 0 ]]; then
        printf '  %s%s%s\n' "${YELLOW}" "$(_i18n ".${CUR_FILE}.health.done_warn")" "${NC}" >&2
    else
        printf '  %s%s%s\n' "${GREEN}" "$(_i18n ".${CUR_FILE}.health.done_ok")" "${NC}" >&2
    fi
    printf '  %s\n' "$(_i18n ".${CUR_FILE}.health.no_probe_note")" >&2
    printf '\n' >&2
}


# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。根据传入的第一个参数 (option)
#           调用相应的检查函数并输出结果。
# 参数:
#   $1: 操作选项 (e.g., --ip, --port, --uuid 等)
#   $@: 剩余参数，传递给被调用的具体函数
# 返回值: 无 (调用具体函数并输出其结果到 >&2)
# 退出码: 如果选项无效，则输出错误信息并退出脚本 (exit 1)
# =============================================================================
function main() {
    # 加载国际化数据
    load_i18n

    local option="${1:-}" # 获取第一个参数作为操作选项
    shift             # 移除第一个参数，剩下的参数留给具体函数处理

    # 使用 case 语句根据选项调用对应的函数
    # 所有函数的输出都重定向到标准错误输出 >&2，这样标准输出可以用于返回结果
    #
    # 每个臂末尾的 `|| exit $?` 是**刻意**的, 而且**必须每个臂都有**:
    #   本脚本的每个选项都是只读检查器, 退出码即检查结论 (0=通过 / 非 0=未通过), 属正常
    #   业务语义。可 `return 1` 会被 set -e 的 ERR trap 当成"意外失败" —— 于是用户在一次
    #   正常的检查里, 报告末尾会多出一条 "[错误] 脚本在第 N 行意外失败 (退出码 1)"。
    #   此前只给 --rule-ip / --rule-domain 打了这个补丁 (它们要经 exec_read 透传退出码),
    #   其余 18 个臂全在冒假报错: 2026-09-24 逐个实测, 15 个臂里 9 个复现, 其中
    #   --net-status 把"BBR 持久化不完整"(正常结论) 渲染成了脚本崩溃。
    #   放进 `||` 右侧即进入"条件上下文", errexit 与 ERR trap 都不触发, 退出码照常透传
    #   (与 menu.sh 入口的 `main "$@" || OPTION=$?` 同一构造)。
    #   留在条件上下文**之外**的 `source _common.sh` / load_i18n 等真·意外失败照旧保留
    #   行号 + 命令的诊断, 不受本补丁影响。新增臂若漏写, test/check_dispatch_exit_test.sh 会红。
    case "${option}" in
    --ip) check_ip "$@" >&2 || exit $? ;;                            # 检查 IP 地址
    --port) check_port "$@" >&2 || exit $? ;;                        # 检查端口
    --uuid) check_uuid "$@" >&2 || exit $? ;;                        # 检查 UUID
    --password) check_password "$@" >&2 || exit $? ;;                # 检查密码
    --path) check_path "$@" >&2 || exit $? ;;                        # 检查路径
    --short) check_short_id "$@" >&2 || exit $? ;;                   # 检查 Short ID
    --domain) check_domain_security "$@" >&2 || exit $? ;;           # 检查域名安全性
    --domain-format) check_domain_format "$@" >&2 || exit $? ;;      # 仅校验域名格式(不解析 DNS)
    --dns) check_dns_resolution "$@" >&2 || exit $? ;;               # 检查 DNS 解析
    --tag) check_xray_config_exists "$@" >&2 || exit $? ;;           # 检查 Xray 配置文件
    --xray) check_xray_version_exists "$@" >&2 || exit $? ;;         # 检查 Xray 版本
    --email) validate_email "$@" >&2 || exit $? ;;                   # 验证邮箱
    --sni-ports) check_sni_ports "$@" >&2 || exit $? ;;              # 检查 SNI 必需端口与防火墙状态
    --proxy-target) check_proxy_target "$@" || exit $? ;;            # 取回伪装目标(结果走 stdout)
    --custom-domain) check_custom_site_domain "$@" >&2 || exit $? ;; # 检查自定义站点域名
    --list-index) check_list_index "$@" >&2 || exit $? ;;            # 校验列表序号
    --rule-ip) check_rule_ip "$@" >&2 || exit $? ;;                  # 写前校验 ip 分流值
    --rule-domain) check_rule_domain "$@" >&2 || exit $? ;;          # 写前校验 domain 分流值
    --net-status) check_net_status "$@" >&2 || exit $? ;;            # 只读体检内核网络与 BBR 状态
    --ipv6-status) check_ipv6_status "$@" >&2 || exit $? ;;          # 只读检测 IPv6 栈状态
    --health) check_health_report "$@" >&2 || exit $? ;;             # 一键全量体检 (只读)
    # P1-3 补漏: 本函数的 case 原本没有 `*)` 分支 —— 未知/拼错的参数什么都不做就退出,
    # 退出码 0。而 core/main.sh 与 README 都推荐脚本化调用走 `core/check.sh --health`
    # (0=无失败项 / 1=有失败项), cron 里把 `--health` 误写成 `--heath` 就会拿到 exit 0,
    # 结果监控永远假绿 —— 这正是 handler.sh:3282 那段注释要防的问题, 本脚本却漏了网。
    # 退出码 EXIT_USAGE(=2) = 用法错误, 与正常 0、真实故障 1 区分开 (与 handler.sh 的 main 保持一致)。
    *)
        printf "${RED}[%s]${NC} %s: %s\n" "$(_i18n '.title.error')" "$(_i18n ".${CUR_FILE}.unknown_option")" "${option}" >&2
        exit "${EXIT_USAGE}"
        ;;
    esac
}

# --- 脚本执行入口 ---
# 将脚本接收到的所有参数传递给 main 函数开始执行
main "$@"
