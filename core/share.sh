#!/usr/bin/env bash
#
# Copyright (C) 2026 crudguy
#
# xray-script-personal-use-only:
#   https://github.com/crudguy/xray-script-personal-use-only
# =============================================================================
# 脚本名称: share.sh
# 功能描述: 生成 Xray 服务的客户端配置信息和分享链接 (如 VLESS, Trojan)。
#           根据服务端配置 (Xray 和 Script) 自动提取必要参数，
#           构造多种类型的分享链接 (包括 Reality, XHTTP, mKCP, TLS 等)，
#           并可选地生成二维码。支持多语言。
# 作者: crudguy
# 时间: 2026-09-19
# 版本: 1.0.0
# 依赖: bash, jq, curl, qrencode, base64 (订阅产物), mkdir/chmod (写订阅文件)
# 配置:
#   - ${XRAY_CONFIG_PATH}: Xray 服务端配置文件 (用于读取协议、UUID、密码等)
#   - ${SCRIPT_CONFIG_PATH}: 脚本自身配置文件 (用于读取端口、域名、路径等)
#   - ${I18N_DIR}/${lang}.json: 国际化文件 (用于显示多语言提示)
# 环境变量:
#   - XRAY_SCRIPT_FP: 覆盖客户端 uTLS 指纹 (默认 chrome; 白名单见 resolve_share_fp)
# =============================================================================

# --- 共享头部: 严格模式 / ERR trap / PATH / 颜色 / 目录常量 / i18n 公共函数 ---
# 实际内容由 core/_common.sh 提供 (所有 source 它的脚本共用, 消除副本漂移);
#   共用数此前写作 13 —— 那个随容器方案一起下线的服务脚本没了之后就不再是这个数,
#   故此处不再写死绝对值 (写死就得跟着增删一起改, 只会再次漂移)。设计取舍 (为何
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
# 注: 此处曾声明 GENERATE_PATH (generate.sh), 仅为"从 serverNames/shortIds 里随机挑一项"
#   而 fork 一次子进程 —— 已改用 bash 内建 $RANDOM, 声明随之删除 (留着会触发 SC2034)。
#   真正需要 generate.sh 的地方 (UUID / 密钥生成) 在 handler.sh 侧, 它有自己的声明。
readonly XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"    # Xray 服务端配置文件路径

# --- 全局变量声明 ---
# 声明用于存储语言参数、国际化数据和配置信息的全局变量
declare -A CLIENT_CONFIG    # 关联数组，存储当前处理的客户端配置片段
declare XRAY_CONFIG='' # 存储 Xray 配置文件的全部 JSON 内容
declare SCRIPT_CONFIG='' # 存储脚本配置文件的全部 JSON 内容
declare XHTTP_EXTRA='' # 存储额外的 XHTTP 下行设置 JSON 字符串
declare XHTTP_EXTRA_ENCODED='' # 存储经过 URL 编码的 XHTTP_EXTRA 字符串
declare SHARE_LINK='' # 存储最终生成的分享链接
# 声明一系列变量用于存储分享链接的各个组成部分，便于拼接不同类型的链接
declare SHARE_LINK_COMPONENT_VLESS='' # VLESS 协议的基础部分
declare SHARE_LINK_COMPONENT_TROJAN='' # Trojan 协议的基础部分
declare SHARE_LINK_COMPONENT_MKCP='' # mKCP 网络传输的参数部分
declare SHARE_LINK_COMPONENT_TLS='' # TLS 安全传输的参数部分
declare SHARE_LINK_COMPONENT_REALITY='' # Reality 安全传输的参数部分
declare SHARE_LINK_COMPONENT_XHTTP='' # XHTTP 网络传输的参数部分
declare SHARE_LINK_COMPONENT_FLOW='' # Flow 控制参数部分
declare SHARE_LINK_COMPONENT_EXTRA='' # 额外参数 (如 downloadSettings) 部分

# --- 分享输出控制 ---
# 用于收敛密钥 (UUID/Trojan 密码/Reality 公钥) 在屏幕上的暴露面。
declare SHARE_SAVE_FILE=''  # 非空时把分享配置写入该文件 (0600), 且不在屏幕打印明文与二维码
declare SHARE_SHOW_QR=1     # 是否在屏幕显示二维码 (1-显示 0-不显示)
declare SHARE_WARNED=0      # 是否已打印过明文密钥警告 (多组配置时避免重复刷屏)

# --- 订阅收集 (--subscription 模式) ---
# 生成每条链接时, 把结构化节点参数序列化进收集器, 供订阅构建复用。
# 直接序列化而非回头 URL-decode 分享链接: 链接里 path/sni 等都做了百分号编码,
# 自己解码既慢又易错; 而 CLIENT_CONFIG 此刻已是解码后的原始字段, 最可靠。
declare -a SHARE_LINKS=()        # 每条节点的 v2rayN 风格分享链接 (含 #tag)
declare SHARE_NODES_JSON=''      # 每条节点的结构化 JSON (换行分隔), 供 Clash/sing-box 重建
declare SHARE_COLLECT_ONLY=0     # 1=仅收集不打印 (订阅模式)
declare SHARE_SUBSCRIPTION=0      # 1=生成订阅文件
declare CLASH_PROXIES=''         # Clash YAML 的 proxies: 列表体
declare -a CLASH_NAMES=()        # 节点名列表 (proxy-groups 引用)
declare SINGBOX_OUTBOUNDS=''     # sing-box 的 outbounds JSON (换行分隔)
declare SINGBOX_SKIP=0           # sing-box 不支持而跳过的节点数 (当前为 mKCP)

# --- 客户端 uTLS 指纹 ---
# 单一取值点: 分享链接 (fp=)、客户端 JSON (tlsSettings/realitySettings.fingerprint)
# 与屏幕打印三处必须一致, 否则客户端指纹与实际声明不符会被 DPI 直接识别。
# 2026-06 起 DPI 已从协议特征转向 JA3/JA4 指纹比对与隧道内行为分析, 服务端配置正确
# 但客户端未声明标准指纹 (或声明了不匹配的指纹) 同样会失效。
# 默认 chrome (兼容性最好); 可用环境变量 XRAY_SCRIPT_FP 覆盖, 白名单见 resolve_share_fp。
declare SHARE_FP='chrome'

# =============================================================================
# 函数名称: resolve_share_fp
# 功能描述: 解析客户端 uTLS 指纹。取环境变量 XRAY_SCRIPT_FP, 未设置则用默认 chrome。
#           仅接受 Xray 支持的指纹名; 非法值回落 chrome 并告警 —— 宁可回落也不能
#           带着拼错的指纹生成链接 (客户端会握手失败, 而报错在客户端, 极难排查)。
#           需在 load_i18n 之后调用 (告警文案依赖 I18N_MAP)。
# 参数: 无
# 返回值: 无 (直接修改全局变量 SHARE_FP), 恒返回 0, 不阻断分享流程
# =============================================================================
function resolve_share_fp() {
    local want="${XRAY_SCRIPT_FP:-chrome}" # 允许环境变量覆盖, 便于适配被针对性识别的网络

    case "${want}" in
    chrome | firefox | safari | ios | android | edge | 360 | qq | random | randomized)
        SHARE_FP="${want}"
        ;;
    *)
        # 非法值: 回落默认并明确告警, 而非静默沿用
        SHARE_FP='chrome'
        # 注: 告警刻意不做占位符替换 —— want 来自环境变量, 走 sed 时含正则元字符
        #     (如 "[") 会让 sed 返回非零, 在 set -e 下整个分享流程被一条告警拖死;
        #     走 bash 参数替换 (${tpl//pat/rep}) 时 "&" 又会被解释成匹配文本。
        #     故改为在文案后另附原值。此处用 echo -e 输出 (颜色变量现为 ANSI-C 引号的
        #     真 ESC, echo -e / printf '%s' 均能正确上色; 历史沿用 echo -e 写法)。
        echo -e "${YELLOW}[$(_i18n ".${CUR_FILE}.fp_invalid")] XRAY_SCRIPT_FP=${want}${NC}" >&2
        ;;
    esac
}

# =============================================================================
# 函数名称: urlencode
# 功能描述: 对输入字符串进行 URL 编码。
#           将非字母数字、非 .~_- 的字符转换为 %XX 格式。
# 参数:
#   $1 (可选): 待编码的字符串。如果不提供，则从标准输入读取。
# 返回值: URL 编码后的字符串 (echo 输出)
# =============================================================================
# shellcheck disable=SC2120  # $1 为可选参数(不给则读 stdin), 现有调用点都走管道, 保留该能力
function urlencode() {
    local input='' # 声明局部变量存储输入

    # 如果没有传入参数，则从标准输入读取
    if [[ $# -eq 0 ]]; then
        input="$(cat)"
    else
        input="${1:-}" # 否则使用第一个参数作为输入
    fi

    local encoded="" # 声明局部变量存储编码后的结果
    local i c hex    # 声明循环变量和临时变量

    # 遍历输入字符串的每个字符
    for ((i = 0; i < ${#input}; i++)); do
        c="${input:$i:1}" # 获取当前字符

        # 检查字符是否为不需要编码的安全字符
        case $c in
        [a-zA-Z0-9.~_-])
            # 如果是安全字符，则直接追加到结果中
            encoded+="$c"
            ;;
        *)
            # 如果不是安全字符，则进行编码
            # printf -v hex 将字符的 ASCII 码转换为两位十六进制数
            printf -v hex "%02X" "'$c"
            # 将 % 和十六进制数追加到结果中
            encoded+="%$hex"
            ;;
        esac
    done

    # 输出编码后的字符串
    echo "$encoded"
}

# =============================================================================
# 函数名称: cache_json_data
# 功能描述: 将 Xray 和脚本的配置文件内容读取到全局变量中进行缓存，
#           避免重复读取文件，提高脚本执行效率。
# 参数: 无
# 返回值: 无 (直接修改全局变量 XRAY_CONFIG 和 SCRIPT_CONFIG)
# =============================================================================
function cache_json_data() {
    # 读取 Xray 配置文件的完整 JSON 内容到全局变量 XRAY_CONFIG
    # 前置校验 (原实现缺失): 未安装 / 已卸载 / 配置被清除时文件不存在, jq 以退出码 2
    #   失败。在 set -Eeuo pipefail + ERR trap 下, 这会被当成"脚本内部错误",
    #   打印内部行号与堆栈式诊断 —— 用户看到的不是"没装 Xray", 而是一堆看不懂的报错。
    #   典型触发: 卸载后仍在主菜单选 7(分享链接) 或 11(生成订阅)。这里提前拦截。
    if [[ ! -f "${XRAY_CONFIG_PATH}" ]]; then
        _error "$(_i18n ".${CUR_FILE}.not_installed")"
    fi
    XRAY_CONFIG="$(jq '.' "${XRAY_CONFIG_PATH}")"
    # 读取脚本配置文件的完整 JSON 内容到全局变量 SCRIPT_CONFIG
    # 注: 脚本配置缺失不至于让分享/订阅整个不可用(仅少数字段为空), 故只做兜底;
    #     若连它都缺, 上面的 Xray 校验通常也已先拦下(安装会同时生成两者)。
    #     兜底必须是 '{}' 而非空串 —— jq 对**空输入**会以退出码 2 失败, 那样后续
    #     `echo "${SCRIPT_CONFIG}" | jq -r ...` 仍会被 set -e 判为失败而崩溃;
    #     给个合法空对象后取值为 null, 不会中断。
    SCRIPT_CONFIG="$(jq '.' "${SCRIPT_CONFIG_PATH}" 2>/dev/null || true)"
    # 兜底写法的硬性约束: 绝不能写成 `[[ -z X ]] && X='{}'` —— 那是本函数最后一条命令,
    # 在"配置正常、非空"的健康路径上测试为假, 整条 && 列表返回 1, 函数随之返回 1,
    # 调用处 (订阅/分享流程) 即被 set -e + ERR trap 判为"脚本内部错误"而中断;
    # 且报错行号指向**调用处**、命令显示 [[ -z ... ]], 极具误导性 (实测: 生成订阅必崩)。
    # 用 if 块: 条件为假时 if 语句本身返回 0, 不污染函数返回值。
    if [[ -z "${SCRIPT_CONFIG}" ]]; then
        SCRIPT_CONFIG='{}'
    fi
}

# =============================================================================
# 函数名称: get_common_config
# 功能描述: 从缓存的 Xray 和脚本配置中提取指定 inbound 索引的通用客户端配置参数，
#           并存储到 CLIENT_CONFIG 关联数组中。
# 参数:
#   $1: Xray 配置中 inbound 数组的索引 (inbound_index)
# 返回值: 无 (直接修改全局变量 CLIENT_CONFIG)
# =============================================================================
function get_common_config() {
    local inbound_index=$1 # 获取 inbound 索引参数

    # 统一探测公网地址 (双栈, 绕过代理, 结果缓存 —— 含跨进程落盘缓存, 见
    # _common.sh:_public_ip_cache_read); 非 CDN 模式用其作为远程主机
    # (v4 优先, 仅 v6 主机回退 [v6], 见 _common.sh:_preferred_remote_host)。
    # 探测必须"直调"以回写缓存: 订阅会按 inbound 逐个调本函数, 直调后同进程只探测
    # 一次; 若写成 remote_host="$(_resolve_public_ips ...)" 则子 shell 丢缓存。
    _resolve_public_ips >/dev/null
    CLIENT_CONFIG[remote_host]="$(_preferred_remote_host)"

    # --- 一次 jq 取完脚本配置的三个字段 (port / publicKey / tag) ---
    # 为什么要合并: 原实现每条字段一次 `echo "$CFG" | jq`, 单入站订阅就要 fork 65 次
    #   jq; 订阅按入站逐个调本函数, 5 节点的 SNI 配置 fork 数翻倍 —— 这几百毫秒
    #   在低配 VPS 上会被放大成"点一下卡一下"。合并后每个入站只剩 2 次 jq。
    # 分隔符用 \x1f (Unit Separator) 而非制表符: tab 属于 IFS 的空白字符, read 会把
    #   连续 tab 合并、空字段直接丢失 (端口空缺这类场景会串位); \x1f 不是空白, 空字段保留。
    local srow='' s_port='' s_public_key='' s_tag=''
    srow="$(printf '%s' "${SCRIPT_CONFIG}" | jq -r '[ (.xray.port // ""), (.xray.publicKey // ""), (.xray.tag // "") ] | map(tostring) | join("\u001f")')"
    IFS=$'\x1f' read -r s_port s_public_key s_tag <<<"${srow}"
    CLIENT_CONFIG[port]="${s_port}"
    CLIENT_CONFIG[public_key]="${s_public_key}"
    CLIENT_CONFIG[tag]="${s_tag}"

    # --- 一次 jq 取完 Xray 配置的全部入站字段 ---
    # 随机索引用 bash 内建 $RANDOM: 这里只是"从 serverNames/shortIds 数组里随机挑一项",
    #   不是密钥生成, 无需 /dev/urandom 级别的不可预测性; 原实现为拿随机数 fork 一次
    #   `bash generate.sh --random` (要重新 source _common.sh), 每个入站 2 次、纯属浪费。
    #   真正的密钥/UUID 生成仍走 generate.sh, 不受影响。
    local r1=$((RANDOM)) r2=$((RANDOM))
    local row='' f_protocol='' f_uuid='' f_password='' f_seed='' f_type='' f_flow='' f_security='' f_path='' f_server_name='' f_short_id='' f_inbound_tag=''
    row="$(printf '%s' "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" --argjson r1 "${r1}" --argjson r2 "${r2}" '
        .inbounds[$i] as $in
        | ($in.streamSettings // {}) as $ss
        | ($ss.realitySettings // {}) as $rs
        | [
            # 协议类型 (vless / trojan / ...)
            ($in.protocol? // ""),
            # 客户端 UUID (VLESS) 与密码 (Trojan)
            ($in.settings.clients[0].id? // ""),
            ($in.settings.clients[0].password? // ""),
            # mKCP 种子: Xray 26.x 起迁进 finalmask, 且类型 id 改过名 ——
            # mkcp-legacy 用 settings.value, mkcp-aes128gcm 用 settings.password,
            # 两种都要认; 更老的配置还可能留 kcpSettings.seed。取首个命中项
            # (finalmask.udp 理论上可有多条), 并容忍残留的 camelCase finalMask 键。
            ( [ ($ss.finalmask // $ss.finalMask).udp[]?
                | select(.type == "mkcp-legacy" or .type == "mkcp-aes128gcm")
                | (.settings.value // .settings.password) ][0]
              // $ss.kcpSettings.seed
              // "" ),
            # 网络传输类型 (tcp / kcp / xhttp)
            ($ss.network? // ""),
            # Flow 控制 (xtls-rprx-vision) 与安全类型 (none / tls / reality)
            ($in.settings.clients[0].flow? // ""),
            ($ss.security? // ""),
            # XHTTP 路径
            ($ss.xhttpSettings.path? // ""),
            # Reality serverNames / shortIds 各随机取一项; 数组为空或缺失 -> 空串
            # (原写法 `.[$r % length]` 在空数组上是除零, 会让整条 jq 以非 0 退出)
            ( (($rs.serverNames?) // []) as $sn | if ($sn | length) == 0 then "" else $sn[$r1 % ($sn | length)] end ),
            ( (($rs.shortIds?) // []) as $si | if ($si | length) == 0 then "" else $si[$r2 % ($si | length)] end ),
            # 入站自身 tag (订阅模式用作节点名, 省掉外面再 fork 一次 jq)
            ($in.tag? // "")
          ] | map(tostring) | join("\u001f")')"
    IFS=$'\x1f' read -r f_protocol f_uuid f_password f_seed f_type f_flow f_security f_path f_server_name f_short_id f_inbound_tag <<<"${row}"

    CLIENT_CONFIG[protocol]="${f_protocol}"
    CLIENT_CONFIG[uuid]="${f_uuid}"
    CLIENT_CONFIG[password]="${f_password}"
    CLIENT_CONFIG[seed]="${f_seed}"
    CLIENT_CONFIG[type]="${f_type}"
    CLIENT_CONFIG[flow]="${f_flow}"
    CLIENT_CONFIG[security]="${f_security}"
    CLIENT_CONFIG[path]="${f_path}"
    CLIENT_CONFIG[server_name]="${f_server_name}"
    CLIENT_CONFIG[short_id]="${f_short_id}"
    CLIENT_CONFIG[inbound_tag]="${f_inbound_tag}"
}

# =============================================================================
# 函数名称: get_tls_down_json
# 功能描述: 生成用于 TLS 下行模式的额外配置 JSON 字符串 (XHTTP_EXTRA)，
#           通常用于 SNI + CDN 的场景。
#           然后对生成的 JSON 进行 URL 编码 (XHTTP_EXTRA_ENCODED)。
# 参数: 无
# 返回值: 无 (直接修改全局变量 XHTTP_EXTRA 和 XHTTP_EXTRA_ENCODED)
# =============================================================================
function get_tls_down_json() {
    # 从脚本配置中获取 CDN 域名作为服务器名称
    local server_name
    server_name="$(echo "${SCRIPT_CONFIG}" | jq -r ".nginx.cdn")"
    # 从脚本配置中获取 Xray 的路径
    local sni_path
    sni_path="$(echo "${SCRIPT_CONFIG}" | jq -r ".xray.path")"

    # 使用 Here Document 构造 XHTTP 下行设置的 JSON 字符串
    XHTTP_EXTRA=$(
        cat <<EOF
{
    "downloadSettings": {
        "address": "${server_name}",
        "port": 443,
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
            "serverName": "${server_name}",
            "allowInsecure": false,
            "alpn": [
                "h2"
            ],
            "fingerprint": "${SHARE_FP}"
        },
        "xhttpSettings": {
            "host": "${server_name}",
            "path": "${sni_path}",
            "mode": "auto"
        }
    }
}
EOF
    )

    # 将生成的 JSON 字符串通过管道传递给 jq 格式化，再传递给 urlencode 进行编码
    XHTTP_EXTRA_ENCODED=$(echo "${XHTTP_EXTRA}" | jq -r '.' | urlencode)
}

# =============================================================================
# 函数名称: get_reality_down_json
# 功能描述: 生成用于 Reality 下行模式的额外配置 JSON 字符串 (XHTTP_EXTRA)，
#           通常用于 SNI + Reality 的场景。
#           然后对生成的 JSON 进行 URL 编码 (XHTTP_EXTRA_ENCODED)。
# 参数: 无
# 返回值: 无 (直接修改全局变量 XHTTP_EXTRA 和 XHTTP_EXTRA_ENCODED)
# =============================================================================
function get_reality_down_json() {
    local inbound_index=1 # 指定要读取的 inbound 索引 (通常为 fallback inbound)

    # 从脚本配置中获取主域名作为服务器名称
    local server_name
    server_name="$(echo "${SCRIPT_CONFIG}" | jq -r ".nginx.domain")"
    # 从脚本配置中获取 Reality 公钥
    local public_key
    public_key="$(echo "${SCRIPT_CONFIG}" | jq -r ".xray.publicKey")"
    # 从脚本配置中获取 Xray 路径
    local sni_path
    sni_path="$(echo "${SCRIPT_CONFIG}" | jq -r ".xray.path")"
    # 从 Xray 配置中随机获取一个 Reality 的 Short ID
    local short_id
    # 随机索引用 bash 内建 $RANDOM: 这里只是从数组里挑一项, 不是密钥生成;
    #   原实现为此 fork 一次 `bash generate.sh --random` (要重新 source _common.sh)。
    short_id="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" --argjson random "$((RANDOM))" '.inbounds[$i].streamSettings.realitySettings.shortIds | .[$random % length?]')"

    # 使用 Here Document 构造 Reality 下行设置的 JSON 字符串
    XHTTP_EXTRA=$(
        cat <<EOF
{
    "downloadSettings": {
        "address": "${server_name}",
        "port": 443,
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
            "show": false,
            "serverName": "${server_name}",
            "fingerprint": "${SHARE_FP}",
            "publicKey": "${public_key}",
            "shortId": "${short_id}",
            "spiderX": "/"
        },
        "xhttpSettings": {
            "host": "",
            "path": "${sni_path}",
            "mode": "auto"
        }
    }
}
EOF
    )

    # 将生成的 JSON 字符串通过管道传递给 jq 格式化，再传递给 urlencode 进行编码
    XHTTP_EXTRA_ENCODED=$(echo "${XHTTP_EXTRA}" | jq -r '.' | urlencode)
}

# =============================================================================
# 函数名称: show_client_config
# 功能描述: 在终端打印格式化的客户端配置信息。
# 参数: 无 (直接使用全局变量 CLIENT_CONFIG)
# 返回值: 无 (直接打印到标准输出)
# =============================================================================
function show_client_config() {
    # 使用 Here Document 打印客户端配置的标题和各项参数
    cat <<EOF
$(_menu_title "$(_i18n ".${CUR_FILE}.client")(${CLIENT_CONFIG[tag]})")
address          : ${CLIENT_CONFIG[remote_host]}
port             : ${CLIENT_CONFIG[port]}
protocol         : ${CLIENT_CONFIG[protocol]}
uuid             : ${CLIENT_CONFIG[uuid]}
password(trojan) : ${CLIENT_CONFIG[password]}
seed(mKCP)       : ${CLIENT_CONFIG[seed]}
flow             : ${CLIENT_CONFIG[flow]}
network          : ${CLIENT_CONFIG[type]}
security         : ${CLIENT_CONFIG[security]}
ServerName       : ${CLIENT_CONFIG[server_name]}
path             : ${CLIENT_CONFIG[path]}
EOF

    # uTLS 指纹 / PublicKey / ShortId / SpiderX 仅在 TLS 系安全传输下才有取值对象;
    # 明文 (如 mKCP) 配置里打印这些字段会误导使用者去客户端填不存在的项。
    case "${CLIENT_CONFIG[security]:-}" in
    tls)
        echo "Fingerprint      : ${SHARE_FP}"
        ;;
    reality)
        echo "Fingerprint      : ${SHARE_FP}"
        echo "PublicKey        : ${CLIENT_CONFIG[public_key]}"
        echo "ShortId          : ${CLIENT_CONFIG[short_id]}"
        echo "SpiderX          : /"
        ;;
    esac
}

# =============================================================================
# 函数名称: get_share_link_component
# 功能描述: 根据当前 CLIENT_CONFIG 中的参数，生成分享链接的各个组成部分。
#           这些组件可以被后续的特定链接生成函数组合使用。
# 参数: 无 (直接使用全局变量 CLIENT_CONFIG)
# 返回值: 无 (直接修改一系列 SHARE_LINK_COMPONENT_* 全局变量)
# =============================================================================
function get_share_link_component() {
    # 生成 VLESS 协议基础链接部分 (协议://UUID@地址:端口?网络类型=...)
    SHARE_LINK_COMPONENT_VLESS="${CLIENT_CONFIG[protocol]}://${CLIENT_CONFIG[uuid]}@${CLIENT_CONFIG[remote_host]}:${CLIENT_CONFIG[port]}?type=${CLIENT_CONFIG[type]}"
    # 生成 Trojan 协议基础链接部分 (协议://密码@地址:端口?网络类型=...)
    SHARE_LINK_COMPONENT_TROJAN="${CLIENT_CONFIG[protocol]}://${CLIENT_CONFIG[password]}@${CLIENT_CONFIG[remote_host]}:${CLIENT_CONFIG[port]}?type=${CLIENT_CONFIG[type]}"
    # 生成 mKCP 网络传输参数部分 (&seed=...)
    SHARE_LINK_COMPONENT_MKCP="&seed=${CLIENT_CONFIG[seed]}"
    # 生成 TLS 安全传输参数部分 (&security=tls&sni=...&alpn=h2&fp=<SHARE_FP>)
    SHARE_LINK_COMPONENT_TLS="&security=${CLIENT_CONFIG[security]}&sni=${CLIENT_CONFIG[server_name]}&alpn=h2&fp=${SHARE_FP}"
    # 生成 Reality 安全传输参数部分 (&security=reality&sni=...&pbk=...&sid=...&spx=%2F&fp=<SHARE_FP>)
    SHARE_LINK_COMPONENT_REALITY="&security=${CLIENT_CONFIG[security]}&sni=${CLIENT_CONFIG[server_name]}&pbk=${CLIENT_CONFIG[public_key]}&sid=${CLIENT_CONFIG[short_id]}&spx=%2F&fp=${SHARE_FP}"
    # 生成 XHTTP 网络传输路径参数部分 (&path=...), 注意去除路径开头的 '/'
    SHARE_LINK_COMPONENT_XHTTP="&path=%2F${CLIENT_CONFIG[path]#/}"
    # 生成 Flow 控制参数部分 (&flow=...)
    SHARE_LINK_COMPONENT_FLOW="&flow=${CLIENT_CONFIG[flow]}"
    # 生成额外参数部分 (&extra=...), 使用之前编码好的 XHTTP_EXTRA_ENCODED
    SHARE_LINK_COMPONENT_EXTRA="&extra=${XHTTP_EXTRA_ENCODED}"
}

# =============================================================================
# 函数名称: get_mkcp_share_link
# 功能描述: 为 mKCP 网络传输类型生成完整的分享链接。
# 参数: 无 (直接使用全局变量 CLIENT_CONFIG)
# 返回值: 无 (直接修改全局变量 SHARE_LINK)
# =============================================================================
function get_mkcp_share_link() {
    # 获取分享链接的各个组件
    get_share_link_component
    # 将 VLESS 基础部分和 mKCP 参数部分拼接成完整链接
    SHARE_LINK="${SHARE_LINK_COMPONENT_VLESS}${SHARE_LINK_COMPONENT_MKCP}"
}

# =============================================================================
# 函数名称: get_vision_share_link
# 功能描述: 为 Vision (XTLS) + Reality 网络传输类型生成完整的分享链接。
# 参数: 无 (直接使用全局变量 CLIENT_CONFIG)
# 返回值: 无 (直接修改全局变量 SHARE_LINK)
# =============================================================================
function get_vision_share_link() {
    # 获取分享链接的各个组件
    get_share_link_component
    # 将 VLESS 基础部分、Reality 安全参数和 Flow 控制参数拼接成完整链接
    SHARE_LINK="${SHARE_LINK_COMPONENT_VLESS}${SHARE_LINK_COMPONENT_REALITY}${SHARE_LINK_COMPONENT_FLOW}"
}

# =============================================================================
# 函数名称: get_xhttp_share_link
# 功能描述: 为 XHTTP + Reality 网络传输类型生成完整的分享链接。
# 参数: 无 (直接使用全局变量 CLIENT_CONFIG 和 XHTTP_EXTRA)
# 返回值: 无 (直接修改全局变量 SHARE_LINK)
# =============================================================================
function get_xhttp_share_link() {
    # 获取分享链接的各个组件
    get_share_link_component
    # 将 VLESS 基础部分、Reality 安全参数和 XHTTP 路径参数拼接成完整链接
    SHARE_LINK="${SHARE_LINK_COMPONENT_VLESS}${SHARE_LINK_COMPONENT_REALITY}${SHARE_LINK_COMPONENT_XHTTP}"
}

# =============================================================================
# 函数名称: get_trojan_share_link
# 功能描述: 为 Trojan + Reality 网络传输类型生成完整的分享链接。
# 参数: 无 (直接使用全局变量 CLIENT_CONFIG 和 XHTTP_EXTRA)
# 返回值: 无 (直接修改全局变量 SHARE_LINK)
# =============================================================================
function get_trojan_share_link() {
    # 获取分享链接的各个组件
    get_share_link_component
    # 将 Trojan 基础部分、Reality 安全参数和 XHTTP 路径参数拼接成完整链接
    SHARE_LINK="${SHARE_LINK_COMPONENT_TROJAN}${SHARE_LINK_COMPONENT_REALITY}${SHARE_LINK_COMPONENT_XHTTP}"
}

# =============================================================================
# 函数名称: get_fallback_xhttp_share_link
# 功能描述: 为 fallback inbound (通常是 index 1) 生成 XHTTP + Reality 分享链接。
#           这个函数会重新从 Xray 配置中读取 fallback inbound 的安全、服务器名和 Short ID。
# 参数: 无
# 返回值: 无 (直接修改全局变量 CLIENT_CONFIG 和 SHARE_LINK)
# =============================================================================
function get_fallback_xhttp_share_link() {
    local inbound_index=1 # 指定 fallback inbound 的索引

    # 从 Xray 配置中重新读取 fallback inbound 的安全类型
    CLIENT_CONFIG[security]="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" '.inbounds[$i].streamSettings.security? | if . == null then empty else . end')"
    # 从 Xray 配置中重新随机读取 fallback inbound 的服务器名称
    # 随机索引用 bash 内建 $RANDOM: 这里只是从数组里挑一项, 不是密钥生成;
    #   原实现为此 fork 一次 `bash generate.sh --random` (要重新 source _common.sh)。
    CLIENT_CONFIG[server_name]="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" --argjson random "$((RANDOM))" '.inbounds[$i].streamSettings.realitySettings.serverNames | .[$random % length?]')"
    # 从 Xray 配置中重新随机读取 fallback inbound 的 Short ID
    # 随机索引用 bash 内建 $RANDOM: 这里只是从数组里挑一项, 不是密钥生成;
    #   原实现为此 fork 一次 `bash generate.sh --random` (要重新 source _common.sh)。
    CLIENT_CONFIG[short_id]="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" --argjson random "$((RANDOM))" '.inbounds[$i].streamSettings.realitySettings.shortIds | .[$random % length?]')"

    # 调用通用的 XHTTP 链接生成函数
    get_xhttp_share_link
}

# =============================================================================
# 函数名称: get_sni_tls_share_link
# 功能描述: 为 SNI + TLS 网络传输类型生成完整的分享链接。
#           通常用于通过 CDN 域名访问的场景。
# 参数: 无 (直接使用全局变量 CLIENT_CONFIG 和 SCRIPT_CONFIG)
# 返回值: 无 (直接修改全局变量 CLIENT_CONFIG 和 SHARE_LINK)
# =============================================================================
function get_sni_tls_share_link() {
    # 设置安全类型为 tls
    CLIENT_CONFIG[security]="tls"
    # 从脚本配置中读取 CDN 域名作为服务器名称
    CLIENT_CONFIG[server_name]="$(echo "${SCRIPT_CONFIG}" | jq -r ".nginx.cdn")"
    # 将远程主机地址也设置为 CDN 域名
    CLIENT_CONFIG[remote_host]="$(echo "${SCRIPT_CONFIG}" | jq -r ".nginx.cdn")"

    # 获取分享链接的各个组件
    get_share_link_component
    # 将 VLESS 基础部分、TLS 安全参数和 XHTTP 路径参数拼接成完整链接
    SHARE_LINK="${SHARE_LINK_COMPONENT_VLESS}${SHARE_LINK_COMPONENT_TLS}${SHARE_LINK_COMPONENT_XHTTP}"
}

# =============================================================================
# 函数名称: get_sni_tls_down_share_link
# 功能描述: 为 SNI + TLS + 下行模式 (带 extra 参数) 生成完整的分享链接。
# 参数: 无 (直接使用全局变量 XHTTP_EXTRA)
# 返回值: 无 (直接修改全局变量 SHARE_LINK)
# =============================================================================
function get_sni_tls_down_share_link() {
    # 首先获取 fallback 的 XHTTP 链接 (基础部分)
    get_fallback_xhttp_share_link
    # 在基础链接后追加额外的下行参数部分
    SHARE_LINK="${SHARE_LINK}${SHARE_LINK_COMPONENT_EXTRA}"
}

# =============================================================================
# 函数名称: get_sni_reality_down_share_link
# 功能描述: 为 SNI + Reality + 下行模式 (带 extra 参数) 生成完整的分享链接。
# 参数: 无 (直接使用全局变量 XHTTP_EXTRA)
# 返回值: 无 (直接修改全局变量 SHARE_LINK)
# =============================================================================
function get_sni_reality_down_share_link() {
    # 首先获取 SNI + TLS 的链接 (基础部分)
    get_sni_tls_share_link
    # 在基础链接后追加额外的下行参数部分
    SHARE_LINK="${SHARE_LINK}${SHARE_LINK_COMPONENT_EXTRA}"
}

# =============================================================================
# 函数名称: show_config
# 功能描述: 打印完整的客户端配置信息、额外配置 (如果有的话)、
#           最终的分享链接以及对应的二维码。
# 参数: 无 (直接使用全局变量 CLIENT_CONFIG, XHTTP_EXTRA, SHARE_LINK, I18N_MAP)
# 返回值: 无 (直接打印到标准输出)
# =============================================================================
function show_config() {
    # 在分享链接末尾追加标签作为锚点 (例如 #my_tag)
    SHARE_LINK="${SHARE_LINK}#${CLIENT_CONFIG[tag]}"

    # 订阅收集模式: 仅记录节点, 不打印明文、不生成二维码、不写保存文件
    if [[ "${SHARE_COLLECT_ONLY:-0}" -eq 1 ]]; then
        _collect_node
        return 0
    fi

    # 保存模式: 汇总写入 0600 文件, 不在屏幕打印任何密钥/二维码
    if [[ -n "${SHARE_SAVE_FILE}" ]]; then
        {
            show_client_config
            if [[ "${XHTTP_EXTRA}" ]]; then
                _menu_title "$(_i18n ".${CUR_FILE}.extra")"
                echo "${XHTTP_EXTRA}" | jq -r '.'
            fi
            _menu_title "$(_i18n ".${CUR_FILE}.link")"
            echo -e "${SHARE_LINK}"
            _menu_rule
        } >>"${SHARE_SAVE_FILE}"
        return 0
    fi

    # 屏幕模式: 首次输出前提示内容含密钥, 避免录屏/共屏/终端回滚导致泄露
    if [[ "${SHARE_WARNED}" -eq 0 ]]; then
        echo -e "${YELLOW}[$(_i18n ".${CUR_FILE}.warning")]${NC}" >&2
        SHARE_WARNED=1
    fi

    # 显示客户端配置信息
    show_client_config

    # 如果存在额外配置 (XHTTP_EXTRA)，则显示它
    if [[ "${XHTTP_EXTRA}" ]]; then
        _menu_title "$(_i18n ".${CUR_FILE}.extra")"
        # 使用 jq 格式化输出额外配置的 JSON
        echo "${XHTTP_EXTRA}" | jq -r '.'
    fi

    # 显示分享链接
    _menu_title "$(_i18n ".${CUR_FILE}.link")"
    echo -e "${SHARE_LINK}"

    # 显示分享链接的二维码 (需要 qrencode 命令; --no-qr 可跳过)
    if [[ "${SHARE_SHOW_QR}" -eq 1 ]]; then
        # 不可裸调 qrencode: 未安装时它返回 127, 经 set -Eeuo pipefail + ERR trap
        # 会直接中止整个分享流程 —— 二维码仅是附加信息, 不该让主流程失败。
        # 缺失时打印可执行安装建议 (i18n 键 share.qr_missing) 后继续。
        if command -v qrencode >/dev/null 2>&1; then
            _menu_title "$(_i18n ".${CUR_FILE}.qr")"
            echo -e "${SHARE_LINK}" | qrencode -t ansiutf8
        else
            printf "${YELLOW}[%s] ${NC}%s\n" "$(_i18n '.title.warn')" "$(_i18n ".${CUR_FILE}.qr_missing")" >&2
        fi
    fi

    # 打印分隔线结束
    _menu_rule
}

# =============================================================================
# 函数名称: show_fallback_config
# 功能描述: 为 "fallback" 配置模式生成并显示多组客户端配置和链接。
#           包括 fallback 的 Vision 链接和 XHTTP 链接。
# 参数: 无
# 返回值: 无 (调用其他函数进行显示)
# =============================================================================
function show_fallback_config() {
    # 设置第一个配置的标签为 'fallbak_vision_reality'
    CLIENT_CONFIG[tag]='fallbak_vision_reality'
    # 生成 Vision 分享链接
    get_vision_share_link
    # 显示第一个配置
    show_config

    # 重新获取第二个 inbound (index 2) 的通用配置
    get_common_config 2
    # 设置第二个配置的标签为 'fallbak_xhttp_reality'
    CLIENT_CONFIG[tag]='fallbak_xhttp_reality'
    # 生成 fallback 的 XHTTP 分享链接
    get_fallback_xhttp_share_link
}

# =============================================================================
# 函数名称: show_sni_config
# 功能描述: 为 "sni" 配置模式生成并显示多组客户端配置和链接。
#           包括 SNI Vision, SNI XHTTP, SNI TLS Down, SNI XHTTP CDN, SNI Reality Down。
# 参数: 无
# 返回值: 无 (调用其他函数进行显示)
# =============================================================================
function show_sni_config() {
    # SNI 模式的 5 组配置按固定顺序展示。每组抽成 _sni_block_* 便于单读单改,
    # 本编排器只保留"有哪几组、什么顺序"这一层信息。
    # 注: 第 5 组 (reality_down) 不在此处 show_config —— 其调用方 (见本文件底部
    #     `sni) show_sni_config; show_config ;;`) 会在本函数返回后统一补一次展示。
    _sni_block_vision_reality
    _sni_block_xhttp_reality
    _sni_block_tls_down
    _sni_block_xhttp_cdn
    _sni_block_reality_down
}

# 组 1: SNI Vision Reality —— 直接使用当前 CLIENT_CONFIG, 不重取 common
function _sni_block_vision_reality() {
    CLIENT_CONFIG[tag]='sni_vision_reality'
    get_vision_share_link
    show_config
}

# 组 2: SNI XHTTP Reality
function _sni_block_xhttp_reality() {
    get_common_config 2
    CLIENT_CONFIG[tag]='sni_xhttp_reality'
    get_fallback_xhttp_share_link
    show_config
}

# 组 3: SNI TLS Down
function _sni_block_tls_down() {
    get_common_config 2
    CLIENT_CONFIG[tag]='sni_tls_down'
    get_tls_down_json
    get_sni_tls_down_share_link
    show_config
}

# 组 4: SNI XHTTP CDN
function _sni_block_xhttp_cdn() {
    get_common_config 2
    CLIENT_CONFIG[tag]='sni_xhttp_cdn'
    XHTTP_EXTRA=""
    get_sni_tls_share_link
    show_config
}

# 组 5: SNI Reality Down —— 由调用方补 show_config, 故此处不调
function _sni_block_reality_down() {
    get_common_config 2
    CLIENT_CONFIG[tag]='sni_reality_down'
    get_reality_down_json
    get_sni_reality_down_share_link
}

# =============================================================================
# 函数名称: _collect_node
# 功能描述: 把当前 CLIENT_CONFIG (已含 #tag 的完整 SHARE_LINK) 序列化为一条节点记录,
#           追加进 SHARE_LINKS 与 SHARE_NODES_JSON。仅在 SHARE_COLLECT_ONLY=1 时由
#           show_config 调用。XHTTP 下行加速的 extra JSON (Xray 专有) 一并保留,
#           供 base64 链接携带; Clash/sing-box 只重建主连接, 不表示 extra。
# 参数: 无 (直接使用全局变量 CLIENT_CONFIG / SHARE_LINK / XHTTP_EXTRA / SHARE_FP)
# 返回值: 无 (修改全局数组与字符串)
# =============================================================================
function _collect_node() {
    local user="${CLIENT_CONFIG[uuid]:-${CLIENT_CONFIG[password]}}"
    # port 走 --argjson 是为了让产物里的端口是 JSON 数字而非字符串; 代价是它必须是
    # 合法字面量 —— 空串或非数字会让 jq 直接报 "Invalid numeric literal" 失败,
    # 进而在 set -e 下中断整轮订阅生成 (用户看到的是"生成失败"而非"端口没配").
    # 故先做数字守卫, 取不到就退回 443 (本项目默认端口), 保证产物始终能生成。
    local port="${CLIENT_CONFIG[port]:-}"
    [[ "${port}" =~ ^[0-9]+$ ]] || port=443
    local node_json
    node_json="$(jq -nc \
        --arg scheme "${CLIENT_CONFIG[protocol]}" \
        --arg user "${user}" \
        --arg host "${CLIENT_CONFIG[remote_host]}" \
        --argjson port "${port}" \
        --arg type "${CLIENT_CONFIG[type]}" \
        --arg security "${CLIENT_CONFIG[security]}" \
        --arg sni "${CLIENT_CONFIG[server_name]}" \
        --arg pbk "${CLIENT_CONFIG[public_key]}" \
        --arg sid "${CLIENT_CONFIG[short_id]}" \
        --arg fp "${SHARE_FP}" \
        --arg flow "${CLIENT_CONFIG[flow]}" \
        --arg path "${CLIENT_CONFIG[path]}" \
        --arg seed "${CLIENT_CONFIG[seed]}" \
        --arg tag "${CLIENT_CONFIG[tag]}" \
        --arg link "${SHARE_LINK}" \
        --argjson extra "${XHTTP_EXTRA:-null}" \
        '{scheme:$scheme,user:$user,host:$host,port:$port,type:$type,security:$security,sni:$sni,pbk:$pbk,sid:$sid,fp:$fp,flow:$flow,path:$path,seed:$seed,tag:$tag,link:$link,extra:($extra)}')"
    SHARE_LINKS+=("${SHARE_LINK}")
    SHARE_NODES_JSON+="${node_json}"$'\n'
}

# =============================================================================
# 函数名称: clash_build_proxy
# 功能描述: 由一条节点 JSON 生成 Clash (mihomo) 的 proxy 列表项 YAML, 追加进
#           CLASH_PROXIES 与 CLASH_NAMES。 transport 覆盖本脚本实际产出的 tcp/xhttp/kcp。
# 参数: $1 节点 JSON (来自 SHARE_NODES_JSON 的一行)
# 返回值: 无 (修改全局 CLASH_PROXIES / CLASH_NAMES)
# =============================================================================
function clash_build_proxy() {
    local n="$1"
    local nl=$'\n'
    # 一次 jq 取完 13 个字段 (原为 13 次 `jq -r '.x' <<<"$n"`): 订阅按节点逐个调本函数,
    # 5 节点就是 65 次 fork, 在低配 VPS 上是可感知的卡顿。分隔与读取方式同 get_common_config
    # (\x1f 而非 tab: tab 属 IFS 空白, 空字段会被 read 合并掉导致后续字段串位)。
    local row=''
    row="$(jq -r '[ .tag, .scheme, .user, .host, .port, .type, .security, .sni, .pbk, .sid, .fp, .flow, .path, .seed ] | map(. // "" | tostring) | join("\u001f")' <<<"${n}")"
    local name='' scheme='' user='' host='' port='' type='' security='' sni='' pbk='' sid='' fp='' flow='' path='' seed=''
    IFS=$'\x1f' read -r name scheme user host port type security sni pbk sid fp flow path seed <<<"${row}"

    # 注: 双引号串里的 "\n" 是字面反斜杠-n, 必须用 ANSI-C 引号 $'\n' 才表示真实换行,
    #      否则整段 proxy 会被压成一行含字面 \n 的文本, Clash YAML 直接拒读。
    local blk="  - name: \"${name}\"${nl}"
    if [[ "${scheme}" == "trojan" ]]; then
        blk+="    type: trojan${nl}"
        blk+="    server: ${host}${nl}"
        blk+="    port: ${port}${nl}"
        blk+="    password: \"${user}\"${nl}"
    else
        blk+="    type: vless${nl}"
        blk+="    server: ${host}${nl}"
        blk+="    port: ${port}${nl}"
        blk+="    uuid: \"${user}\"${nl}"
    fi
    blk+="    network: ${type}${nl}"
    blk+="    udp: true${nl}"

    case "${security}" in
    reality)
        [[ "${scheme}" == "trojan" ]] || blk+="    tls: true${nl}"
        blk+="    servername: ${sni}${nl}"
        blk+="    client-fingerprint: ${fp}${nl}"
        blk+="    reality-opts:${nl}"
        blk+="      public-key: \"${pbk}\"${nl}"
        blk+="      short-id: \"${sid}\"${nl}"
        ;;
    tls)
        [[ "${scheme}" == "trojan" ]] || blk+="    tls: true${nl}"
        blk+="    servername: ${sni}${nl}"
        blk+="    client-fingerprint: ${fp}${nl}"
        blk+="    alpn:${nl}      - h2${nl}"
        ;;
    *)
        # none: mKCP 等无 TLS 的传输, 不加 tls/reality
        ;;
    esac

    [[ -n "${flow}" ]] && blk+="    flow: ${flow}${nl}"

    case "${type}" in
    xhttp)
        blk+="    xhttp-opts:${nl}"
        blk+="      host: ${sni}${nl}"
        blk+="      path: ${path:-/}${nl}"
        blk+="      mode: auto${nl}"
        ;;
    kcp)
        blk+="    kcp-opts:${nl}"
        blk+="      seed: ${seed}${nl}"
        ;;
    esac

    CLASH_PROXIES+="${blk}"
    CLASH_NAMES+=("${name}")
}

# =============================================================================
# 函数名称: singbox_build_outbound
# 功能描述: 由一条节点 JSON 生成 sing-box 的 outbound JSON, 追加进 SINGBOX_OUTBOUNDS。
#           sing-box 无 mKCP 传输, 该类型节点跳过并计数 (SINGBOX_SKIP)。
# 参数: $1 节点 JSON
# 返回值: 无 (修改全局 SINGBOX_OUTBOUNDS / SINGBOX_SKIP)
# =============================================================================
function singbox_build_outbound() {
    local n="$1"
    # 一次 jq 取完 13 个字段 (原为 4 次 + 构造时内嵌 9 次命令替换 = 13 次 fork, 且这部分
    # 每节点都要跑一遍)。分隔/读取方式同 get_common_config (\x1f 而非 tab)。
    local row=''
    row="$(jq -r '[ .scheme, .type, .security, (.port // ""), .tag, .host, .user, .sni, .fp, .flow, .pbk, .sid, .path ] | map(. // "" | tostring) | join("\u001f")' <<<"${n}")"
    local scheme='' type='' security='' nport='' ntag='' nhost='' nuser='' nsni='' nfp='' nflow='' npbk='' nsid='' npath=''
    IFS=$'\x1f' read -r scheme type security nport ntag nhost nuser nsni nfp nflow npbk nsid npath <<<"${row}"

    # sing-box 无 mKCP 传输, 跳过并计数
    if [[ "${type}" == "kcp" ]]; then
        SINGBOX_SKIP=$((SINGBOX_SKIP + 1))
        return 0
    fi

    # 端口守卫 (与 _collect_node 同源问题): 节点 JSON 里的 port 可能是空串或非数字,
    # 直接喂给 --argjson 会让 jq 解析失败并中断整个 sing-box 订阅生成。
    # 注: 值为 null 时 jq -r 输出字面 null, --argjson 能接受; 但空串不行, 故统一守卫。
    [[ "${nport}" =~ ^[0-9]+$ ]] || nport=443

    local obj
    obj="$(jq -nc \
        --arg scheme "${scheme}" \
        --arg tag "${ntag}" \
        --arg host "${nhost}" \
        --argjson port "${nport}" \
        --arg user "${nuser}" \
        --arg sni "${nsni}" \
        --arg fp "${nfp}" \
        --arg flow "${nflow}" \
        --arg pbk "${npbk}" \
        --arg sid "${nsid}" \
        --arg path "${npath}" \
        --arg type "${type}" \
        --arg security "${security}" \
        '
        (if $scheme == "trojan" then
            {type:"trojan", tag:$tag, server:$host, server_port:$port, password:$user}
         else
            {type:"vless", tag:$tag, server:$host, server_port:$port, uuid:$user}
            + (if $flow != "" then {flow:$flow} else {} end)
         end)
        +
        (if $security == "none" then {} else
            {tls:(
                {enabled:true, server_name:$sni, utls:{enabled:true, fingerprint:$fp}}
                + (if $security == "reality"
                    then {reality:{enabled:true, public_key:$pbk, short_id:$sid}}
                    else {alpn:["h2"]} end)
            )}
         end)
        +
        (if $type == "xhttp"
            then {transport:{type:"xhttp", path:($path|if . == "" then "/" else . end), host:$sni, mode:"auto"}}
            else {} end)
        ')"
    SINGBOX_OUTBOUNDS+="${obj}"$'\n'
}

# =============================================================================
# 函数名称: _clash_template
# 功能描述: 用 CLASH_PROXIES / CLASH_NAMES 拼出完整 Clash YAML (含 proxy-groups/rules)。
# 参数: 无
# 返回值: 通过 stdout 输出完整 YAML 文本
# =============================================================================
function _clash_template() {
    local group_list='' nm
    for nm in "${CLASH_NAMES[@]}"; do
        group_list+="      - \"${nm}\""$'\n'
    done
    cat <<EOF
port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
external-controller: 127.0.0.1:9090
dns:
  enable: false
proxies:
${CLASH_PROXIES}proxy-groups:
  - name: "♻️ 自动选择"
    type: url-test
    url: https://www.gstatic.com/generate_204
    interval: 300
    proxies:
${group_list}  - name: "🚀 节点选择"
    type: select
    proxies:
      - "♻️ 自动选择"
${group_list}      - DIRECT
rules:
  - GEOIP,CN,DIRECT
  - MATCH,🚀 节点选择
EOF
}

# =============================================================================
# 函数名称: _singbox_template
# 功能描述: 用 SINGBOX_OUTBOUNDS 拼出完整 sing-box JSON (outbounds + 基础 route)。
# 参数: 无
# 返回值: 通过 stdout 输出格式化后的 JSON 文本
# =============================================================================
function _singbox_template() {
    local arr
    arr="$(printf '%s\n' "${SINGBOX_OUTBOUNDS}" | jq -s '.')"
    jq -c --argjson arr "${arr}" '{
        outbounds: ($arr + [{type:"direct",tag:"direct"},{type:"block",tag:"block"}]),
        route: {rules:[
            {outbound:"direct", geoip:"private"},
            {outbound:"direct", geosite:"cn"},
            {outbound:"block", domain_suffix:["doubleclick.net","googletagmanager.com"]}
        ]}
    }' <<<'{}' | jq '.'
}

# =============================================================================
# 函数名称: subscription_report
# 功能描述: 打印订阅生成结果摘要 (文件路径 + 节点数 + 局限说明 + 密钥提醒)。
# 参数: $1 base64 文件路径 $2 Clash 文件路径 $3 sing-box 文件路径
#       $4 节点数 $5 sing-box 跳过的节点数
# 返回值: 无 (打印到标准输出)
# =============================================================================
function subscription_report() {
    local b64_file="$1" clash_file="$2" sb_file="$3" n="$4" skip="$5"
    local t=''
    _menu_title "$(_i18n ".${CUR_FILE}.subscription.title")"
    t="$(_i18n ".${CUR_FILE}.subscription.nodes")"; echo -e "${t//\{n\}/$n}"
    t="$(_i18n ".${CUR_FILE}.subscription.base64")"; echo -e "${t//\{path\}/$b64_file}"
    t="$(_i18n ".${CUR_FILE}.subscription.clash")"; echo -e "${t//\{path\}/$clash_file}"
    t="$(_i18n ".${CUR_FILE}.subscription.singbox")"; echo -e "${t//\{path\}/$sb_file}"
    echo -e "$(_i18n ".${CUR_FILE}.subscription.limit")"
    if [[ "${skip}" -gt 0 ]]; then
        t="$(_i18n ".${CUR_FILE}.subscription.skip")"; echo -e "${t//\{n\}/$skip}"
    fi
    echo -e "${YELLOW}$( _i18n ".${CUR_FILE}.subscription.secret")${NC}"
    _menu_rule
}

# =============================================================================
# 函数名称: build_subscriptions
# 功能描述: 把收集到的节点构建为三种订阅并原子写入 SCRIPT_CONFIG_DIR (权限 0600)。
#           base64 用原始分享链接 (保留 XHTTP extra); Clash/sing-box 由结构化字段重建。
# 参数: 无 (使用全局 SHARE_LINKS / SHARE_NODES_JSON)
# 返回值: 无
# =============================================================================
function build_subscriptions() {
    local out_dir="${SCRIPT_CONFIG_DIR}"
    local b64_file="${out_dir}/subscription-base64.txt"
    local clash_file="${out_dir}/subscription-clash.yaml"
    local sb_file="${out_dir}/subscription-singbox.json"
    mkdir -p "${out_dir}" 2>/dev/null || true

    # 1) base64 订阅 (v2rayN/NekoBox/FoXray 通用): 链接换行拼接后 base64, 去换行保证单行
    local b64=''
    if [[ ${#SHARE_LINKS[@]} -gt 0 ]]; then
        b64="$(printf '%s\n' "${SHARE_LINKS[@]}" | base64 | tr -d '\n')"
    fi
    printf '%s\n' "${b64}" | _atomic_write "${b64_file}"

    # 2) Clash YAML
    CLASH_PROXIES=''
    CLASH_NAMES=()
    local n
    while IFS= read -r n; do
        [[ -z "${n}" ]] && continue
        clash_build_proxy "${n}"
    done <<<"${SHARE_NODES_JSON}"
    printf '%s\n' "$(_clash_template)" | _atomic_write "${clash_file}"

    # 3) sing-box JSON (mKCP 不可表示, 跳过并计数)
    SINGBOX_OUTBOUNDS=''
    SINGBOX_SKIP=0
    while IFS= read -r n; do
        [[ -z "${n}" ]] && continue
        singbox_build_outbound "${n}"
    done <<<"${SHARE_NODES_JSON}"
    printf '%s\n' "$(_singbox_template)" | _atomic_write "${sb_file}"

    subscription_report "${b64_file}" "${clash_file}" "${sb_file}" "${#SHARE_LINKS[@]}" "${SINGBOX_SKIP}"
}

# =============================================================================
# 函数名称: _build_subscription_link
# 功能描述: 根据当前 CLIENT_CONFIG 的协议/网络/安全特征, 用通用组件组装一条分享链接。
#           覆盖 vless/trojan × tcp/xhttp/kcp × reality/tls/none 的全部组合,
#           与既有 get_vision/xhttp/trojan/mkcp_share_link 产出一致, 供订阅遍历复用。
# 参数: 无 (直接使用全局变量 CLIENT_CONFIG / SHARE_LINK_COMPONENT_*)
# 返回值: 无 (修改全局变量 SHARE_LINK)
# =============================================================================
function _build_subscription_link() {
    get_share_link_component
    local base
    case "${CLIENT_CONFIG[protocol]}" in
        trojan) base="${SHARE_LINK_COMPONENT_TROJAN}" ;;
        *) base="${SHARE_LINK_COMPONENT_VLESS}" ;;
    esac
    SHARE_LINK="${base}"
    # mKCP 传输层 (&seed=)
    if [[ "${CLIENT_CONFIG[type]:-}" == "kcp" ]]; then SHARE_LINK+="${SHARE_LINK_COMPONENT_MKCP}"; fi
    # 安全层 (reality / tls)
    case "${CLIENT_CONFIG[security]:-}" in
        reality) SHARE_LINK+="${SHARE_LINK_COMPONENT_REALITY}" ;;
        tls) SHARE_LINK+="${SHARE_LINK_COMPONENT_TLS}" ;;
    esac
    # XHTTP 路径层 (&path=)
    if [[ "${CLIENT_CONFIG[type]:-}" == "xhttp" ]]; then SHARE_LINK+="${SHARE_LINK_COMPONENT_XHTTP}"; fi
    # Flow 控制层 (&flow=) —— 用 if 而非 &&, 避免空 flow 时函数以非 0 退出 (set -e 下触发调用处 abort)
    if [[ -n "${CLIENT_CONFIG[flow]:-}" ]]; then SHARE_LINK+="${SHARE_LINK_COMPONENT_FLOW}"; fi
}

# =============================================================================
# 函数名称: _subscription_collect_all_inbounds
# 功能描述: 订阅模式下通用遍历 XRAY_CONFIG 的全部入站, 逐条读取配置并收集为节点。
#           fallback/sni 模式不走此函数 (它们各自的 show_*_config 已聚合多入站);
#           其余模式 (含自定义多入站) 均经此覆盖, 避免丢节点。
# 参数: 无
# 返回值: 无 (循环调用 get_common_config / _build_subscription_link / show_config)
# =============================================================================
function _subscription_collect_all_inbounds() {
    local inbound_count i tag
    inbound_count="$(echo "${XRAY_CONFIG}" | jq -r '(.inbounds | length) // 0')"
    # 0-based 遍历全部入站 (jq 数组下标); 非客户端入站 (dokodemo-door 等) 由下方协议过滤跳过
    for ((i = 0; i < inbound_count; i++)); do
        get_common_config "$i"
        # 仅处理可生成客户端节点的入站 (vless / trojan)
        case "${CLIENT_CONFIG[protocol]:-}" in
            vless | trojan) ;;
            *) continue ;;
        esac
        # 节点名: 优先用入站自身 tag, 否则回退 ${modeTag}-${i} 保证唯一 (避免多入站重名)。
        # tag 已由 get_common_config 一并取出 (CLIENT_CONFIG[inbound_tag]), 这里不再单独 fork jq
        tag="${CLIENT_CONFIG[inbound_tag]:-}"
        [[ -z "${tag}" ]] && tag="${CLIENT_CONFIG[tag]}-$((i + 1))"
        CLIENT_CONFIG[tag]="${tag}"
        _build_subscription_link
        show_config
    done
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
#           1. 加载国际化数据。
#           2. 缓存配置文件数据。
#           3. 获取第一个 inbound (index 1) 的通用配置。
#           4. 根据脚本配置中的 tag 值，选择相应的链接生成函数。
#           5. 调用 show_config 显示最终结果。
# 参数:
#   $@: 所有命令行参数 (--save / --save=<路径> / --no-qr / --subscription,
#       详见 main() 的参数解析; 另支持环境变量 XRAY_SCRIPT_SHARE_FILE 指定落盘路径)
# 返回值: 无 (协调调用其他函数完成整个流程)
# =============================================================================
function main() {
    # 解析参数: --save[=路径] 保存到 0600 文件; --no-qr 不显示二维码
    local arg=''
    for arg in "$@"; do
        case "${arg}" in
        --save) SHARE_SAVE_FILE="${SCRIPT_CONFIG_DIR}/share-link.txt" ;;
        --save=*) SHARE_SAVE_FILE="${arg#--save=}" ;;
        --no-qr) SHARE_SHOW_QR=0 ;;
        --subscription) SHARE_SUBSCRIPTION=1 ;;  # 生成 base64/Clash/sing-box 订阅
        esac
    done
    # 环境变量兜底 (便于从菜单或自动化中启用保存模式, 无需改动调用链)
    if [[ -z "${SHARE_SAVE_FILE}" && -n "${XRAY_SCRIPT_SHARE_FILE:-}" ]]; then
        SHARE_SAVE_FILE="${XRAY_SCRIPT_SHARE_FILE}"
    fi

    # 加载国际化数据 (指纹非法值告警依赖 I18N_MAP, 必须先于 resolve_share_fp)
    load_i18n

    # 解析客户端 uTLS 指纹 (默认 chrome, 可用环境变量 XRAY_SCRIPT_FP 覆盖)
    resolve_share_fp

    # 缓存 Xray 和脚本配置数据
    cache_json_data

    # 订阅模式: 仅收集节点并生成三种订阅文件, 全程不打印明文/二维码
    if [[ "${SHARE_SUBSCRIPTION:-0}" -eq 1 ]]; then
        SHARE_COLLECT_ONLY=1
        # fallback/sni 的聚合函数以 CLIENT_CONFIG 已填好首个 inbound 为前提 (display 模式由本函数
        # 末尾"获取第一个 inbound"处的 `get_common_config 1` 预填), 订阅分支提前返回，
        # 故在此同样预填一次, 保证首节点字段正确。
        get_common_config 1
        case "$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag | ascii_downcase')" in
        # fallback/sni 的聚合函数内部逐条 show_config (collect 模式即收集节点), 但末尾会
        # "只生成最后一条链接而不 show_config" —— display 模式由 main 末尾的 show_config 兜底显示;
        # 订阅模式在下方提前 return, 够不到那里, 故在此显式补收一条, 与 display 模式节点数对齐。
        fallback) show_fallback_config; show_config ;; # Fallback 模式 (2 入站)
        sni) show_sni_config; show_config ;;           # SNI 模式 (5 配置)
        *)
            # 简单模式 (vision/trojan/xhttp/mkcp 等): 通用遍历全部入站, 逐条生成节点,
            # 自定义/多入站配置也不会丢节点; fallback/sni 已各自聚合, 此处不重复处理
            _subscription_collect_all_inbounds
            ;;
        esac
        build_subscriptions
        return 0
    fi

    # 保存模式: 预先以 0600 创建输出文件, 避免明文先按默认权限落盘
    # 注: umask 只在子 shell 内生效, 不影响脚本其余部分创建的目录/文件。
    if [[ -n "${SHARE_SAVE_FILE}" ]]; then
        # 拒绝写入已存在的符号链接: 本脚本以 root 运行, 而 `: >文件` 这类重定向会
        # **跟随**符号链接把它指向的目标文件截断清零 —— 传一个被预置的链接路径,
        # 就能借本脚本的权限清空机器上任意文件。正常用法下这里应当是新建文件。
        if [[ -L "${SHARE_SAVE_FILE}" ]]; then
            echo -e "${RED}[$(_i18n_sub ".${CUR_FILE}.save_symlink_refused" '${path}' "${SHARE_SAVE_FILE}")]${NC}" >&2
            exit 1
        fi
        # 父目录同样按 0700 创建: 默认 umask 下会生成可被任意用户遍历的目录,
        # 即便文件本身是 0600, 也不该把"有哪些分享文件"暴露给同机其它用户。
        (umask 077 && mkdir -p "$(dirname "${SHARE_SAVE_FILE}")") 2>/dev/null
        if ! (umask 077 && : >"${SHARE_SAVE_FILE}"); then
            echo -e "${RED}[$(_i18n_sub ".${CUR_FILE}.fail_save" '${path}' "${SHARE_SAVE_FILE}")]${NC}" >&2
            exit 1
        fi
        # 显式再收紧一次权限 (与 _atomic_write 的落盘约定一致, 不依赖环境 umask)
        chmod 600 "${SHARE_SAVE_FILE}"
    fi

    # 获取第一个 inbound (index 1) 的通用配置
    get_common_config 1

    # 根据脚本配置中的 tag (转换为小写) 选择不同的处理分支
    case "$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag | ascii_downcase')" in
    mkcp) get_mkcp_share_link ;;      # mKCP 模式
    xhttp) get_xhttp_share_link ;;    # XHTTP 模式
    trojan) get_trojan_share_link ;;  # Trojan 模式
    fallback) show_fallback_config ;; # Fallback 模式
    sni) show_sni_config ;;           # SNI 模式
    *) get_vision_share_link ;;       # 默认为 Vision 模式
    esac

    # 显示最终的配置和链接信息 (重定向到标准错误输出 >&2，虽然不太常见)
    # 保存模式下 show_config 会改为写入文件, 屏幕不出现明文
    show_config >&2

    # 保存模式: 仅提示输出文件位置 (权限已收紧为 0600)
    if [[ -n "${SHARE_SAVE_FILE}" ]]; then
        echo -e "$(_i18n_sub ".${CUR_FILE}.saved" '${path}' "${SHARE_SAVE_FILE}")" >&2
    fi
}

# --- 脚本执行入口 ---
# 将脚本接收到的所有参数传递给 main 函数开始执行
main "$@"
