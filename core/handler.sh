#!/usr/bin/env bash
#
# Copyright (C) 2026 crudguy
#
# xray-script-personal-use-only:
#   https://github.com/crudguy/xray-script-personal-use-only
# =============================================================================
# 脚本名称: handler.sh
# 功能描述: xray-script-personal-use-only 项目的处理器脚本。
#           负责执行具体的操作，如安装/卸载 Xray/Nginx、配置文件生成、
#           启动/停止服务、管理 Docker 容器、处理路由规则等。
#           由 main.sh 调用，根据传入参数执行相应功能。
# 作者: crudguy
# 时间: 2026-09-19
# 版本: 1.0.0
# 依赖: bash, jq, curl, systemctl, crontab, sed, awk, grep, cut, tr
# 配置:
#   - ${SCRIPT_CONFIG_DIR}/config.json: 读取和写入脚本配置 (如版本、域名、密钥等)
#   - ${I18N_DIR}/${lang}.json: 用于读取具体的提示文本 (i18n 数据文件)
#   - ${CONFIG_DIR}/xray/*.json: 读取 Xray 配置模板
#   - ${CONFIG_DIR}/nginx/conf/*: 读取 Nginx 配置模板
#   - /usr/local/etc/xray/config.json: 读取和写入 Xray 最终配置文件
#   - /usr/local/nginx/conf/*: 读取和写入 Nginx 最终配置文件
#   - ${HOME}/.acme.sh/: 读取和写入 SSL 证书相关文件
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

# 定义项目内相关目录和脚本的路径
readonly SERVICE_DIR="${PROJECT_ROOT}/service"    # 服务管理脚本目录
readonly TOOL_DIR="${PROJECT_ROOT}/tool"          # 工具脚本目录
readonly SCRIPT_XRAY_DIR="${CONFIG_DIR}/xray"     # Xray 配置模板目录
# Nginx 安装前缀 (与 service/nginx.sh 的 --prefix 保持一致); 配置目录位于该前缀内
readonly NGINX_PREFIX_DIR="/usr/local/nginx"         # Nginx 安装前缀
readonly NGINX_CONFIG_DIR="${NGINX_PREFIX_DIR}/conf" # Nginx 配置目录 (目标路径)
# 定义项目内子脚本的路径
readonly GENERATE_PATH="${CUR_DIR}/generate.sh" # 生成器脚本
readonly CHECK_PATH="${CUR_DIR}/check.sh"       # 检查器脚本
readonly SHARE_PATH="${CUR_DIR}/share.sh"       # 分享链接生成脚本
readonly READ_PATH="${CUR_DIR}/read.sh"         # 用户输入读取脚本
# 注意: 这里的 NGINX_PATH 是「Nginx 服务管理脚本的文件路径」, 而 service/nginx.sh
#       里的同名 NGINX_PATH 是「Nginx 安装目录」—— 同名不同义, 极易误改。
#       本文件只用 NGINX_PATH 调用 `bash "${NGINX_PATH}" --xxx`; 涉及安装路径时
#       一律用 NGINX_PREFIX_DIR (与 core/_common.sh 的 _nginx_binary 同源)。
readonly NGINX_PATH="${SERVICE_DIR}/nginx.sh"   # Nginx 服务管理脚本 (非安装目录!)
readonly SSL_PATH="${SERVICE_DIR}/ssl.sh"       # SSL 证书管理脚本
readonly DOCKER_PATH="${SERVICE_DIR}/docker.sh" # Docker 容器管理脚本
readonly TRAFFIC_PATH="${TOOL_DIR}/traffic.sh"  # 流量统计脚本
readonly GEODATA_PATH="${TOOL_DIR}/geodata.sh"  # GeoData 更新脚本
readonly BACKUP_PATH="${TOOL_DIR}/backup.sh"    # 配置导出/导入脚本
# 定义外部配置文件和脚本的路径
readonly XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"    # Xray 最终配置文件路径
readonly ACME_PATH="${HOME}/.acme.sh/acme.sh"                  # ACME.sh 脚本路径

# --- 全局变量声明 ---
# 声明用于存储配置数据和国际化数据的全局变量
declare SCRIPT_CONFIG
SCRIPT_CONFIG="$(jq '.' "${SCRIPT_CONFIG_PATH}" || true)" # 存储从 config.json 读取的脚本配置
declare XRAY_CONFIG=""                                    # 存储 Xray 配置 (通常在运行时加载)
# 声明一个关联数组，用于在脚本运行时临时存储用户输入的配置数据
declare -A CONFIG_DATA # 用于临时存储用户输入的配置数据

# --- 第三方引导脚本固定版本 (供应链防篡改) ---
# XTLS install-release.sh: 固定到经验证的 commit, 并锁定其 SHA256 做逐字节校验,
# 避免上游 main 分支被替换/投毒时静默执行恶意脚本。
# 跟随上游最新版本时: 设 XRAY_INSTALL_REF=main 且 XRAY_INSTALL_SHA256= (置空即跳过摘要比对)。
declare XRAY_INSTALL_REF="${XRAY_INSTALL_REF-e741a4f56d368afbb9e5be3361b40c4552d3710d}"
declare XRAY_INSTALL_URL="${XRAY_INSTALL_URL-https://raw.githubusercontent.com/XTLS/Xray-install/${XRAY_INSTALL_REF}/install-release.sh}"
declare XRAY_INSTALL_SHA256="${XRAY_INSTALL_SHA256-7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555}"


# =============================================================================
# 函数名称: _error
# 功能描述: 打印错误信息到标准错误输出并退出脚本。
# 参数:
#   $@: 要输出的错误信息文本
# 返回值: 无 (直接打印到标准错误输出 >&2 并退出)
# 退出码: 1
# =============================================================================
function _error() {
    # $1=错误消息; $2=可选的可执行建议 (非空时以 [建议] 追加一行到 stderr)
    local msg="${1:-}" hint="${2:-}"
    printf "${RED}[%s] ${NC}%s\n" "$(_i18n '.title.error')" "${msg}" >&2
    if [[ -n "${hint}" ]]; then
        printf "${YELLOW}[%s] ${NC}%s\n" "$(_i18n '.title.hint')" "${hint}" >&2
    fi
    exit 1
}

# --- 审计留痕 ---
# 关键操作 (安装/卸载/启停/证书) 追加到审计日志并同步 syslog, 供无人值守场景事后回溯。
# 只记录动作与时间, 不写入密钥/口令/邮箱等敏感内容。
readonly AUDIT_LOG_PATH="${SCRIPT_CONFIG_DIR}/audit.log"

# =============================================================================
# 函数名称: _audit_log
# 功能描述: 追加一条审计记录 (文件 + syslog 双写)。任何写入失败都不阻断主流程。
# 参数:
#   $1: 动作名 (如 install / purge / start)
#   $2: 补充说明 (可选)
# 返回值: 恒为 0
# =============================================================================
function _audit_log() {
    local action="${1:-}"
    local detail="${2:-}"
    local who=''
    local record=''
    # 动作为空时不记录
    [[ -n "${action}" ]] || return 0
    # 取当前用户 (USER 未设置时回退到 id -un)
    who="${USER:-}"
    if [[ -z "${who}" ]]; then
        who="$(id -un 2>/dev/null || echo unknown)"
    fi
    # 组装记录: 时间 | 用户 | PID | 动作 | 说明
    record="$(printf '%s | user=%s | pid=%s | %s%s' \
        "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${who}" "$$" \
        "${action}" "${detail:+ | ${detail}}")"
    # 落盘: 首次创建后收紧为 600 (日志只含操作元数据)
    (umask 077 && mkdir -p "${SCRIPT_CONFIG_DIR}") 2>/dev/null || true
    if [[ ! -e "${AUDIT_LOG_PATH}" ]]; then
        { : >"${AUDIT_LOG_PATH}"; } 2>/dev/null && chmod 600 "${AUDIT_LOG_PATH}" 2>/dev/null || true
    fi
    printf '%s\n' "${record}" >>"${AUDIT_LOG_PATH}" 2>/dev/null || true
    # 同步 syslog (系统无 logger 命令时静默跳过)
    if command -v logger >/dev/null 2>&1; then
        logger -t xray-script-personal-use-only "${record}" 2>/dev/null || true
    fi
    return 0
}

# =============================================================================
# 函数名称: exec_generate
# 功能描述: 执行 generate.sh 脚本，用于生成 UUID、密码、密钥等。
# 参数:
#   $@: 传递给 generate.sh 脚本的参数
# 返回值: generate.sh 脚本的输出 (echo 输出)
# =============================================================================
function exec_generate() {
    # 执行 generate.sh 脚本，并传递所有参数
    bash "${GENERATE_PATH}" "$@"
}

# =============================================================================
# 函数名称: exec_docker
# 功能描述: 执行 docker.sh 脚本，用于管理 Docker 相关操作。
#           如果执行失败，则退出当前脚本。
# 参数:
#   $@: 传递给 docker.sh 脚本的参数
# 返回值: 无 (docker.sh 的退出码即为当前函数的退出码)
# 退出码: 如果 docker.sh 执行失败 (返回非 0)，则当前脚本也退出 (|| exit 1)
# =============================================================================
function exec_docker() {
    # 执行 docker.sh 脚本，并传递所有参数
    # 如果 docker.sh 返回非 0 状态码，则当前脚本也退出
    bash "${DOCKER_PATH}" "$@" || exit 1
}

# =============================================================================
# 函数名称: exec_ssl
# 功能描述: 执行 ssl.sh 脚本，用于管理 SSL 证书相关操作。
# 参数:
#   $@: 传递给 ssl.sh 脚本的参数
# 返回值: ssl.sh 脚本的退出码 (通过 return $? 返回)
# =============================================================================
function exec_ssl() {
    # 执行 ssl.sh 脚本，并传递所有参数
    # 注: 用 || 先接住退出码再 return, 避免 set -e 抢在 return 之前退出
    bash "${SSL_PATH}" "$@" || return $?
}

# =============================================================================
# 函数名称: exec_check
# 功能描述: 执行 check.sh 脚本，用于验证输入或配置的有效性。
# 参数:
#   $@: 传递给 check.sh 脚本的参数
# 返回值: check.sh 脚本的退出码 (通过 return $? 返回)
# =============================================================================
function exec_check() {
    # 执行 check.sh 脚本，并传递所有参数
    # 注: check.sh 退出码即校验结果 (0 通过/非 0 不通过), 属正常语义, 不能让 set -e 抢先退出
    bash "${CHECK_PATH}" "$@" || return $?
}

# =============================================================================
# 函数名称: port_held_by_xray
# 功能描述: 探测指定 TCP 端口当前是否由 xray 进程监听。
#           用于 SNI 迁移前的"自我占用"判定: 非 SNI 模式下 xray 直听 443,
#           切换 SNI 前必须先让它让出端口, 否则端口预检必然失败。
#           检测手段与 check.sh 的 get_listening_process_by_port 一致
#           (优先 ss, 回落 lsof) —— handler 与 check 是两个独立进程,
#           函数无法跨脚本复用, 故此处保留精简实现。
# 参数:
#   $1: 端口号
# 返回值: 0-该端口由 xray 监听, 1-否则 (含无法探测的情形)
# =============================================================================
function port_held_by_xray() {
    local port="${1:-}"
    local proc=''
    # 优先 ss (iproute2); 无权限时末列可能为空或 '-', 由下方统一清理
    if cmd_exists 'ss'; then
        proc="$(ss -lntp "( sport = :${port} )" 2>/dev/null | awk 'NR > 1 {print $NF; exit}' || true)"
    fi
    # ss 不可用或未取到监听者时回落到 lsof
    if [[ -z "${proc}" ]] && cmd_exists 'lsof'; then
        proc="$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | awk 'NR == 2 {print $1; exit}' || true)"
    fi
    [[ "${proc}" == '-' ]] && proc=''
    [[ "${proc}" == *xray* ]]
}


# =============================================================================
# 函数名称: exec_read
# 功能描述: 执行 read.sh 脚本读取用户输入，并进行验证。
#           1. 调用 read.sh 获取用户输入。
#           2. 根据输入类型，调用 check.sh 进行验证。
#           3. 对于特定输入（如 short），进行特殊处理和验证。
#           4. 将验证通过的输入存储到 CONFIG_DATA 关联数组中。
# 参数:
#   $1: 配置项名称 (对应 read.sh 的参数，如 port, uuid, domain 等)
# 返回值: 无 (直接修改全局变量 CONFIG_DATA)
# =============================================================================
function exec_read() {
    local opt="${1:-}"  # 获取配置项名称
    local flag=true # 初始化循环标志为 true
    local result='' # 声明用于存储 read.sh 输出的局部变量
    # 交互输入的**重试上限**: 允许用户输错重来, 但必须有界。
    # 背景: 此前循环无上限, 一旦 stdin 关闭 (cron / 管道 / `< /dev/null`), 每轮都会
    #       fork 一个 read.sh 拿到空串、通不过校验、立刻再 fork —— 无退让地空转,
    #       实测 CPU 打满且不停止 (见 .workbuddy/reports 审计报告 P0-1)。
    #       现在 EOF 由 read.sh 直接以非 0 退出码上报 (下方立即失败退出), 本上限则
    #       兜住"输入源可用但内容一直不合法"的情形 (例如被喂了一整段非法值)。
    local max_retries=3
    local retries=0
    local valid=true # 本轮输入是否通过校验
    # 循环直到输入有效 (flag 为 false)
    while ${flag}; do
        # 调用 read.sh 脚本获取用户输入
        # 注: read.sh 在 EOF (无输入源) 时以非 0 退出 —— 这是"根本无法交互"的信号,
        #     不是"用户答错了"。重试多少次结果都一样, 必须立即失败退出, 不能用
        #     `|| true` 兜住, 也不能让 set -e 抢先把它当成普通失败。
        if ! result="$(bash "${READ_PATH}" "--${opt}")"; then
            _error "$(_i18n ".${CUR_FILE}.input_unavailable")"
        fi
        # 根据配置项名称进行特定验证
        valid=true
        case "${opt}" in
        version)
            # 验证 Xray 版本
            exec_check '--xray' "${result}" || valid=false
            ;;
        email)
            # 验证邮箱地址
            exec_check '--email' "${result}" || valid=false
            ;;
        block-bt | block-cn | block-ad)
            # 为阻止选项设置默认值 'Y'
            result="${result:-Y}"
            ;;
        rules)
            # 为规则选项设置默认值 'N'
            result="${result:-N}"
            ;;
        port)
            # 验证端口号
            exec_check '--port' "${result}" || valid=false
            ;;
        uuid | fallback)
            # 验证 UUID (fallback 也使用 uuid 验证)
            # 注: 与相邻分支保持一致, 校验不通过时重新输入而非直接终止 (原本缺 || continue)
            exec_check '--uuid' "${result}" || valid=false
            ;;
        seed | password)
            # 验证密码或种子
            exec_check '--password' "${result}" || valid=false
            ;;
        target)
            # 验证目标域名
            exec_check '--domain' "${result}" || valid=false
            ;;
        only-change-domain)
            # 为仅更新域名选项设置默认值 'Y'
            result="${result:-Y}"
            ;;
        domain | cdn)
            # 验证域名或 CDN 域名
            exec_check '--dns' "${result}" || valid=false
            # 如果是 'domain' 选项，同时设置 CONFIG_DATA['target']
            [[ "${1:-}" == 'domain' ]] && CONFIG_DATA['target']="${result}"
            ;;
        custom-domain)
            exec_check '--custom-domain' "${result}" "${CONFIG_DATA['ignore-domain']:-}" || valid=false
            ;;
        remove-cert)
            # 仅校验域名格式 (不做 DNS 解析, 待移除证书的域名可能已下线)
            exec_check '--domain-format' "${result}" || valid=false
            ;;
        proxy-target)
            result="$(exec_check '--proxy-target' "${result}")" || valid=false
            ;;
        site-index)
            exec_check '--list-index' "${result}" "${CONFIG_DATA['site-count']:-}" || valid=false
            ;;
        short)
            # 特殊处理 Short IDs
            # 如果输入为空，进行验证 (可能是检查默认值)
            # 注: 与其它分支统一语义 —— 校验不通过即计入重试, 不再"静默当有效值存下"。
            #     原写法 `[[ -z ... ]] && exec_check ... && break` 在校验失败时会继续
            #     往下走, 最终把非法值当有效值存进 CONFIG_DATA。
            if [[ -z "${result}" ]]; then
                exec_check '--short' "${result}" || valid=false
            else
                # 将逗号分隔的输入分割成数组
                IFS=',' read -r -a values <<<"${result}"
                # 遍历每个 Short ID 进行验证
                for value in "${values[@]}"; do
                    if exec_check '--short' "${value}"; then
                        # 验证通过则追加到 CONFIG_DATA['short_ids']
                        CONFIG_DATA['short_ids']="${CONFIG_DATA['short_ids']:-} ${value}"
                    fi
                done
            fi
            ;;
        path)
            # 验证路径
            exec_check '--path' "${result}" || valid=false
            ;;
        esac
        # 输入验证通过，设置 flag 为 false 退出循环
        if ${valid}; then
            flag=false
            continue
        fi
        # 校验失败: 计入重试次数, 超限即报错退出 —— 循环有界, 不再无限空转
        retries=$((retries + 1))
        if ((retries >= max_retries)); then
            _error "$(_i18n ".${CUR_FILE}.input_retry_exhausted")"
        fi
    done
    # 将最终的用户输入结果存储到 CONFIG_DATA 关联数组中
    CONFIG_DATA["${1:-}"]="${result}"
}

# =============================================================================
# 函数名称: reset_json_fields
# 功能描述: 重置 JSON 对象中指定键下的字段值。
#           1. 如果指定了目标键 ($2)，则只重置该键下的字段。
#           2. 如果未指定目标键，则重置整个 JSON 对象的字段。
#           3. 保留指定的字段 ($3, $4, ...) 不变，其他字段根据类型重置为空值。
# 参数:
#   $1: 原始 JSON 字符串
#   $2: 目标键名 (例如 'xray' 或 'nginx')，如果为 "null" 则重置整个对象
#   $@: (从 $3 开始) 需要保留的字段名列表
# 返回值: 重置后的 JSON 字符串 (echo 输出)
# =============================================================================
function reset_json_fields() {
    local raw_json="${1:-}"   # 获取原始 JSON 字符串
    local target_key="${2:-}" # 获取目标键名
    # 移除前两个参数，剩下的就是需要保留的字段名
    shift 2
    local keep_fields=("$@") # 获取需要保留的字段名数组
    # 将保留字段名数组转换为 jq 可用的 JSON 数组
    local jq_keep
    jq_keep=$(printf '%s\n' "${keep_fields[@]}" | jq -R . | jq -s .)
    # 使用 jq 脚本进行重置操作
    raw_json=$(echo "${raw_json}" | jq --arg key "${target_key}" --argjson keep "$jq_keep" '
        # 定义递归函数 clear_recursive，用于清空值
        def clear_recursive:
            if type == "object" then with_entries(.value |= clear_recursive)
            elif type == "array" then map(clear_recursive) | unique
            elif type == "number" then 0
            elif type == "boolean" then false
            else ""
            end;
        # 定义函数 exec_clear，用于判断字段是否需要保留
        def exec_clear:
            if .key | IN($keep[]) then .
            else .value |= clear_recursive
            end;
        # 根据是否指定了目标键来决定重置范围
        if $key != "null" then .[$key] |= with_entries(exec_clear)
        else . |= with_entries(exec_clear)
        end
    ')
    # 输出重置后的 JSON 字符串
    echo "${raw_json}"
}

# =============================================================================
# 函数名称: persist_script_config
# 功能描述: 将内存中的脚本配置 (SCRIPT_CONFIG) 原子写回 config.json, 并置位订阅重建
#           脏标记 SUB_REFRESH_DIRTY。真正的订阅重建由 main 的 dispatch 末尾统一收口
#           (见 refresh_subscription_after_config_change), 避免一次调用里重复重建。
# 参数: 无 (使用全局 SCRIPT_CONFIG / SCRIPT_CONFIG_PATH)
# 返回值: 无
# =============================================================================
function persist_script_config() {
    printf '%s\n' "${SCRIPT_CONFIG}" | _atomic_write "${SCRIPT_CONFIG_PATH}"
    # 配置变了 -> 订阅 (配置的派生快照) 需要重建。此处只置脏, 真正重建由 main 的 dispatch
    # 末尾统一收口一次 —— 单次调用里常有连续两次 persist, 就地重建会白跑一遍。
    SUB_REFRESH_DIRTY=1
}

# =============================================================================
# 函数名称: _verify_xray_config
# 功能描述: 用 xray 自身的配置校验模式 (xray run -test) 复核配置文件语法,
#           仅作"写盘后的语义复核", 失败返回非 0 供上层回滚。
#           以下情形视为通过 (返回 0): xray 尚未安装 / 配置校验被显式关闭
#           (XRAY_CONFIG_TEST_SKIP=1) / 旧版 xray 不支持 -test 选项。
# 参数:
#   $1: 配置文件路径 (默认 ${XRAY_CONFIG_PATH})
# 返回值: 0-通过(或跳过) 1-校验未通过
# =============================================================================
function _verify_xray_config() {
    local cfg="${1:-${XRAY_CONFIG_PATH}}"
    local out=''
    # 逃生开关: 显式跳过校验
    [[ "${XRAY_CONFIG_TEST_SKIP:-0}" == '1' ]] && return 0
    # 安装早期阶段: 配置文件或 xray 命令尚不存在, 直接跳过
    [[ -f "${cfg}" ]] || return 0
    command -v xray >/dev/null 2>&1 || return 0
    # xray run -test 成功即视为合规
    if out="$(xray run -test -config "${cfg}" 2>&1)"; then
        return 0
    fi
    # 兼容不支持 -test 的旧版 xray: 视为跳过而非失败
    if printf '%s' "${out}" | grep -qi 'flag provided but not defined'; then
        return 0
    fi
    # 其余情况判定为配置非法, 输出原始报错便于定位
    [[ -n "${out}" ]] && printf '%s\n' "${out}" >&2
    return 1
}

# =============================================================================
# 函数名称: persist_xray_config
# 功能描述: 将内存中的 Xray 配置落盘 (原子写)。为防写坏生产配置, 增加三道护栏:
#           1) 写前用 jq -e 校验待写入内容是合法 JSON, 非法直接拒绝写入;
#           2) 写前把既有配置备份为 <path>.bak;
#           3) 写后用 _verify_xray_config 做语义复核, 失败则回滚备份并终止。
# 参数: 无 (使用全局变量 XRAY_CONFIG)
# 返回值: 无 (失败时调用 _error 退出)
# =============================================================================
function persist_xray_config() {
    local backup_path="${XRAY_CONFIG_PATH}.bak" # 上一份配置备份 (供回滚)
    # 写前校验: 待写入内容必须是合法 JSON, 否则拒绝写入, 避免把生产配置写坏
    if command -v jq >/dev/null 2>&1 && ! printf '%s' "${XRAY_CONFIG}" | jq -e . >/dev/null 2>&1; then
        _error "$(_i18n '.handler.persist.invalid_json')"
    fi
    # 写前备份既有配置 (存在时), 供下一步语义复核失败时回滚
    if [[ -f "${XRAY_CONFIG_PATH}" ]]; then
        cp -f "${XRAY_CONFIG_PATH}" "${backup_path}" 2>/dev/null || true
    fi
    # 原子写入
    printf '%s\n' "${XRAY_CONFIG}" | _atomic_write "${XRAY_CONFIG_PATH}" || _error "$(_i18n '.handler.persist.write_failed')"
    # 写后语义复核: 用 xray 自身解析一遍, 不通过则回滚到备份并终止
    if ! _verify_xray_config "${XRAY_CONFIG_PATH}"; then
        if [[ -f "${backup_path}" ]]; then
            cp -f "${backup_path}" "${XRAY_CONFIG_PATH}" 2>/dev/null || true
        fi
        _error "$(_i18n '.handler.persist.verify_failed')"
    fi
    # 配置已落盘且复核通过 -> 订阅 (写死了入站参数的派生快照) 需要重建; 只置脏, 见收口说明
    SUB_REFRESH_DIRTY=1
}

# 订阅重建脏标记: 由 persist_script_config / persist_xray_config 置位, 由
# refresh_subscription_after_config_change (main 的 dispatch 末尾) 消费并清零。
# 顶层初始化 (而非 declare -g in function): handler.sh 以子进程方式被调用, 每次都是全新环境。
SUB_REFRESH_DIRTY=0

# =============================================================================
# 函数名称: refresh_subscription_after_config_change
# 功能描述: 配置变更后按需重建订阅产物。
#           订阅是配置的"派生快照" —— 生成出来的链接里写死了域名/端口/UUID/SNI 等参数,
#           所以配置一改, 用户手上那份订阅就静默失效 (客户端仍按旧参数去连)。两个
#           persist_* 是配置落盘的唯一收口点, 它们只置 SUB_REFRESH_DIRTY, 真正的重建
#           在这里统一做一次 (主菜单任一配置操作只重建一次, 不做重复功)。
# 参数: 无
# 返回值: 恒 0 —— 订阅只是附带产物, 重建失败不该把已经成功的配置变更变成失败
# =============================================================================
function refresh_subscription_after_config_change() {
    # 本次调用没有写过配置 -> 直接返回 (只读类 handler 都走这条)
    if [[ "${SUB_REFRESH_DIRTY}" != '1' ]]; then
        return 0
    fi
    SUB_REFRESH_DIRTY=0
    # 只有已经生成过订阅才重建: 没这个需求的用户不该被凭空造出文件
    local f=''
    local found=0
    for f in "${SCRIPT_CONFIG_DIR}"/subscription-*; do
        if [[ -f "${f}" ]]; then
            found=1
            break
        fi
    done
    if [[ "${found}" -ne 1 ]]; then
        return 0
    fi
    if bash "${SHARE_PATH}" --subscription >/dev/null 2>&1; then
        _audit_log 'subscription.refresh' 'config changed: subscription regenerated'
    else
        _audit_log 'subscription.refresh' 'config changed: regeneration FAILED'
        _warn "$(_i18n '.handler.subscription.refresh_failed')"
    fi
    return 0
}

# =============================================================================
# 函数名称: get_custom_site_socket_name
# 功能描述: 由域名 + 端口派生稳定的 unix socket 名 (域名 sha256 前 12 位 + 端口)。
#           优先 openssl, 回退 shasum; 两者皆不可用时报错退出。
# 参数:
#   $1: domain - 站点域名
#   $2: port   - 站点端口
# 返回值: echo 输出 socket 名 (生成失败时 _error 退出)
# =============================================================================
function get_custom_site_socket_name() {
    local domain="${1:-}"
    local port="${2:-}"
    local hash=''

    hash="$(printf '%s' "${domain}" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}' | cut -c1-12)"
    [[ -n "${hash}" ]] || hash="$(printf '%s' "${domain}" | shasum -a 256 2>/dev/null | awk '{print $1}' | cut -c1-12)"
    [[ -n "${hash}" ]] || _error "failed to generate custom site socket name"
    echo "${hash}${port}"
}

# =============================================================================
# 函数名称: get_custom_site_upstream_name
# 功能描述: 由域名 + 端口派生 Nginx upstream 名 (custom_site_ + socket 名),
#           保证 stream 配置与站点配置引用同一 upstream。
# 参数:
#   $1: domain - 站点域名
#   $2: port   - 站点端口
# 返回值: echo 输出 upstream 名
# =============================================================================
function get_custom_site_upstream_name() {
    local domain="${1:-}"
    local port="${2:-}"
    echo "custom_site_$(get_custom_site_socket_name "${domain}" "${port}")"
}

# =============================================================================
# 函数名称: parse_proxy_target
# 功能描述: 解析代理目标串 (scheme://host:port) 为三段制表符分隔值, 供上层 IFS 读取。
# 参数:
#   $1: proxy_target - 形如 https://host:443 的目标串
# 返回值: 0-解析成功 (stdout: scheme<TAB>host<TAB>port) 1-格式不合法
# =============================================================================
function parse_proxy_target() {
    local proxy_target="${1:-}"
    if [[ "${proxy_target}" =~ ^(https?)://([^:]+):([0-9]+)$ ]]; then
        printf '%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        return 0
    fi
    return 1
}

# =============================================================================
# 函数名称: sync_missing_nginx_support_dir
# 功能描述: 按相对路径把源目录里的文件补拷到目标目录, 仅补"目标缺失"者, 不覆盖已存在
#           文件 —— 避免抹掉用户对 Nginx 支持文件的本地改动。
# 参数:
#   $1: source_dir - 源目录 (不存在则直接返回 0)
#   $2: target_dir - 目标目录
# 返回值: 0-成功(或源目录不存在) 1-建目录/拷贝失败
# =============================================================================
function sync_missing_nginx_support_dir() {
    local source_dir="${1:-}"
    local target_dir="${2:-}"
    local source_path=''
    local relative_path=''
    local target_path=''

    [[ -d "${source_dir}" ]] || return 0
    mkdir -p "${target_dir}" || return 1

    while IFS= read -r -d '' source_path; do
        relative_path="${source_path#${source_dir}/}"
        target_path="${target_dir}/${relative_path}"
        [[ -e "${target_path}" ]] && continue
        mkdir -p "$(dirname "${target_path}")" || return 1
        cp -f "${source_path}" "${target_path}" || return 1
    done < <(find "${source_dir}" -type f -print0)
}

# 注: 此处原有一个 _sed_in_place (sed -i 就地替换) 已删除 —— 全仓零调用, 且与
#     _common.sh:_replace_in_file 确立的"读-改-写"原子写方向相反, 留着只会诱导复发。
#     需要就地替换语义时请用 _replace_in_file。

# =============================================================================
# 函数名称: ensure_nginx_support_files
# 功能描述: 确保 Nginx 运行所需的标准目录结构存在, 并从仓库模板补齐缺失的
#           conf.d / web / nginxconfig.io 支持文件。
# 参数: 无
# 返回值: 0-成功 1-建目录或同步文件失败
# =============================================================================
function ensure_nginx_support_files() {
    mkdir -p \
        "${NGINX_CONFIG_DIR}/sites-available" \
        "${NGINX_CONFIG_DIR}/sites-enabled" \
        "${NGINX_CONFIG_DIR}/modules-enabled" \
        "${NGINX_CONFIG_DIR}/conf.d" \
        "${NGINX_CONFIG_DIR}/web" \
        "${NGINX_CONFIG_DIR}/nginxconfig.io" || return 1

    sync_missing_nginx_support_dir "${CONFIG_DIR}/nginx/conf/conf.d" "${NGINX_CONFIG_DIR}/conf.d" || return 1
    sync_missing_nginx_support_dir "${CONFIG_DIR}/nginx/conf/web" "${NGINX_CONFIG_DIR}/web" || return 1
    sync_missing_nginx_support_dir "${CONFIG_DIR}/nginx/conf/nginxconfig.io" "${NGINX_CONFIG_DIR}/nginxconfig.io" || return 1
}

# =============================================================================
# 函数名称: write_stream_config
# 功能描述: 依据脚本配置生成 Nginx stream 段配置 (SNI 分流 + unix socket upstream)
#           并写入指定路径。主域与 CDN 走固定 upstream, 自定义站点逐个生成独立 upstream。
# 参数:
#   $1: target_path   - 目标配置文件路径
#   $2: source_config - (可选) 配置 JSON, 默认 ${SCRIPT_CONFIG}
# 返回值: 无 (写盘失败由上层/调用方判定)
# =============================================================================
function write_stream_config() {
    local target_path="${1:-}"
    local source_config="${2:-${SCRIPT_CONFIG}}"
    local domain
    domain="$(echo "${source_config}" | jq -r '.nginx.domain')"
    local cdn_domain
    cdn_domain="$(echo "${source_config}" | jq -r '.nginx.cdn')"
    local site_domain=''
    local site_port=''
    local socket_name=''
    local upstream_name=''

    {
        echo 'stream {'
        echo '    map $ssl_preread_server_name $tcpsni_name {'
        [[ -n "${domain}" && "${domain}" != 'null' ]] && printf '        %-30s %s;\n' "${domain}" 'nginx_to_xray_vision'
        [[ -n "${cdn_domain}" && "${cdn_domain}" != 'null' ]] && printf '        %-30s %s;\n' "${cdn_domain}" 'cdn_to_nginx'
        while IFS=$'\t' read -r site_domain site_port; do
            [[ -n "${site_domain}" ]] || continue
            upstream_name="$(get_custom_site_upstream_name "${site_domain}" "${site_port}")"
            printf '        %-30s %s;\n' "${site_domain}" "${upstream_name}"
        done < <(echo "${source_config}" | jq -r '.nginx.custom_sites // [] | .[] | [.domain, (.port | tostring)] | @tsv')
        printf '        %-30s %s;\n' 'default' 'default_backend'
        echo '    }'
        echo
        echo '    upstream nginx_to_xray_vision {'
        echo '        server unix:/dev/shm/nginx/nginx_to_xray_vision.sock;'
        echo '    }'
        echo
        echo '    upstream cdn_to_nginx {'
        echo '        server unix:/dev/shm/nginx/cdn_to_nginx.sock;'
        echo '    }'
        echo
        while IFS=$'\t' read -r site_domain site_port; do
            [[ -n "${site_domain}" ]] || continue
            socket_name="$(get_custom_site_socket_name "${site_domain}" "${site_port}")"
            upstream_name="$(get_custom_site_upstream_name "${site_domain}" "${site_port}")"
            echo "    upstream ${upstream_name} {"
            echo "        server unix:/dev/shm/nginx/${socket_name}.sock;"
            echo '    }'
            echo
        done < <(echo "${source_config}" | jq -r '.nginx.custom_sites // [] | .[] | [.domain, (.port | tostring)] | @tsv')
        echo '    upstream default_backend {'
        echo '        server unix:/dev/shm/nginx/default_backend.sock;'
        echo '    }'
        echo
        echo '    server {'
        echo '        listen         443 reuseport;'
        echo '        listen         [::]:443 reuseport;'
        echo '        ssl_preread    on;'
        echo '        proxy_protocol on;'
        echo '        proxy_pass     $tcpsni_name;'
        echo '    }'
        echo '}'
    } >"${target_path}"
}

# =============================================================================
# 函数名称: rebuild_stream_config
# 功能描述: 用给定配置重建标准位置的 stream 配置 (modules-enabled/stream.conf)。
# 参数:
#   $1: source_config - (可选) 配置 JSON, 默认 ${SCRIPT_CONFIG}
# 返回值: 同 write_stream_config
# =============================================================================
function rebuild_stream_config() {
    local source_config="${1:-${SCRIPT_CONFIG}}"
    write_stream_config "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" "${source_config}"
}

# =============================================================================
# 函数名称: render_custom_site_config
# 功能描述: 由站点参数渲染一份自定义站点 Nginx 配置: 复制模板并替换域名 / socket /
#           代理目标, 最后按本机 HTTP/3 能力裁剪 quic 指令 (见 align_site_http3)。
# 参数:
#   $1: domain      - 站点域名
#   $2: scheme      - 上游协议 (http/https)
#   $3: host        - 上游主机
#   $4: port        - 上游端口
#   $5: output_path - 输出配置文件路径
# 返回值: 0-成功 1-复制模板或补齐支持文件失败
# =============================================================================
function render_custom_site_config() {
    local domain="${1:-}"
    local scheme="${2:-}"
    local host="${3:-}"
    local port="${4:-}"
    local output_path="${5:-}"
    local socket_name
    socket_name="$(get_custom_site_socket_name "${domain}" "${port}")"
    local proxy_target="${scheme}://${host}:${port}"

    ensure_nginx_support_files || return 1
    cp -f "${CONFIG_DIR}/nginx/conf/sites-available/custom-site.example.com.conf" "${output_path}" || return 1
    _replace_in_file "${output_path}" "example.com" "${domain}"
    _replace_in_file "${output_path}" "unix:/dev/shm/nginx/custom_site.sock" "unix:/dev/shm/nginx/${socket_name}.sock"
    _replace_in_file "${output_path}" "PROXY_TARGET" "${proxy_target}"
    # 站点配置里的 HTTP/3 (quic) 指令必须与本机 Nginx 编译能力一致, 否则
    # nginx -t 会因无法识别的 quic 参数失败, 把整个 Nginx 拖垮 (见 align_site_http3)
    align_site_http3 "${output_path}"
}

# =============================================================================
# 函数名称: align_site_http3
# 功能描述: 让渲染出来的站点配置与本地 Nginx 的 HTTP/3 能力保持一致。
#           - 编译了 --with-http_v3_module: 原样保留模板里的 quic 监听与 Alt-Svc;
#           - 未编译: 逐行剥离这两类指令。因为 nginx 遇到不认识的 quic 参数会
#             直接 `[emerg] invalid parameter "quic"` 拒绝启动 —— 保留它们等于
#             让站点配置变成一颗哑弹, 剥离后至少退化成"没有 HTTP/3 但服务正常"。
# 参数:
#   $1: conf - 已渲染完成的站点配置文件路径
# 返回值: 恒 0 (配置自适应属尽力而为, 不该中断安装/改域名流程)
# =============================================================================
function align_site_http3() {
    local conf="${1:-}"
    [[ -f "${conf}" ]] || return 0
    if _nginx_supports_http3; then
        return 0
    fi
    sed -i -e '/^[[:space:]]*listen[[:space:]].*[[:space:]]quic/d' \
        -e '/^[[:space:]]*add_header[[:space:]].*Alt-Svc/d' "${conf}"
    _warn "$(_i18n ".${CUR_FILE}.nginx.http3_stripped")"
    return 0
}

# =============================================================================
# 函数名称: sync_custom_sites_config
# 功能描述: 遍历配置里的自定义站点, 逐个渲染站点配置 (sites-available) 并软链到
#           sites-enabled, 使 Nginx 生效集合与配置保持一致。
# 参数:
#   $1: source_config - (可选) 配置 JSON, 默认 ${SCRIPT_CONFIG}
# 返回值: 0-成功 1-任一站点渲染或建链失败
# =============================================================================
function sync_custom_sites_config() {
    local source_config="${1:-${SCRIPT_CONFIG}}"
    local domain=''
    local scheme=''
    local host=''
    local port=''
    local conf_path=''

    while IFS=$'\t' read -r domain scheme host port; do
        [[ -n "${domain}" ]] || continue
        conf_path="${NGINX_CONFIG_DIR}/sites-available/${domain}.conf"
        render_custom_site_config "${domain}" "${scheme}" "${host}" "${port}" "${conf_path}" || return 1
        ln -sf "${conf_path}" "${NGINX_CONFIG_DIR}/sites-enabled/${domain}.conf" || return 1
    done < <(echo "${source_config}" | jq -r '.nginx.custom_sites // [] | .[] | [.domain, .scheme, .host, (.port | tostring)] | @tsv')
}

# =============================================================================
# 函数名称: test_and_reload_nginx
# 功能描述: 校验 Nginx 配置并使其生效 —— 先补支持文件, 再 nginx -t 校验, 最后按运行
#           状态选择 reload (已在跑) 或 start (未启动)。返回值即"是否成功"。
# 参数: 无
# 返回值: 0-校验并生效成功 1-任一步失败
# =============================================================================
function test_and_reload_nginx() {
    ensure_nginx_support_files || return 1
    nginx -t || return 1
    # 注: 重载/启动失败应由调用方判定 (函数语义即"是否成功"), 用 || return 1 表达
    if systemctl -q is-active nginx; then
        systemctl -q reload nginx || return 1
    else
        systemctl -q start nginx || return 1
    fi
}

# =============================================================================
# 函数名称: get_custom_sites_count
# 功能描述: 读取配置中自定义站点的数量。
# 参数: 无
# 返回值: echo 输出站点数 (整数)
# =============================================================================
function get_custom_sites_count() {
    echo "${SCRIPT_CONFIG}" | jq -r '.nginx.custom_sites // [] | length'
}

# =============================================================================
# 函数名称: show_custom_sites_list
# 功能描述: 打印自定义站点清单 (序号 | 域名 | 代理目标 | socket 名), 供增删改前查看;
#           无站点时提示为空。
# 参数: 无
# 返回值: 恒 0
# =============================================================================
function show_custom_sites_list() {
    local custom_site_count
    custom_site_count="$(get_custom_sites_count)"
    local index=''
    local domain=''
    local scheme=''
    local host=''
    local port=''
    local socket_name=''

    if ((custom_site_count == 0)); then
        echo -e "${YELLOW}[$(_i18n '.title.info')]${NC} $(_i18n ".${CUR_FILE}.custom_sites.empty")" >&2
        return 0
    fi

    echo -e "${GREEN}[$(_i18n '.title.info')]${NC} $(_i18n ".${CUR_FILE}.custom_sites.list_header")" >&2
    while IFS=$'\t' read -r index domain scheme host port; do
        socket_name="$(get_custom_site_socket_name "${domain}" "${port}")"
        printf '%s | %s | %s://%s:%s | %s.sock\n' "${index}" "${domain}" "${scheme}" "${host}" "${port}" "${socket_name}" >&2
    done < <(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.custom_sites // [] | to_entries[] | [(.key + 1 | tostring), .value.domain, .value.scheme, .value.host, (.value.port | tostring)] | @tsv')
}

# =============================================================================
# 函数名称: read_custom_site_domain_update
# 功能描述: 交互读取自定义站点域名 (更新场景): 空输入保持当前值, 非空经校验后返回;
#           无输入源 (EOF) 视为致命错误 —— 不能与"回车保持原值"混淆, 否则
#           cron/管道下会静默沿用旧值。
# 参数:
#   $1: current_domain - 当前域名 (回车时原样返回)
# 返回值: echo 输出最终域名 (输入源不可用时 _error 退出)
# =============================================================================
function read_custom_site_domain_update() {
    local current_domain="${1:-}"
    local result=''
    echo -e "${YELLOW}[$(_i18n '.title.tip')]${NC} $(_i18n ".${CUR_FILE}.custom_sites.keep_current")" >&2
    while true; do
        # 注: read.sh 在 EOF (无输入源) 时以非 0 退出 —— 它不等于"用户回车保持原值"。
        #     无输入源时必须失败退出: 否则 cron / 管道场景下会静默沿用旧值, 用户
        #     以为改了实际没改。空串 (用户直接回车) 才走下方"保持当前值"分支。
        if ! result="$(bash "${READ_PATH}" '--custom-domain')"; then
            _error "$(_i18n ".${CUR_FILE}.input_unavailable")"
        fi
        if [[ -z "${result}" ]]; then
            echo "${current_domain}"
            return 0
        fi
        if exec_check '--custom-domain' "${result}" "${current_domain}"; then
            echo "${result}"
            return 0
        fi
    done
}

# =============================================================================
# 函数名称: read_custom_site_proxy_target_update
# 功能描述: 交互读取自定义站点的代理目标 (更新场景): 空输入保持当前值, 非空经校验后
#           返回; EOF 无输入源同样视为致命错误 (原因同 read_custom_site_domain_update)。
# 参数:
#   $1: current_proxy_target - 当前代理目标 (回车时原样返回)
# 返回值: echo 输出最终代理目标 (输入源不可用时 _error 退出)
# =============================================================================
function read_custom_site_proxy_target_update() {
    local current_proxy_target="${1:-}"
    local result=''
    echo -e "${YELLOW}[$(_i18n '.title.tip')]${NC} $(_i18n ".${CUR_FILE}.custom_sites.keep_current")" >&2
    while true; do
        # 注: 同上 —— EOF (无输入源) 必须失败退出, 不能与"用户回车保持原值"混为一谈。
        if ! result="$(bash "${READ_PATH}" '--proxy-target')"; then
            _error "$(_i18n ".${CUR_FILE}.input_unavailable")"
        fi
        if [[ -z "${result}" ]]; then
            echo "${current_proxy_target}"
            return 0
        fi
        result="$(exec_check '--proxy-target' "${result}")" || continue
        echo "${result}"
        return 0
    done
}

# =============================================================================
# 函数名称: rollback_stream_config_backup
# 功能描述: 回滚 stream 配置: 有备份则用备份覆盖, 无备份 (本次为新建) 则删除文件,
#           使配置恢复到变更前状态。
# 参数:
#   $1: backup_path - 备份文件路径
# 返回值: 无
# =============================================================================
function rollback_stream_config_backup() {
    local backup_path="${1:-}"
    local stream_path="${NGINX_CONFIG_DIR}/modules-enabled/stream.conf"
    if [[ -f "${backup_path}" ]]; then
        mv -f "${backup_path}" "${stream_path}"
    else
        rm -f "${stream_path}"
    fi
}

# =============================================================================
# 函数名称: get_custom_site_json_by_index
# 功能描述: 按 1 基序号取出配置中对应自定义站点的紧凑 JSON (越界输出 null)。
# 参数:
#   $1: site_index - 站点序号 (从 1 开始)
# 返回值: echo 输出该站点的紧凑 JSON
# =============================================================================
function get_custom_site_json_by_index() {
    local site_index="${1:-}"
    echo "${SCRIPT_CONFIG}" | jq -c --argjson idx "$((site_index - 1))" '.nginx.custom_sites // [] | .[$idx]'
}

# =============================================================================
# 函数名称: add_rule
# 功能描述: 在 Xray 配置的 routing.rules 中添加或更新路由规则。
#           1. 检查是否存在具有相同 ruleTag 的规则。
#           2. 如果存在且是 domain 或 ip 规则，则追加新值。
#           3. 如果不存在，则创建新规则。
#           4. 新规则可以插入到指定位置或相对于其他规则的位置。
#           5. 更新后的配置写入 XRAY_CONFIG_PATH 文件。
# 参数:
#   $1: rule_tag - 规则标签 (ruleTag)，用于唯一标识规则
#   $2: domain_or_ip - 规则类型 ("domain" 或 "ip")
#   $3: value - 要添加的值 (可以是逗号分隔的多个值)
#   $4: outboundTag - 出站标签 (例如 "block", "warp")
#   $5: position - (可选) 插入位置或相对于 target_tag 的位置 ("before", "after", 数字索引)
#   $6: target_tag - (可选) 用于定位插入位置的参考规则标签
# 返回值: 无 (直接修改 XRAY_CONFIG_PATH 文件)
# =============================================================================
function add_rule() {
    local rule_tag=${1:-}     # 获取规则标签
    local domain_or_ip=${2:-} # 获取规则类型 (domain/ip)
    # 将逗号分隔的值转换为 JSON 数组
    local value
    value=$(echo "${3:-}" | tr ',' '\n' | jq -R | jq -s)
    local outboundTag=${4:-} # 获取出站标签
    local position=${5:-}    # 获取插入位置参数
    local target_tag=${6:-}  # 获取目标规则标签参数
    # 如果 XRAY_CONFIG 未初始化，则从文件加载
    XRAY_CONFIG="${XRAY_CONFIG:-$(jq '.' "${XRAY_CONFIG_PATH}")}"
    # 检查是否存在具有相同 ruleTag 的规则
    local existing_rule
    existing_rule=$(echo "${XRAY_CONFIG}" | jq -r --arg ruleTag "${rule_tag}" '.routing.rules[] | select(.ruleTag == $ruleTag)')
    # 如果规则已存在
    if [[ "${existing_rule}" ]]; then
        # 如果是 domain 规则
        if [[ "${domain_or_ip}" == "domain" ]]; then
            # 将新值追加到现有 domain 数组并去重
            XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg ruleTag "${rule_tag}" --argjson value "${value}" '.routing.rules |= map(if .ruleTag == $ruleTag then .domain += $value | .domain |= unique else . end)')"
        # 如果是 ip 规则
        elif [[ "${domain_or_ip}" == "ip" ]]; then
            # 将新值追加到现有 ip 数组并去重
            XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg ruleTag "${rule_tag}" --argjson value "${value}" '.routing.rules |= map(if .ruleTag == $ruleTag then .ip += $value | .ip |= unique else . end)')"
        fi
    else
        # 规则不存在，创建新的规则 JSON 对象
        # 安全加固: 改用 jq 构造 new_rule, 避免对 ${rule_tag}/${outboundTag}/${domain_or_ip} 做字符串插值后喂 --argjson
        #           (含引号/反斜杠/换行会导致 jq 解析失败并中断规则持久化); 动态键用 ($domainOrIp) 实现。
        local new_rule
        new_rule="$(jq -nc --arg ruleTag "${rule_tag}" --arg ot "${outboundTag}" --arg domainOrIp "${domain_or_ip}" --argjson dom "${value}" '{ruleTag:$ruleTag, ($domainOrIp):$dom, outboundTag:$ot}')"
        # 如果指定了 target_tag
        if [[ -n "${target_tag}" ]]; then
            # 检查 target_tag 对应的规则是否存在
            local target_rule
            target_rule=$(echo "${XRAY_CONFIG}" | jq -r --arg ruleTag "${target_tag}" '.routing.rules[] | select(.ruleTag == $ruleTag)')
            if [[ "${target_rule}" ]]; then
                # 获取 target_tag 对应规则的索引
                local target_index
                target_index=$(echo "${XRAY_CONFIG}" | jq -r --arg ruleTag "${target_tag}" '.routing.rules | to_entries | map(select(.value.ruleTag == $ruleTag)) | .[0].key')
                # 根据 position 参数决定插入位置
                if [[ "${position}" == "before" ]]; then
                    # 插入到 target_tag 规则之前
                    XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson target_index "${target_index}" --argjson new_rule "${new_rule}" '.routing.rules |= .[:$target_index] + $new_rule + .[$target_index:]')"
                elif [[ "${position}" == "after" ]]; then
                    # 插入到 target_tag 规则之后
                    XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson target_index $((target_index + 1)) --argjson new_rule "${new_rule}" '.routing.rules |= .[:$target_index] + $new_rule + .[$target_index:]')"
                else
                    # 默认追加到末尾
                    XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson new_rule "${new_rule}" '.routing.rules += $new_rule')"
                fi
            else
                # target_tag 规则不存在，追加到末尾
                XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson new_rule "${new_rule}" '.routing.rules += $new_rule')"
            fi
        else
            # 未指定 target_tag
            # 如果指定了数字位置
            if [[ -n "${position}" && "${position}" -ge 0 ]]; then
                # 插入到指定索引位置
                XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson position "${position}" --argjson new_rule "${new_rule}" '.routing.rules |= .[:$position] + $new_rule + .[$position:]')"
            else
                # 默认追加到末尾
                XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson new_rule "${new_rule}" '.routing.rules += $new_rule')"
            fi
        fi
    fi
    # 将更新后的 Xray 配置写入文件
    persist_xray_config
}

# =============================================================================
# 函数名称: handler_routing
# 功能描述: 处理路由规则配置的处理器。
#           1. 检查 WARP 状态是否满足配置要求。
#           2. 调用 exec_read 读取用户输入的规则值。
#           3. 调用 add_rule 将规则添加到 Xray 配置中。
# 参数:
#   $1: rule_type - 规则类型 ("block" 或 "warp")
#   $2: rule_target - 规则目标 ("ip" 或 "domain")
# 返回值: 无 (通过调用其他函数执行操作)
# 退出码: 如果 WARP 状态不满足要求，则调用 _error 退出脚本 (exit 1)
# =============================================================================
function handler_routing() {
    # 从脚本配置中读取 WARP 状态
    local WARP_STATUS
    WARP_STATUS="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.warp' || true)"
    local rule_type="${1:-}"                         # 获取规则类型 (block/warp)
    local rule_target="${2:-}"                       # 获取规则目标 (ip/domain)
    local rule_tag="${rule_type}-${rule_target}" # 构造规则标签
    # 检查 WARP 状态是否满足配置要求
    # 如果是 warp 规则但 WARP 未启用，则报错
    # 注: 用 is_enabled 而非 -ne 1 —— jq 对缺失/null 字段输出字面 "null",
    #     参与算术比较会在 set -u 下崩溃 (见 _common.sh:is_enabled 说明)。
    if [[ "${rule_type}" == 'warp' ]] && ! is_enabled "${WARP_STATUS}"; then
        _error "$(_i18n ".${CUR_FILE}.warp.status")"
    fi
    # 调用 exec_read 读取用户输入的规则值
    # 注: exec_read 把结果写入 CONFIG_DATA (见 handler.sh:exec_read 末行), 不是 XRAY_CONFIG。
    exec_read "${rule_tag}"
    # 调用 add_rule 将规则添加到 Xray 配置中
    # 修复: 原取 ${XRAY_CONFIG[${rule_tag}]} 有双重错误 ——
    #   1) XRAY_CONFIG 是**标量**(share.sh 声明, 存的是服务端配置 JSON 全文), 取下标
    #      语义就不对, 用户输入根本不在这里;
    #   2) 下标 "block-ip" 之类的字符串会触发 bash **算术求值**, 在 set -u 下直接
    #      "block: 未绑定的变量" 崩溃 —— 路由菜单 3/4/5/6 从未真正执行过 add_rule。
    # 现改为从 CONFIG_DATA 取用户实际输入, 并用 :- 兜住键缺失。
    add_rule "${rule_tag}" "${rule_target}" "${CONFIG_DATA[${rule_tag}]:-}" "${rule_type}"
}

# =============================================================================
# 函数名称: handler_reset_script_config
# 功能描述: 重置脚本配置文件 (config.json) 中指定部分的字段。
#           1. 根据目标配置部分 (xray/nginx) 调用 reset_json_fields。
#           2. 保留特定字段不变，其他字段清空。
#           3. 将重置后的配置写回 SCRIPT_CONFIG_PATH 文件。
# 参数:
#   $1: TARGET_CONFIG - 目标配置部分 ("xray" 或 "nginx")，默认为 "xray"
# 返回值: 无 (直接修改 SCRIPT_CONFIG 全局变量和 SCRIPT_CONFIG_PATH 文件)
# =============================================================================
# shellcheck disable=SC2120  # $1 为可选参数(缺省 xray), 现有调用点均省略, 保留该能力
function handler_reset_script_config() {
    local TARGET_CONFIG="${1:-xray}" # 获取目标配置部分，默认为 xray
    # 根据目标配置部分调用 reset_json_fields 进行重置
    case "${TARGET_CONFIG,,}" in
    xray)
        # 重置 xray 部分，保留 version, warp, rules 字段
        SCRIPT_CONFIG=$(reset_json_fields "${SCRIPT_CONFIG}" 'xray' 'version' 'warp' 'rules')
        ;;
    nginx)
        # 重置 nginx 部分，保留 version, ca, ca_server 字段
        SCRIPT_CONFIG=$(reset_json_fields "${SCRIPT_CONFIG}" 'nginx' 'version' 'ca' 'ca_server')
        ;;
    esac
    # 将重置后的脚本配置写入文件
    persist_script_config
}

# =============================================================================
# 函数名称: handler_ca_server
# 功能描述: 切换证书颁发机构 (zerossl / letsencrypt)。目标与当前一致时仅刷新 OCSP
#           配置; 不一致则为所有在用域名 (主域 / CDN / 自定义站点) 逐个重新签发,
#           任一失败则把此前已切换的域名回滚回原 CA, 不在半途留下混合证书状态。
# 参数:
#   $1: target_ca_server - 目标 CA (zerossl / letsencrypt), 非法值回退 zerossl
# 返回值: 无 (失败时 _error 退出)
# =============================================================================
function handler_ca_server() {
    local target_ca_server="${1:-zerossl}"
    local current_ca_server
    current_ca_server="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.ca_server' || true)"
    local domain
    domain="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.domain' || true)"
    local cdn_domain
    cdn_domain="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdn' || true)"
    local -a reissue_targets=()
    local -a switched_domains=()
    local reissue_domain=''

    case "${target_ca_server,,}" in
    zerossl | letsencrypt) ;;
    *) target_ca_server='zerossl' ;;
    esac
    case "${current_ca_server,,}" in
    zerossl | letsencrypt) ;;
    *) current_ca_server='zerossl' ;;
    esac

    if [[ "${target_ca_server,,}" == "${current_ca_server,,}" ]]; then
        handler_update_ocsp_config "${target_ca_server}" 'y'
        return 0
    fi

    [[ -n "${domain}" && "${domain}" != 'null' ]] && reissue_targets+=("${domain}")
    if [[ -n "${cdn_domain}" && "${cdn_domain}" != 'null' && "${cdn_domain}" != "${domain}" ]]; then
        reissue_targets+=("${cdn_domain}")
    fi
    while IFS= read -r reissue_domain; do
        [[ -n "${reissue_domain}" ]] || continue
        reissue_targets+=("${reissue_domain}")
    done < <(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.custom_sites // [] | .[] | .domain')

    for reissue_domain in "${reissue_targets[@]}"; do
        if exec_ssl '--issue' "--domain=${reissue_domain}" "--ca=${target_ca_server}"; then
            switched_domains+=("${reissue_domain}")
            continue
        fi

        # 用独立变量名: 原来内层沿用 reissue_domain, 会覆盖外层循环变量 (SC2167/SC2165),
        # 内层结束后本次外层迭代里 ${reissue_domain} 已不再是它自己的值。
        for rollback_domain in "${switched_domains[@]}"; do
            exec_ssl '--issue' "--domain=${rollback_domain}" "--ca=${current_ca_server}" || true
        done
        exec_ssl '--set-ca' "--ca=${current_ca_server}" || true
        handler_update_ocsp_config "${current_ca_server}" 'y' || true
        _error "ca switch failed, rolled back to ${current_ca_server}"
    done

    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg caServer "${target_ca_server,,}" '.nginx.ca_server = $caServer')"
    persist_script_config
    exec_ssl '--set-ca' "--ca=${target_ca_server}" || _error "failed to set acme default ca"
    handler_update_ocsp_config "${target_ca_server}" 'y'
}

# =============================================================================
# 函数名称: handler_update_ocsp_config
# 功能描述: 按 CA 能力切换 nginx.conf 的 OCSP stapling —— letsencrypt 不支持 stapling,
#           故注释掉 ssl_stapling / ssl_stapling_verify; zerossl 则取消注释恢复。
#           需要时校验并重载 nginx。nginx.conf 不存在时直接跳过。
# 参数:
#   $1: ca_server   - 目标 CA (zerossl / letsencrypt), 非法值回退 zerossl
#   $2: need_reload - 'y' 时执行 nginx -t 并 reload
# 返回值: 恒 0
# =============================================================================
function handler_update_ocsp_config() {
    local ca_server="${1:-zerossl}"
    local need_reload="${2:-n}"
    local nginx_conf="${NGINX_CONFIG_DIR}/nginx.conf"
    case "${ca_server,,}" in
    zerossl | letsencrypt) ;;
    *) ca_server='zerossl' ;;
    esac
    [[ -f "${nginx_conf}" ]] || return 0

    if [[ "${ca_server,,}" == 'letsencrypt' ]]; then
        sed -i -E 's|^([[:space:]]*)ssl_stapling([[:space:]]+on;)|\1# ssl_stapling\2|' "${nginx_conf}"
        sed -i -E 's|^([[:space:]]*)ssl_stapling_verify([[:space:]]+on;)|\1# ssl_stapling_verify\2|' "${nginx_conf}"
    else
        sed -i -E 's|^([[:space:]]*)#([[:space:]]*)ssl_stapling([[:space:]]+on;)|\1ssl_stapling\3|' "${nginx_conf}"
        sed -i -E 's|^([[:space:]]*)#([[:space:]]*)ssl_stapling_verify([[:space:]]+on;)|\1ssl_stapling_verify\3|' "${nginx_conf}"
    fi

    if [[ "${need_reload}" == 'y' ]] && cmd_exists 'nginx' && systemctl -q is-active nginx; then
        nginx -t && systemctl -q reload nginx || _error "nginx.conf check failed after OCSP toggle"
    fi
}

# =============================================================================
# 函数名称: handler_script_config
# 功能描述: 处理并更新脚本配置文件 (config.json)。
#           1. 打印配置更新提示。
#           2. 调用 handler_reset_script_config 重置配置。
#           3. 从 CONFIG_DATA 中获取或生成配置值。
#           4. 根据配置标签 (tag) 更新不同的字段。
#           5. 将更新后的配置写回 SCRIPT_CONFIG_PATH 文件。
# 参数:
#   $1: CONFIG_TAG - 配置标签 (例如 Vision, XHTTP, SNI 等)，默认从 CONFIG_DATA 获取
# 返回值: 无 (直接修改 SCRIPT_CONFIG 全局变量和 SCRIPT_CONFIG_PATH 文件)
# =============================================================================
function handler_script_config() {
    # 打印绿色的配置更新提示
    echo -e "${GREEN}[$(_i18n '.title.config')]${NC} $(_i18n ".${CUR_FILE}.script.config_update")" >&2
    # 重置脚本配置 (默认重置 xray 部分)
    handler_reset_script_config
    # 从 CONFIG_DATA 或生成器获取配置值
    # 获取配置标签
    local CONFIG_TAG="${1:-${CONFIG_DATA['tag']:-}}"
    # 获取规则状态
    local XRAY_RULES_STATUS="${CONFIG_DATA['rules']:-}"
    # 获取 block bt 状态
    local XRAY_RULES_BT="${CONFIG_DATA['block-bt']:-}"
    # 获取 block cn 状态
    local XRAY_RULES_CN="${CONFIG_DATA['block-cn']:-}"
    # 获取 block ad 状态
    local XRAY_RULES_AD="${CONFIG_DATA['block-ad']:-}"
    # 获取端口，默认 443
    local XRAY_PORT="${CONFIG_DATA['port']:-443}"
    # 获取或生成 UUID
    local XRAY_UUID
    XRAY_UUID="$(exec_generate '--uuid' ${CONFIG_DATA['uuid']:-})"
    # 获取或生成 Fallback UUID
    local FALLBACK_UUID="${CONFIG_DATA['fallback']:-$(exec_generate '--uuid')}"
    # 获取或生成 Trojan 密码
    local TROJAN_PASSWORD="${CONFIG_DATA['password']:-$(exec_generate '--password')}"
    # 获取或生成 mKCP Seed
    local KCP_SEED="${CONFIG_DATA['seed']:-$(exec_generate '--password')}"
    # 获取或生成 XHTTP 路径
    local XHTTP_PATH="${CONFIG_DATA['path']:-$(exec_generate '--path')}"
    # 获取或生成目标域名
    local TARGET_DOMAIN="${CONFIG_DATA['target']:-$(exec_generate '--target')}"
    # 生成服务器名称列表
    local SERVER_NAMES
    SERVER_NAMES="$(exec_generate '--server-names' "${TARGET_DOMAIN}")"
    # 获取 CDN 域名
    local CDN_DOMAIN="${CONFIG_DATA['cdn']:-}"
    # 获取或生成 Short IDs
    local SHORT_IDS
    SHORT_IDS="$(exec_generate '--short-ids' ${CONFIG_DATA['short_ids']:-'8 8'})"
    # 获取 CA 邮箱
    local CA_EMAIL="${CONFIG_DATA['email']:-}"
    # 更新脚本配置中的规则状态
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg reset "${XRAY_RULES_STATUS,,}" ' if $reset != "n" then .xray.rules.reset = 1 else .xray.rules.reset = 0 end ')"
    # 更新脚本配置中的 block bt 状态
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg bt "${XRAY_RULES_BT,,}" ' if $bt != "n" then .xray.rules.bt = 1 else .xray.rules.bt = 0 end ')"
    # 更新脚本配置中的 block cn 状态
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg cn "${XRAY_RULES_CN,,}" ' if $cn != "n" then .xray.rules.cn = 1 else .xray.rules.cn = 0 end ')"
    # 更新脚本配置中的 block ad 状态
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg ad "${XRAY_RULES_AD,,}" ' if $ad != "n" then .xray.rules.ad = 1 else .xray.rules.ad = 0 end ')"
    # 根据配置标签更新特定字段
    case "${CONFIG_TAG,,}" in
    trojan)
        # 更新 Trojan 密码
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg password "${TROJAN_PASSWORD}" '.xray.trojan = $password')"
        ;;
    mkcp | vision | xhttp | fallback | sni)
        # 更新 UUID
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg uuid "${XRAY_UUID}" '.xray.uuid = $uuid')"
        ;;
    esac
    # 根据配置标签更新特定字段 (第二部分)
    case "${CONFIG_TAG,,}" in
    fallback)
        # 更新 Fallback UUID
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg uuid "${FALLBACK_UUID}" '.xray.fallback = $uuid')"
        ;;
    mkcp)
        # 为 mKCP 生成随机端口并更新 Seed
        XRAY_PORT="$(exec_generate '--port')"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg seed "${KCP_SEED}" '.xray.kcp = $seed')"
        ;;
    sni)
        # 更新 Fallback UUID
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg uuid "${FALLBACK_UUID}" '.xray.fallback = $uuid')"
        # 为 SNI 更新 CA 邮箱、域名和 CDN
        [[ -n "${CA_EMAIL}" ]] && SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg ca "${CA_EMAIL}" '.nginx.ca = $ca')"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg domain "${TARGET_DOMAIN}" '.nginx.domain = $domain')"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg cdn "${CDN_DOMAIN}" '.nginx.cdn = $cdn')"
        ;;
    esac
    # 根据配置标签更新特定字段 (第三部分)
    case "${CONFIG_TAG,,}" in
    xhttp | trojan | fallback | sni)
        # 更新路径
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg path "${XHTTP_PATH}" '.xray.path = $path')"
        ;;
    esac
    # 根据配置标签更新特定字段 (第四部分)
    case "${CONFIG_TAG,,}" in
    vision | xhttp | trojan | fallback | sni)
        # 更新目标域名、服务器名称和 Short IDs
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg target "${TARGET_DOMAIN}" '.xray.target = $target')"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --argjson serverNames "${SERVER_NAMES}" '.xray.serverNames = $serverNames')"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --argjson shortIds "${SHORT_IDS}" '.xray.shortIds = $shortIds')"
        ;;
    esac
    # 更新配置标签和端口
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg tag "${CONFIG_TAG}" '.xray.tag = $tag')"
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --argjson port "${XRAY_PORT}" '.xray.port = $port')"
    # 将更新后的脚本配置写入文件
    persist_script_config
}

# =============================================================================
# 函数名称: handler_x25519_config
# 功能描述: 处理并更新脚本配置文件 (config.json)。
#           1. 获取 X25519 密钥对。
#           2. 将 X25519 密钥对写入 SCRIPT_CONFIG_PATH 文件。
# 参数: 无
# 返回值: 无 (直接修改 SCRIPT_CONFIG 全局变量和 SCRIPT_CONFIG_PATH 文件)
# =============================================================================
function handler_x25519_config() {
    # 打印绿色的配置更新提示
    echo -e "${GREEN}[$(_i18n '.title.config')]${NC} $(_i18n ".${CUR_FILE}.script.config_update")" >&2
    # 生成 X25519 密钥对
    local X25519
    X25519="$(exec_generate '--x25519')"
    # 提取私钥
    local PRIVATE_KEY
    PRIVATE_KEY="$(echo "${X25519}" | awk -F, '{print $1}')"
    # 提取公钥
    local PUBLIC_KEY
    PUBLIC_KEY="$(echo "${X25519}" | awk -F, '{print $2}')"
    # 提取 Hash32
    local HASH32
    HASH32="$(echo "${X25519}" | awk -F, '{print $3}')"
    # 输出显示 x25519 密钥对
    # 注: 原写法 `"...${NC} "${KEY}""` 中间那对引号实际闭合在外层引号之后,
    #     ${KEY} 处于**未加引号**状态会被 IFS 拆词 (SC2027)。
    #
    # 私钥默认**不回显**: Reality 私钥是长期密钥, 一旦落到终端回滚 / screen 或 tmux
    # 日志 / 运维录屏 / `2>log` 重定向里, 等同永久泄露, 且它并不需要给到客户端
    # (客户端只需 Public Key 与 Short ID)。私钥已写入脚本配置, 需要时读该文件即可。
    # 仅当显式设置 SHOW_PRIVATE_KEY=1 时才打印明文, 供迁移/调试等确有必要的场景。
    if is_enabled "${SHOW_PRIVATE_KEY:-0}"; then
        echo -e "${GREEN}[Private Key]${NC} ${PRIVATE_KEY}" >&2
    else
        echo -e "${YELLOW}[Private Key]${NC} $(_i18n ".${CUR_FILE}.script.private_key_hidden")" >&2
    fi
    echo -e "${GREEN}[Public Key]${NC} ${PUBLIC_KEY}" >&2
    echo -e "${GREEN}[Hash32]${NC} ${HASH32}" >&2
    # 更新脚本配置中的私钥和公钥，以及哈希值
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg privateKey "${PRIVATE_KEY}" '.xray.privateKey = $privateKey')"
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg publicKey "${PUBLIC_KEY}" '.xray.publicKey = $publicKey')"
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg hash32 "${HASH32}" '.xray.hash32 = $hash32')"
    # 将更新后的脚本配置写入文件
    persist_script_config
}

# =============================================================================
# 函数名称: handler_xray_config
# 功能描述: 处理并更新 Xray 核心配置文件 (/usr/local/etc/xray/config.json)。
#           1. 打印配置更新提示。
#           2. 从脚本配置中读取各项参数。
#           3. 加载对应配置标签的模板文件。
#           4. 根据配置标签和参数替换模板中的占位符。
#           5. 处理路由规则 (保留当前规则或重置并添加默认规则)。
#           6. 将更新后的配置写回 XRAY_CONFIG_PATH 和 SCRIPT_CONFIG_PATH 文件。
# 参数: 无
# 返回值: 无 (直接修改 XRAY_CONFIG 全局变量和 XRAY_CONFIG_PATH/SCRIPT_CONFIG_PATH 文件)
# =============================================================================
function handler_xray_config() {
    # 打印绿色的 Xray 配置更新提示
    echo -e "${GREEN}[$(_i18n '.title.config')]${NC} $(_i18n ".${CUR_FILE}.xray.config_update")" >&2
    # 从脚本配置中读取各项参数
    local CONFIG_TAG
    CONFIG_TAG="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag')"                # 获取配置标签
    local XRAY_PORT
    XRAY_PORT="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.port')"                # 获取端口
    local XRAY_UUID
    XRAY_UUID="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.uuid')"                # 获取 UUID
    local FALLBACK_UUID
    FALLBACK_UUID="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.fallback')"        # 获取 Fallback UUID
    local TROJAN_PASSWORD
    TROJAN_PASSWORD="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.trojan')"        # 获取 Trojan 密码
    local KCP_SEED
    KCP_SEED="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.kcp')"                  # 获取 mKCP Seed
    local TARGET_DOMAIN
    TARGET_DOMAIN="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.target')"          # 获取目标域名
    local SERVER_NAMES
    SERVER_NAMES="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.serverNames')"      # 获取服务器名称
    local PRIVATE_KEY
    PRIVATE_KEY="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.privateKey')"        # 获取私钥
    local SHORT_IDS
    SHORT_IDS="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.shortIds')"            # 获取 Short IDs
    local XHTTP_PATH
    XHTTP_PATH="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.path')"               # 获取路径
    local XRAY_RULES_STATUS
    XRAY_RULES_STATUS="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.rules.reset')" # 获取规则状态
    local XRAY_RULES_BT
    XRAY_RULES_BT="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.rules.bt')"        # 获取 bt 规则状态
    local XRAY_RULES_CN
    XRAY_RULES_CN="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.rules.cn')"        # 获取 cn 规则状态
    local XRAY_RULES_AD
    XRAY_RULES_AD="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.rules.ad')"        # 获取 ad 规则状态
    local XRAY_RULES
    XRAY_RULES="$(echo "${SCRIPT_CONFIG}" | jq -r '.rules')"                   # 获取路由规则
    local WARP_STATUS
    # 注: 与其它取 WARP 状态的调用点保持一致加 `|| true` —— jq 失败时取空串即可,
    #     不应让 set -e 把整个配置生成流程打断 (下方 is_enabled 会把空串当未启用)。
    WARP_STATUS="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.warp' || true)"      # 获取 WARP 状态
    # 加载对应配置标签的 Xray 配置模板
    XRAY_CONFIG="$(jq '.' ${SCRIPT_XRAY_DIR}/${CONFIG_TAG}.json)"
    # 如果配置标签不是 sni，则更新端口
    if [[ "${CONFIG_TAG,,}" != 'sni' ]]; then
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson port "${XRAY_PORT}" '.inbounds[1].port = $port')"
    fi
    # 根据配置标签更新特定字段 (第一部分)
    case "${CONFIG_TAG,,}" in
    mkcp | vision | xhttp | fallback | sni)
        # 更新客户端 UUID
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg uuid "${XRAY_UUID}" '.inbounds[1].settings.clients[0].id = $uuid')"
        ;;
    trojan)
        # 更新 Trojan 客户端密码
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg password "${TROJAN_PASSWORD}" '.inbounds[1].settings.clients[0].password = $password')"
        ;;
    esac
    # P-优化: REALITY serverNames 守卫 —— 防手滑把占位符/空值写进 .xray.serverNames,
    #   导致握手失败或把伪装目标暴露成 example.com。
    #   - 非空且非占位符 example.com;
    #   - 非 sni 模板时, serverNames 必须包含 target 域名 (REALITY 要求 SNI 命中其中一个)。
    case "${CONFIG_TAG,,}" in
    vision | xhttp | trojan | fallback | sni)
        if [[ -z "${SERVER_NAMES}" || "${SERVER_NAMES}" == '[]' || "${SERVER_NAMES}" == 'null' ]]; then
            _error "REALITY serverNames 为空, 请先配置 .xray.serverNames (config.json)"
        fi
        if [[ "${SERVER_NAMES}" == *'example.com'* ]]; then
            _error "REALITY serverNames 含占位符 example.com, 请改为真实 target 域名"
        fi
        if [[ "${CONFIG_TAG,,}" != 'sni' ]]; then
            if ! echo "${SERVER_NAMES}" | jq -e --arg d "${TARGET_DOMAIN}" 'any(.[]; . == $d)' >/dev/null 2>&1; then
                _error "REALITY serverNames 必须包含 target 域名 ${TARGET_DOMAIN} (config.json 的 .xray.serverNames)"
            fi
        fi
        ;;
    esac
    # 根据配置标签更新特定字段 (第二部分)
    case "${CONFIG_TAG,,}" in
    mkcp)
        # 更新 mKCP Seed
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg seed "${KCP_SEED}" '.inbounds[1].streamSettings.kcpSettings.seed = $seed')"
        ;;
    vision | xhttp | trojan | fallback | sni)
        # 如果不是 sni 配置，更新 Reality 目标
        if [[ "${CONFIG_TAG,,}" != 'sni' ]]; then
            XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg target "${TARGET_DOMAIN}:443" '.inbounds[1].streamSettings.realitySettings.target = $target')"
        fi
        # 更新 Reality 服务器名称、私钥和 Short IDs
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson serverNames "${SERVER_NAMES}" '.inbounds[1].streamSettings.realitySettings.serverNames = $serverNames')"
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg privateKey "${PRIVATE_KEY}" '.inbounds[1].streamSettings.realitySettings.privateKey = $privateKey')"
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson shortIds "${SHORT_IDS}" '.inbounds[1].streamSettings.realitySettings.shortIds = $shortIds')"
        ;;
    esac
    # 根据配置标签更新特定字段 (第三部分)
    case "${CONFIG_TAG,,}" in
    xhttp | trojan)
        # 更新 XHTTP 路径
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg path "${XHTTP_PATH}" '.inbounds[1].streamSettings.xhttpSettings.path = $path')"
        ;;
    fallback | sni)
        # 更新 Fallback 客户端 UUID 和 XHTTP 路径
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg uuid "${FALLBACK_UUID}" '.inbounds[2].settings.clients[0].id = $uuid')"
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg path "${XHTTP_PATH}" '.inbounds[2].streamSettings.xhttpSettings.path = $path')"
        ;;
    esac
    # 处理路由规则
    case "${XRAY_RULES_STATUS}" in
    0)
        # 保留当前路由规则
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson rules "${XRAY_RULES}" '.routing.rules = $rules')"
        ;;
    1)
        # 重置并添加默认路由规则
        # 修复: 这三个值的实际取值是用户输入的 "Y" / "N" (见 exec_read 的默认处理),
        #       不是数字 —— 原 `-eq 1` 遇到 "Y" 会触发算术求值并在 set -u 下崩溃
        #       (实测: bash: Y: 未绑定的变量), 用户一旦选择"阻止 BT"就直接中断。
        #       现统一走 is_enabled, 语义与写入脚本配置时的判定 ($bt != "n") 一致。
        is_enabled "${XRAY_RULES_BT}" && add_rule "bt" "protocol" "bittorrent" "block" 1
        is_enabled "${XRAY_RULES_CN}" && add_rule "cn-ip" "ip" "geoip:cn" "block" "after" "private-ip"
        is_enabled "${XRAY_RULES_AD}" && add_rule "ad-domain" "domain" "geosite:category-ads-all" "block"
        ;;
    esac
    # 处理 WARP 状态
    if is_enabled "${WARP_STATUS}"; then
        # 获取 WARP 容器 IP
        local container_ip
        container_ip="$(exec_docker '--obtain-container-ip')"
        # 构造 WARP Socks 出站配置 JSON
        local socks_config='[{"tag":"warp","protocol":"socks","settings":{"servers":[{"address":"'"${container_ip}"'","port":40001}]}}]'
        # 将 WARP 出站配置添加到 Xray 配置中
        XRAY_CONFIG=$(echo "${XRAY_CONFIG}" | jq --argjson socks_config "${socks_config}" '.outbounds += $socks_config')
    fi
    # 获取更新后的路由规则
    XRAY_RULES="$(echo "${XRAY_CONFIG}" | jq '.routing.rules')"
    # 更新脚本配置中的路由规则
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --argjson rules "${XRAY_RULES}" '.rules = $rules')"
    # 将更新后的脚本配置和 Xray 配置写入文件
    persist_script_config
    persist_xray_config
}

# =============================================================================
# 函数名称: handler_read_xray_config
# 功能描述: 读取 Xray 配置所需的用户输入。
#           1. 验证配置标签的有效性。
#           2. 根据脚本配置决定是否需要读取规则相关输入。
#           3. 根据配置标签读取对应的各项配置参数。
# 参数:
#   $1: CONFIG_TAG - 配置标签 (例如 Vision, XHTTP, SNI 等)
# 返回值: 无 (直接修改 CONFIG_DATA 全局关联数组)
# 退出码: 如果配置标签无效，则退出脚本 (exit 1)
# =============================================================================
function handler_read_xray_config() {
    local CONFIG_TAG="${1:-}" # 获取配置标签
    # 验证配置标签的有效性，无效则退出
    if ! exec_check '--tag' "${CONFIG_TAG}"; then
        exit 1
    fi
    # 将配置标签存储到 CONFIG_DATA
    CONFIG_DATA['tag']="${CONFIG_TAG}"
    # 检查脚本配置中的规则状态，如果是 current 或 reset 则读取规则输入
    if echo "${SCRIPT_CONFIG}" | jq -r '.xray.rules.reset' | grep -Eq '^(0|1)$'; then
        exec_read 'rules'
    fi
    # 如果规则状态不是 'n'，则读取阻止选项
    local _rules_status="${CONFIG_DATA['rules']:-}"
    if [[ "${_rules_status,,}" != 'n' ]]; then
        exec_read 'block-bt'
        exec_read 'block-cn'
        exec_read 'block-ad'
    fi
    # 读取端口
    exec_read 'port'
    # 根据配置标签读取特定参数 (第一部分)
    case "${CONFIG_TAG,,}" in
    trojan) exec_read 'password' ;;                             # 读取 Trojan 密码
    mkcp | vision | xhttp | fallback | sni) exec_read 'uuid' ;; # 读取 UUID
    esac
    # 根据配置标签读取特定参数 (第二部分)
    case "${CONFIG_TAG,,}" in
    fallback | sni) exec_read 'fallback' ;; # 读取 Fallback UUID
    mkcp) exec_read 'seed' ;;               # 读取 mKCP Seed
    esac
    # 根据配置标签读取特定参数 (第三部分)
    case "${CONFIG_TAG,,}" in
    vision | xhttp | trojan | fallback) exec_read 'target' ;; # 读取目标域名
    sni)
        # 为 SNI 配置读取域名和 CDN
        local CA_EMAIL
        CA_EMAIL="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.ca' || true)"
        # 如果 CA 邮箱为空，则读取邮箱
        [[ -z "${CA_EMAIL}" ]] && exec_read 'email'
        exec_read 'domain' # 读取域名
        exec_read 'cdn'    # 读取 CDN
        ;;
    esac
    # 根据配置标签读取特定参数 (第四部分)
    case "${CONFIG_TAG,,}" in
    vision | xhttp | trojan | fallback | sni) exec_read 'short' ;; # 读取 Short IDs
    esac
    # 根据配置标签读取特定参数 (第五部分)
    case "${CONFIG_TAG,,}" in
    xhttp | trojan | fallback | sni) exec_read 'path' ;; # 读取路径
    esac
}

# =============================================================================
# 函数名称: handler_sni_config
# 功能描述: 处理 SNI 配置相关的特殊操作。
#           1. 根据当前配置标签决定是否需要停止相关服务。
#           2. 如果是 SNI 配置，则调用 handler_web 配置 Web 服务。
# 参数:
#   $1: web - Web 服务类型 (normal, v3, v4)
# 返回值: 无 (通过调用其他函数执行操作)
# =============================================================================
function handler_sni_config() {
    # 从脚本配置中读取当前配置标签
    local CONFIG_TAG
    CONFIG_TAG="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag' || true)"
    local web="${1:-}" # 获取 Web 服务类型参数
    # 根据当前配置标签执行不同操作
    case "${CONFIG_TAG,,}" in
    mkcp | vision | xhttp | trojan | fallback)
        # 对于非 SNI 配置，停止 Nginx 服务
        handler_nginx_stop
        ;;
    sni)
        # 为域名和 CDN 配置 Nginx 和 SSL
        handler_change_domain 'domain' 'n'
        handler_change_domain 'cdn' 'n'
        if (( $(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.custom_sites // [] | length') > 0 )); then
            echo -e "${GREEN}[$(_i18n '.title.info')]${NC} $(_i18n ".${CUR_FILE}.custom_sites.syncing")" >&2
            sync_custom_sites_config "${SCRIPT_CONFIG}" || _error "failed to sync custom sites"
            rebuild_stream_config "${SCRIPT_CONFIG}"
        fi
        # 对于 SNI 配置，调用 handler_web 配置 Web 服务
        handler_web "${web}"
        ;;
    esac
}

# =============================================================================
# 函数名称: handler_check_sni_ports
# 功能描述: SNI 配置前的端口预检。预检失败时先分辨是否为"自家非 SNI xray 仍占着 443"
#           这一可自愈场景: 是则临时停 xray 让位后复检, 通过即放行 (随后 --restart 会
#           重新拉起); 仍未通过则恢复现场并按真实原因报错。
# 参数: 无
# 返回值: 0-预检通过 (失败时 _error 退出)
# =============================================================================
function handler_check_sni_ports() {
    # 预检通过则直接放行
    if exec_check '--sni-ports'; then
        return 0
    fi
    # 预检失败: 先分辨是否为「自家非 SNI xray 仍占着 443」这一可自愈场景。
    # 背景: 非 SNI 模式 xray 直听 443, 而本预检发生在 --script-config SNI 之前,
    #       此刻 xray 仍以旧配置运行 → 必然撞车, 形成「Vision 装好却换不了 SNI」的死结。
    #       预检本意是挡"别人"占端口, 不该拦自己, 故此处主动让位后再复检。
    if port_held_by_xray '443'; then
        echo -e "${YELLOW}[$(_i18n '.title.tip')]${NC} $(_i18n ".${CUR_FILE}.sni.port_guard_self_stop")" >&2
        # 只停服务, 不动 enable 状态: 随后的 --restart 会重新拉起并保持开机自启
        systemctl -q stop xray || true
        if exec_check '--sni-ports'; then
            return 0
        fi
        # 复检仍未通过 → 说明还有别的端口被"他人"占着, 回滚刚做的变更,
        # 保持现场原样, 让用户按真实原因处理后重试
        _ensure_xray_runtime_dirs
        systemctl -q start xray || true
    fi
    _error "$(_i18n ".${CUR_FILE}.sni.port_guard_fail")"
}

# =============================================================================
# 函数名称: handler_custom_site_list
# 功能描述: 打印自定义站点清单 (handler 入口, 转调 show_custom_sites_list)。
# 参数: 无
# 返回值: 恒 0
# =============================================================================
function handler_custom_site_list() {
    show_custom_sites_list
}

# =============================================================================
# 函数名称: handler_custom_site_add
# 功能描述: 新增一个自定义反代站点: 读取域名与代理目标, 签发证书, 渲染站点配置并
#           启用, 重建 stream 配置后校验重载。任一步失败均回滚 (删配置 / 恢复 stream
#           备份 / 撤销续期) 并报错, 不留半配置状态。
# 参数: 无 (交互式读取)
# 返回值: 无 (失败时 _error 退出)
# =============================================================================
function handler_custom_site_add() {
    local domain=''
    local proxy_target=''
    local scheme=''
    local host=''
    local port=''
    local updated_script_config=''
    local conf_path=''
    local link_path=''
    local stream_backup="${SCRIPT_CONFIG_DIR}/stream.conf.custom-sites.bak"

    exec_read 'custom-domain'
    exec_read 'proxy-target'

    domain="${CONFIG_DATA['custom-domain']:-}"
    proxy_target="${CONFIG_DATA['proxy-target']:-}"
    IFS=$'\t' read -r scheme host port <<<"$(parse_proxy_target "${proxy_target}")" || _error "failed to parse proxy target"

    updated_script_config="$(echo "${SCRIPT_CONFIG}" | jq \
        --arg domain "${domain}" \
        --arg scheme "${scheme}" \
        --arg host "${host}" \
        --argjson port "${port}" \
        '.nginx.custom_sites = ((.nginx.custom_sites // []) + [{"domain": $domain, "scheme": $scheme, "host": $host, "port": $port}])')"

    conf_path="${NGINX_CONFIG_DIR}/sites-available/${domain}.conf"
    link_path="${NGINX_CONFIG_DIR}/sites-enabled/${domain}.conf"
    [[ -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" ]] && cp -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" "${stream_backup}"

    exec_ssl '--issue' "--domain=${domain}" || _error "failed to issue certificate for ${domain}"
    if ! render_custom_site_config "${domain}" "${scheme}" "${host}" "${port}" "${conf_path}"; then
        rollback_stream_config_backup "${stream_backup}"
        exec_ssl '--stop-renew' "--domain=${domain}" || true
        _error "failed to render custom site config"
    fi
    if ! ln -sf "${conf_path}" "${link_path}"; then
        rm -f "${conf_path}"
        rollback_stream_config_backup "${stream_backup}"
        exec_ssl '--stop-renew' "--domain=${domain}" || true
        _error "failed to enable custom site config"
    fi
    rebuild_stream_config "${updated_script_config}"

    if ! test_and_reload_nginx; then
        rm -f "${conf_path}" "${link_path}"
        rollback_stream_config_backup "${stream_backup}"
        exec_ssl '--stop-renew' "--domain=${domain}" || true
        test_and_reload_nginx || true
        _error "failed to apply custom site ${domain}"
    fi

    rm -f "${stream_backup}"
    SCRIPT_CONFIG="${updated_script_config}"
    persist_script_config
    echo -e "${GREEN}[$(_i18n '.title.info')]${NC} $(_i18n ".${CUR_FILE}.custom_sites.added")${domain}" >&2
}

# =============================================================================
# 函数名称: handler_custom_site_update
# 功能描述: 修改已有自定义站点 (域名或代理目标)。域名未变时仅重渲染同一份配置;
#           域名变更时为新域签发证书、切换配置与软链并撤销旧域续期。任一步失败按
#           新旧域名分别回滚到变更前状态并报错。
# 参数: 无 (交互式读取序号与字段)
# 返回值: 无 (失败时 _error 退出)
# =============================================================================
function handler_custom_site_update() {
    local custom_site_count
    custom_site_count="$(get_custom_sites_count)"
    local site_index=''
    local current_site=''
    local old_domain=''
    local old_scheme=''
    local old_host=''
    local old_port=''
    local old_proxy_target=''
    local new_domain=''
    local new_proxy_target=''
    local new_scheme=''
    local new_host=''
    local new_port=''
    local updated_script_config=''
    local old_conf_path=''
    local new_conf_path=''
    local old_link_path=''
    local new_link_path=''
    local old_conf_backup=''
    local stream_backup="${SCRIPT_CONFIG_DIR}/stream.conf.custom-sites.bak"

    show_custom_sites_list
    ((custom_site_count > 0)) || return 0
    CONFIG_DATA['site-count']="${custom_site_count}"
    exec_read 'site-index'
    site_index="${CONFIG_DATA['site-index']:-}"
    current_site="$(get_custom_site_json_by_index "${site_index}")"

    old_domain="$(echo "${current_site}" | jq -r '.domain')"
    old_scheme="$(echo "${current_site}" | jq -r '.scheme')"
    old_host="$(echo "${current_site}" | jq -r '.host')"
    old_port="$(echo "${current_site}" | jq -r '.port')"
    old_proxy_target="${old_scheme}://${old_host}:${old_port}"

    new_domain="$(read_custom_site_domain_update "${old_domain}")"
    new_proxy_target="$(read_custom_site_proxy_target_update "${old_proxy_target}")"
    IFS=$'\t' read -r new_scheme new_host new_port <<<"$(parse_proxy_target "${new_proxy_target}")" || _error "failed to parse proxy target"

    updated_script_config="$(echo "${SCRIPT_CONFIG}" | jq \
        --argjson idx "$((site_index - 1))" \
        --arg domain "${new_domain}" \
        --arg scheme "${new_scheme}" \
        --arg host "${new_host}" \
        --argjson port "${new_port}" \
        '.nginx.custom_sites[$idx] = {"domain": $domain, "scheme": $scheme, "host": $host, "port": $port}')"

    old_conf_path="${NGINX_CONFIG_DIR}/sites-available/${old_domain}.conf"
    new_conf_path="${NGINX_CONFIG_DIR}/sites-available/${new_domain}.conf"
    old_link_path="${NGINX_CONFIG_DIR}/sites-enabled/${old_domain}.conf"
    new_link_path="${NGINX_CONFIG_DIR}/sites-enabled/${new_domain}.conf"
    old_conf_backup="${SCRIPT_CONFIG_DIR}/${old_domain}.custom-site.bak.conf"
    [[ -f "${old_conf_path}" ]] && cp -f "${old_conf_path}" "${old_conf_backup}"
    [[ -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" ]] && cp -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" "${stream_backup}"

    if [[ "${new_domain}" == "${old_domain}" ]]; then
        [[ "${new_proxy_target}" != "${old_proxy_target}" ]] && echo -e "${GREEN}[$(_i18n '.title.info')]${NC} $(_i18n ".${CUR_FILE}.custom_sites.upstream_only")" >&2
        if ! render_custom_site_config "${new_domain}" "${new_scheme}" "${new_host}" "${new_port}" "${new_conf_path}"; then
            [[ -f "${old_conf_backup}" ]] && mv -f "${old_conf_backup}" "${old_conf_path}"
            rollback_stream_config_backup "${stream_backup}"
            _error "failed to render custom site config"
        fi
        if ! ln -sf "${new_conf_path}" "${new_link_path}"; then
            [[ -f "${old_conf_backup}" ]] && mv -f "${old_conf_backup}" "${old_conf_path}"
            rollback_stream_config_backup "${stream_backup}"
            _error "failed to enable custom site config"
        fi
        rebuild_stream_config "${updated_script_config}"

        if ! test_and_reload_nginx; then
            [[ -f "${old_conf_backup}" ]] && mv -f "${old_conf_backup}" "${old_conf_path}"
            ln -sf "${old_conf_path}" "${old_link_path}" || true
            rollback_stream_config_backup "${stream_backup}"
            test_and_reload_nginx || true
            _error "failed to update custom site ${old_domain}"
        fi
    else
        exec_ssl '--issue' "--domain=${new_domain}" || _error "failed to issue certificate for ${new_domain}"
        if ! render_custom_site_config "${new_domain}" "${new_scheme}" "${new_host}" "${new_port}" "${new_conf_path}"; then
            rollback_stream_config_backup "${stream_backup}"
            exec_ssl '--stop-renew' "--domain=${new_domain}" || true
            _error "failed to render custom site config"
        fi
        if ! ln -sf "${new_conf_path}" "${new_link_path}"; then
            rm -f "${new_conf_path}"
            rollback_stream_config_backup "${stream_backup}"
            exec_ssl '--stop-renew' "--domain=${new_domain}" || true
            _error "failed to enable custom site config"
        fi
        rm -f "${old_conf_path}" "${old_link_path}"
        rebuild_stream_config "${updated_script_config}"

        if ! test_and_reload_nginx; then
            rm -f "${new_conf_path}" "${new_link_path}"
            [[ -f "${old_conf_backup}" ]] && mv -f "${old_conf_backup}" "${old_conf_path}"
            ln -sf "${old_conf_path}" "${old_link_path}" || true
            rollback_stream_config_backup "${stream_backup}"
            exec_ssl '--stop-renew' "--domain=${new_domain}" || true
            test_and_reload_nginx || true
            _error "failed to switch custom site domain ${old_domain} -> ${new_domain}"
        fi
        exec_ssl '--stop-renew' "--domain=${old_domain}" || true
    fi

    rm -f "${old_conf_backup}" "${stream_backup}"
    SCRIPT_CONFIG="${updated_script_config}"
    persist_script_config
    echo -e "${GREEN}[$(_i18n '.title.info')]${NC} $(_i18n ".${CUR_FILE}.custom_sites.updated")${new_domain}" >&2
}

# =============================================================================
# 函数名称: handler_custom_site_delete
# 功能描述: 删除一个自定义站点: 移除配置与软链, 重建 stream 配置后校验重载; 失败则
#           从备份恢复并报错。成功后停止该域名的证书续期。
# 参数: 无 (交互式读取序号)
# 返回值: 无 (失败时 _error 退出)
# =============================================================================
function handler_custom_site_delete() {
    local custom_site_count
    custom_site_count="$(get_custom_sites_count)"
    local site_index=''
    local current_site=''
    local domain=''
    local conf_path=''
    local link_path=''
    local conf_backup=''
    local stream_backup="${SCRIPT_CONFIG_DIR}/stream.conf.custom-sites.bak"
    local updated_script_config=''

    show_custom_sites_list
    ((custom_site_count > 0)) || return 0
    CONFIG_DATA['site-count']="${custom_site_count}"
    exec_read 'site-index'
    site_index="${CONFIG_DATA['site-index']:-}"
    current_site="$(get_custom_site_json_by_index "${site_index}")"
    domain="$(echo "${current_site}" | jq -r '.domain')"
    conf_path="${NGINX_CONFIG_DIR}/sites-available/${domain}.conf"
    link_path="${NGINX_CONFIG_DIR}/sites-enabled/${domain}.conf"
    conf_backup="${SCRIPT_CONFIG_DIR}/${domain}.custom-site.bak.conf"

    updated_script_config="$(echo "${SCRIPT_CONFIG}" | jq --argjson idx "$((site_index - 1))" 'del(.nginx.custom_sites[$idx])')"
    [[ -f "${conf_path}" ]] && cp -f "${conf_path}" "${conf_backup}"
    [[ -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" ]] && cp -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" "${stream_backup}"

    rm -f "${conf_path}" "${link_path}"
    rebuild_stream_config "${updated_script_config}"

    if ! test_and_reload_nginx; then
        [[ -f "${conf_backup}" ]] && mv -f "${conf_backup}" "${conf_path}"
        ln -sf "${conf_path}" "${link_path}" || true
        rollback_stream_config_backup "${stream_backup}"
        test_and_reload_nginx || true
        _error "failed to delete custom site ${domain}"
    fi

    rm -f "${conf_backup}" "${stream_backup}"
    SCRIPT_CONFIG="${updated_script_config}"
    persist_script_config
    exec_ssl '--stop-renew' "--domain=${domain}" || true
    echo -e "${GREEN}[$(_i18n '.title.info')]${NC} $(_i18n ".${CUR_FILE}.custom_sites.deleted")${domain}" >&2
}

# =============================================================================
# 函数名称: handler_custom_sites
# 功能描述: 自定义站点功能的分发入口, 按动作派发到 list / add / update / delete。
# 参数:
#   $1: action - 动作 (list / add / update / delete)
# 返回值: 无 (未知动作时 _error 退出)
# =============================================================================
function handler_custom_sites() {
    case "${1:-}" in
    list) handler_custom_site_list ;;
    add) handler_custom_site_add ;;
    update) handler_custom_site_update ;;
    delete) handler_custom_site_delete ;;
    *) _error "unsupported custom site action: ${1:-}" ;;
    esac
}

# =============================================================================
# 函数名称: handler_xray_version
# 功能描述: 处理 Xray 版本配置。
#           1. 根据输入参数确定 Xray 版本。
#           2. 从 GitHub API 获取最新版本或自定义版本。
#           3. 将版本信息更新到脚本配置中。
# 参数:
#   $1: xray_version - 版本指定 ("latest", "custom", 或具体版本号)，默认为 release
# 返回值: 无 (直接修改 CONFIG_DATA 和 SCRIPT_CONFIG 全局变量)
# =============================================================================
function handler_xray_version() {
    local xray_version="${1:-}" # 获取版本指定参数
    # 根据版本指定参数确定具体版本
    case "${xray_version,,}" in
    latest)
        # 获取最新的 Xray 版本 (网络/API 失败时留空由上层回退, 不因 set -e 直接终止)
        CONFIG_DATA['version']="$(curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 "$(_gh_url 'https://api.github.com/repos/XTLS/Xray-core/releases')" | jq -r '.[0].tag_name')" || CONFIG_DATA['version']=""
        ;;
    custom)
        # 读取用户自定义的版本
        exec_read 'version'
        ;;
    *)
        # 获取最新的 release 版本 (网络/API 失败时留空由上层回退, 不因 set -e 直接终止)
        CONFIG_DATA['version']="$(curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 "$(_gh_url 'https://api.github.com/repos/XTLS/Xray-core/releases/latest')" | jq -r '.tag_name')" || CONFIG_DATA['version']=""
        ;;
    esac
    # 更新脚本配置中的 Xray 版本
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg xray "${CONFIG_DATA['version']:-}" '.xray.version = $xray')"
    # 将更新后的脚本配置写入文件
    persist_script_config
}

# =============================================================================
# 函数名称: handler_change_xray_port
# 功能描述: 修改 Xray 端口配置。
# 参数: 无
# 返回值: 无 (直接修改 SCRIPT_CONFIG 全局变量)
# =============================================================================
function handler_change_xray_port() {
    # 默认端口
    local XRAY_PORT="443"
    # 获取配置标签
    local CONFIG_TAG
    CONFIG_TAG="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag' || true)"

    # 读取端口
    exec_read 'port'

    # 根据配置标签处理端口
    case "${CONFIG_TAG,,}" in
    mkcp)
        # 输入为空，则默认为 mKCP 生成随机端口
        XRAY_PORT="${CONFIG_DATA['port']:-$(exec_generate '--port')}"
        ;;
    *)
        # 输入为空，则使用默认端口
        XRAY_PORT="${CONFIG_DATA['port']:-${XRAY_PORT}}"
        ;;
    esac

    # 更新脚本配置中的 Xray 端口
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --argjson port "${XRAY_PORT}" '.xray.port = $port')"
    # 将更新后的脚本配置写入文件
    persist_script_config
}

# =============================================================================
# 函数名称: handler_install
# 功能描述: 安装 Xray 核心。
#           1. 确定要安装的 Xray 版本。
#           2. 检查系统中是否已安装 Xray。
#           3. 如果未安装或强制安装，则从 Xray-install 脚本安装。
# 参数:
#   $1: xray_version - (可选) 要安装的 Xray 版本
#   $2: force_install - (可选) 是否强制安装 ('y' 表示强制)，默认为 'n'
# 返回值: 无 (通过调用外部脚本执行安装)
# =============================================================================
function handler_install() {
    local xray_version="${1:-}"       # 获取版本参数
    local force_install="${2:-n}" # 获取强制安装参数，默认为 'n'
    # 如果提供了版本参数，则处理版本配置
    if [[ -n "${xray_version}" ]]; then
        handler_xray_version "${xray_version}"
    else
        # 否则从脚本配置中读取版本
        CONFIG_DATA['version']="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.version')"
    fi
    # 检查 Xray 命令是否存在，或是否强制安装
    if ! cmd_exists 'xray' || [[ "${force_install}" != n ]]; then
        # 下载 Xray-install 脚本(固定 commit) → 完整性体检(体积+语法+SHA256) → 执行
        # 取代原 `curl | bash -c` 管道; 版本与摘要见文件顶部的 XRAY_INSTALL_* 常量。
        local install_script=''
        if ! install_script="$(_download_verified "${XRAY_INSTALL_URL}" "${XRAY_INSTALL_SHA256}")"; then
            _error "$(_i18n ".${CUR_FILE}.install.fail_download")"
        fi
        # 调用 Xray-install 脚本进行安装 ($0 仅影响其帮助/报错文案, 不影响行为)
        # 注: install-release.sh 在全新安装时会 `rm`(无 -f) 删除尚不存在的 systemd
        #     drop-in 文件 (10-donot_touch_multi_conf.conf 等) 而返回非零; 该非零
        #     不代表 Xray 本体安装失败。故先接住其退出码, 再用 `cmd_exists xray`
        #     做产物校验来裁定成败 (与 BBR/日志轮转的 `|| true` 容错思路一致)。
        #     否则 set -Eeuo pipefail 会把这种可容忍错误当成脚本崩溃, 直接跳过后续
        #     "生成配置 / 启动 / 分享链接" 步骤, 表现为装完无分享信息。
        bash "${install_script}" install -u root --version "${CONFIG_DATA['version']:-}" || true
        rm -f "${install_script}"
        # 安装产物校验: xray 二进制应已就位, 否则视为安装失败
        if ! cmd_exists 'xray'; then
            _error "$(_i18n ".${CUR_FILE}.install.fail_runtime")"
        fi
        # 审计留痕
        _audit_log 'install' "xray version=${CONFIG_DATA['version']:-}"
    fi
    # 内核网络调优: 启用 BBR (幂等; 失败只告警, 不阻断 Xray 安装)
    handler_bbr || true
    # 日志轮转: 安装 logrotate 配置 (幂等; 非 Linux / 无 logrotate 时静默跳过)
    _ensure_logrotate || true
}

# =============================================================================
# 函数名称: handler_bbr
# 功能描述: 检测并按需启用内核 BBR 拥塞控制 (幂等)。
#           1. 先读 net.ipv4.tcp_congestion_control 与 net.core.default_qdisc;
#              两项已是 bbr/fq 时直接返回, 不产生任何写操作。
#           2. 加载 tcp_bbr / sch_fq 模块 —— 这一步不可省: 发行版内核把 BBR 编成
#              模块 (net/ipv4/tcp_bbr.ko), 未加载时算法不会出现在
#              net.ipv4.tcp_available_congestion_control 里, 此时直接写 sysctl 必然失败
#              (实测 Debian 6.1 默认只有 reno/cubic), 容易误判成"内核不支持"。
#              模块加载失败才判定内核不支持, 告警后返回 (不阻断调用方)。
#           3. 写 /etc/modules-load.d 持久化模块加载, 否则重启后 BBR 静默失效。
#           4. 写 /etc/sysctl.d 落两个参数 —— 必须成对: 缺 fq 时 BBR 失去 pacing,
#              抗丢包的收益会明显打折。
#           5. sysctl -p 应用后再复核一次, 未生效即告警 (与项目的启停复查约定一致)。
#
#           设计取舍: 用 modprobe 的成败判断内核是否支持, 而非解析 uname 版本号 ——
#           部分发行版 backport 内核版本号低于 4.9 但仍带 BBR, 按版本号会误判。
# 参数: 无
# 返回值: 0-已生效 (含本就已启用) 1-内核不支持 2-写入或复核失败
#         注: 调用方不应据此中断安装流程。
# =============================================================================
function handler_bbr() {
    local modules_load_file='/etc/modules-load.d/xray-script-personal-use-only-bbr.conf'
    local sysctl_conf_file='/etc/sysctl.d/99-xray-script-personal-use-only-bbr.conf'
    local current_cc=''
    local current_qdisc=''

    # 读取当前状态 (sysctl 不可用时留空, 落入下方启用分支)
    current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"

    # 已启用: 只报告, 不写文件
    if [[ "${current_cc}" == 'bbr' && "${current_qdisc}" == 'fq' ]]; then
        echo -e "${GREEN}[$(_i18n '.title.tip')] ${NC}$(_i18n ".${CUR_FILE}.bbr.already")" >&2
        echo -e "  net.ipv4.tcp_congestion_control = ${current_cc}" >&2
        echo -e "  net.core.default_qdisc          = ${current_qdisc}" >&2
        return 0
    fi

    echo -e "${YELLOW}[$(_i18n '.title.tip')] ${NC}$(_i18n ".${CUR_FILE}.bbr.enabling")" >&2

    # 模块加载: 判内核是否支持 BBR 的可靠依据
    if ! cmd_exists 'modprobe' || ! modprobe tcp_bbr 2>/dev/null; then
        echo -e "${YELLOW}[$(_i18n '.title.warn')]${NC} $(_i18n ".${CUR_FILE}.bbr.unsupported")" >&2
        return 1
    fi
    # fq 缺失时 BBR 仍可工作, 只是效果打折, 故失败不阻断
    modprobe sch_fq 2>/dev/null || true

    # 持久化: 模块自加载 + 内核参数 (两处均原子写)
    mkdir -p /etc/modules-load.d /etc/sysctl.d || return 2
    if ! printf 'tcp_bbr\nsch_fq\n' | _atomic_write "${modules_load_file}"; then
        echo -e "${RED}[$(_i18n '.title.fail')]${NC} $(_i18n ".${CUR_FILE}.bbr.verify_failed")" >&2
        return 2
    fi
    if ! printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' | _atomic_write "${sysctl_conf_file}"; then
        echo -e "${RED}[$(_i18n '.title.fail')]${NC} $(_i18n ".${CUR_FILE}.bbr.verify_failed")" >&2
        return 2
    fi

    # 应用: 只加载本文件, 不触碰其它 sysctl 配置
    sysctl -p "${sysctl_conf_file}" >/dev/null 2>&1 || true

    # 复核
    current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    if [[ "${current_cc}" == 'bbr' && "${current_qdisc}" == 'fq' ]]; then
        echo -e "${GREEN}[$(_i18n '.title.pass')]${NC} $(_i18n ".${CUR_FILE}.bbr.verified")" >&2
        echo -e "  net.ipv4.tcp_congestion_control = ${current_cc}" >&2
        echo -e "  net.core.default_qdisc          = ${current_qdisc}" >&2
        _audit_log 'bbr' 'enabled: tcp_congestion_control=bbr, default_qdisc=fq'
        return 0
    fi

    echo -e "${RED}[$(_i18n '.title.fail')]${NC} $(_i18n ".${CUR_FILE}.bbr.verify_failed")" >&2
    return 2
}

# =============================================================================
# 网络加速组: 体检 / 内核网络调优 / 进程句柄上限
# -----------------------------------------------------------------------------
# 与 handler_bbr 的分工: handler_bbr 负责"把 BBR 打开"(写 modules-load.d 与
# sysctl.d 两处并持久化); 本组负责"看清它到底有没有生效", 外加两批 BBR 常见
# 配套、但**不该自动施加**的整机级优化。
#
# 为什么后两批不跟 BBR 一起自动开: BBR 只改拥塞控制算法本身, 面小且可逆; 而
# TCP 缓冲上限与 nofile 是整机参数 (对所有进程/用户/服务生效) —— 128MB 的缓冲
# 天花板在极端情况下会显著抬高内存占用, 1000000 的句柄上限让任何进程都能吃满
# fd。故一律做成独立入口 + 二次确认, 绝不自动施加, 且只写自己名下带
# "xray-script-personal-use-only-" 前缀的文件 (不进 /etc/sysctl.conf, 不动别人的同名配置)。
# =============================================================================

# --- 输出助手: 与 check.sh / backup.sh 里的同名函数格式完全一致 ---
function _warn() { echo -e "${YELLOW}[$(_i18n '.title.warn')]${NC} $*" >&2; }
function _info() { echo -e "${GREEN}[$(_i18n '.title.info')]${NC} $*" >&2; }
function _pass() { echo -e "${GREEN}[$(_i18n '.title.pass')]${NC} $*" >&2; }

# =============================================================================
# 函数名称: _net_norm
# 功能描述: 归一化 sysctl 取值, 供字符串比对。
#           必要性: tcp_rmem / tcp_wmem 是多值参数, 输出形如 "4096\t87380\t6291456",
#           分隔符是制表符还是空格、宽度几个, 随内核与 procps 版本而变, 直接做
#           字符串相等判断会把"已达标"误判成"需要修改", 于是每次都重写文件。
# 参数: $1 原始取值
# 返回值: 直接打印归一化结果 (恒返回 0)
# =============================================================================
function _net_norm() {
    local v="${1:-}"
    # 制表符换空格, 再把连续空格压成一个, 最后去掉首尾空白
    v="${v//$'\t'/ }"
    while [[ "${v}" == *'  '* ]]; do v="${v//  / }"; done
    while [[ "${v}" == ' '* ]]; do v="${v# }"; done
    while [[ "${v}" == *' ' ]]; do v="${v% }"; done
    printf '%s' "${v}"
}

# =============================================================================
# 函数名称: _unit_exists
# 功能描述: 判断 systemd 单元是否存在 (用于避免对未安装的服务执行启停)。
# 参数: $1 单元名
# 返回值: 0-存在 1-不存在或无 systemd
# =============================================================================
function _unit_exists() {
    local unit="${1:-}"
    [[ -n "${unit}" ]] || return 1
    cmd_exists 'systemctl' || return 1
    systemctl cat "${unit}" >/dev/null 2>&1
}

# =============================================================================
# 函数名称: handler_net_status
# 功能描述: 转发到 check.sh 的只读网络体检, 并在有结论后写审计日志。
#           体检本体放 check.sh —— 那里有现成的 _info/_pass/_fail 报告语汇,
#           且 check.sh 已被本项目当作"只读检查器"使用, 语义一致。
# 参数: 无
# 返回值: 恒为 0。原因: 本函数经 exec_handler 调用, 而 exec_handler 把非 0
#         一律翻译成"[错误] handler 执行失败"并退出整个菜单。"体检发现未达标"
#         是一种正常结论而非执行错误, 让报告本身说话即可, 不该把用户踢出菜单。
# =============================================================================
function handler_net_status() {
    [[ -f "${CHECK_PATH}" ]] || _error "$(_i18n ".${CUR_FILE}.net_status.unavailable")"
    local rc=0
    bash "${CHECK_PATH}" '--net-status' || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        _audit_log 'net-status' 'bbr/fq/persist all ok'
    else
        _audit_log 'net-status' 'issues found (see report)'
    fi
    return 0
}

# =============================================================================
# 函数名称: handler_health
# 功能描述: 转发到 check.sh 的一键全量体检, 并按结论写审计日志。
#           体检本体放 check.sh —— 与 handler_net_status 同一取舍: check.sh 已被
#           本项目当作"只读检查器"使用, 报告语汇 (分区标题 + 通过/警告/失败)
#           与阈值判定都在那边, 这里只做转发与留痕, 不复制一份判据。
# 参数: 无
# 返回值: 恒为 0。理由同 handler_net_status: 本函数经 exec_handler 调用, 而
#         exec_handler 把非 0 一律翻译成"[错误] handler 执行失败"并退出整个菜单。
#         "体检查出问题"是正常结论而非执行错误, 让报告本身说话即可。
#         需要真实退出码的脚本化调用请直接用 `check.sh --health` (0/1)。
# =============================================================================
function handler_health() {
    [[ -f "${CHECK_PATH}" ]] || _error "$(_i18n ".${CUR_FILE}.health.unavailable")"
    local rc=0
    bash "${CHECK_PATH}" '--health' || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        _audit_log 'health' 'report done (no failures)'
    else
        _audit_log 'health' 'report done (failures found)'
    fi
    return 0
}

# =============================================================================
# 函数名称: handler_net_tune
# 功能描述: 写入内核网络高并发调优参数 (幂等, 需二次确认)。
#           1. 逐项读当前值并与目标值比对 —— 全部达标即直接返回, 不写任何文件;
#           2. 列出"将修改"的项与"已达标"的项数, 确认后才动手 (默认取消);
#           3. 原子写 /etc/sysctl.d/99-xray-script-personal-use-only-net.conf;
#           4. `sysctl -p <本文件>` 应用 —— 刻意不用 `sysctl --system`: 那会连带
#              加载整机其它 sysctl 配置, 别人的坏配置会把本次改动一起带崩;
#           5. 逐项复核, 未被内核接受的项列出来 (部分内核会钳低缓冲上限)。
# 参数: 无
# 返回值: 0-已应用/本就达标/用户取消 (均属正常结束)
# =============================================================================
function handler_net_tune() {
    local sysctl_file='/etc/sysctl.d/99-xray-script-personal-use-only-net.conf'
    local -a keys=(
        'net.core.somaxconn'
        'net.ipv4.tcp_max_syn_backlog'
        'net.core.rmem_max'
        'net.core.wmem_max'
        'net.ipv4.tcp_rmem'
        'net.ipv4.tcp_wmem'
        'fs.file-max'
        'net.ipv4.tcp_slow_start_after_idle'
        'net.ipv4.tcp_tw_reuse'
        'net.ipv4.tcp_fastopen'
    )
    # 取值来源: 社区通用的"BBR + 高并发"配方, 面向高带宽高延迟 (BDP 大) 链路。
    # 注: rmem/wmem 抬的是**上限**而非实际占用, 但极限下单 socket 可占到 128MB,
    #     故属可选优化而非常规必需 —— 这也是本函数不自动执行的原因。
    local -a vals=(
        '65535'                   # somaxconn: accept 队列 (默认 4096), 防突发丢握手
        '65535'                   # syn_backlog: SYN 队列
        '134217728'               # rmem_max: 单 socket 接收缓冲上限 (128MB)
        '134217728'               # wmem_max: 单 socket 发送缓冲上限 (128MB)
        '4096 87380 134217728'    # tcp_rmem: 自动调优的 min/default/max
        '4096 65536 134217728'    # tcp_wmem: 同上 (发送方向)
        '1000000'                 # file-max: 全机 fd 上限, 与句柄上限配套
        '0'                       # slow_start_after_idle: 空闲后不把 cwnd 打回初值
        '1'                       # tw_reuse: 复用 TIME_WAIT (比已废弃的 tw_recycle 安全)
        '3'                       # tcp_fastopen: 客户端+服务端均启用 TFO, 省一次 RTT (需 xray sockopt.tcpFastOpen 配合)
    )

    cmd_exists 'sysctl' || _error "$(_i18n ".${CUR_FILE}.net_tune.no_sysctl")"
    mkdir -p /etc/sysctl.d || _error "$(_i18n ".${CUR_FILE}.net_tune.write_failed")/etc/sysctl.d"

    local i=0 key='' want='' cur='' body='' plan='' failed='' confirm=''
    local changes=0 kept=0

    for i in "${!keys[@]}"; do
        key="${keys[${i}]:-}"
        want="${vals[${i}]:-}"
        cur="$(_net_norm "$(sysctl -n "${key}" 2>/dev/null || true)")"
        if [[ "${cur}" == "${want}" ]]; then
            kept=$((kept + 1))
        else
            changes=$((changes + 1))
            plan="${plan}    ${key}: ${cur:-?} -> ${want}"$'\n'
        fi
        body="${body}${key} = ${want}"$'\n'
    done

    if [[ "${changes}" -eq 0 ]]; then
        _info "$(_i18n ".${CUR_FILE}.net_tune.already")"
        _audit_log 'net-tune' "noop: all ${kept} keys already at target"
        return 0
    fi

    printf '\n%s\n' "$(_i18n ".${CUR_FILE}.net_tune.plan_title")" >&2
    printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.net_tune.plan_file")" "${sysctl_file}" >&2
    printf '  %s\n' "$(_i18n ".${CUR_FILE}.net_tune.plan_scope")" >&2
    printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.net_tune.plan_change")" "${changes}" >&2
    printf '%s' "${plan}" >&2
    if [[ "${kept}" -gt 0 ]]; then
        printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.net_tune.plan_keep")" "${kept}" >&2
    fi

    printf '\n%s' "${YELLOW}[$(_i18n '.title.warn')]${NC}" >&2
    printf ' %s [y/N]: ' "$(_i18n ".${CUR_FILE}.net_tune.confirm")" >&2
    # 无 TTY / 读到 EOF 时 read 返回非 0, 落空串即等价"取消" (安全默认)
    read -r confirm || confirm=''
    case "${confirm,,}" in
    y | yes) ;;
    *)
        _info "$(_i18n ".${CUR_FILE}.net_tune.cancelled")"
        return 0
        ;;
    esac

    _info "$(_i18n ".${CUR_FILE}.net_tune.applying")"
    if ! printf '%s' "${body}" | _atomic_write "${sysctl_file}"; then
        _error "$(_i18n ".${CUR_FILE}.net_tune.write_failed")${sysctl_file}" "$(_i18n ".${CUR_FILE}.net_tune.write_failed_hint")"
    fi
    # 只应用本文件 (见函数头对 sysctl --system 的说明)
    sysctl -p "${sysctl_file}" >/dev/null 2>&1 || true

    failed=''
    for i in "${!keys[@]}"; do
        key="${keys[${i}]:-}"
        want="${vals[${i}]:-}"
        cur="$(_net_norm "$(sysctl -n "${key}" 2>/dev/null || true)")"
        if [[ "${cur}" != "${want}" ]]; then
            failed="${failed}    ${key}: ${cur:-?} (${want})"$'\n'
        fi
    done

    if [[ -z "${failed}" ]]; then
        _pass "$(_i18n ".${CUR_FILE}.net_tune.done")"
        _audit_log 'net-tune' "applied ${changes} key(s), all verified"
    else
        _warn "$(_i18n ".${CUR_FILE}.net_tune.partial")"
        printf '%s' "${failed}" >&2
        _audit_log 'net-tune' "applied ${changes} key(s), some not accepted"
    fi
    return 0
}

# =============================================================================
# 函数名称: _nofile_probe
# 功能描述: 读取指定进程实际生效的 fd 软上限 (Max open files 的第一列)。
#           改 limits 之后必须从 /proc/<pid>/limits 读才知道"服务是否真拿到了",
#           读全局 ulimit 只能看到当前 shell 会话的值。
# 参数: $1 进程名 (如 xray / nginx)
# 返回值: 0-取到并打印上限值 1-未取到 (进程不在或无 /proc)
# =============================================================================
function _nofile_probe() {
    local svc="${1:-}"
    local p='' line='' soft=''
    [[ -n "${svc}" ]] || return 1
    if cmd_exists 'pidof'; then
        p="$(pidof "${svc}" 2>/dev/null || true)"
    elif cmd_exists 'pgrep'; then
        p="$(pgrep -x "${svc}" 2>/dev/null | sed -n '1p' || true)"
    fi
    p="${p%% *}" # 多进程/多 PID 时只取第一个
    [[ -n "${p}" ]] || return 1
    [[ -r "/proc/${p}/limits" ]] || return 1
    # here-redirect 遍历而非管道 —— 管道会让循环跑在子 shell 里
    while IFS= read -r line; do
        case "${line}" in
        'Max open files'*)
            # 形如: Max open files  1000000  1000000  files
            # 只要第一列 (软上限); 硬上限与单位列此处不用, 用 _ 占位避免未用变量
            read -r _ _ _ soft _ _ <<<"${line}"
            printf '%s' "${soft}"
            return 0
            ;;
        esac
    done <"/proc/${p}/limits"
    return 1
}

# =============================================================================
# 函数名称: handler_nofile_limit
# 功能描述: 提高进程文件句柄上限 (nofile), 覆盖登录会话与 systemd 服务两条路径。
#           1. 读 fs.nr_open 并据此钳制目标值 —— nofile 硬上限超过 fs.nr_open 时
#              pam_limits 会静默忽略, 只写文件不钳制等于"看着成功其实没生效";
#           2. 列出三个将写入的文件与影响面, 确认后才动手 (默认取消);
#           3. 原子写 /etc/security/limits.d 与 /etc/systemd/{system,user}.conf.d
#              下本项目专属命名的文件;
#           4. `systemctl daemon-reexec` 让 systemd 重新读取 Manager 段配置;
#           5. 询问是否立刻重启 xray / nginx —— 已运行的服务不会自动套用新上限,
#              但重启会瞬断连接, 故这一步单独确认而不是替用户决定;
#           6. 从 /proc/<pid>/limits 读回真实值复核, 而不是只看文件写完没。
# 参数: 无
# 返回值: 0-已写入/用户取消 (均属正常结束)
# =============================================================================
function handler_nofile_limit() {
    local target=1000000
    local limits_file='/etc/security/limits.d/99-xray-script-personal-use-only-nofile.conf'
    local sysd_sys_file='/etc/systemd/system.conf.d/99-xray-script-personal-use-only-nofile.conf'
    local sysd_usr_file='/etc/systemd/user.conf.d/99-xray-script-personal-use-only-nofile.conf'
    local banner='# Managed by xray-script-personal-use-only (nofile limit). Safe to delete this file.'

    local -a files=("${limits_file}" "${sysd_sys_file}" "${sysd_usr_file}")
    # did_restart 必须显式初始化: 它在"是否重启"分支里才被赋值, 而下方复核段无条件
    # 读它 —— 漏了初值, 用户在重启确认里选 N (或直接 EOF) 时就会因 set -u 报
    # unbound variable 崩掉, 偏偏那正是"配置已写好、只差重启"的正常路径。
    local f='' nr_open='' cur='' confirm='' answer='' val='' did_restart=0
    local -a restart_list=()
    local svc=''

    # --- 钳制: 目标值不得超过 fs.nr_open, 否则 pam_limits 静默忽略 ---
    if cmd_exists 'sysctl'; then
        nr_open="$(_net_norm "$(sysctl -n fs.nr_open 2>/dev/null || true)")"
    fi
    if [[ "${nr_open}" =~ ^[0-9]+$ ]] && ((target > nr_open)); then
        target="${nr_open}"
        _warn "$(_i18n ".${CUR_FILE}.nofile.clamped")${target}"
    fi

    cur="$(ulimit -Hn 2>/dev/null || true)"

    printf '\n%s\n' "$(_i18n ".${CUR_FILE}.nofile.plan_title")" >&2
    printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.nofile.current_label")" "${cur:-?}" >&2
    printf '  %s%s\n' "$(_i18n ".${CUR_FILE}.nofile.target_label")" "${target}" >&2
    printf '  %s\n' "$(_i18n ".${CUR_FILE}.nofile.plan_scope")" >&2
    for f in "${files[@]}"; do
        printf '    %s\n' "${f}" >&2
    done

    printf '\n%s' "${YELLOW}[$(_i18n '.title.warn')]${NC}" >&2
    printf ' %s [y/N]: ' "$(_i18n ".${CUR_FILE}.nofile.confirm")" >&2
    read -r confirm || confirm=''
    case "${confirm,,}" in
    y | yes) ;;
    *)
        _info "$(_i18n ".${CUR_FILE}.nofile.cancelled")"
        return 0
        ;;
    esac

    _info "$(_i18n ".${CUR_FILE}.nofile.applying")"
    mkdir -p /etc/security/limits.d /etc/systemd/system.conf.d /etc/systemd/user.conf.d \
        || _error "$(_i18n ".${CUR_FILE}.nofile.write_failed")" "$(_i18n ".${CUR_FILE}.nofile.write_failed_hint")"

    if ! printf '%s\nroot soft nofile %s\nroot hard nofile %s\n* soft nofile %s\n* hard nofile %s\n' \
        "${banner}" "${target}" "${target}" "${target}" "${target}" | _atomic_write "${limits_file}"; then
        _error "$(_i18n ".${CUR_FILE}.nofile.write_failed")${limits_file}" "$(_i18n ".${CUR_FILE}.nofile.write_failed_hint")"
    fi
    for f in "${sysd_sys_file}" "${sysd_usr_file}"; do
        if ! printf '%s\n[Manager]\nDefaultLimitNOFILE=%s\n' "${banner}" "${target}" \
            | _atomic_write "${f}"; then
            _error "$(_i18n ".${CUR_FILE}.nofile.write_failed")${f}" "$(_i18n ".${CUR_FILE}.nofile.write_failed_hint")"
        fi
    done

    # --- 让 systemd 重新读取 Manager 段 (新上限对之后启动的服务生效) ---
    if cmd_exists 'systemctl'; then
        _info "$(_i18n ".${CUR_FILE}.nofile.reexec")"
        systemctl daemon-reexec >/dev/null 2>&1 \
            || _warn "$(_i18n ".${CUR_FILE}.nofile.reexec_failed")"
    fi

    # --- 重启服务: 单独确认 (会瞬断连接) ---
    if _unit_exists 'xray'; then restart_list+=('xray'); fi
    if _unit_exists 'nginx'; then restart_list+=('nginx'); fi

    if [[ "${#restart_list[@]}" -gt 0 ]]; then
        printf '\n%s' "${YELLOW}[$(_i18n '.title.warn')]${NC}" >&2
        printf ' %s [y/N]: ' "$(_i18n ".${CUR_FILE}.nofile.restart_confirm")" >&2
        read -r answer || answer=''
        case "${answer,,}" in
        y | yes)
            did_restart=1
            _info "$(_i18n ".${CUR_FILE}.nofile.restarting")"
            # 子 shell 包住: handler_restart / handler_nginx_restart 在复核失败时
            # 会 exit 1, 而此刻三个文件已写好, 不该因一次重启失败把整件事判成"没做成"。
            for svc in "${restart_list[@]}"; do
                if [[ "${svc}" == 'nginx' ]]; then
                    (handler_nginx_restart) || _warn "$(_i18n ".${CUR_FILE}.nofile.restart_failed")${svc}"
                else
                    (handler_restart) || _warn "$(_i18n ".${CUR_FILE}.nofile.restart_failed")${svc}"
                fi
            done
            ;;
        *)
            _info "$(_i18n ".${CUR_FILE}.nofile.restart_skipped")"
            ;;
        esac
    fi

    # --- 复核: 从 /proc 读服务真实拿到的上限 (只在重启过之后才有意义) ---
    if [[ "${did_restart}" -eq 1 ]]; then
        printf '\n  %s\n' "$(_i18n ".${CUR_FILE}.nofile.verify_title")" >&2
        for svc in "${restart_list[@]}"; do
            val=''
            if ! val="$(_nofile_probe "${svc}")"; then val='?'; fi
            if [[ "${val}" == "${target}" ]]; then
                printf '    %s%s: %s%s\n' "${GREEN}" "${svc}" "${val}" "${NC}" >&2
            else
                printf '    %s%s: %s%s\n' "${YELLOW}" "${svc}" \
                    "$(_i18n ".${CUR_FILE}.nofile.expect_label")${target})" "${NC}" >&2
            fi
        done
        printf '\n' >&2
    fi

    _pass "$(_i18n ".${CUR_FILE}.nofile.done")"
    _audit_log 'nofile-limit' "target=${target}, files=3"
    return 0
}

# =============================================================================
# 函数名称: _purge_crontab_entries
# 功能描述: 移除本项目写入的 cron 任务 (卸载 Xray 时调用)。
#           仅按本项目脚本的绝对路径匹配, 不触碰用户自建任务与 acme.sh 的证书续期任务。
# 参数: 无
# 返回值: 0 (无论是否命中, 都视为清理完成)
# =============================================================================
function _purge_crontab_entries() {
    local marker=''
    local removed=0
    for marker in "${GEODATA_PATH}" "${NGINX_PATH}"; do
        # 注: 尚无 crontab 时 crontab -l 退出码为 1, 故在 if 条件中判定 (set -e 不介入)
        if crontab -l 2>/dev/null | grep -qF -- "${marker}"; then
            # 过滤后可能为 0 行, 用 || true 兜底 (空内容写入等价于清空)
            crontab -l 2>/dev/null | grep -vF -- "${marker}" | crontab - || true
            removed=$((removed + 1))
        fi
    done
    if (("${removed}" > 0)); then
        echo -e "${GREEN}[$(_i18n '.title.tip')] ${NC}$(_i18n ".${CUR_FILE}.purge.cron_removed")" >&2
    else
        echo -e "${YELLOW}[$(_i18n '.title.warn')]${NC} $(_i18n ".${CUR_FILE}.purge.cron_empty")" >&2
    fi
    return 0
}

# =============================================================================
# 函数名称: handler_purge
# 功能描述: 卸载 Xray 核心及其配置, 并收口本项目写在共享组件里的痕迹。
#           1. 先下载并校验卸载脚本 (失败即终止, 不动任何配置)。
#           2. 清理本项目写入的 cron 定时任务。
#           3. 回滚本项目写入 Nginx 的站点/SNI 配置 (Nginx 本体保留)。
#           4. 执行上游卸载, 并重置 config.json 的 xray 字段。
#
#           保留 Nginx、acme.sh (含已签发证书)、Docker 容器与用户自建站点配置。
# 参数: 无
# 返回值: 无 (通过调用外部脚本执行卸载)
# =============================================================================
function handler_purge() {
    # 下载 Xray-install 脚本(固定 commit) → 完整性体检 → 执行卸载 (取代原 `curl | bash -c` 管道)
    # 卸载范围提示: 清 Xray + 本项目写入 cron / Nginx 的痕迹, 共享组件本体一律保留
    echo -e "${YELLOW}[$(_i18n '.title.warn')]${NC} $(_i18n ".${CUR_FILE}.purge.scope_notice")" >&2
    # 审计留痕 (卸载不可逆, 先落日志再执行)
    _audit_log 'purge' 'xray + project cron/nginx-config traces (nginx itself kept)'
    # 先把卸载脚本下载并校验完再动配置: 失败时直接终止, 避免
    # "卸载未执行却已清空 cron 与站点配置"的半完成状态
    local purge_script=''
    if ! purge_script="$(_download_verified "${XRAY_INSTALL_URL}" "${XRAY_INSTALL_SHA256}")"; then
        _error "$(_i18n ".${CUR_FILE}.install.fail_download")"
    fi
    # 1) 清理本项目写入的 cron 定时任务 (Xray 卸载后这些任务已无意义)
    _purge_crontab_entries
    # 2) 回滚本项目写入 Nginx 的站点/SNI 配置 (Nginx 本体保留, 供其它站点继续使用)
    # 注: 回滚失败不阻断 Xray 卸载, 仅告警
    bash "${NGINX_PATH}" --rollback-config || echo -e "${YELLOW}[$(_i18n '.title.warn')]${NC} $(_i18n ".${CUR_FILE}.purge.nginx_rollback_fail")" >&2
    # 3) 调用 Xray-install 脚本进行卸载 (带 --purge 参数)
    # 注: Xray 未安装时上游脚本以 exit 1 结束, 需兜底以免 set -e 中断后续配置重置
    bash "${purge_script}" remove --purge || echo -e "${YELLOW}[$(_i18n '.title.warn')]${NC} $(_i18n ".${CUR_FILE}.purge.fail")" >&2
    rm -f "${purge_script}"
    # 4) 重置 xray 字段
    SCRIPT_CONFIG=$(reset_json_fields "${SCRIPT_CONFIG}" 'xray')
    # 将重置后的脚本配置写入文件
    persist_script_config
    # 审计留痕
    _audit_log 'purge.done' 'xray config reset'
}

# =============================================================================
# 函数名称: handler_start
# 功能描述: 启动 Xray 服务。
#           1. 检查 Xray 服务是否已在运行。
#           2. 如果未运行则启动服务。
#           3. 检查 Xray 服务是否已设置开机自启。
#           4. 如果未设置则启用开机自启。
# 参数: 无
# 返回值: 无 (通过 systemctl 命令执行操作)
# =============================================================================
function handler_start() {
    _ensure_xray_runtime_dirs
    # 检查 Xray 服务是否活跃，如果不活跃则启动 (失败交由下方复查统一处理)
    systemctl -q is-active xray || systemctl -q start xray || true
    # 检查 Xray 服务是否已启用，如果未启用则启用
    systemctl -q is-enabled xray || systemctl -q enable xray || true
    # 启动后复查: 轮询等待服务进入 active 状态 (最多约 5 秒)
    # 注: 原先只发抑制了 systemctl 的报错, 端口被占时界面仍显示"已完成"而实际不通。
    local wait_i=0
    for ((wait_i = 0; wait_i < 10; wait_i++)); do
        systemctl -q is-active xray && break
        sleep 0.5
    done
    # 复查未通过: 留痕(失败)并终止, 与 handler_restart 的兜底保持一致
    if ! systemctl -q is-active xray; then
        _audit_log 'start.failed' 'xray'
        _error "$(_i18n '.handler.start.verify_failed')"
    fi
    # 审计留痕
    _audit_log 'start' 'xray'
}

# =============================================================================
# 函数名称: handler_stop
# 功能描述: 停止 Xray 服务。
#           1. 检查 Xray 服务是否正在运行。
#           2. 如果正在运行则停止服务。
#           3. 检查 Xray 服务是否已设置开机自启。
#           4. 如果已设置则禁用开机自启。
# 参数: 无
# 返回值: 无 (通过 systemctl 命令执行操作)
# =============================================================================
function handler_stop() {
    # 检查 Xray 服务是否活跃，如果活跃则停止
    # 注: `A && B` 作函数末句时, A 为假 (Xray 未运行) 会让函数返回非 0,
    #     裸调用处被 set -e 传播而中断 (连点两次"停止服务"即触发); 末尾补 || true 兜底。
    systemctl -q is-active xray && systemctl -q stop xray || true
    # 检查 Xray 服务是否已启用，如果启用则禁用
    systemctl -q is-enabled xray && systemctl -q disable xray || true
    # 审计留痕
    _audit_log 'stop' 'xray'
}

# =============================================================================
# 函数名称: handler_restart
# 功能描述: 重启 Xray 服务。
#           1. 检查 Xray 服务是否正在运行。
#           2. 如果正在运行则重启服务，否则启动服务。
#           3. 检查 Xray 服务是否已设置开机自启。
#           4. 如果未设置则启用开机自启。
# 参数: 无
# 返回值: 无 (通过 systemctl 命令执行操作)
# =============================================================================
function handler_restart() {
    # 重启前配置自检: 配置文件存在却无法解析时终止, 避免带着坏配置重启
    if [[ -f "${XRAY_CONFIG_PATH}" ]] && command -v jq >/dev/null 2>&1 && ! jq -e . "${XRAY_CONFIG_PATH}" >/dev/null 2>&1; then
        _error "$(_i18n '.handler.persist.invalid_json')"
    fi
    _ensure_xray_runtime_dirs
    # 检查 Xray 服务是否活跃，如果活跃则重启，否则启动 (失败交由下方复查统一处理)
    systemctl -q is-active xray && systemctl -q restart xray || systemctl -q start xray || true
    # 检查 Xray 服务是否已启用，如果未启用则启用
    systemctl -q is-enabled xray || systemctl -q enable xray || true
    # 重启后复查: 轮询等待服务进入 active 状态 (最多约 5 秒)
    local wait_i=0
    for ((wait_i = 0; wait_i < 10; wait_i++)); do
        systemctl -q is-active xray && break
        sleep 0.5
    done
    # 复查未通过: 留痕(失败)并终止, 避免界面误报"已完成"而 443 实际不通
    if ! systemctl -q is-active xray; then
        _audit_log 'restart.failed' 'xray'
        _error "$(_i18n '.handler.restart.verify_failed')"
    fi
    # 审计留痕 (仅在确认服务已运行后才记为成功)
    _audit_log 'restart' 'xray'
}

# =============================================================================
# 函数名称: handler_share
# 功能描述: 调用 share.sh 脚本显示分享链接。
# 参数: 无
# 返回值: share.sh 脚本的输出
# =============================================================================
function handler_share() {
    # 执行 share.sh 脚本 (透传参数, 例如 --save / --no-qr)
    bash "${SHARE_PATH}" "$@"
}

# =============================================================================
# 函数名称: handler_subscription
# 功能描述: 调用 share.sh 生成订阅 (base64 / Clash / sing-box 三文件, 权限 0600)。
# 参数: 无 (透传参数, 目前无额外参数)
# 返回值: share.sh 的退出码
# =============================================================================
function handler_subscription() {
    # 执行 share.sh 订阅生成 (仅收集节点并写文件, 不打印明文)
    bash "${SHARE_PATH}" --subscription "$@"
}

# =============================================================================
# 函数名称: handler_traffic
# 功能描述: 调用 traffic.sh 脚本显示流量统计。
# 参数: 无
# 返回值: traffic.sh 脚本的输出
# =============================================================================
function handler_traffic() {
    # 执行 traffic.sh 脚本
    bash "${TRAFFIC_PATH}"
}

# =============================================================================
# 函数名称: handler_export_config
# 功能描述: 导出配置与证书为单个归档, 用于备份 / 迁移 / 灾备。
#           转发给 tool/backup.sh, 参数原样透传 (它自己解析位置参数与开关)。
# 参数:
#   $1 (可选): 输出文件路径; 省略则落在 ${SCRIPT_CONFIG_DIR}/backup/ 下按时间戳命名
#   $@ (可选): --with-docker 等开关
# 返回值: 无 (失败时 _error 终止)
# =============================================================================
function handler_export_config() {
    bash "${BACKUP_PATH}" '--export' "$@" || _error "$(_i18n '.handler.backup.export_failed')"
    _audit_log 'backup.export' "${1:-default}"
}

# =============================================================================
# 函数名称: handler_import_config
# 功能描述: 从归档还原配置与证书。转发给 tool/backup.sh。
#           归档路径为必需参数 —— 不给路径就直接报错, 不做"猜测最近一份备份"
#           这类隐含行为: 导入会覆盖生产配置, 必须由调用者显式指定来源。
# 参数:
#   $1: 归档文件路径 (必需)
#   $@ (可选): --yes 跳过交互确认 (无 TTY 时若不传会等价于取消)
# 返回值: 无 (失败时 _error 终止)
# =============================================================================
function handler_import_config() {
    [[ -n "${1:-}" ]] || _error "$(_i18n '.handler.backup.import_usage')"
    bash "${BACKUP_PATH}" '--import' "$@" || _error "$(_i18n '.handler.backup.import_failed')"
    _audit_log 'backup.import' "${1:-}"
    # 导入把 config.json 与 Xray 配置整体换掉了 -> 订阅 (派生快照) 必须重建。
    # 这条路径不经过 persist_*, 只能显式置脏 (收口点见 main 的 dispatch 末尾)。
    SUB_REFRESH_DIRTY=1
}

# =============================================================================
# 函数名称: handler_geodata_cron
# 功能描述: 管理 GeoData 更新的 Cron 任务。
#           1. 检查 Xray 是否已安装。
#           2. 如果是快速模式 (IS_QUICK=1)，则直接更新 GeoData。
#           3. 否则，检查 Cron 任务是否存在。
#           4. 如果存在则移除，如果不存在则添加，并立即执行一次更新。
# 参数:
#   $1: IS_QUICK - 是否为快速模式 (1 表示是, 0 表示否)，默认为 0
# 返回值: 无 (通过 crontab 命令管理任务，调用 geodata.sh 执行更新)
# =============================================================================
function handler_geodata_cron() {
    local IS_QUICK="${1:-0}" # 获取快速模式参数，默认为 0
    # 从脚本配置中检查 Xray 状态 (版本)
    local XRAY_STATUS
    XRAY_STATUS="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.version' || true)"
    # 如果 Xray 已安装
    if ! [[ -z "${XRAY_STATUS}" ]]; then
        # 如果是快速模式
        if (("${IS_QUICK}" == 0)) && crontab -l | grep -q "${GEODATA_PATH}"; then
            # 移除现有的 GeoData Cron 任务
            # 注: 无 geodata 任务时过滤结果可能为 0 行, 用 || true 兜底 (空内容写入等价于清空)
            crontab -l 2>/dev/null | grep -v "${GEODATA_PATH}" | crontab - || true
            # 打印关闭 Cron 任务的提示
            echo -e "${GREEN}[$(_i18n '.title.tip')] ${NC}$(_i18n ".${CUR_FILE}.geodata.close_cron")" >&2
        else
            # 设置 geodata.sh 脚本为可执行
            chmod a+x "${GEODATA_PATH}"
            # 添加新的 GeoData Cron 任务 (每天 6:30 执行)
            (
                # 注: 尚无 crontab 时 crontab -l 退出码为 1, 用 || true 兜底
                crontab -l 2>/dev/null || true
                echo "30 6 * * * ${GEODATA_PATH} >/dev/null 2>&1"
            ) | awk '!x[$0]++' | crontab -
            # 打印开启 Cron 任务的提示
            echo -e "${GREEN}[$(_i18n '.title.tip')] ${NC}$(_i18n ".${CUR_FILE}.geodata.update")" >&2
            # 立即执行一次 GeoData 更新
            # 注: Xray 未运行时 geodata.sh 退出码非 0 (数据其实已刷新), 需兜底避免中断后续提示
            "${GEODATA_PATH}" || true
            # 打印已开启 Cron 任务的提示
            echo -e "${GREEN}[$(_i18n '.title.tip')] ${NC}$(_i18n ".${CUR_FILE}.geodata.open_cron")" >&2
        fi
    else
        # Xray 未安装时必须给出反馈: 原实现在这里静默返回, 用户在菜单里选了本项却
        # 得不到任何输出 —— 既可能误以为"已经设好了", 也可能以为脚本卡死。
        echo -e "${YELLOW}[$(_i18n '.title.warn')]${NC} $(_i18n ".${CUR_FILE}.geodata.not_installed")" >&2
    fi
}

# =============================================================================
# 函数名称: handler_docker
# 功能描述: 确保 Docker 已安装。
#           1. 检查系统中是否存在 docker 命令。
#           2. 如果不存在，则调用 exec_docker 安装 Docker。
# 参数: 无
# 返回值: 无 (通过调用其他函数执行操作)
# =============================================================================
function handler_docker() {
    # 检查 docker 命令是否存在
    if ! cmd_exists 'docker'; then
        # 如果不存在，则调用 docker.sh 安装 Docker
        exec_docker '--install'
    fi
}

# =============================================================================
# 函数名称: handler_warp
# 功能描述: 管理 WARP (WireGuard) 配置。
#           1. 确保 Docker 已安装。
#           2. 检查当前 WARP 状态。
#           3. 如果已启用，则禁用并从 Xray 配置中移除相关规则。
#           4. 如果未启用，则启用并添加 WARP 出站和路由规则到 Xray 配置。
#           5. 更新脚本配置中的 WARP 状态。
# 参数: 无
# 返回值: 无 (通过调用其他函数和脚本执行操作，修改配置文件)
# =============================================================================
function handler_warp() {
    # 确保 Docker 已安装
    handler_docker
    # 从脚本配置中读取当前 WARP 状态
    local WARP_STATUS
    WARP_STATUS="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.warp' || true)"
    # 从 Xray 配置文件加载配置
    XRAY_CONFIG="$(jq '.' "${XRAY_CONFIG_PATH}")"
    # 如果 WARP 已启用 (状态为 1)
    if is_enabled "${WARP_STATUS}"; then
        WARP_STATUS=0 # 设置状态为禁用
        # 调用 docker.sh 禁用 WARP 容器
        exec_docker '--disable-warp'
        # 从 Xray 配置中删除 WARP 出站和相关路由规则
        XRAY_CONFIG=$(echo "${XRAY_CONFIG}" | jq 'del(.outbounds[] | select(.tag == "warp")) | del(.routing.rules[] | select(.outboundTag == "warp"))')
    else
        WARP_STATUS=1 # 设置状态为启用
        # 调用 docker.sh 构建并启用 WARP 容器
        exec_docker '--build-warp'
        local container_ip
        container_ip="$(exec_docker '--enable-warp')" # 获取 WARP 容器 IP
        # 构造 WARP Socks 出站配置 JSON
        local socks_config='[{"tag":"warp","protocol":"socks","settings":{"servers":[{"address":"'"${container_ip}"'","port":40001}]}}]'
        # 将 WARP 出站配置添加到 Xray 配置中
        XRAY_CONFIG=$(echo "${XRAY_CONFIG}" | jq --argjson socks_config "${socks_config}" '.outbounds += $socks_config')
    fi
    # 更新脚本配置中的 WARP 状态
    SCRIPT_CONFIG=$(echo "${SCRIPT_CONFIG}" | jq --arg warp "${WARP_STATUS}" '.xray.warp = $warp')
    # 将更新后的脚本配置和 Xray 配置写入文件
    persist_script_config
    persist_xray_config
}

# =============================================================================
# 函数名称: handler_reset_warp
# 功能描述: 重新构建并启动 WARP 容器。
#           1. 确保 Docker 已安装。
#           2. 检查当前 WARP 状态。
#           3. 如果已启用，则执行清空容器日志，并重置 WARP 容器。
#           4. 如果未启用，则跳过。
# 参数: 无
# 返回值: 无 (通过调用其他函数和脚本执行操作)
# =============================================================================
function handler_reset_warp() {
    # 确保 Docker 已安装
    handler_docker
    # 从脚本配置中读取当前 WARP 状态
    local WARP_STATUS
    WARP_STATUS="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.warp' || true)"
    # 从 Xray 配置文件加载配置
    XRAY_CONFIG="$(jq '.' "${XRAY_CONFIG_PATH}")"
    # 如果 WARP 已启用 (状态为 1)
    if is_enabled "${WARP_STATUS}"; then
        # 清空 WARP 容器日志数据
        exec_docker '--clean-container-logs'
        # 调用 docker.sh 禁用 WARP 容器
        exec_docker '--disable-warp'
        # 调用 docker.sh 构建并启用 WARP 容器
        exec_docker '--build-warp'
        exec_docker '--enable-warp'
    fi
}

# =============================================================================
# 函数名称: handler_nginx_install
# 功能描述: 安装并补全 Nginx (幂等)。
#           1. 仅当系统不存在 nginx 命令时, 才编译安装本项目 Nginx (带 --brotli 参数)。
#           2. 无论是否新装, 都确保 SSL 证书管理工具 (acme.sh) 就绪。
#           3. 当且仅当 Nginx 为本项目编译版时, 才写入站点配置并记录版本号。
#
#           拆成三段的原因: 原实现把「装 Nginx / 装 acme.sh / 写配置 / 记版本」
#           捆在同一个 cmd_exists 判断里。若机器上预装了发行版 nginx, 整块会被跳过,
#           连带导致 acme.sh 缺失、SNI 站点配置不生效、版本号为空
#           (进而 handler_nginx_cron 静默失效), 也不会把发行版换成编译版。
#           版本号同时是「Nginx 自动更新」开关的已安装标记, 必须照常记录。
# 参数: 无
# 返回值: 无 (通过调用其他脚本执行操作)
# =============================================================================
function handler_nginx_install() {
    # --- 段一: 编译安装 (仅当系统没有 nginx 命令时执行) ---
    if ! cmd_exists 'nginx'; then
        # 调用 nginx.sh 脚本安装 Nginx (带 Brotli 支持)
        bash "${NGINX_PATH}" --install --brotli || _error "nginx install failed"
    fi

    # --- 段二: 安装 SSL 证书管理工具 (handler_ssl_install 自带"已存在则跳过") ---
    handler_ssl_install || _error "ssl install failed during nginx setup"

    # --- 段三: 配置与版本记录 (仅针对本项目编译版) ---
    # 发行版预装的 nginx 无 Brotli 等模块, 套用本项目配置会让 nginx -t 失败, 故跳过并告警。
    if ! is_local_nginx_installed; then
        echo -e "${YELLOW}[$(_i18n '.title.warn')]${NC} $(_i18n ".${CUR_FILE}.nginx.foreign_binary")" >&2
        return 0
    fi
    # 配置 Nginx (站点配置 / Brotli / OCSP), 幂等覆盖
    handler_nginx_config || _error "nginx config apply failed"
    # 获取 Nginx 版本
    local NGINX_VERSION
    NGINX_VERSION="$(nginx -V 2>&1 | grep "^nginx version:.*" | cut -d / -f 2 || true)"
    [[ -n "${NGINX_VERSION}" ]] || _error "failed to detect nginx version"
    # 更新脚本配置中的 Nginx 版本
    SCRIPT_CONFIG=$(echo "${SCRIPT_CONFIG}" | jq --arg version "${NGINX_VERSION}" '.nginx.version = $version')
    # 将更新后的脚本配置写入文件
    persist_script_config || _error "failed to persist nginx version"
    # 补开机自启: nginx.sh 的 --install 只写 unit 与 daemon-reload, 不自启也不 enable
    # (enable 原先只散落在 handler_nginx_restart 里)。若后续证书签发失败,
    # handler_sni_config 会 exit 1 提前终止, 此时会留下"已安装但未 enable"的静默状态,
    # 重启后 Nginx 不会被拉起; 与 Xray 侧 handler_start/handler_restart 的兜底保持一致。
    # 注: 用 || true 收敛, enable 失败不应中断整个安装流程。
    systemctl -q is-enabled nginx || systemctl -q enable nginx || true
    # 审计留痕
    _audit_log 'install' "nginx version=${NGINX_VERSION}"
}

# =============================================================================
# 函数名称: handler_nginx_update
# 功能描述: 更新 Nginx。
# 参数: 无
# 返回值: 无 (通过调用 nginx.sh 脚本执行更新)
# =============================================================================
function handler_nginx_update() {
    # 调用 nginx.sh 脚本更新 Nginx (带 Brotli 支持)
    bash "${NGINX_PATH}" --update --brotli
}

# =============================================================================
# 函数名称: handler_nginx_purge
# 功能描述: 卸载 Nginx —— 归属判定在 nginx.sh 内完成。
#           仅当 /usr/local/nginx 下存在本项目编译版时才卸载; 检测到发行版 Nginx 会
#           拒绝执行并打印包归属 (误删会让机器上其它站点一起失去 Web 服务)。
# 参数: 无
# 返回值: 无 (通过调用 nginx.sh 脚本执行卸载)
# =============================================================================
function handler_nginx_purge() {
    # 注: nginx.sh 以非 0 退出表示"已拒绝卸载", 属正常分支而非错误。
    #     用 if 包住可抑制 set -e 与 ERR trap, 避免打印行号+命令的噪声。
    if ! bash "${NGINX_PATH}" --purge; then
        echo -e "${YELLOW}[$(_i18n '.title.warn')]${NC} $(_i18n ".${CUR_FILE}.nginx.purge_refused")" >&2
        # 拒绝卸载时未做任何改动, 故不动 config.json, 以免丢失已配置的域名/证书信息
        _audit_log 'purge.skip' 'nginx (refused: not a local build)'
        return 0
    fi
    # 审计留痕
    _audit_log 'purge' 'nginx'
    # 重置 nginx 字段
    SCRIPT_CONFIG=$(reset_json_fields "${SCRIPT_CONFIG}" 'nginx')
    # 将重置后的脚本配置写入文件
    persist_script_config
}

# =============================================================================
# 函数名称: handler_nginx_cron
# 功能描述: 管理 Nginx 更新的 Cron 任务。
#           1. 检查 Nginx 是否已安装。
#           2. 检查 Cron 任务是否存在。
#           3. 如果存在则移除。
#           4. 如果不存在则添加 (每天 3:00 执行更新)。
# 参数: 无
# 返回值: 无 (通过 crontab 命令管理任务)
# =============================================================================
function handler_nginx_cron() {
    # 从脚本配置中检查 Nginx 状态 (版本)
    local NGINX_STATUS
    NGINX_STATUS="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.version' || true)"
    # 如果 Nginx 已安装
    if [[ -n "${NGINX_STATUS}" ]]; then
        # 检查是否存在 Nginx 更新的 Cron 任务
        if crontab -l | grep -q "${NGINX_PATH}"; then
            # 移除现有的 Nginx Cron 任务
            # 注: 无 nginx 任务时过滤结果可能为 0 行, 用 || true 兜底 (空内容写入等价于清空)
            crontab -l 2>/dev/null | grep -v "${NGINX_PATH}" | crontab - || true
            # 打印关闭 Cron 任务的提示
            echo -e "${GREEN}[$(_i18n '.title.tip')] ${NC}$(_i18n ".${CUR_FILE}.nginx.close_cron")" >&2
        else
            # 设置 nginx.sh 脚本为可执行
            chmod a+x "${NGINX_PATH}"
            # 添加新的 Nginx 更新 Cron 任务 (每天 3:00 执行)
            (
                # 注: 尚无 crontab 时 crontab -l 退出码为 1, 用 || true 兜底
                crontab -l 2>/dev/null || true
                echo "0 3 * * * ${NGINX_PATH} --update --brotli >/dev/null 2>&1"
            ) | awk '!x[$0]++' | crontab -
            # 打印开启 Cron 任务的提示
            echo -e "${GREEN}[$(_i18n '.title.tip')] ${NC}$(_i18n ".${CUR_FILE}.nginx.open_cron")" >&2
        fi
    else
        # 同上: Nginx 未安装时原实现静默返回, 用户选了菜单项却零反馈, 无从判断
        # 是"已设置"还是"没生效"。这里与 handler_nginx_stop 的处理保持一致。
        echo -e "${YELLOW}[$(_i18n '.title.warn')]${NC} $(_i18n ".${CUR_FILE}.nginx.not_installed")" >&2
    fi
}

# =============================================================================
# 函数名称: handler_nginx_stop
# 功能描述: 停止 nginx 服务。
#           1. 检查 nginx 服务是否正在运行。
#           2. 如果正在运行则停止服务。
#           3. 检查 nginx 服务是否已设置开机自启。
#           4. 如果已设置则禁用开机自启。
# 参数: 无
# 返回值: 无 (通过 systemctl 命令执行操作)
# =============================================================================
function handler_nginx_stop() {
    # 未安装 nginx 时直接返回: 非 SNI 模式的配置切换会走到这里,
    # 不应因"没有这个服务"而让整个脚本中断 (set -e 下 systemctl 返回非 0 会中断)。
    if ! cmd_exists 'nginx'; then
        echo -e "${YELLOW}[$(_i18n '.title.warn')]${NC} $(_i18n ".${CUR_FILE}.nginx.not_installed")" >&2
        return 0
    fi
    # 检查 nginx 服务是否活跃，如果活跃则停止
    # 注: 服务未运行时 is-active 返回非 0, "停一个没跑的服务"不算错误, 用 || true 兜底
    systemctl -q is-active nginx && systemctl -q stop nginx || true
    # 检查 nginx 服务是否已启用，如果启用则禁用
    systemctl -q is-enabled nginx && systemctl -q disable nginx || true
}

# =============================================================================
# 函数名称: handler_nginx_restart
# 功能描述: 重启 nginx 服务。
#           1. 检查 nginx 服务是否正在运行。
#           2. 如果正在运行则重启服务，否则启动服务。
#           3. 检查 nginx 服务是否已设置开机自启。
#           4. 如果未设置则启用开机自启。
# 参数: 无
# 返回值: 无 (通过 systemctl 命令执行操作)
# =============================================================================
function handler_nginx_restart() {
    # 前置校验: 未安装 nginx 时给出明确提示, 避免 systemctl 失败在 set -e 下静默中断脚本
    cmd_exists 'nginx' || _error "$(_i18n ".${CUR_FILE}.nginx.not_installed")"
    ensure_nginx_support_files || return 1
    # 检查 nginx 服务是否活跃，如果活跃则重启，否则启动 (失败交由下方复查统一处理)
    systemctl -q is-active nginx && systemctl -q restart nginx || systemctl -q start nginx || true
    # 检查 nginx 服务是否已启用，如果未启用则启用
    systemctl -q is-enabled nginx || systemctl -q enable nginx || true
    # 重启后复查: 轮询等待服务进入 active 状态 (最多约 5 秒), 与 Xray 侧 handler_restart 对称。
    # 注: `nginx -t` 只验配置语法不做 bind, 80/443 被他人占用时只有真实启动才暴露 ——
    #     没有这一步, 界面会误报"已完成"而站点实际不可访问。
    local wait_i=0
    for ((wait_i = 0; wait_i < 10; wait_i++)); do
        systemctl -q is-active nginx && break
        sleep 0.5
    done
    # 复查未通过: 终止, 避免带着不可用的 Nginx 继续后续步骤
    if ! systemctl -q is-active nginx; then
        _error "$(_i18n ".${CUR_FILE}.nginx.verify_failed")"
    fi
}

# =============================================================================
# 函数名称: handler_ssl_install
# 功能描述: 安装 SSL 证书管理工具 (acme.sh)。
#           1. 检查 acme.sh 是否已安装。
#           2. 如果未安装，则从脚本配置中读取 CA 邮箱。
#           3. 调用 ssl.sh 脚本安装 acme.sh。
# 参数: 无
# 返回值: 无 (通过调用 ssl.sh 脚本执行安装)
# =============================================================================
function handler_ssl_install() {
    # 检查 acme.sh 脚本是否存在
    if [[ ! -e "${ACME_PATH}" ]]; then
        # 从脚本配置中读取 CA 邮箱
        local CA_EMAIL
        CA_EMAIL="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.ca' || true)"
        local CA_SERVER
        CA_SERVER="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.ca_server' || true)"
        [[ -z "${CA_SERVER}" || "${CA_SERVER}" == 'null' ]] && CA_SERVER='zerossl'
        # 调用 ssl.sh 脚本安装 acme.sh
        exec_ssl '--install' "--email=${CA_EMAIL}" "--ca=${CA_SERVER}" || exit 1
        # 审计留痕 (只记 CA 厂商, 不落邮箱明文)
        _audit_log 'install' "acme.sh ca=${CA_SERVER}"
    fi
}

# =============================================================================
# 函数名称: handler_change_domain
# 功能描述: 更改 Nginx 配置中的域名 (包括 SSL 证书)。
#           1. 获取旧域名。
#           2. 读取新域名 (如果未提供)。
#           3. 如果旧域名存在，则停止其证书续签并删除配置文件。
#           4. 复制并修改新的站点配置模板。
#           5. 申请新的 SSL 证书。
#           6. 更新脚本配置中的域名。
#           7. 调用 handler_nginx_restart 重启 Nginx 服务。
# 参数:
#   $1: target_domain - 目标域名类型 ("domain" 或 "cdn")
#   $2: stop_cert_service - 管理停止证书签发服务类型 ("n", 或默认的 "y")
# 返回值: 无 (通过文件操作和调用其他脚本执行)
# =============================================================================
function handler_change_domain() {
    # 获取 XHTTP PATH
    local XHTTP_PATH
    XHTTP_PATH="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.path')"
    # 获取目标域名类型参数
    local target_domain="${1:-}"
    # 获取管理停止证书签发服务参数
    local stop_cert_service="${2:-y}"
    # 从脚本配置中获取旧域名
    local old_domain
    old_domain="$(echo "${SCRIPT_CONFIG}" | jq -r --arg key "${target_domain}" '.nginx[$key]')"
    ensure_nginx_support_files || _error "failed to sync nginx support files"
    # 如果 CONFIG_DATA 中没有新域名，且 stop_cert_service 为 "y"，则读取用户输入
    if [[ -z "${CONFIG_DATA["${target_domain}"]:-}" && "${stop_cert_service}" == "y" ]]; then
        [[ "${old_domain}" ]] && exec_read 'only-change-domain'
        exec_read "${target_domain}"
    else
        CONFIG_DATA["${target_domain}"]="${old_domain}"
    fi
    # 备份旧域名的 Nginx 配置文件
    [[ -e "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" ]] && cp -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" "${SCRIPT_CONFIG_DIR}/stream.conf"
    if [[ -n "${old_domain}" && -e "${NGINX_CONFIG_DIR}/sites-available/${old_domain}.conf" ]]; then
        cp -f "${NGINX_CONFIG_DIR}/sites-available/${old_domain}.conf" "${SCRIPT_CONFIG_DIR}/${old_domain}.conf"
        # 删除旧域名的 Nginx 配置文件 (available 与 enabled)
        rm -f "${NGINX_CONFIG_DIR}/sites-available/${old_domain}.conf"
        rm -f "${NGINX_CONFIG_DIR}/sites-enabled/${old_domain}.conf"
    fi
    # 复制站点配置模板到 available 目录
    cp -f "${CONFIG_DIR}/nginx/conf/sites-available/${target_domain}.example.com.conf" "${NGINX_CONFIG_DIR}/sites-available/${CONFIG_DATA["${target_domain}"]:-}.conf"
    # 替换配置文件中的 example.com 为实际域名
    _replace_in_file "${NGINX_CONFIG_DIR}/sites-available/${CONFIG_DATA["${target_domain}"]:-}.conf" "example.com" "${CONFIG_DATA["${target_domain}"]:-}"
    # 替换配置文件中的 /yourpath 为 xhttp path
    _replace_in_file "${NGINX_CONFIG_DIR}/sites-available/${CONFIG_DATA["${target_domain}"]:-}.conf" "/yourpath" "${XHTTP_PATH}"
    # HTTP/3 指令与本地 Nginx 能力对齐 (未编译 http_v3 时剥离 quic, 见 align_site_http3)
    align_site_http3 "${NGINX_CONFIG_DIR}/sites-available/${CONFIG_DATA["${target_domain}"]:-}.conf"
    # 创建从 available 到 enabled 的软链接
    ln -sf "${NGINX_CONFIG_DIR}/sites-available/${CONFIG_DATA["${target_domain}"]:-}.conf" "${NGINX_CONFIG_DIR}/sites-enabled/${CONFIG_DATA["${target_domain}"]:-}.conf"
    # 为新域名申请 SSL 证书
    if exec_ssl '--issue' --domain="${CONFIG_DATA["${target_domain}"]:-}"; then
        # 如果旧域名存在
        if [[ -n "${old_domain}" && "${stop_cert_service}" == "y" ]] && exec_ssl '--status' --domain="${old_domain}"; then
            # 停止旧域名的证书续签
            exec_ssl '--stop-renew' --domain="${old_domain}"
        fi
    else
        # 删除新配置 (available 与 enabled)
        rm -f "${NGINX_CONFIG_DIR}/sites-available/${CONFIG_DATA["${target_domain}"]:-}.conf"
        rm -f "${NGINX_CONFIG_DIR}/sites-enabled/${CONFIG_DATA["${target_domain}"]:-}.conf"
        # 恢复备份的 Nginx 配置文件
        # 修复: 原为裸 `mv -f` —— 备份不存在时 mv 返回非 0, 在 set -e 下会**立即中止
        #       整个函数**, 于是下面的"恢复旧域名配置 / 重建软链 / 重启 Nginx"全部
        #       执行不到。而新站点配置已在上方被删除, 结果是**新旧两侧配置都没有**,
        #       站点彻底不可用且没有提示 —— 换域名失败本应可回退, 却变成了最坏结果。
        #       回滚路径必须逐条容错: 能恢复多少恢复多少, 最后统一重启。
        if [[ -f "${SCRIPT_CONFIG_DIR}/stream.conf" ]]; then
            mv -f "${SCRIPT_CONFIG_DIR}/stream.conf" "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" || true
        else
            print_warn "$(_i18n ".${CUR_FILE}.nginx.rollback_backup_missing")"
        fi
        # 旧域名配置与软链成对恢复: 只有备份确实存在才建链, 避免指向不存在文件的坏链接
        if [[ -n "${old_domain}" && -f "${SCRIPT_CONFIG_DIR}/${old_domain}.conf" ]]; then
            mv -f "${SCRIPT_CONFIG_DIR}/${old_domain}.conf" "${NGINX_CONFIG_DIR}/sites-available/${old_domain}.conf" || true
            ln -sf "${NGINX_CONFIG_DIR}/sites-available/${old_domain}.conf" "${NGINX_CONFIG_DIR}/sites-enabled/${old_domain}.conf"
        fi
        # 重启或启动 Nginx
        handler_nginx_restart
        exit 1
    fi
    # 更新脚本配置中的域名
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg key "${target_domain}" --arg domain "${CONFIG_DATA["${target_domain}"]:-}" '.nginx[$key] = $domain')"
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg key "${target_domain}" --arg domain "${old_domain}" 'if $key == "domain" then del(.target[$key]) else . end')"
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg key "${target_domain}" --arg domain "${CONFIG_DATA["${target_domain}"]:-}" 'if $key == "domain" then .xray.target = $domain else . end')"
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg key "${target_domain}" --arg domain "${CONFIG_DATA["${target_domain}"]:-}" 'if $key == "domain" then .xray.serverNames = [$domain] else . end')"
    rebuild_stream_config "${SCRIPT_CONFIG}"
    # 将更新后的脚本配置写入文件
    persist_script_config
    # 如果仅更新域名
    local _only_change_domain="${CONFIG_DATA['only-change-domain']:-}"
    if [[ "${_only_change_domain,,}" == "y" ]]; then
        # 恢复备份的 Nginx 配置文件
        # 修复: 同为裸 `mv -f` —— 备份缺失时返回非 0, 在 set -e 下直接中止, 后面的
        #       "替换域名 / 对齐 HTTP3 / 重建软链 / 重启 Nginx"全部跳过, 站点配置被
        #       留在改了一半的状态。这里先确认备份存在再执行整段, 否则告警并跳过。
        local _new_domain="${CONFIG_DATA["${target_domain}"]:-}"
        if [[ -f "${SCRIPT_CONFIG_DIR}/${old_domain}.conf" ]]; then
            mv -f "${SCRIPT_CONFIG_DIR}/${old_domain}.conf" "${NGINX_CONFIG_DIR}/sites-available/${_new_domain}.conf" || true
            rm -f "${NGINX_CONFIG_DIR}/sites-enabled/${_new_domain}.conf"
            # 更新域名
            _replace_in_file "${NGINX_CONFIG_DIR}/sites-available/${_new_domain}.conf" "${old_domain}" "${_new_domain}"
            # 恢复到位的配置同样要对齐 HTTP/3 能力 (备份件可能来自未做对齐的旧版本)
            align_site_http3 "${NGINX_CONFIG_DIR}/sites-available/${_new_domain}.conf"
            # 创建从 available 到 enabled 的软链接
            ln -sf "${NGINX_CONFIG_DIR}/sites-available/${_new_domain}.conf" "${NGINX_CONFIG_DIR}/sites-enabled/${_new_domain}.conf"
            rebuild_stream_config "${SCRIPT_CONFIG}"
        else
            print_warn "$(_i18n ".${CUR_FILE}.nginx.rollback_backup_missing")"
        fi
    fi
    # 重启或启动 Nginx
    handler_nginx_restart
}

# =============================================================================
# 函数名称: handler_renew_ssl
# 功能描述: 强制续期所有由 acme.sh 管理的 SSL 证书。
# 参数: 无
# 返回值: 无 (通过文件操作和调用其他脚本执行)
# =============================================================================
function handler_renew_ssl() {
    exec_ssl '--renew' || _error "ssl renew failed"
    handler_nginx_restart || _error "nginx restart failed after renew"
    handler_restart || _error "xray restart failed after renew"
}

# =============================================================================
# 函数名称: handler_remove_certificate
# 功能描述: 移除指定域名的 SSL 证书 (精确单域名粒度, 而非整套 acme.sh 卸载)。
#           1. 读取要移除证书的域名 (仅格式校验, 不解析 DNS)。
#           2. 危险操作二次确认 (移除会让使用该证书的站点 HTTPS 立即失效)。
#           3. 调用 ssl.sh --stop-renew 精确移除该域名证书。
# 参数: 无
# 返回值: 0-成功或用户取消 1-移除失败
# =============================================================================
function handler_remove_certificate() {
    # 读取要移除证书的域名 (仅格式校验, 不要求 DNS 解析)
    exec_read 'remove-cert'
    local domain="${CONFIG_DATA['remove-cert']:-}"

    # 危险操作二次确认: 移除证书会令使用它的站点 HTTPS 立即失效
    local confirm=''
    printf "${YELLOW}[%s]${NC} %s" "$(_i18n '.title.warn')" "$(_i18n_sub ".${CUR_FILE}.remove_cert.confirm" '${domain}' "${domain}")" >&2
    read -r confirm || confirm=
    if [[ "${confirm,,}" != 'y' && "${confirm,,}" != 'yes' ]]; then
        echo -e "${YELLOW}[$(_i18n '.title.warn')]${NC} $(_i18n ".${CUR_FILE}.remove_cert.cancelled")" >&2
        return 0
    fi

    # 精确移除该域名证书 (ssl.sh 内部另有 DOMAIN_REGEX 格式校验兜底)
    exec_ssl '--stop-renew' "--domain=${domain}" || {
        echo -e "${RED}[$(_i18n '.title.error')]${NC} $(_i18n_sub ".${CUR_FILE}.remove_cert.fail" '${domain}' "${domain}")" >&2
        return 1
    }
    echo -e "${GREEN}[$(_i18n '.title.info')]${NC} $(_i18n_sub ".${CUR_FILE}.remove_cert.success" '${domain}' "${domain}")" >&2
}

# =============================================================================
# 函数名称: handler_nginx_config
# 功能描述: 配置 Nginx。
#           1. 创建 sites-enabled 目录。
#           2. 备份并复制 Nginx 主配置文件和站点配置模板。
#           3. 从脚本配置中读取域名和 CDN。
#           4. 调用 handler_change_domain 为域名和 CDN 配置 SSL。
# 参数: 无
# 返回值: 无 (通过文件操作执行)
# =============================================================================
function handler_nginx_config() {
    # 创建 Nginx sites-enabled 目录 (如果不存在)
    mkdir -vp ${NGINX_CONFIG_DIR}/sites-enabled || return 1
    if [[ -f "${NGINX_CONFIG_DIR}/nginx.conf" ]]; then
        mv "${NGINX_CONFIG_DIR}/nginx.conf" "${NGINX_CONFIG_DIR}/default.conf.bak" || return 1
    fi
    # 复制项目中的 Nginx 配置文件到目标目录
    cp -af ${CONFIG_DIR}/nginx/conf/* ${NGINX_CONFIG_DIR} || return 1
    # 部署 user nginx; 前确保专用用户与日志目录归属就位, worker 才能正常降权运行
    _ensure_nginx_user

    local CA_SERVER
    CA_SERVER="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.ca_server' || true)"
    handler_update_ocsp_config "${CA_SERVER}" || return 1
}

# =============================================================================
# 函数名称: handler_web
# 功能描述: 重启 Web 服务使配置生效 (Web 前端固定为 Nginx 默认页面)。
#           1. 调用 handler_nginx_restart 重启 Nginx 服务。
#           2. 调用 handler_restart 重启 Xray 服务。
#           3. 更新脚本配置中的 Web 类型。
# 参数:
#   $1: web - Web 服务类型 (恒为 "normal")
# 返回值: 无 (通过调用其他函数执行操作)
# =============================================================================
function handler_web() {
    local web="${1:-normal}" # Web 前端固定为 normal, 保留形参以兼容既有调用点
    # Web 前端固定为 Nginx 默认页面, 此处仅重启服务使配置生效
    handler_nginx_restart
    handler_restart
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg web "${web}" '.nginx.web = $web')"
    persist_script_config
}

# =============================================================================
# 函数名称: handler_quick_install
# 功能描述: 执行一键快速安装流程。
#           1. 调用 handler_script_config 配置脚本。
#           2. 调用 handler_install 安装 Xray。
#           3. 调用 handler_xray_config 配置 Xray。
#           4. 添加默认的阻止规则 (BT, CN IP, AD Domain)。
#           5. 调用 handler_geodata_cron 更新 GeoData 并设置 Cron。
#           6. 调用 handler_restart 重启 Xray 服务。
#           7. 调用 handler_share 显示分享链接。
# 参数:
#   $1: quick_install_type - 速安装类型 (例如 Vision, XHTTP, Fallback)，默认为 Vision
# 返回值: 无 (通过调用一系列处理器函数执行完整安装流程)
# =============================================================================
function handler_quick_install() {
    local quick_install_type="${1:-Vision}" # 获取快速安装类型参数，默认为 Vision
    # 配置脚本 (设置各种参数)
    handler_script_config "${quick_install_type}"
    # 安装 Xray (使用 release 版本)
    handler_install 'release'
    # 生成 x25519 配置
    handler_x25519_config
    # 配置 Xray (生成并写入 config.json)
    handler_xray_config
    # 添加默认的阻止规则
    add_rule "bt" "protocol" "bittorrent" "block" 1
    add_rule "cn-ip" "ip" "geoip:cn" "block" "after" "private-ip"
    add_rule "ad-domain" "domain" "geosite:category-ads-all" "block"
    # 更新 GeoData 并设置 Cron 任务 (快速模式)
    handler_geodata_cron 1
    # 重启 Xray 服务
    handler_restart
    # 显示分享链接
    handler_share
    # 安装完成后顺带生成订阅三件套 (base64/Clash/sing-box), 让用户一次拿到所有客户端可用的配置:
    # v2rayN/NekoBox/FoXray 用 base64 链接, Clash 用 YAML, sing-box 用 JSON。订阅是配置的"派生快照",
    # 此处首次生成后, 后续配置变更由 refresh_subscription_after_config_change 自动重建。
    # 用 || true 兜底: 订阅生成异常不应中断已成功的安装 (best-effort, 与刷新机制一致)。
    handler_subscription || true
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
#           1. 加载国际化数据。
#           2. 根据传入的第一个参数 ($1) 调用对应的处理器函数。
#           3. 将剩余参数传递给处理器函数。
# 参数:
#   $@: 命令行参数，第一个参数决定要调用的处理器函数
# 返回值: 无 (通过调用其他函数执行具体操作)
# =============================================================================
function main() {
    # 加载国际化数据
    load_i18n

    local option="${1:-}" # 获取第一个参数作为操作选项
    shift             # 移除第一个参数，剩下的参数留给具体函数处理

    # 根据第一个参数调用对应的处理器函数
    case "${option}" in
    --quick) handler_quick_install "${1:-}" ;;    # 一键快速安装
    --install) handler_install "$@" ;;        # 安装 Xray
    --version) handler_xray_version "${1:-}" ;;   # 设置 Xray 版本
    --purge) handler_purge ;;                 # 卸载 Xray
    --nginx-install) handler_nginx_install ;; # 安装 Nginx
    --nginx-update) handler_nginx_update ;;   # 更新 Nginx
    --nginx-purge) handler_nginx_purge ;;     # 卸载 Nginx
    --script-config)
        handler_read_xray_config "${1:-}" # 读取 Xray 配置输入
        handler_script_config         # 更新脚本配置
        ;;
    --xray-config)
        handler_sni_config "${1:-}" # 处理 SNI 配置
        handler_x25519_config   # 生成 x25519 配置
        handler_xray_config     # 更新 Xray 配置
        ;;
    --sni-ports) handler_check_sni_ports ;;
    --routing) handler_routing "$@" ;; # 处理路由规则
    --change-domain)
        handler_change_domain "${1:-}" # 处理域名配置
        handler_xray_config        # 更新 Xray 配置
        handler_restart            # 重启 Xray
        local _only_change_domain="${CONFIG_DATA['only-change-domain']:-}"
        if ! [[ "${_only_change_domain,,}" == "y" ]]; then
            # 还原 Web 服务
            handler_web "$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.web')"
        fi
        ;;                                      # 更改域名
    --renew-certificate) handler_renew_ssl ;;   # 强制证书续签
    --remove-certificate) handler_remove_certificate ;; # 移除单域名证书
    --web) handler_web "${1:-}" ;;                  # 配置 Web 服务
    --ca-server) handler_ca_server "${1:-}" ;;
    --custom-sites) handler_custom_sites "${1:-}" ;;
    --share) handler_share "$@" ;;              # 显示分享链接 (支持 --save / --no-qr)
    --subscription) handler_subscription "$@" ;; # 生成订阅 (base64/Clash/sing-box)
    --nginx-cron) handler_nginx_cron ;;         # 管理 Nginx Cron
    --geodata-cron) handler_geodata_cron ;;     # 管理 GeoData Cron
    --warp) handler_warp ;;                     # 管理 WARP
    --reset-warp) handler_reset_warp ;;         # 重置 WARP
    --traffic) handler_traffic ;;               # 显示流量统计
    --change-port)
        handler_change_xray_port  # 处理 Xray 端口配置
        handler_xray_config       # 更新 Xray 配置
        handler_restart           # 重启 Xray
        handler_share             # 显示分享链接
        ;;                        # 修改 Xray 端口
    --start) handler_start ;;     # 启动 Xray
    --stop) handler_stop ;;       # 停止 Xray
    --restart) handler_restart ;; # 重启 Xray
    --bbr) handler_bbr ;;         # 启用/修复内核 BBR 拥塞控制 (幂等)
    --net-status) handler_net_status ;;     # 只读体检内核网络与 BBR 状态
    --health) handler_health ;;             # 一键全量体检 (只读)
    --net-tune) handler_net_tune ;;         # 内核网络高并发调优 (需确认)
    --nofile-limit) handler_nofile_limit ;; # 进程文件句柄上限 (需确认)
    --export-config) handler_export_config "$@" ;; # 导出配置与证书到归档
    --import-config) handler_import_config "$@" ;; # 从归档还原配置与证书
    # P1-3: 未知/未支持的参数 -> 打印用法并退出。原本 case 无 `*)` 分支, 传错参数 ->
    # 什么都不做 -> exit 0, 放进 cron 的 `--health` 写成 `--heath` 会让监控永远绿。
    # 退出码 2 = 用法错误, 与正常 0、真实故障 1 区分开。
    *)
        printf "${RED}[%s]${NC} %s: %s\n" "$(_i18n '.title.error')" "$(_i18n '.handler.unknown_option')" "${option}" >&2
        exit 2
        ;;
    esac

    # 配置写入收口: 本次调用若改过配置 (persist_* 置脏), 在这里统一重建一次订阅产物
    refresh_subscription_after_config_change
}

# --- 脚本执行入口 ---
# 将脚本接收到的所有参数传递给 main 函数开始执行
main "$@"
