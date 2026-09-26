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
#           启动/停止服务、处理路由规则等。
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
# 当前锁定 commit: e741a4f56d368afbb9e5be3361b40c4552d3710d
#   可核验: https://github.com/XTLS/Xray-install/commit/e741a4f56d368afbb9e5be3361b40c4552d3710d
# 更新流程 (REF 与 SHA256 必须成对更新, 缺一不可):
#   1) 把 XRAY_INSTALL_REF 改为目标 commit;
#   2) 重新计算摘要: curl -fsSL "${XRAY_INSTALL_URL}" | sha256sum, 输出填入 XRAY_INSTALL_SHA256;
#   3) 二者任一过期都会让 _download_verified 校验失败 (fail-closed), 不会静默放行。
# 跟随上游最新版本 (放弃固定): 设 XRAY_INSTALL_REF=main 且 XRAY_INSTALL_SHA256= (置空即跳过摘要比对)。
declare XRAY_INSTALL_REF="${XRAY_INSTALL_REF-e741a4f56d368afbb9e5be3361b40c4552d3710d}"
declare XRAY_INSTALL_URL="${XRAY_INSTALL_URL-https://raw.githubusercontent.com/XTLS/Xray-install/${XRAY_INSTALL_REF}/install-release.sh}"
declare XRAY_INSTALL_SHA256="${XRAY_INSTALL_SHA256-7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555}"


# 注: _error / _warn / _info / _pass 现由 _common.sh 统一提供 (print_* 的短名别名)。
#     此处曾内联一份 _error, 与 main.sh 的那份逐字相同、与 _common.sh 的 print_error
#     也逐字相同 —— 删除只留单一真源。

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
    # 注: 这里必须用 `{ ...; } 2>/dev/null` 包一层, 不能写 `printf ... >>"$X" 2>/dev/null` ——
    #     bash 打开重定向失败时报错走的是**当时的** stderr, 直接写在命令上的 `2>/dev/null`
    #     罩不住它 (实测: 组形式能吞, 直接形式会把 "没有那个文件或目录" 喷到终端)。
    #     审计是旁路, 配置目录不可写时不能往用户屏幕上插一行报错 (会插在分享链接/二维码中间)。
    { printf '%s\n' "${record}" >>"${AUDIT_LOG_PATH}"; } 2>/dev/null || true
    # 同步 syslog (系统无 logger 命令时静默跳过)
    if command -v logger >/dev/null 2>&1; then
        logger -t xray-script-personal-use-only "${record}" 2>/dev/null || true
    fi
    return 0
}

# =============================================================================
# 函数名称: _audit_dispatch
# 功能描述: dispatch 层审计留痕收口 —— 为 handler 各臂没有自行记录的写操作补一条记录。
#
# 为什么需要它:
#   各臂里散落的 `_audit_log` 只覆盖了分派臂里的一部分 (安装 / 卸载 / 启停 / 证书 /
#   备份 / BBR 调优), 而**改配置类**恰恰是零留痕 —— routing(分流规则)、xray-config、
#   change-domain、change-port、warp / reset-warp、sniff-route-only、custom-sites、
#   geodata-cron、nginx-cron、remove-certificate…… 这些才是事后最需要回溯的动作
#   ("前天那台机器上的分流规则是谁改的?")。反过来, 只读的 net-status / health 反倒
#   留了痕 —— 覆盖面与"变更审计"的语义正好反了, 故在此统一收口。
#
# 为什么放 dispatch 层而不是逐臂去补:
#   1) 动作名天然可得 (option 去掉 `--` 前缀), 不必为每个臂各写一份, 也不会漏。
#   2) 菜单路径与 CLI 直调 (`bash handler.sh --routing ...`) 都经过 main, 一处收口两处覆盖。
#   3) 调用点在 case **之前** (事前留痕): 不少失败路径直接 `_error`/exit, case 之后的代码
#      根本跑不到, 而"有人请求执行了 purge"这件事本身就是要审计的内容。动作的结果
#      (成功 / 失败 / 版本号 / 变更条数) 仍由臂内既有的 `_audit_log` 补充。
#
# 参数:
#   $1: option —— handler main 收到的第一个参数 (如 --routing)
#   $2: detail —— 其余参数拼成的补充说明 (可选; 只含子命令/类型/端口, 不含密钥)
# 返回值: 恒为 0 (审计失败绝不影响主流程)
# =============================================================================
function _audit_dispatch() {
    local option="${1:-}"
    local detail="${2:-}"
    # 无 option (异常调用) 不记录
    [[ -n "${option}" ]] || return 0
    # 排除名单 —— 下列选项不在本层重复记录, 分两类:
    #   A. 臂内已自行留痕, 且细节比这里更丰富 (版本号 / 变更条数 / .failed 后缀):
    #      purge / start / stop / restart / install / nginx-install / quick /
    #      export-config / import-config / nginx-purge / bbr / net-tune /
    #      nofile-limit / net-status / health / ipv6-status
    #   B. 查看类操作: share / traffic / sni-ports
    #      语义上它们回答的都是"当前是什么状态", 回答不了"谁改了什么"; 又因
    #      audit.log 目前尚无轮转 (见审计报告 P3), 放进来只会把真正的变更记录挤出日志。
    #      注: **这三并非严格只读** —— --sni-ports 在端口被自家 xray 占用时会
    #      `systemctl stop xray` 再复检, 失败还会 start 回来 (见 handler_check_sni_ports),
    #      --share --save 也会写 share-link.txt。它们被排除的理由不是"零副作用",
    #      而是"副产物是自愈性质的中间动作, 不是用户意图的变更", 记进去反而淹没真变更。
    #  注: net-status / health 臂内的留痕**刻意保留** —— "上次体检是什么时候、结果如何"
    #      对无人值守机器有值班价值, 属诊断历史, 与 B 类新增排除项不冲突。
    #  注: --ipv6-enable / --ipv6-disable / --ipv6-disable-hard **刻意不排除** ——
    #      它们是真实的内核参数变更, 由本函数统一记 ipv6-enable / ipv6-disable /
    #      ipv6-disable-hard 三条动作, 符合"变更单一收口"的约定。
    case "${option}" in
    --purge | --start | --stop | --restart | --install | --nginx-install | --quick) return 0 ;;
    --export-config | --import-config | --nginx-purge) return 0 ;;
    --bbr | --net-tune | --nofile-limit | --net-status | --health | --ipv6-status) return 0 ;;
    --share | --traffic | --sni-ports) return 0 ;;
    esac
    _audit_log "${option#--}" "${detail}"
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
    #       实测 CPU 打满且不停止 (记录见 .workbuddy/memory/2026-09-24.md)。
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
        block-ip | warp-ip)
            # 写前校验 ip 分流值: 明显非法 (如把域名/乱码填进 ip 分流) 当场提示重输,
            # 由本函数的重试上限兜底, 从而**不进** "写盘 -> xray 校验失败 -> 回滚 + 退出码 1" 的流程。
            # 注: 空输入 (直接回车 / 纯逗号空格) 与"取消"同义, 此处**不判失败** ——
            #     交由 add_rule 的 value_empty 守卫统一告警并 no-op; 若在此判失败,
            #     用户想取消时反而会撞上 3 次重试后退出。
            if [[ -n "${result//[[:space:],]/}" ]]; then
                exec_check '--rule-ip' "${result}" || valid=false
            fi
            ;;
        block-domain | warp-domain)
            # 写前校验 domain 分流值 (同 ip 分支: 空输入放行交给 value_empty 守卫)
            if [[ -n "${result//[[:space:],]/}" ]]; then
                exec_check '--rule-domain' "${result}" || valid=false
            fi
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
        # jq 内部函数 exec_clear: 决定每个字段是**清空还是保留原值** ——
        #   键名在 $keep 白名单里 -> 原样保留; 否则递归清空。
        #   (注意它是 jq 的 def, 不是 bash 函数, 全仓 grep 不到同名 bash 定义)
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
# 子函数名称: _kcp_mask_json
# 功能描述: 按指定类型 id 生成 mKCP 的 finalmask 对象 (含 seed)。
#           Xray 26.x 把 mKCP 的 seed/header 迁到了 finalmask, 但类型 id 中途改过名,
#           两种写法的字段名也不同 (故此处按 id 分别拼装, 见 get_kcp_finalmask 的说明)。
# 参数:
#   $1: 类型 id (mkcp-legacy / mkcp-aes128gcm)
#   $2: mKCP seed
# 返回值: 0-stdout 打印 finalmask JSON; 1-未知 id
# =============================================================================
function _kcp_mask_json() {
    local id="${1:-}" seed="${2:-}"
    case "${id}" in
    # 空 header + 非空 value = AES-128-GCM, value 即密码 (与旧 kcpSettings.seed 等价)
    mkcp-legacy)
        jq -nc --arg seed "${seed}" '{udp:[{type:"mkcp-legacy",settings:{header:"",value:$seed}}]}'
        ;;
    mkcp-aes128gcm)
        jq -nc --arg seed "${seed}" '{udp:[{type:"mkcp-aes128gcm",settings:{password:$seed}}]}'
        ;;
    *)
        return 1
        ;;
    esac
}

# =============================================================================
# 子函数名称: _kcp_fallback_id
# 功能描述: 探测失败时的回退 id 选择, 仅依赖 xray 版本号 (26.2~26.5 → mkcp-aes128gcm,
#           26.6+ → mkcp-legacy), 不靠"凭空猜一个 id 再让 xray -test 验证" (验证需要
#           xray 二进制, 而走到这里正是因为探测拿不到 xray 的 -test 结果)。
#           作为 get_kcp_finalmask 探测失败后的最后兜底, 保证落盘配置不是 26.x 已移除的
#           kcpSettings.seed 死路; 具体拼装仍复用 _kcp_mask_json, 与探测成功路径同一套结构。
# 参数: 无
# 返回值: 0-stdout 打印 id ('mkcp-legacy' / 'mkcp-aes128gcm')
# =============================================================================
function _kcp_fallback_id() {
    local ver='' major=0 minor=0
    if cmd_exists 'xray'; then
        ver="$(xray --version 2>/dev/null | head -1)"
    elif [[ -x "${XRAY_BIN_PATH:-/usr/local/bin/xray}" ]]; then
        ver="$("${XRAY_BIN_PATH:-/usr/local/bin/xray}" --version 2>/dev/null | head -1)"
    fi
    if [[ "${ver}" =~ Xray\ ([0-9]+)\.([0-9]+) ]]; then
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"
    fi
    if (( major > 26 )) || (( major == 26 && minor >= 6 )); then
        printf '%s' 'mkcp-legacy'
    else
        printf '%s' 'mkcp-aes128gcm'
    fi
}

# =============================================================================
# 函数名称: get_kcp_finalmask
# 功能描述: 生成 mKCP 的 finalmask 配置, 类型 id 由本机 xray 二进制实测选定。
#
#   背景 (2026-09-23 实测上游源码确认): Xray 26.x 把 mKCP 的 seed/header 迁进 finalmask,
#   但类型 id 在 26.6 前后改过一次名, 两种写法互不兼容 —— 写错一边, Xray 会以
#   "unknown config id" 拒绝加载**整份**配置 (实测 26.3.27 报 unknown config id: mkcp-legacy):
#     A) mkcp-legacy    + settings.{header:"", value:"<seed>"}   26.6 起 / 当前主线
#     B) mkcp-aes128gcm + settings.password:"<seed>"             26.2.6 ~ 26.5.x
#   两者的线上协议完全一致 (空 header + 密码即 AES-128-GCM, 密码为 seed, 与旧
#   kcpSettings.seed 一一对应), 差别只在配置写法。既然写错任一边都是"整份配置加载失败",
#   就不写死版本号 (记错一次即复发), 改为拿本机已装的 xray 逐个试跑: 用 xray 自己的
#   `run -test` 校验最小配置, 取第一个被接受的写法 —— 上游日后再改名也能自适应。
#
# 参数:
#   $1: mKCP seed (config.json 的 .xray.kcp)
# 返回值: 0-stdout 打印可嵌入 streamSettings 的 finalmask JSON
#         1-无法判定 (xray 缺失 / 不支持 -test / 两种写法都不被接受), 由调用方回退;
#           此时若拿到过 xray 的报错, 会把**最后一条**打到 stderr 供排查 (见下)
# 注意: 诊断输出必须走 stderr —— 调用方是 `if KCP_MASK="$(get_kcp_finalmask ...)"`,
#       stdout 被命令替换捕获, 往里写会污染返回的 JSON。
# =============================================================================
function get_kcp_finalmask() {
    local seed="${1:-}"
    local id='' json='' tmp_dir='' tmp_file='' xray_bin=''
    local err='' last_err=''
    # 定位 xray: 优先 PATH, 兜底用代码库约定的绝对路径 (与 traffic.sh / check.sh 一致)。
    # 仅依赖 command -v 会在脚本运行时 PATH 不含 /usr/local/bin 时漏掉已安装的 xray,
    # 误判"未安装"而走死路回退 (写 kcpSettings.seed, 而 26.x 已移除该字段)。
    if cmd_exists 'xray'; then
        xray_bin="$(command -v xray)"
    elif [[ -x "${XRAY_BIN_PATH:-/usr/local/bin/xray}" ]]; then
        xray_bin="${XRAY_BIN_PATH:-/usr/local/bin/xray}"
    else
        return 1
    fi
    # 临时文件落点: 与 _download_verified 同一套回退顺序。
    # 注: 不用 ${TMPFILE_DIR:-${SCRIPT_CONFIG_DIR}} 这种嵌套写法 —— 在 set -u 下,
    # 当 SCRIPT_CONFIG_DIR 未定义时会触发"未绑定的变量"而中断; 改为逐层判空, 行为不变。
    tmp_dir="${TMPFILE_DIR:-}"
    [[ -z "${tmp_dir}" ]] && tmp_dir="${SCRIPT_CONFIG_DIR:-}"
    if [[ ! -d "${tmp_dir}" || ! -w "${tmp_dir}" ]]; then
        tmp_dir="${TMPDIR:-/tmp}"
    fi
    # 模板必须带 .json 后缀 —— xray 26.x 按扩展名判断配置格式, 无后缀会直接
    # "Failed to get format of <path>" (exit 23) 拒载整份配置。此前漏了后缀, 使本函数
    # 的逐个候选实测恒失败、一路退到 _kcp_fallback_id 的版本号猜测 (2026-09-24 实测确认)。
    tmp_file="$(mktemp "${tmp_dir%/}/.${SCRIPT_NAME}-kcp.XXXXXXXX.json")" || return 1
    for id in 'mkcp-legacy' 'mkcp-aes128gcm'; do
        json="$(_kcp_mask_json "${id}" "${seed}")" || continue
        # 最小配置: 只留一个 mKCP 入站与一个 freedom 出站, 不引路由/geoip/DNS ——
        # 探测只关心 finalmask 的类型 id 能否被解析, 配置越简单越不会被无关原因误判。
        # -test 只解析配置不监听端口, 所以这里写个高位端口即可。
        jq -nc --argjson fm "${json}" '{
            log: {loglevel: "none"},
            inbounds: [{
                tag: "kcp-mask-probe", listen: "127.0.0.1", port: 65123, protocol: "vless",
                settings: {clients: [{id: "00000000-0000-0000-0000-000000000001"}], decryption: "none"},
                streamSettings: {network: "kcp", kcpSettings: {}, finalmask: $fm}
            }],
            outbounds: [{protocol: "freedom"}]
        }' >"${tmp_file}" 2>/dev/null || continue
        # 捕获 xray 的 stdout+stderr: 成功时丢弃, 失败时留作诊断 (仅最后一个候选的报错保留)
        if err="$("${xray_bin}" run -test -config "${tmp_file}" 2>&1)"; then
            rm -f "${tmp_file}"
            printf '%s' "${json}"
            return 0
        fi
        last_err="${err}"
    done
    rm -f "${tmp_file}"
    # 两种写法都不被接受: 把本机 xray 的最后一条报错打到 stderr。
    # 此前这里静默 return 1, 调用方只能打印笼统的"未安装或不支持 -test"提示 —— 而真实原因
    # 往往是"本机 xray 报某个我们没预期的错"(版本不在候选内 / 结构又改了), 静默会把它藏住。
    if [[ -n "${last_err}" ]]; then
        print_warn "$(_i18n '.handler.xray.kcp_mask_probe_error')"
        printf '%s\n' "${last_err}" >&2
    fi
    return 1
}

# =============================================================================
# 函数名称: heal_mkcp_finalmask
# 功能描述: mKCP finalmask 类型 id 自适应自愈 (Xray 26.x 版本相关)。
#           背景: Xray 26.6 把 finalmask 的类型 id 从 mkcp-aes128gcm 改名成
#           mkcp-legacy, 二者互不兼容 —— 写错一边, xray 会以 "unknown config id"
#           拒绝加载整份配置。若用户升级 (或降级) Xray 后没有重新跑"更新配置",
#           已落盘的 mKCP config 就会因 id 过期而加载失败 (见 2026-09-23 的残留风险说明)。
#           本函数在 xray 安装/升级后、启动前跑一次: 若本机 xray 已不接受当前 config
#           里的 finalmask 写法, 就用 get_kcp_finalmask 按新 xray 实测重选 id 并原地重写。
# 参数: 无
# 返回值: 恒 0 (自愈失败也不阻断安装/启动, 只告警; 交原流程的 -test 守卫兜底)
# =============================================================================
function heal_mkcp_finalmask() {
    # 前置: 本机必须已装 xray (否则无从探测, 且无配置可修)
    cmd_exists 'xray' || return 0
    # 仅当已落盘 config 存在才处理 (全新安装尚无 config, 交给后续的 xray-config 流程)
    local cfg="${XRAY_CONFIG_PATH:-/usr/local/etc/xray/config.json}"
    [[ -f "${cfg}" ]] || return 0
    # 只关心 mKCP 配置 (其它协议无 finalmask, 跳过以免无谓开销与误伤)
    local net=''
    net="$(jq -r '.inbounds[1].streamSettings.network // empty' "${cfg}" 2>/dev/null || true)"
    [[ "${net}" == 'kcp' ]] || return 0
    # 当前 config 本机 xray 能接受 -> 无需动作 (也顺便确认不是 routing/证书等其它错误)
    if _verify_xray_config "${cfg}"; then
        return 0
    fi
    # 校验失败 -> 仅当错误指向 finalmask/mkcp 时才自愈, 其它错误不动 (避免乱重写)
    local err=''
    # 注: xray 校验失败时退出码非 0, 此赋值在 set -e (handler.sh:32) 下会抢先退出,
    # 故用 || true 兜住; 真正判错交给下方 grep 关键词, 而非退出码。
    err="$(xray run -test -config "${cfg}" 2>&1)" || true
    if ! printf '%s' "${err}" | grep -qiE 'finalmask|mkcp|unknown config id'; then
        return 0
    fi
    # 取 seed: 优先从已落盘 config 反读, 否则退回脚本配置 (.xray.kcp)
    local seed=''
    seed="$(jq -r '
        .inbounds[1].streamSettings.finalmask.udp[0].settings.value //
        .inbounds[1].streamSettings.finalmask.udp[0].settings.password //
        .inbounds[1].streamSettings.kcpSettings.seed // empty
    ' "${cfg}" 2>/dev/null || true)"
    [[ -z "${seed}" ]] && seed="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.kcp // empty' 2>/dev/null || true)"
    [[ -z "${seed}" ]] && return 0
    # 按新 xray 实测重选 id
    local fm=''
    if ! fm="$(get_kcp_finalmask "${seed}")"; then
        return 0
    fi
    # 原地重写 finalmask 并原子落盘
    local new_cfg=''
    if ! new_cfg="$(jq --argjson fm "${fm}" '
        .inbounds[1].streamSettings |= (del(.finalMask) | .finalmask = $fm)
    ' "${cfg}" 2>/dev/null)"; then
        return 0
    fi
    # 写前备份
    cp -f "${cfg}" "${cfg}.bak" 2>/dev/null || true
    printf '%s\n' "${new_cfg}" | _atomic_write "${cfg}" || return 0
    # 写后复核: 仍不通过则回滚备份 (自愈失败时宁可回到原状, 交原流程 -test 守卫报错)
    if ! _verify_xray_config "${cfg}"; then
        cp -f "${cfg}.bak" "${cfg}" 2>/dev/null || true
        print_warn "$(_i18n '.handler.xray.kcp_mask_heal_failed')"
        return 0
    fi
    print_warn "$(_i18n '.handler.xray.kcp_mask_healed')"
    return 0
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
        # 写后复核未通过且已回滚到备份 —— 配置处于安全状态。这里**不再 _error 退出**:
        # _error 会一路冒泡成 install.sh trampoline 的"脚本在第 N 行意外失败", 并直接杀掉整个
        # 交互脚本, 用户被迫重进菜单。改为 print_warn + 以非 0 返回, 交由 exec_handler 软失败
        # (回到菜单, 可重试), 行为对齐仓库既有的"预期内不可用 → print_warn + 回菜单"惯例。
        if [[ -f "${backup_path}" ]]; then
            cp -f "${backup_path}" "${XRAY_CONFIG_PATH}" 2>/dev/null || true
        fi
        print_warn "$(_i18n '.handler.persist.verify_failed')"
        return 1
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
#           conf.d / nginxconfig.io 支持文件。
#           注: 早期版本这里列过 "web", 但仓库里从来没有 config/nginx/conf/web ——
#           sync_missing_nginx_support_dir 对不存在的源目录是 `return 0` 静默跳过,
#           所以那一项从未生效, 已从描述中去掉 (别再照着说明去找它)。
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
    # 注: 模板缺失时这里刻意**不**自己 _error, 只 return 1 —— 调用方
    #     (_custom_site_prepare 等) 的失败分支带着完整的回滚 (停续签 / 清半成品 /
    #     恢复 stream 备份), 在本函数里抢先用 _error 退出会绕过那套回滚。
    #     这条路径已有用例守着 (handler_custom_sites_arm_test T14/T19)。
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
    # 修复: 用户输入可能为空 (直接回车) 或夹带多余逗号/空格 (如 "1.2.3.4,, 5.6.7.8")。
    # 原 `tr ',' '\n' | jq -R | jq -s` 会把空串变成 [""] (含一个空字符串的数组),
    # 进而生成 ip:[""] 这类非法路由规则 —— xray 校验报 "invalid IP: " 触发回滚 + 退出码 1。
    # 现先去首尾空格、丢弃空元素; 若结果仍为空数组, 视为"未输入", 不创建规则直接返回。
    local value
    value=$(printf '%s' "${3:-}" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | awk 'NF' | jq -R | jq -s)
    if [[ "${value}" == "[]" ]]; then
        _warn "$(_i18n '.handler.rule.value_empty')"
        return 0
    fi
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
                    XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson target_index "${target_index}" --argjson new_rule "${new_rule}" '.routing.rules |= .[:$target_index] + [$new_rule] + .[$target_index:]')"
                elif [[ "${position}" == "after" ]]; then
                    # 插入到 target_tag 规则之后
                    XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson target_index $((target_index + 1)) --argjson new_rule "${new_rule}" '.routing.rules |= .[:$target_index] + [$new_rule] + .[$target_index:]')"
                else
                    # 默认追加到末尾
                    # $new_rule 是 add_rule 用 jq -nc 构造的单个对象; 追加时必须包成单元素数组 [$new_rule],
# 否则 .routing.rules += $new_rule 等价于 array + object -> jq 报错
# "array and object cannot be added" (与位置插入分支同理, 旧 bug: 6fcda2a 漏改此处)。
XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson new_rule "${new_rule}" '.routing.rules += [$new_rule]')"
                fi
            else
                # target_tag 规则不存在，追加到末尾
                # $new_rule 是 add_rule 用 jq -nc 构造的单个对象; 追加时必须包成单元素数组 [$new_rule],
# 否则 .routing.rules += $new_rule 等价于 array + object -> jq 报错
# "array and object cannot be added" (与位置插入分支同理, 旧 bug: 6fcda2a 漏改此处)。
XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson new_rule "${new_rule}" '.routing.rules += [$new_rule]')"
            fi
        else
            # 未指定 target_tag
            # 如果指定了数字位置
            if [[ -n "${position}" && "${position}" -ge 0 ]]; then
                # 插入到指定索引位置
                XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson position "${position}" --argjson new_rule "${new_rule}" '.routing.rules |= .[:$position] + [$new_rule] + .[$position:]')"
            else
                # 默认追加到末尾
                # $new_rule 是 add_rule 用 jq -nc 构造的单个对象; 追加时必须包成单元素数组 [$new_rule],
# 否则 .routing.rules += $new_rule 等价于 array + object -> jq 报错
# "array and object cannot be added" (与位置插入分支同理, 旧 bug: 6fcda2a 漏改此处)。
XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson new_rule "${new_rule}" '.routing.rules += [$new_rule]')"
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
        # 重置 xray 部分，保留 version, warp, rules, sniffRouteOnly 字段
        # (后两者是用户显式设置的开关/规则, 与"配置本身"无关, 不该被重置掉)
        SCRIPT_CONFIG=$(reset_json_fields "${SCRIPT_CONFIG}" 'xray' 'version' 'warp' 'rules' 'sniffRouteOnly')
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
    # 采集参数 (声明为 local, 供下方 _xray_* 子函数经由 bash 动态作用域读取, 避免 20+ 处重复声明)
    local CONFIG_TAG XRAY_PORT XRAY_UUID FALLBACK_UUID TROJAN_PASSWORD KCP_SEED \
          TARGET_DOMAIN SERVER_NAMES PRIVATE_KEY SHORT_IDS XHTTP_PATH \
          XRAY_RULES_STATUS XRAY_RULES_BT XRAY_RULES_CN XRAY_RULES_AD XRAY_RULES WARP_STATUS \
          XRAY_SNIFF_ROUTE_ONLY
    _xray_collect_params   # 从 SCRIPT_CONFIG 读取并填充上述 local + 加载配置模板到全局 XRAY_CONFIG
    _xray_apply_inbounds   # 按 CONFIG_TAG 应用 inbound 字段, 并做 REALITY serverNames 守卫
    _xray_apply_sniffing   # 嗅探域名仅用于路由 (默认关: 配置零改写)
    _xray_apply_rules      # 按 XRAY_RULES_STATUS 保留/重置路由规则
    _xray_apply_dns        # 顶层 dns 段 (显式解析器; 字段集由本机实测决定)
    _xray_apply_domain_strategy  # 有 IP 类规则时切 IPIfNonMatch, 让 geoip 分流真正生效
    # 注: 必须接住非 0 —— 启用了 WARP 却没写进出站, 路由规则会指向不存在的 tag,
    #     xray 会拒绝加载整份配置, 比"这次配置更新失败"严重得多。中止本次生成,
    #     由 exec_handler 软失败回菜单 (不 _error 杀整个交互脚本)。
    _xray_apply_warp || return 1   # 启用 WARP 时追加 wireguard 出站
    _xray_apply_warp_balancer      # WARP 健康探测 + 自动回落 (未启用则清理残留)
    _xray_apply_sockopt            # 出站 sockopt 网络调优 (字段集由本机实测决定)
    # 回写路由规则到脚本配置并持久化
    # 注: 副本必须取**未改写**形态 —— 上面 _xray_apply_warp_balancer 可能把规则改成了
    #     balancerTag (探测启用时), 那是"给 xray 看的临时形态"。权威副本里规则 tag 恒为
    #     outboundTag="warp" (add_rule 就这么写, handler_warp 关闭分支也按这个形态删),
    #     否则下次写回配置时形态会随"当次探测结果"漂移, 且开关 WARP 会漏删规则。
    XRAY_RULES="$(echo "${XRAY_CONFIG}" | jq --arg bt "${WARP_BALANCER_TAG}" '.routing.rules
        | if type == "array" then
            map(if .balancerTag == $bt then del(.balancerTag) + {outboundTag: "warp"} else . end)
          else . end')"
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --argjson rules "${XRAY_RULES}" '.rules = $rules')"
    persist_script_config
    persist_xray_config
}

# =============================================================================
# 子函数名称: _xray_collect_params
# 功能描述: 从 SCRIPT_CONFIG 读取 Xray 各项参数填充父函数的 local 变量, 并加载配置模板到全局 XRAY_CONFIG。
#           (动态作用域: 此处赋值均写回 handler_xray_config 已声明的 local, 不另起 local)
# =============================================================================
function _xray_collect_params() {
    CONFIG_TAG="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag')"                # 获取配置标签
    XRAY_PORT="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.port')"                # 获取端口
    XRAY_UUID="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.uuid')"                # 获取 UUID
    FALLBACK_UUID="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.fallback')"        # 获取 Fallback UUID
    TROJAN_PASSWORD="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.trojan')"        # 获取 Trojan 密码
    KCP_SEED="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.kcp')"                  # 获取 mKCP Seed
    TARGET_DOMAIN="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.target')"          # 获取目标域名
    SERVER_NAMES="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.serverNames')"      # 获取服务器名称
    PRIVATE_KEY="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.privateKey')"        # 获取私钥
    SHORT_IDS="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.shortIds')"            # 获取 Short IDs
    XHTTP_PATH="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.path')"               # 获取路径
    XRAY_RULES_STATUS="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.rules.reset')" # 获取规则状态
    XRAY_RULES_BT="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.rules.bt')"        # 获取 bt 规则状态
    XRAY_RULES_CN="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.rules.cn')"        # 获取 cn 规则状态
    XRAY_RULES_AD="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.rules.ad')"        # 获取 ad 规则状态
    XRAY_RULES="$(echo "${SCRIPT_CONFIG}" | jq -r '.rules')"                   # 获取路由规则
    # 注: 与其它取 WARP 状态的调用点保持一致加 `|| true` —— jq 失败时取空串即可,
    #     不应让 set -e 把整个配置生成流程打断 (下方 is_enabled 会把空串当未启用)。
    WARP_STATUS="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.warp' || true)"      # 获取 WARP 状态
    # 嗅探域名仅用于路由 (默认关): 键可能不存在 (老配置文件), 用 // 0 兜底 — is_enabled
    # 只认 1/true/yes/y/on, 空串与 "null" 都会被判为关闭, 与"默认关"一致。
    XRAY_SNIFF_ROUTE_ONLY="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.sniffRouteOnly // 0' || true)"
    # 加载对应配置标签的 Xray 配置模板 (写入全局 XRAY_CONFIG)
    XRAY_CONFIG="$(jq '.' ${SCRIPT_XRAY_DIR}/${CONFIG_TAG}.json)"
}

# =============================================================================
# 子函数名称: _xray_apply_inbounds
# 功能描述: 按 CONFIG_TAG 应用 inbound 字段更新 + REALITY serverNames 守卫。
#           (动态作用域: 读父 local 的 CONFIG_TAG/XRAY_* 等, 改写全局 XRAY_CONFIG; 不另起同名 local)
# =============================================================================
function _xray_apply_inbounds() {
    # 如果配置标签不是 sni，则更新端口
    if [[ "${CONFIG_TAG,,}" != 'sni' ]]; then
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson port "${XRAY_PORT}" '.inbounds[1].port = $port')"
    fi
    # 根据配置标签更新特定字段 (第一部分)
    case "${CONFIG_TAG,,}" in
    mkcp | vision | xhttp | fallback | sni)
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg uuid "${XRAY_UUID}" '.inbounds[1].settings.clients[0].id = $uuid')"
        ;;
    trojan)
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg password "${TROJAN_PASSWORD}" '.inbounds[1].settings.clients[0].password = $password')"
        ;;
    esac
    # P-优化: REALITY serverNames 守卫 —— 防手滑把占位符/空值写进 .xray.serverNames,
    #   导致握手失败或把伪装目标暴露成 example.com。
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
        # Xray 26.x 起 mKCP 的 seed 字段已移除, 改用 finalmask; 具体用哪个类型 id
        # 由 get_kcp_finalmask 拿本机 xray 实测选定 (26.3.27 只认 mkcp-aes128gcm,
        # 26.6+ 只认 mkcp-legacy, 两者线上协议一致)。
        local KCP_MASK=''
        if KCP_MASK="$(get_kcp_finalmask "${KCP_SEED}")"; then
            # 顺手 del 掉 camelCase 旧键: Go 的 json 解码对键名大小写不敏感, 若模板/旧配置里
            # 残留一个 finalMask, 与这里的 finalmask 并存时取值取决于出现顺序, 留着就是隐患。
            XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson fm "${KCP_MASK}" '
                .inbounds[1].streamSettings |= (del(.finalMask) | .finalmask = $fm)')"
        else
            # 探测不出: 按本机 xray 版本选一个最贴近的 finalmask 写法写入,
            # 不再写 26.x 已移除的 kcpSettings.seed (那会导致 26.x 直接加载失败、且难以排查)。
            # 回退 id 由 _kcp_fallback_id 依版本判定 (26.2~26.5 → mkcp-aes128gcm, 26.6+ →
            # mkcp-legacy); 具体拼装复用 _kcp_mask_json, 与探测成功路径用同一套结构。
            local KCP_FALLBACK_ID='' KCP_FALLBACK_FM=''
            KCP_FALLBACK_ID="$(_kcp_fallback_id)"
            KCP_FALLBACK_FM="$(_kcp_mask_json "${KCP_FALLBACK_ID}" "${KCP_SEED}")"
            print_warn "$(_i18n '.handler.xray.kcp_mask_fallback')"
            XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson fm "${KCP_FALLBACK_FM}" '
                .inbounds[1].streamSettings |= (del(.finalMask) | .finalmask = $fm)')"
        fi
        ;;
    vision | xhttp | trojan | fallback | sni)
        if [[ "${CONFIG_TAG,,}" != 'sni' ]]; then
            XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg target "${TARGET_DOMAIN}:443" '.inbounds[1].streamSettings.realitySettings.target = $target')"
        fi
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson serverNames "${SERVER_NAMES}" '.inbounds[1].streamSettings.realitySettings.serverNames = $serverNames')"
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg privateKey "${PRIVATE_KEY}" '.inbounds[1].streamSettings.realitySettings.privateKey = $privateKey')"
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson shortIds "${SHORT_IDS}" '.inbounds[1].streamSettings.realitySettings.shortIds = $shortIds')"
        ;;
    esac
    # 根据配置标签更新特定字段 (第三部分)
    case "${CONFIG_TAG,,}" in
    xhttp | trojan)
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg path "${XHTTP_PATH}" '.inbounds[1].streamSettings.xhttpSettings.path = $path')"
        ;;
    fallback | sni)
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg uuid "${FALLBACK_UUID}" '.inbounds[2].settings.clients[0].id = $uuid')"
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg path "${XHTTP_PATH}" '.inbounds[2].streamSettings.xhttpSettings.path = $path')"
        ;;
    esac
}

# =============================================================================
# 子函数名称: _xray_apply_rules
# 功能描述: 按 XRAY_RULES_STATUS 保留现有路由规则或重置为默认规则 (调用 add_rule)。
# =============================================================================
function _xray_apply_rules() {
    case "${XRAY_RULES_STATUS}" in
    0)
        # 保留当前路由规则
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson rules "${XRAY_RULES}" '.routing.rules = $rules')"
        ;;
    1)
        # 重置并添加默认路由规则
        is_enabled "${XRAY_RULES_BT}" && add_rule "bt" "protocol" "bittorrent" "block" 1
        is_enabled "${XRAY_RULES_CN}" && add_rule "cn-ip" "ip" "geoip:cn" "block" "after" "private-ip"
        is_enabled "${XRAY_RULES_AD}" && add_rule "ad-domain" "domain" "geosite:category-ads-all" "block"
        ;;
    esac
}

# =============================================================================
# WARP 出站 (原生 WireGuard)
#
# 背景: 原实现靠 Docker 拉 cloudflare-warp 容器, Xray 侧用 socks 出站指向容器暴露的
#   40001 端口。代价是必须装 Docker、多一个常驻容器、多一跳 socks 转发, 且注册动作
#   在容器里由 warp-cli 完成。Xray 26.x 自带 wireguard 出站, 可直连 Cloudflare WARP
#   端点, 于是改为: 一次性注册拿到 WireGuard 凭据 -> 落 warp.json 复用 -> 出站直接写
#   wireguard。注册只做一次, 之后反复开关 WARP 不再联网。
#
# 凭据来源优先级:
#   1) ${SCRIPT_CONFIG_DIR}/warp.json —— 本脚本自己注册并落盘的, 复用零联网
#   2) 向 Cloudflare 注册端点现注册一份 (需 curl 能访问 api.cloudflareclient.com)
#
# 已知识别风险: 注册端点对部分机房 IP 段会直接回 500 (社区有实测案例)。此时保持既有
#   配置不动 + 明确报错, 绝不把状态位改成"已启用" —— 否则路由规则会指向不存在的出站,
#   整份 Xray 配置都会加载失败。
# =============================================================================

# WARP 凭据文件 (含私钥; 由 _atomic_write 保证 600 权限)
readonly WARP_CREDENTIALS_PATH="${SCRIPT_CONFIG_DIR}/warp.json"
# Cloudflare WARP 注册端点与客户端标识 (Android 6.10 / build 2158)
readonly WARP_API_URL='https://api.cloudflareclient.com/v0a2158/reg'
readonly WARP_API_CLIENT_VERSION='a-6.10-2158'
readonly WARP_API_USER_AGENT='okhttp/3.12.1'
# 注册响应缺 endpoint 时的兜底端点, 与官方客户端一致
readonly WARP_ENDPOINT_FALLBACK='engage.cloudflareclient.com:2408'
# 官方客户端同款 MTU: WARP 隧道内层取 1280 以避免分片
readonly WARP_MTU='1280'
# 启用健康探测时的出站 tag。探测开启后指向 WARP 的规则改由 balancer 中转 (见
# _warp_rules_use_balancer): 走哪个 tag 出站是实现细节, 规则侧不感知。
#
# ── 实测结论 (真机 Xray 26.3.27, 2026-09-26) ────────────────────────────────
# 1) 规则里的 outboundTag **只**在 outbounds 里查 tag, 绝不会落到 balancer —— 把
#    balancer 改名叫 warp、出站叫 warp-out, 规则 outboundTag="warp" 依然不通 (实测
#    矩阵已验)。走 balancer 的唯一途径是规则字段 **balancerTag**。
# 2) tag 解析不到时不是"忽略该条规则", 而是 fail-closed: 命中该规则的流量全部阻断,
#    且不留显眼日志 —— 表现为"WARP 分流静默失效", 极难排查。
# 故"规则照旧写 warp、由 balancer 顶替同名 tag"这条设想**不成立**: 开探测后出站已改名
# warp-out, 规则里的 warp 无处可解析 -> 整条 WARP 分流静默断掉。修法是把改写的责任
# 收在 _warp_rules_use_balancer / _warp_rules_use_outbound 这对函数里 (幂等, 可来回切),
# 而不是去动本常量、也不是让规则裸写 balancerTag。
readonly WARP_OUTBOUND_TAG='warp-out'
# ---- WARP 健康探测与自动回落 ----
# WARP 出站指向 Cloudflare 任播 IP, 隧道抖动或出口被目标站点风控时会出现"TCP 连得上但
# 数据不通"的状态, 光看进程活着判断不出来。observatory 周期探测真实可用性, balancer 在
# 探测判定失效时把流量交给 fallbackTag, 实现"WARP 挂了自动走直连"而不是干等超时。
# balancer 的 selector 只放 WARP 自己: 若把 direct 也放进去做"选优", leastPing 会因为
# 直连延迟更低而把本该走 WARP 的流量抢走, 违背分流本意。
readonly WARP_BALANCER_TAG='warp-balancer'
# 探测目标取 Cloudflare 自家 204 端点: WARP 出口必然可达; 墙外 VPS 直连通常也可达。
readonly WARP_PROBE_URL='https://cp.cloudflare.com/generate_204'
readonly WARP_PROBE_INTERVAL='30s'
# ---- 顶层 DNS ----
# 不写 dns 段时 Xray 的域名解析交给系统 resolver (主机商 DNS), 结果不可控。
# 显式声明 DoH 解析器 (防劫持) + 一家明文兜底 (DoH 被 QoS 时仍能出结果)。
readonly XRAY_DNS_SERVERS='["https://1.1.1.1/dns-query","https://8.8.8.8/dns-query","1.1.1.1"]'
readonly XRAY_DNS_QUERY_STRATEGY='UseIPv4'
# ---- 出站 sockopt 网络调优 ----
# 服务端出站 (freedom) 直连目标站点时, 内核默认给"已建立但对端无响应"的连接留了很长超时
# (Linux tcp_retries2 默认约 15 分钟), 代理层表现为"客户端卡住不动、看不出错"。
# 显式 tcpUserTimeout 让链路在无 ACK 达该毫秒数时判定死亡, 客户端能立刻重试或换路。
# tcpKeepAliveIdle/Interval 把长连接保活在 NAT / 中间设备老化之前, 避免"看着连着其实已断"。
# 注: 文档字段名是**全小写** tcpcongestion, 且它依赖内核算法可用性 —— 内核已由 BBR 调优
#     生效, socket 默认即继承, 故此处刻意不写, 免得在内核无该算法时把连接配置搞坏。
readonly XRAY_SOCKOPT_USER_TIMEOUT=10000     # 毫秒; 无 ACK 即判死 (内核默认约 15 分钟)
readonly XRAY_SOCKOPT_KEEPALIVE_IDLE=45      # 秒; 空闲多久开始保活探测 (Xray 出站默认同值)
readonly XRAY_SOCKOPT_KEEPALIVE_INTERVAL=15  # 秒; 保活探测间隔
# ---- 嗅探域名仅用于路由 (sniffing.routeOnly, 默认关) ----
# 默认 (关): 嗅探出的域名既参与路由判定, 也作为出站连接目标 —— 出站保持按域名直连,
#             CDN 场景下域名解析能选到更近的回源节点, 这是本脚本一直以来的行为。
# 开启:      嗅探结果只服务路由, 出站退回用客户端给的 IP 连接。代价是可能丢掉上述
#             CDN 优选, 收益是出站不再产生额外域名解析 (减少解析开销与域名泄漏面)。
# 因此做成显式开关而非默认行为: 影响面取决于上游是否套 CDN, 不该替所有用户决定。
# 探测端口: `xray run -test` 只解析配置不监听, 取高位端口避免与真实服务撞车。
readonly XRAY_SNIFF_PROBE_PORT=65124

# =============================================================================
# 子函数名称: _xray_bin_path
# 功能描述: 定位本机 xray 可执行文件 (PATH 优先, 兜底代码库约定的绝对路径)。
#           仅依赖 command -v 会在运行时 PATH 不含 /usr/local/bin 时漏掉已安装的 xray。
# 参数: 无
# 返回值: 0-stdout 输出路径; 1-未找到
# =============================================================================
function _xray_bin_path() {
    if cmd_exists 'xray'; then
        command -v xray
        return 0
    fi
    if [[ -x "${XRAY_BIN_PATH:-/usr/local/bin/xray}" ]]; then
        printf '%s\n' "${XRAY_BIN_PATH:-/usr/local/bin/xray}"
        return 0
    fi
    return 1
}

# =============================================================================
# 子函数名称: _warp_key_probe
# 功能描述: 用最小 wireguard 出站配置实测本机 xray 能否解析这对密钥。
#           密钥的 base64 编码变体 (标准带 padding / raw 去 padding / url-safe) 各家
#           实现不一, Xray 内部认哪一种不写死 —— 拿本机二进制试, 能解析的才用,
#           否则会把"编码不对"的密钥写进配置, 直到 xray 加载时才炸。
# 参数: $1 客户端私钥 $2 peer 公钥 $3 xray 路径 $4 临时文件路径
# 返回值: 0-被接受; 非 0-被拒绝
# =============================================================================
function _warp_key_probe() {
    local priv="${1:-}" pub="${2:-}" bin="${3:-}" tmp_file="${4:-}"
    if [[ -z "${priv}" || -z "${pub}" || -z "${bin}" || -z "${tmp_file}" ]]; then
        return 1
    fi
    jq -nc --arg sk "${priv}" --arg pk "${pub}" '{
        log: {loglevel: "none"},
        outbounds: [{
            tag: "warp-key-probe", protocol: "wireguard",
            settings: {
                secretKey: $sk,
                address: ["172.16.0.2/32"],
                peers: [{publicKey: $pk, endpoint: "162.159.192.1:2408", allowedIPs: ["0.0.0.0/0"]}]
            }
        }]
    }' >"${tmp_file}" 2>/dev/null || return 1
    "${bin}" run -test -config "${tmp_file}" >/dev/null 2>&1
}

# =============================================================================
# 子函数名称: _warp_gen_keypair
# 功能描述: 生成一对 WireGuard 可用的 Curve25519 密钥。
#           优先用 xray 自带的 `wg` 子命令 —— 它产出的编码必然能被 xray 自己解析, 无需
#           试错; 老版本 xray 没有该子命令时退回 openssl (X25519 与 WireGuard 是同一套
#           曲线运算, 密钥可直接互换), 此时用 _warp_key_probe 逐个试编码变体。
# 参数: 无
# 返回值: 0-stdout 输出 "私钥 公钥" (空格分隔); 1-失败 (原因打 stderr)
# =============================================================================
function _warp_gen_keypair() {
    local bin=''
    bin="$(_xray_bin_path)" || {
        print_warn "$(_i18n '.handler.warp.no_xray')"
        return 1
    }
    local out='' priv='' pub=''
    # 路径一: xray wg (自产自销, 编码天然兼容)
    if out="$("${bin}" wg 2>/dev/null)"; then
        priv="$(printf '%s\n' "${out}" | sed -ne '1s/.*:[[:space:]]*//p')"
        pub="$(printf '%s\n' "${out}" | sed -ne '2s/.*:[[:space:]]*//p')"
        if [[ -n "${priv}" && -n "${pub}" ]]; then
            printf '%s %s\n' "${priv}" "${pub}"
            return 0
        fi
    fi
    # 路径二: openssl X25519
    local tmp_dir=''
    tmp_dir="${TMPFILE_DIR:-}"
    [[ -z "${tmp_dir}" ]] && tmp_dir="${SCRIPT_CONFIG_DIR:-}"
    if [[ ! -d "${tmp_dir}" || ! -w "${tmp_dir}" ]]; then
        tmp_dir="${TMPDIR:-/tmp}"
    fi
    local key_pem='' tmp_file=''
    # .json 后缀是必需的: xray 26.x 靠扩展名判断配置格式 (见 _xray_config_probe 的说明)
    key_pem="$(mktemp "${tmp_dir%/}/.${SCRIPT_NAME}-warpkey.XXXXXXXX")" || return 1
    tmp_file="$(mktemp "${tmp_dir%/}/.${SCRIPT_NAME}-warpprobe.XXXXXXXX.json")" || {
        rm -f "${key_pem}"
        return 1
    }
    local openssl_err=''
    if ! openssl_err="$(openssl genpkey -algorithm X25519 -out "${key_pem}" 2>&1)"; then
        rm -f "${key_pem}" "${tmp_file}"
        print_warn "$(_i18n '.handler.warp.key_failed')"
        printf '%s\n' "${openssl_err}" >&2
        return 1
    fi
    # PKCS#8 (私钥) 与 SPKI (公钥) 的 DER 编码尾部 32 字节即裸密钥
    local priv_std='' pub_std=''
    priv_std="$(openssl pkey -in "${key_pem}" -outform DER 2>/dev/null | tail -c 32 | base64 -w0 || true)"
    pub_std="$(openssl pkey -in "${key_pem}" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 -w0 || true)"
    rm -f "${key_pem}"
    if [[ -z "${priv_std}" || -z "${pub_std}" ]]; then
        rm -f "${tmp_file}"
        print_warn "$(_i18n '.handler.warp.key_failed')"
        return 1
    fi
    # 逐个编码变体试跑, 取第一个被本机 xray 接受的
    local variant='' last_err=''
    for variant in 'std' 'raw' 'urlsafe'; do
        case "${variant}" in
            std)
                priv="${priv_std}"
                pub="${pub_std}"
                ;;
            raw)
                priv="${priv_std%=*}"
                pub="${pub_std%=*}"
                ;;
            urlsafe)
                priv="$(printf '%s' "${priv_std}" | tr '+/' '-_' | tr -d '=')"
                pub="$(printf '%s' "${pub_std}" | tr '+/' '-_' | tr -d '=')"
                ;;
        esac
        if _warp_key_probe "${priv}" "${pub}" "${bin}" "${tmp_file}"; then
            rm -f "${tmp_file}"
            printf '%s %s\n' "${priv}" "${pub}"
            return 0
        fi
        last_err="${variant}"
    done
    rm -f "${tmp_file}"
    # 三种编码都不被接受 —— 多半是 xray 过老 (无 wireguard 出站) 而非编码问题
    print_warn "$(_i18n '.handler.warp.key_failed')"
    printf '%s\n' "$(_i18n '.handler.warp.key_probe_failed') (${last_err})" >&2
    return 1
}

# =============================================================================
# 子函数名称: _warp_reserved_from_client_id
# 功能描述: 由 WARP 账号的 client_id 解出 WireGuard 协议要求的 3 字节 reserved。
#           官方客户端把它填进握手包首部, 部分 WARP 端点据此校验; 拿不到就退回 0 0 0。
# 参数: $1 client_id (base64)
# 返回值: 恒 0, stdout 输出 "b1 b2 b3" (十进制, 空格分隔)
# =============================================================================
function _warp_reserved_from_client_id() {
    local cid="${1:-}"
    if [[ -z "${cid}" ]]; then
        printf '0 0 0'
        return 0
    fi
    # 补 padding: base64 解码要求长度为 4 的倍数
    case $((${#cid} % 4)) in
        2) cid="${cid}==" ;;
        3) cid="${cid}=" ;;
    esac
    local nums=''
    nums="$(printf '%s' "${cid}" | tr '_-' '/+' | base64 -d 2>/dev/null | od -An -tu1 | tr -s ' \n' ' ' || true)"
    nums="${nums# }"
    nums="${nums% }"
    local count=0
    count="$(printf '%s\n' "${nums}" | wc -w)"
    if [[ "${count}" -ge 3 ]]; then
        printf '%s' "${nums}" | cut -d' ' -f1-3
    else
        printf '0 0 0'
    fi
}

# =============================================================================
# 子函数名称: _warp_register
# 功能描述: 向 Cloudflare WARP 注册端点注册一个设备, 取回接口地址与 peer 信息。
#           设备私钥由本机生成 (服务端只登记公钥), 私钥不经过网络。
#           curl 禁用 -f: 要拿到 HTTP 状态码本身来区分"网络不通"与"被端点拒绝"。
# 参数: $1 客户端公钥 (base64) $2 客户端私钥 (base64)
# 返回值: 0-stdout 输出凭据 JSON; 1-失败 (原因已 print_warn, 调用方保持配置不动)
# =============================================================================
function _warp_register() {
    local pub="${1:-}" priv="${2:-}"
    if [[ -z "${pub}" || -z "${priv}" ]]; then
        return 1
    fi
    if ! cmd_exists 'curl'; then
        print_warn "$(_i18n '.handler.warp.no_curl')"
        return 1
    fi
    local tos='' payload=''
    tos="$(date -u +'%Y-%m-%dT%H:%M:%S.000Z')"
    payload="$(jq -nc --arg key "${pub}" --arg tos "${tos}" \
        '{key: $key, install_id: "", fcm_token: "", tos: $tos, model: "PC", serial_number: "", locale: "en_US"}')" || return 1
    # -w 把状态码追加到末行, 便于区分"网络不通"与"被端点拒绝(如 500)"
    local raw='' code='' resp=''
    raw="$(curl -sS --max-time 30 -X POST \
        -H "User-Agent: ${WARP_API_USER_AGENT}" \
        -H "CF-Client-Version: ${WARP_API_CLIENT_VERSION}" \
        -H 'Content-Type: application/json; charset=UTF-8' \
        --data "${payload}" -w '\n%{http_code}' "${WARP_API_URL}" 2>/dev/null || true)"
    code="${raw##*$'\n'}"
    resp="${raw%$'\n'*}"
    if [[ "${code}" != '200' ]]; then
        print_warn "$(_i18n_sub '.handler.warp.register_failed' '{code}' "${code:-unknown}")"
        return 1
    fi
    local v4='' v6='' peer_pub='' endpoint='' client_id=''
    v4="$(printf '%s' "${resp}" | jq -r '.config.interface.addresses.v4 // empty' 2>/dev/null || true)"
    v6="$(printf '%s' "${resp}" | jq -r '.config.interface.addresses.v6 // empty' 2>/dev/null || true)"
    peer_pub="$(printf '%s' "${resp}" | jq -r '.config.peers[0].public_key // empty' 2>/dev/null || true)"
    endpoint="$(printf '%s' "${resp}" | jq -r '.config.peers[0].endpoint.host // .config.peers[0].endpoint.v4 // empty' 2>/dev/null || true)"
    client_id="$(printf '%s' "${resp}" | jq -r '.config.client_id // empty' 2>/dev/null || true)"
    if [[ -z "${v4}" || -z "${peer_pub}" ]]; then
        print_warn "$(_i18n '.handler.warp.register_parse_failed')"
        return 1
    fi
    [[ -n "${endpoint}" ]] || endpoint="${WARP_ENDPOINT_FALLBACK}"
    local reserved=''
    reserved="$(_warp_reserved_from_client_id "${client_id}")"
    jq -nc --arg priv "${priv}" --arg pub "${pub}" --arg v4 "${v4}" --arg v6 "${v6}" \
        --arg peer "${peer_pub}" --arg endpoint "${endpoint}" --arg reserved "${reserved}" '{
        private_key: $priv,
        public_key: $pub,
        address: (["\($v4)/32"] + (if $v6 == "" then [] else ["\($v6)/128"] end)),
        peer_public_key: $peer,
        endpoint: $endpoint,
        reserved: ($reserved | split(" ") | map(tonumber))
    }'
}

# =============================================================================
# 子函数名称: _warp_ensure_credentials
# 功能描述: 取一份可用的 WARP WireGuard 凭据: 先复用已落盘文件 (零联网), 没有再注册,
#           新凭据当场落盘 (600) 供后续复用。
# 参数: 无
# 返回值: 0-stdout 输出凭据 JSON; 1-失败 (原因已 print_warn, 调用方保持配置不动)
# =============================================================================
function _warp_ensure_credentials() {
    if [[ -r "${WARP_CREDENTIALS_PATH}" ]]; then
        local existing=''
        existing="$(jq -c '.' "${WARP_CREDENTIALS_PATH}" 2>/dev/null || true)"
        # 字段齐全才复用: 半截凭据会让出站构造静默生成空值, 直到 xray 加载才炸
        if [[ -n "${existing}" ]] && printf '%s' "${existing}" | jq -e \
            'has("private_key") and has("peer_public_key") and ((.address // []) | length > 0)' >/dev/null 2>&1; then
            printf '%s' "${existing}"
            return 0
        fi
    fi
    local pair='' priv='' pub='' creds=''
    pair="$(_warp_gen_keypair)" || return 1
    priv="${pair%% *}"
    pub="${pair##* }"
    creds="$(_warp_register "${pub}" "${priv}")" || return 1
    printf '%s\n' "${creds}" | _atomic_write "${WARP_CREDENTIALS_PATH}" || return 1
    printf '%s' "${creds}"
}

# =============================================================================
# 子函数名称: _warp_forget_credentials
# 功能描述: 丢弃已落盘的 WARP 凭据 (重置出口时用, 下次会重新注册一台设备)。
# 参数: 无
# 返回值: 恒 0
# =============================================================================
function _warp_forget_credentials() {
    rm -f "${WARP_CREDENTIALS_PATH}"
}

# =============================================================================
# 子函数名称: _warp_outbound_json
# 功能描述: 由凭据 JSON 生成 Xray 的 wireguard 出站 (tag 固定 warp, 与分流规则对应)。
#           这里 allowedIPs 全量放行 —— 走不走 WARP 由路由规则决定, 出站不重复设限。
# 参数: $1 凭据 JSON
# 返回值: 0-stdout 输出出站 JSON; 1-凭据不合法
# =============================================================================
function _warp_outbound_json() {
    local creds="${1:-}"
    # 出站 tag 由调用方按"是否启用健康探测"决定 (见 _warp_outbound_tag); 默认仍是 warp ——
    # 不开探测时, 规则里的 outboundTag=warp 必须能直接落到这个出站上。
    local tag="${2:-warp}"
    [[ -n "${creds}" ]] || return 1
    printf '%s' "${creds}" | jq -c --argjson mtu "${WARP_MTU}" --arg tag "${tag}" '{
        tag: $tag,
        protocol: "wireguard",
        settings: {
            secretKey: .private_key,
            address: .address,
            peers: [{
                publicKey: .peer_public_key,
                endpoint: .endpoint,
                allowedIPs: ["0.0.0.0/0", "::/0"],
                keepAlive: 25
            }],
            reserved: .reserved,
            mtu: $mtu
        }
    }' 2>/dev/null
}

# =============================================================================
# 子函数名称: _xray_apply_warp
# 功能描述: 启用 WARP 时追加 wireguard 出站到全局 XRAY_CONFIG (先 del 再 +=, 幂等)。
# 参数: 无 (读父函数 local 的 WARP_STATUS, 改写全局 XRAY_CONFIG)
# 返回值: 0-成功 (含"未启用"的零操作); 1-取凭据/构造出站失败
# 注意: 失败必须让调用方中止 —— 路由规则里引用了 warp 出站, 出站没写进去会让 xray
#       拒绝加载整份配置, 比"这次配置更新失败"严重得多。
# =============================================================================
function _xray_apply_warp() {
    is_enabled "${WARP_STATUS}" || return 0
    local creds='' outbound='' tag=''
    creds="$(_warp_ensure_credentials)" || return 1
    _warp_outbound_tag     # 实测决定出站 tag (开探测时交给同名 balancer 接管)
    tag="${_WARP_OB_TAG}"
    outbound="$(_warp_outbound_json "${creds}" "${tag}")" || return 1
    [[ -n "${outbound}" ]] || return 1
    # del 两个候选 tag: 形态切换 (探测由可用变不可用, 或反之) 时旧出站要能被清掉, 否则
    # 会留下一个指向失效凭据/失效 tag 的僵尸出站。
    XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson ob "${outbound}" \
        --arg ot "${WARP_OUTBOUND_TAG}" '
        del(.outbounds[] | select(.tag == "warp" or .tag == $ot)) | .outbounds += [$ob]')"
}

# =============================================================================
# 子函数名称: _xray_config_probe
# 功能描述: 把候选配置片段套进最小骨架, 实测本机 xray 能否接受。
#           新增顶层段 (observatory / dns) 属于"低版本不认识就拒绝整份配置"的字段 ——
#           按版本号猜并不可靠 (mKCP finalmask 的教训: 两种写法互不兼容, 写错一边整份
#           被拒), 所以一律先拿本机二进制试, 能解析才写进正式配置。
# 参数: $1 片段 JSON (对象; 浅合并进骨架)
# 返回值: 0-被接受; 1-被拒绝 / 无 xray / 建不了临时文件
# =============================================================================
function _xray_config_probe() {
    # 每次调用先清空上一次的报错: 降级提示只该打"导致这次降级"的原因, 不是历史残留
    _XRAY_PROBE_ERR=''
    local fragment="${1:-}"
    [[ -n "${fragment}" ]] || return 1
    local bin='' tmp_dir='' tmp_file=''
    bin="$(_xray_bin_path)" || {
        _XRAY_PROBE_ERR='xray binary not found on this host'
        return 1
    }
    tmp_dir="${TMPFILE_DIR:-}"
    [[ -z "${tmp_dir}" ]] && tmp_dir="${SCRIPT_CONFIG_DIR:-}"
    if [[ ! -d "${tmp_dir}" || ! -w "${tmp_dir}" ]]; then
        tmp_dir="${TMPDIR:-/tmp}"
    fi
    # .json 后缀是必需的: xray 26.x 按扩展名判断配置格式, 无后缀一律
    # "Failed to get format of <path>" (exit 23) 拒载整份配置 —— 那会把"探测链路坏了"
    # 伪装成"本机不支持该写法", 让降级链一路走到底。此处曾长期漏后缀, 使本机 26.3.27
    # 明明支持的 observatory / 顶层 dns 段被静默跳过 (2026-09-24 用同版本二进制实测定位)。
    tmp_file="$(mktemp "${tmp_dir%/}/.${SCRIPT_NAME}-xrayprobe.XXXXXXXX.json")" || {
        _XRAY_PROBE_ERR="mktemp failed in ${tmp_dir}"
        return 1
    }
    # 骨架里放 direct / warp / warp-out / block 四个占位出站: balancer 的 selector 与
    # fallbackTag 都要能解析到对应 tag, 否则会被误判成"引用了不存在的出站"而谎报不支持。
    if ! jq -nc --argjson frag "${fragment}" '
        {
            log: {loglevel: "none"},
            outbounds: [
                {tag: "direct", protocol: "freedom"},
                {tag: "warp", protocol: "freedom"},
                {tag: "warp-out", protocol: "freedom"},
                {tag: "block", protocol: "blackhole"}
            ]
        } + $frag' >"${tmp_file}" 2>/dev/null; then
        _XRAY_PROBE_ERR='jq failed to build the probe skeleton'
        rm -f "${tmp_file}"
        return 1
    fi
    # 用 if 接住而不是 `out="$(...)"` 裸赋值: set -e 下赋值语句会继承命令替换的退出码,
    # 非 0 会当场杀掉整个交互脚本 (自愈路径踩过同一个坑)。
    local rc=0
    if out="$("${bin}" run -test -config "${tmp_file}" 2>&1)"; then
        rc=0
    else
        rc=1
        _XRAY_PROBE_ERR="${out}"
    fi
    rm -f "${tmp_file}"
    return "${rc}"
}

# =============================================================================
# 子函数名称: _xray_probe_error_hint
# 功能描述: 把上一次 _xray_config_probe 被拒时 xray 的原始报错转到 stderr。降级链走到
#           底时调用 —— 只要报错是 "Failed to get format" 之类, 一眼就能看出是探测环境
#           问题而不是"本机不支持", 不必再去猜根因。
#           **只能写 stderr**: 调用方 (--share / --export-config) 会消费 stdout。
# 参数: 无 (读全局 _XRAY_PROBE_ERR)
# 返回值: 恒 0
# =============================================================================
function _xray_probe_error_hint() {
    [[ -n "${_XRAY_PROBE_ERR}" ]] || return 0
    print_warn "$(_i18n '.handler.xray.probe_error')"
    printf '%s\n' "${_XRAY_PROBE_ERR}" >&2
    return 0
}

# 上一次探测被拒时 xray 的原始报错 (供 _xray_probe_error_hint 转 stderr)
_XRAY_PROBE_ERR=''
# 观测/均衡支持性缓存: '' 未探测 / full 支持 / plain 不支持 (降级为纯出站)
_XRAY_OBS_MODE=''
# sniffing.routeOnly 支持性缓存: '' 未探测 / on 支持 / off 不支持 (降级为不写该字段)
_XRAY_SNIFF_MODE=''
# 当前出站 tag (由 _warp_outbound_tag 填充, 与探测结果同步)
_WARP_OB_TAG=''

# =============================================================================
# 子函数名称: _xray_observatory_mode
# 功能描述: 实测本机 xray 是否接受 observatory + routing.balancers, 结果缓存到
#           _XRAY_OBS_MODE (进程内只测一次)。不支持时打印一次告警并降级为纯出站 ——
#           出站本身照常可用, 只是少了"WARP 挂了自动走直连"。
# 参数: 无
# 返回值: 恒 0 (结果读 _XRAY_OBS_MODE)
# =============================================================================
function _xray_observatory_mode() {
    if [[ -z "${_XRAY_OBS_MODE}" ]]; then
        local frag=''
        frag="$(jq -nc --arg bt "${WARP_BALANCER_TAG}" --arg url "${WARP_PROBE_URL}" \
            --arg iv "${WARP_PROBE_INTERVAL}" --arg sel "${WARP_OUTBOUND_TAG}" '{
            observatory: {
                subjectSelector: [$sel], probeUrl: $url, probeInterval: $iv,
                enableConcurrency: true
            },
            routing: {
                balancers: [{
                    tag: $bt, selector: [$sel], fallbackTag: "direct",
                    strategy: {type: "leastPing"}
                }]
            }
        }')"
        if _xray_config_probe "${frag}"; then
            _XRAY_OBS_MODE='full'
        else
            _XRAY_OBS_MODE='plain'
            print_warn "$(_i18n '.handler.warp.no_observatory')"
            _xray_probe_error_hint
        fi
    fi
    return 0
}

# =============================================================================
# 子函数名称: _warp_outbound_tag
# 功能描述: 决定 wireguard 出站用哪个 tag。开探测时用 WARP_OUTBOUND_TAG (warp-out),
#           并配套把规则改写成走 balancer (见 _warp_rules_use_balancer); 降级时用
#           warp, 规则直接落到出站。
# 参数: 无
# 返回值: 恒 0 (结果读 _WARP_OB_TAG)
# =============================================================================
function _warp_outbound_tag() {
    if [[ -z "${_WARP_OB_TAG}" ]]; then
        _xray_observatory_mode
        if [[ "${_XRAY_OBS_MODE}" == 'full' ]]; then
            _WARP_OB_TAG="${WARP_OUTBOUND_TAG}"
        else
            _WARP_OB_TAG='warp'
        fi
    fi
    return 0
}

# =============================================================================
# 子函数名称: _warp_rules_use_balancer
# 功能描述: 把指向 WARP 出站的规则改写成走 balancer: outboundTag 换成 balancerTag。
#           实测 (Xray 26.3.27) 规则里的 outboundTag 只在 outbounds 里查 tag, 解析
#           不到就 fail-closed 阻断整条分流 —— 开探测后出站已改名 warp-out, 所以
#           必须显式改字段, 否则"分流静默失效且无日志"。详见 WARP_OUTBOUND_TAG 处注释。
#           只动 outboundTag=="warp" 的规则; 两个键**不同时保留** —— 同存时的优先级
#           未经实测, 留单键才能保证行为确定。
# 参数: 无 (改写全局 XRAY_CONFIG)
# 返回值: 恒 0
# =============================================================================
function _warp_rules_use_balancer() {
    XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg bt "${WARP_BALANCER_TAG}" '
        if (.routing.rules | type) == "array" then
            .routing.rules |= map(
                if .outboundTag == "warp"
                then del(.outboundTag) + {balancerTag: $bt}
                else . end)
        else . end')"
}

# =============================================================================
# 子函数名称: _warp_rules_use_outbound
# 功能描述: _warp_rules_use_balancer 的逆操作 —— 把 balancerTag 还原回
#           outboundTag="warp"。降级形态 (出站 tag=warp) 与未启用 WARP 时**必须**
#           还原: 否则上一轮 full 形态留下的 balancerTag 会指向一个已不存在的
#           balancer, fail-closed 断流。
# 参数: 无 (改写全局 XRAY_CONFIG)
# 返回值: 恒 0
# =============================================================================
function _warp_rules_use_outbound() {
    XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg bt "${WARP_BALANCER_TAG}" '
        if (.routing.rules | type) == "array" then
            .routing.rules |= map(
                if .balancerTag == $bt
                then del(.balancerTag) + {outboundTag: "warp"}
                else . end)
        else . end')"
}

# =============================================================================
# 子函数名称: _xray_apply_warp_balancer
# 功能描述: 给 WARP 出站加健康探测与自动回落。
#           启用: 写 observatory (周期探测 warp-out) + routing.balancers
#                 (tag=warp-balancer, selector=[warp-out], fallbackTag=direct,
#                  strategy=leastPing), 并把规则改成走 balancerTag —— 实测
#                 outboundTag 不会落 balancer, 不改字段则分流 fail-closed。
#           **规则字段的改写/还原都由本函数单点负责**: handler_xray_config 的注入链
#           与 handler_warp / handler_reset_warp 三条路径都经过这里, 所以不必改
#           add_rule, 存量规则也会在下次生成配置时自动迁移。
#           降级 (xray 不支持 observatory): 不写观测/均衡段, 但**把规则还原成
#                 outboundTag** —— 否则上一轮 full 形态留下的 balancerTag 会指向一个
#                 本轮不会写的 balancer, fail-closed 断流。
#           未启用: 只幂等清掉观测/均衡段, **不碰规则** —— "清掉指向 WARP 的分流规则"
#                 归 handler_warp 关闭分支 (它还要同步 SCRIPT_CONFIG.rules 权威副本)。
# 参数: 无 (读父函数 local 的 WARP_STATUS, 改写全局 XRAY_CONFIG)
# 返回值: 0-成功 (含降级与未启用的零操作)
# =============================================================================
function _xray_apply_warp_balancer() {
    if ! is_enabled "${WARP_STATUS}"; then
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg bt "${WARP_BALANCER_TAG}" '
            del(.observatory) | del(.burstObservatory)
            | if (.routing.balancers | type) == "array" then
                .routing.balancers |= map(select(.tag != $bt))
              else . end
            | if (.routing.balancers | type) == "array" and (.routing.balancers | length) == 0 then
                del(.routing.balancers)
              else . end')"
        # 注: 此处**不**碰规则 —— "清掉指向 WARP 的分流规则"是 handler_warp 关闭分支的
        # 职责 (它还要同步 SCRIPT_CONFIG.rules 权威副本, 只清一处反而更糟)。本函数只管
        # 观测/均衡段。
        return 0
    fi
    _warp_outbound_tag
    if [[ "${_WARP_OB_TAG}" != "${WARP_OUTBOUND_TAG}" ]]; then
        # 降级形态 (出站 tag=warp): 不能写 balancer —— 它的 selector 会解析不到 warp-out,
        # 反而让配置加载失败。但必须把上一轮 full 形态留下的 balancerTag 还原回去。
        _warp_rules_use_outbound
        return 0
    fi
    _warp_rules_use_balancer
    local obs='' bal=''
    obs="$(jq -nc --arg url "${WARP_PROBE_URL}" --arg iv "${WARP_PROBE_INTERVAL}" \
        --arg sel "${WARP_OUTBOUND_TAG}" '
        {subjectSelector: [$sel], probeUrl: $url, probeInterval: $iv, enableConcurrency: true}')"
    bal="$(jq -nc --arg bt "${WARP_BALANCER_TAG}" --arg sel "${WARP_OUTBOUND_TAG}" '
        [{tag: $bt, selector: [$sel], fallbackTag: "direct", strategy: {type: "leastPing"}}]')"
    XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson obs "${obs}" --argjson bal "${bal}" '
        .observatory = $obs
        | .routing = ((.routing // {}) | .balancers = $bal)')"
}

# 顶层 DNS 支持性缓存: '' 未探测 / full 全字段 / minimal 仅 servers / off 不加
_XRAY_DNS_MODE=''

# =============================================================================
# 子函数名称: _xray_dns_mode
# 功能描述: 实测本机 xray 能接受哪一档 dns 段 (全字段 -> 仅 servers -> 不加), 结果缓存
#           到 _XRAY_DNS_MODE (进程内只测一次)。queryStrategy / enableParallelQuery 是较新
#           版本才有的字段, 老版本遇到会拒绝整份配置, 所以逐档降级而不是按版本号猜。
# 参数: 无
# 返回值: 恒 0 (结果读 _XRAY_DNS_MODE)
# =============================================================================
function _xray_dns_mode() {
    if [[ -z "${_XRAY_DNS_MODE}" ]]; then
        local frag_full='' frag_min=''
        frag_full="$(jq -nc --argjson servers "${XRAY_DNS_SERVERS}" \
            --arg qs "${XRAY_DNS_QUERY_STRATEGY}" \
            '{dns: {servers: $servers, queryStrategy: $qs, enableParallelQuery: true}}')"
        frag_min="$(jq -nc --argjson servers "${XRAY_DNS_SERVERS}" '{dns: {servers: $servers}}')"
        if _xray_config_probe "${frag_full}"; then
            _XRAY_DNS_MODE='full'
        elif _xray_config_probe "${frag_min}"; then
            _XRAY_DNS_MODE='minimal'
        else
            _XRAY_DNS_MODE='off'
            print_warn "$(_i18n '.handler.dns.unsupported')"
            _xray_probe_error_hint
        fi
    fi
    return 0
}

# =============================================================================
# 子函数名称: _xray_apply_dns
# 功能描述: 写入顶层 dns 段 (显式解析器), 让 Xray 内部的域名解析不再依赖系统 resolver。
# 参数: 无 (改写全局 XRAY_CONFIG)
# 返回值: 恒 0
# =============================================================================
function _xray_apply_dns() {
    _xray_dns_mode
    local dns_json=''
    case "${_XRAY_DNS_MODE}" in
    full)
        dns_json="$(jq -nc --argjson servers "${XRAY_DNS_SERVERS}" \
            --arg qs "${XRAY_DNS_QUERY_STRATEGY}" \
            '{servers: $servers, queryStrategy: $qs, enableParallelQuery: true}')"
        ;;
    minimal)
        dns_json="$(jq -nc --argjson servers "${XRAY_DNS_SERVERS}" '{servers: $servers}')"
        ;;
    *)
        return 0
        ;;
    esac
    XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson dns "${dns_json}" '.dns = $dns')"
}

# =============================================================================
# 子函数名称: _xray_apply_domain_strategy
# 功能描述: 规则集里存在 IP 类条件 (geoip:cn / private-ip / 自定义 IP) 时, 把
#           routing.domainStrategy 从默认的 AsIs 切成 IPIfNonMatch。
#           原因: AsIs 下 IP 规则只对"客户端直接发 IP"的连接生效, 客户端发域名时规则
#           形同虚设 (开关开了却不生效)。IPIfNonMatch 是"其余规则都没命中, 再把域名解析
#           成 IP 重匹配一次", 代价是一次带缓存的解析。
#           没有 IP 规则时保持 AsIs 并清掉残留, 不给纯域名分流场景增加解析开销。
# 参数: 无 (改写全局 XRAY_CONFIG)
# 返回值: 恒 0
# =============================================================================
function _xray_apply_domain_strategy() {
    local has_ip_rule=''
    has_ip_rule="$(echo "${XRAY_CONFIG}" | jq -r '
        [(.routing.rules // [])[] | select(((.ip // []) | length) > 0)] | length > 0')"
    if [[ "${has_ip_rule}" == 'true' ]]; then
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq '.routing.domainStrategy = "IPIfNonMatch"')"
    else
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq 'del(.routing.domainStrategy)')"
    fi
}

# 出站 sockopt 支持性缓存: '' 未探测 / full 全套 / minimal 仅 tcpUserTimeout / off 不加
_XRAY_SOCKOPT_MODE=''

# =============================================================================
# 子函数名称: _xray_sockopt_mode
# 功能描述: 实测本机 xray 接受哪一档出站 sockopt (全套 -> 仅 tcpUserTimeout -> 不加),
#           结果缓存到 _XRAY_SOCKOPT_MODE (进程内只测一次)。
#           sockopt 里的 keep-alive / 用户超时字段属于"低版本不认识就拒绝整份配置"的
#           类型, 按版本号猜并不可靠 (mKCP finalmask 的教训) —— 一律先拿本机二进制试,
#           能解析才写进正式配置。
# 参数: 无
# 返回值: 恒 0 (结果读 _XRAY_SOCKOPT_MODE)
# =============================================================================
function _xray_sockopt_mode() {
    if [[ -z "${_XRAY_SOCKOPT_MODE}" ]]; then
        local frag_full='' frag_min=''
        # 探测片段自带 outbounds: _xray_config_probe 的骨架是浅合并, 同名键被整体替换 ——
        # 这里不需要 warp/block 占位出站 (片段里不含 balancer, 没有 selector 要解析)。
        frag_full="$(jq -nc --argjson ut "${XRAY_SOCKOPT_USER_TIMEOUT}" \
            --argjson ki "${XRAY_SOCKOPT_KEEPALIVE_IDLE}" \
            --argjson kp "${XRAY_SOCKOPT_KEEPALIVE_INTERVAL}" '{
            outbounds: [{
                tag: "direct", protocol: "freedom",
                sockopt: {
                    tcpFastOpen: true, tcpUserTimeout: $ut,
                    tcpKeepAliveIdle: $ki, tcpKeepAliveInterval: $kp
                }
            }]
        }')"
        frag_min="$(jq -nc --argjson ut "${XRAY_SOCKOPT_USER_TIMEOUT}" '{
            outbounds: [{
                tag: "direct", protocol: "freedom",
                sockopt: {tcpUserTimeout: $ut}
            }]
        }')"
        if _xray_config_probe "${frag_full}"; then
            _XRAY_SOCKOPT_MODE='full'
        elif _xray_config_probe "${frag_min}"; then
            _XRAY_SOCKOPT_MODE='minimal'
        else
            _XRAY_SOCKOPT_MODE='off'
            print_warn "$(_i18n '.handler.sockopt.unsupported')"
            _xray_probe_error_hint
        fi
    fi
    return 0
}

# =============================================================================
# 子函数名称: _xray_apply_sockopt
# 功能描述: 给所有 freedom 出站写入网络调优 sockopt。
#           合并而非覆盖 —— 模板里已存在的 tcpFastOpen 等字段必须保留 (否则等于回退)。
#           只改 protocol=="freedom" 的出站: blackhole / wireguard(WARP) 与它无关, 误改
#           后者会把 WARP 隧道的 socket 选项也拖下水。
# 参数: 无 (改写全局 XRAY_CONFIG)
# 返回值: 恒 0 (off 档为零操作)
# =============================================================================
function _xray_apply_sockopt() {
    _xray_sockopt_mode
    local so_json=''
    case "${_XRAY_SOCKOPT_MODE}" in
    full)
        so_json="$(jq -nc --argjson ut "${XRAY_SOCKOPT_USER_TIMEOUT}" \
            --argjson ki "${XRAY_SOCKOPT_KEEPALIVE_IDLE}" \
            --argjson kp "${XRAY_SOCKOPT_KEEPALIVE_INTERVAL}" \
            '{tcpFastOpen: true, tcpUserTimeout: $ut,
              tcpKeepAliveIdle: $ki, tcpKeepAliveInterval: $kp}')"
        ;;
    minimal)
        so_json="$(jq -nc --argjson ut "${XRAY_SOCKOPT_USER_TIMEOUT}" \
            '{tcpUserTimeout: $ut}')"
        ;;
    *)
        return 0
        ;;
    esac
    XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson so "${so_json}" '
        .outbounds |= map(
            if .protocol == "freedom"
            then .sockopt = ((.sockopt // {}) + $so)
            else . end
        )')"
}

# =============================================================================
# 子函数名称: _xray_sniff_mode
# 功能描述: 实测本机 xray 是否接受 sniffing.routeOnly, 结果缓存到 _XRAY_SNIFF_MODE
#           (进程内只测一次)。该字段是"嗅探域名仅用于路由"的载体, 属版本相关标识,
#           按本仓惯例不写死 —— 若上游改名/移除, 探测失败时宁可不写该字段 (保持出站
#           按域名直连的既有行为), 也不要把整份配置写坏。
# 参数: 无
# 返回值: 恒 0 (结果读 _XRAY_SNIFF_MODE: on 支持 / off 不支持)
# =============================================================================
function _xray_sniff_mode() {
    if [[ -z "${_XRAY_SNIFF_MODE}" ]]; then
        local frag=''
        # 最小片段: 一个 127.0.0.1 高位端口的 vless 入站, 只在 sniffing 段带 routeOnly。
        # 探测只关心该字段能否被解析 —— 配置越简单越不会被无关原因误判。
        frag="$(jq -nc --argjson port "${XRAY_SNIFF_PROBE_PORT}" '{
            inbounds: [{
                tag: "sniff-probe", listen: "127.0.0.1", port: $port, protocol: "vless",
                settings: {clients: [{id: "00000000-0000-0000-0000-000000000001"}], decryption: "none"},
                sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}
            }]
        }')"
        if _xray_config_probe "${frag}"; then
            _XRAY_SNIFF_MODE='on'
        else
            _XRAY_SNIFF_MODE='off'
            print_warn "$(_i18n '.handler.sniffing.unsupported')"
            _xray_probe_error_hint
        fi
    fi
    return 0
}

# =============================================================================
# 子函数名称: _xray_apply_sniffing
# 功能描述: 按 .xray.sniffRouteOnly 开关决定 sniffing 段的 routeOnly 字段。
#           - 关 (默认): **仅当配置里确实存在该字段时才删除**。默认路径零改写, 保证
#             "关" 时的产物与本功能引入前逐字节一致 (这是该开关的核心承诺)。
#           - 开: 先实测本机支持性, 支持则给所有已启用 sniffing 的入站加 routeOnly:true。
#           注: 官方文档写明 routeOnly "需要开启 destOverride 使用", 故作用域只圈
#           `sniffing.enabled == true` 的入站 —— 本仓所有模板的 sniffing 恒为
#           `{enabled:true, destOverride:[http,tls,quic]}` (由测试 T9n 锁住), 二者等价。
# 参数: 无 (读全局 XRAY_CONFIG / XRAY_SNIFF_ROUTE_ONLY)
# 返回值: 恒 0 (不支持时静默不写, 告警已由 _xray_sniff_mode 打印)
# =============================================================================
function _xray_apply_sniffing() {
    if ! is_enabled "${XRAY_SNIFF_ROUTE_ONLY:-0}"; then
        local has_residual=''
        has_residual="$(echo "${XRAY_CONFIG}" | jq -r '
            [.inbounds[]? | .sniffing? | select(.routeOnly != null)] | length > 0')"
        if [[ "${has_residual}" == 'true' ]]; then
            XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq '
                .inbounds |= map(
                    if .sniffing.enabled == true
                    then del(.sniffing.routeOnly)
                    else . end
                )')"
        fi
        return 0
    fi
    _xray_sniff_mode
    if [[ "${_XRAY_SNIFF_MODE}" != 'on' ]]; then
        return 0
    fi
    XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq '
        .inbounds |= map(
            if .sniffing.enabled == true
            then .sniffing.routeOnly = true
            else . end
        )')"
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
    # 脚本配置里存在历史重置标记 (.xray.rules.reset 为 0 或 1) 则重新读取规则输入
    #   (注意判定的是**存在该标记**, 取值是 0/1 而非字面 current/reset)
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
#   $1: web - Web 服务类型 (当前只有 normal; v3/v4 曾存在但已移除)
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
        # 注: jq 失败时 stdout 为空, `((  > 0 ))` 就退化成 bash 语法错误 (rc 1) 并在
        #     set -e 下直接带崩整个装配流程, 而真正的原因 (配置不是合法 JSON) 被彻底
        #     掩盖 —— 与 `jq --argjson` 收到空值是同一类坑。计数一律"取回 + 数字兜底"。
        #     另: `// []` 只兜 null/false, 挡不住 custom_sites 被写成字符串 (此时 length
        #     是字符数, 会拿垃圾去 sync), 故这里按 type 判定而非只看非空。
        local custom_sites_count
        custom_sites_count="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.custom_sites | if type == "array" then length else 0 end' || echo 0)"
        [[ "${custom_sites_count}" =~ ^[0-9]+$ ]] || custom_sites_count=0
        if ((custom_sites_count > 0)); then
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
    # 注: parse_proxy_target 失败时**输出为空** —— 直接 `<<<"$(...)"` 去读, read 只会读到
    #     一个空行并返回 0, 原先跟在后面的 `|| _error` 永远进不去 (是死代码)。后果比看起来
    #     严重: port 为空 -> jq --argjson port "" 报错 -> 变量被置空 -> 后续渲染用空目标,
    #     最终被误报成 "failed to render custom site config", 真正的原因 (代理目标格式非法)
    #     被完全掩盖。必须先判定 parse 本身的成败再读字段。
    local proxy_fields=''
    if ! proxy_fields="$(parse_proxy_target "${proxy_target}")"; then
        _error "failed to parse proxy target"
    fi
    IFS=$'\t' read -r scheme host port <<<"${proxy_fields}"

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

    _custom_site_read_inputs
    _custom_site_prepare

    if [[ "${new_domain}" == "${old_domain}" ]]; then
        _custom_site_apply_same
    else
        _custom_site_apply_change
    fi

    rm -f "${old_conf_backup}" "${stream_backup}"
    SCRIPT_CONFIG="${updated_script_config}"
    persist_script_config
    echo -e "${GREEN}[$(_i18n '.title.info')]${NC} $(_i18n ".${CUR_FILE}.custom_sites.updated")${new_domain}" >&2
}

# =============================================================================
# 函数名称: _custom_site_read_inputs
# 功能描述: 提取选中自定义站点的旧值, 交互读取新的域名/代理目标, 计算 updated_script_config。
# 参数: 无 (读写父函数 local: site_index / current_site / old_* / new_* / updated_script_config)
# 返回值: 无
# =============================================================================
function _custom_site_read_inputs() {
    current_site="$(get_custom_site_json_by_index "${site_index}")"
    old_domain="$(echo "${current_site}" | jq -r '.domain')"
    old_scheme="$(echo "${current_site}" | jq -r '.scheme')"
    old_host="$(echo "${current_site}" | jq -r '.host')"
    old_port="$(echo "${current_site}" | jq -r '.port')"
    old_proxy_target="${old_scheme}://${old_host}:${old_port}"

    new_domain="$(read_custom_site_domain_update "${old_domain}")"
    new_proxy_target="$(read_custom_site_proxy_target_update "${old_proxy_target}")"
    # 注: 同 handler_custom_site_add —— 必须先看 parse 的成败, 不能依赖 read 的返回值。
    local new_proxy_fields=''
    if ! new_proxy_fields="$(parse_proxy_target "${new_proxy_target}")"; then
        _error "failed to parse proxy target"
    fi
    IFS=$'\t' read -r new_scheme new_host new_port <<<"${new_proxy_fields}"

    updated_script_config="$(echo "${SCRIPT_CONFIG}" | jq \
        --argjson idx "$((site_index - 1))" \
        --arg domain "${new_domain}" \
        --arg scheme "${new_scheme}" \
        --arg host "${new_host}" \
        --argjson port "${new_port}" \
        '.nginx.custom_sites[$idx] = {"domain": $domain, "scheme": $scheme, "host": $host, "port": $port}')"
}

# =============================================================================
# 函数名称: _custom_site_prepare
# 功能描述: 计算新旧站点配置/软链路径, 并备份旧站点 conf 与 stream.conf。
# 参数: 无 (读写父函数 local: old_conf_path / new_conf_path / old_link_path / new_link_path / old_conf_backup)
# 返回值: 无
# =============================================================================
function _custom_site_prepare() {
    old_conf_path="${NGINX_CONFIG_DIR}/sites-available/${old_domain}.conf"
    new_conf_path="${NGINX_CONFIG_DIR}/sites-available/${new_domain}.conf"
    old_link_path="${NGINX_CONFIG_DIR}/sites-enabled/${old_domain}.conf"
    new_link_path="${NGINX_CONFIG_DIR}/sites-enabled/${new_domain}.conf"
    old_conf_backup="${SCRIPT_CONFIG_DIR}/${old_domain}.custom-site.bak.conf"
    # 与 share.sh:cache_json_data 同样的坑: 不用 `[[ 条件 ]] && 动作` —— 它一旦成为
    # 函数最后一条命令, 条件为假就会让函数返回 1, 调用处被 set -e + ERR trap 判成
    # "脚本内部错误"而中断。旧站 conf / stream.conf 不存在都属正常情况, 本就该静默跳过。
    if [[ -f "${old_conf_path}" ]]; then
        cp -f "${old_conf_path}" "${old_conf_backup}"
    fi
    if [[ -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" ]]; then
        cp -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" "${stream_backup}"
    fi
}

# =============================================================================
# 函数名称: _custom_site_apply_same
# 功能描述: 同域名仅更新 upstream (代理目标): 渲染 conf -> 建链 -> 重建 stream -> 重载 Nginx。
#           任一环节失败则从备份回滚并 _error。
# 参数: 无 (使用父函数 local: new_domain / old_domain / new_conf_path / new_link_path /
#           old_conf_backup / stream_backup / updated_script_config / old_proxy_target)
# 返回值: 无
# =============================================================================
function _custom_site_apply_same() {
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
}

# =============================================================================
# 函数名称: _custom_site_apply_change
# 功能描述: 换域名: 申请新证书 -> 渲染 conf -> 建链 -> 删旧 -> 重建 stream -> 重载 Nginx。
#           任一环节失败则从备份回滚、停止新域名续签并 _error。
# 参数: 无 (使用父函数 local: new_domain / old_domain / new_conf_path / new_link_path /
#           old_conf_path / old_link_path / old_conf_backup / stream_backup / updated_script_config)
# 返回值: 无
# =============================================================================
function _custom_site_apply_change() {
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
    # 兜底: 上面两条分支拿到的都必须是个数字 —— 否则下一行 jq 会甩出
    #       "invalid JSON text passed to --argjson" 并以非 0 退出, 而本文件跑在
    #       set -Eeuo pipefail 下, 赋值失败会 **直接终止整个人机交互脚本**, 用户看到的是
    #       "脚本在第 N 行意外失败", 和刚才"改个端口"的动作完全对不上。
    #       可达路径: mkcp 模式下用户直接回车 (交 generate.sh 现算), 而 generate.sh
    #       没能算出值 (其 generate_random 依赖 od 取随机, od 缺失/异常即输出空串)。
    #       此时回落到默认端口 —— 端口是可见的 (分享链接/体检报告都会显示), 不会误导。
    if [[ ! "${XRAY_PORT}" =~ ^[0-9]+$ ]]; then
        XRAY_PORT="443"
    fi

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
    # mKCP finalmask 类型 id 自适应自愈: 升级/重装 Xray 后, 已落盘 config 若因 id 改名而失效则自动重写
    heal_mkcp_finalmask || true
}

# =============================================================================
# 函数名称: _bbr_persist_files
# 功能描述: 原子写入 BBR 的两份持久化文件 —— modules-load.d 的模块自加载 +
#           sysctl.d 的内核参数。内容固定 (tcp_bbr/sch_fq 与 bbr/fq), 幂等。
#
#           抽出来的动机: handler_bbr 有两条路径都会落盘 —— "从零启用"与
#           "已生效但未持久化"(云镜像/面板可能只在内存里设过 BBR)。落盘逻辑
#           必须同源, 否则口径一漂移就会出现"体检说缺失、安装说无需操作"。
# 参数: $1 modules-load.d 文件路径  $2 sysctl.d 文件路径
# 返回值: 0-两份均写入成功 1-目录创建或任一写入失败
# =============================================================================
function _bbr_persist_files() {
    local modules_load_file="${1:-}"
    local sysctl_conf_file="${2:-}"
    [[ -n "${modules_load_file}" && -n "${sysctl_conf_file}" ]] || return 1
    mkdir -p /etc/modules-load.d /etc/sysctl.d || return 1
    if ! printf 'tcp_bbr\nsch_fq\n' | _atomic_write "${modules_load_file}"; then
        return 1
    fi
    if ! printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' | _atomic_write "${sysctl_conf_file}"; then
        return 1
    fi
    return 0
}

# =============================================================================
# 函数名称: handler_bbr
# 功能描述: 检测并按需启用内核 BBR 拥塞控制 (幂等)。
#           1. 先读 net.ipv4.tcp_congestion_control 与 net.core.default_qdisc;
#              两项已是 bbr/fq **且** 两份持久化文件齐全时直接返回, 不产生任何写操作。
#              若已生效但持久化文件缺失 (云镜像/面板常只在内存里设过 BBR), 则只补齐
#              这两份文件, 不做模块加载 —— 已生效本身说明模块/内建必然可用。
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

    # 已生效: 内核参数已是 bbr/fq。但"生效"不等于"持久" —— 云镜像/面板可能只在
    # 内存里设过 (sysctl -w), 重启即静默失效。故仍要确认两份持久化文件在不在。
    if [[ "${current_cc}" == 'bbr' && "${current_qdisc}" == 'fq' ]]; then
        echo -e "${GREEN}[$(_i18n '.title.tip')] ${NC}$(_i18n ".${CUR_FILE}.bbr.already")" >&2
        echo -e "  net.ipv4.tcp_congestion_control = ${current_cc}" >&2
        echo -e "  net.core.default_qdisc          = ${current_qdisc}" >&2
        # 两份齐全 -> 真的无需操作 (零写盘)
        if [[ -e "${modules_load_file}" && -e "${sysctl_conf_file}" ]]; then
            return 0
        fi
        # 缺则补齐: 内容即当前生效值, 幂等无害; 补完即持久, 体检的"持久化"项随之转绿。
        echo -e "${YELLOW}[$(_i18n '.title.tip')]${NC} $(_i18n ".${CUR_FILE}.bbr.persist_repair")" >&2
        if ! _bbr_persist_files "${modules_load_file}" "${sysctl_conf_file}"; then
            echo -e "${RED}[$(_i18n '.title.fail')]${NC} $(_i18n ".${CUR_FILE}.bbr.verify_failed")" >&2
            return 2
        fi
        _audit_log 'bbr' 'persisted: already active, wrote persistence files'
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

    # 持久化: 模块自加载 + 内核参数 (与"已生效但未持久化"分支共用同一落盘实现)
    if ! _bbr_persist_files "${modules_load_file}" "${sysctl_conf_file}"; then
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

# --- 输出助手 ---
# _warn / _info / _pass 已下沉到 _common.sh (print_warn / print_info / print_pass 的短名别名)。
# 原先此处的注释写"与 check.sh / backup.sh 里的同名函数格式完全一致" —— 与事实不符:
# backup.sh 确为逐字相同, 但 check.sh 的报告语汇刻意为**黄色**且只取首参 (体检语境用颜色把
# "信息"与"通过"在视觉上分开)。现 check.sh 已改用 _check_info/_check_pass/_check_fail
# 前缀彻底消歧义, 本文件的 _info 仍是 _common.sh 的绿色别名。该安排由
# test/output_helper_sink_test.sh 显式守护。

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
# 函数名称: _ipv6_iface_list
# 功能描述: 枚举非 lo 的网络接口名 (空格分隔), 供软禁用逐个关闭接口的 IPv6。
#           解析 `ip -o link show` 的一行一接口格式:
#             "2: eth0: <BROADCAST,...> ..."   -> eth0
#             "6: veth0@if3: <BROADCAST,...>"  -> veth0  (必须去掉 @ifN: sysctl 键
#                                                 里只有 veth0, 带后缀会写出一堆
#                                                 无效键)
# 参数: 无
# 返回值: 恒 0 (结果走 stdout; 无 ip 命令或只有 lo 时输出空串)
# =============================================================================
function _ipv6_iface_list() {
    local line='' name='' result=''
    cmd_exists 'ip' || return 0
    # here-string 遍历而非管道 —— 管道会让循环跑在子 shell 里, 累积变量全丢
    while IFS= read -r line; do
        name="${line#*: }"
        name="${name%%:*}"
        name="${name%%@*}"
        [[ -n "${name}" ]] || continue
        # 刻意写成 if 而非 `[[ ]] && continue`: 后者条件为假时整条语句返回 1,
        # 会被 set -e 判为失败而中断 (本项目已登记的坑)
        if [[ "${name}" == 'lo' ]]; then
            continue
        fi
        result="${result}${result:+ }${name}"
    done <<<"$(ip -o link show 2>/dev/null || true)"
    printf '%s' "${result}"
}

# =============================================================================
# 函数名称: _ipv6_soft_pending_ifaces
# 功能描述: 列出"软禁用尚未覆盖"的非 lo 接口 (仍开着 IPv6 的), 空格分隔。
#           用于幂等判定: 结果为空即软禁用已完整生效。
# 参数: 无
# 返回值: 恒 0 (结果走 stdout)
# =============================================================================
function _ipv6_soft_pending_ifaces() {
    local list='' iface='' v='' result=''
    local -a ifaces=()
    list="$(_ipv6_iface_list)"
    if [[ -z "${list}" ]]; then
        printf ''
        return 0
    fi
    read -r -a ifaces <<<"${list}" || true
    for iface in "${ifaces[@]}"; do
        [[ -n "${iface}" ]] || continue
        v="$(sysctl -n "net.ipv6.conf.${iface}.disable_ipv6" 2>/dev/null || true)"
        if [[ "${v}" != '1' ]]; then
            result="${result}${result:+ }${iface}"
        fi
    done
    printf '%s' "${result}"
}

# =============================================================================
# 函数名称: _ipv6_sysctl_body
# 功能描述: 生成 IPv6 持久化文件的内容 (stdout), 供 _atomic_write 写盘。
#
#           **顺序即语义, 不可重排**: 写 net.ipv6.conf.all.disable_ipv6 会让内核
#           遍历并重置**所有**接口, 所以 all 必须排在逐接口行之前 —— 反过来写,
#           刚设好的 eth0=1 会被随后的 all=0 一次性抹掉, 表现为"重启后 IPv6 又
#           回来了", 而且只在重启后才暴露。
#
#           三种模式的取舍 (模式名与 handler_ipv6 完全一致, 不做二次映射 ——
#           曾经用过 enable/soft/hard 的另一套名字, 透传时对不上 case, 结果是
#           **静默生成一个只含换行符的文件**: 写盘成功、sysctl -p 返回 0、rc 也是 0,
#           只有复核才发现值没变。命名不一致的代价就是这么隐蔽):
#             enable       全 0; 含 lo 是为覆盖此前可能被写成 1 的情况。
#             disable      软禁用: all=0 (保持协议栈开启, nginx 的 listen [::] 才能
#                          bind) + lo=0 (回环始终保留) + default=1 (管将来新增的
#                          接口: 容器、热插网卡) + 逐接口 =1 (现存接口)。
#             disable-hard 硬禁用: all=1 + default=1, 彻底关栈。实测 (内核 6.12)
#                          这**不会**让 bind(::) 失败, 但仍会切断所有 IPv6 通信 ——
#                          用户侧表现就是 IPv6 不可达。
# 参数: $1 模式 (enable | disable | disable-hard)
# 返回值: 恒 0 (内容走 stdout)
# =============================================================================
function _ipv6_sysctl_body() {
    local mode="${1:-}"
    local list='' iface=''
    local -a ifaces=()

    case "${mode}" in
    enable)
        printf 'net.ipv6.conf.all.disable_ipv6 = 0\n'
        printf 'net.ipv6.conf.default.disable_ipv6 = 0\n'
        printf 'net.ipv6.conf.lo.disable_ipv6 = 0\n'
        ;;
    disable-hard)
        printf 'net.ipv6.conf.all.disable_ipv6 = 1\n'
        printf 'net.ipv6.conf.default.disable_ipv6 = 1\n'
        ;;
    disable)
        # 顺序敏感, 见函数头
        printf 'net.ipv6.conf.all.disable_ipv6 = 0\n'
        printf 'net.ipv6.conf.lo.disable_ipv6 = 0\n'
        printf 'net.ipv6.conf.default.disable_ipv6 = 1\n'
        list="$(_ipv6_iface_list)"
        if [[ -n "${list}" ]]; then
            read -r -a ifaces <<<"${list}" || true
            for iface in "${ifaces[@]}"; do
                [[ -n "${iface}" ]] || continue
                printf 'net.ipv6.conf.%s.disable_ipv6 = 1\n' "${iface}"
            done
        fi
        ;;
    esac
    return 0
}

# =============================================================================
# 函数名称: handler_ipv6_status
# 功能描述: 转发到 check.sh 的 IPv6 只读检测 (含出站连通性探测), 并按结论留痕。
#           与 handler_net_status 同一取舍 —— 判据与报告语汇都在 check.sh,
#           这里只转发与记录, 不复制一份判据。
# 参数: 无
# 返回值: 恒为 0 (理由同 handler_net_status: 非 0 会被 exec_handler 翻译成
#         "[错误] handler 执行失败"并把用户踢出菜单, 而"IPv6 半残"是一种正常
#         结论而非执行错误, 让报告自己说话即可)
# =============================================================================
function handler_ipv6_status() {
    [[ -f "${CHECK_PATH}" ]] || _error "$(_i18n ".${CUR_FILE}.ipv6.unavailable")"
    local rc=0
    bash "${CHECK_PATH}" '--ipv6-status' || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        _audit_log 'ipv6-status' 'ok or explicitly disabled'
    else
        _audit_log 'ipv6-status' 'half-broken / undetermined (see report)'
    fi
    return 0
}

# =============================================================================
# 函数名称: handler_ipv6
# 功能描述: 启用 / 禁用 IPv6 (幂等, 危险操作二次确认)。
#           1. 模式 -> 目标值: enable(all=0,default=0) / disable(软: all=0,default=1)
#              / disable-hard(硬: all=1,default=1)。
#           2. 幂等: 目标值已达成**且**持久化文件在, 直接返回零写盘。只比值不查
#              文件会漏掉"当前生效但重启失效"的情形 —— 那是 BBR 那条"生效 !=
#              持久"铁律的同类问题。软禁用还要逐个接口查, 因为它管的不止两个开关。
#           3. 列影响面 + 二次确认 (默认取消), 与 handler_net_tune 同一姿态。
#           4. 原子写 /etc/sysctl.d/99-...-ipv6.conf。
#           5. `sysctl -p <本文件>` 应用 —— 刻意不用 `sysctl --system`: 那会连带
#              加载整机其它 sysctl 配置, 别人的坏配置会把本次改动一起带崩。
#           6. 复核目标值; 软禁用再查一遍逐接口, 未覆盖的接口列名告警。
#
#           关于 nginx: 本项目 nginx 资产的 redirect.conf / stream.conf 与生成的
#           站点 conf 都写了 `listen [::]:80/443`。**是否会被禁用打断实测决定**,
#           不靠推断 —— 见 _ipv6_listen_probe 的函数头 (实测结论: sysctl 关 IPv6
#           并不阻止 bind(::), 所以不会打断; GRUB 级 ipv6.disable=1 才会)。
#           只有实测"不可监听"且 nginx 确实配置了 [::] 时, 才在确认前额外告警。
# 参数: $1 模式 (enable | disable | disable-hard)
# 返回值: 恒为 0 (已应用 / 本就达标 / 用户取消 都属正常结束; 致命错走 _error 直接退出)
# =============================================================================
function handler_ipv6() {
    local mode="${1:-}"
    # $2/$3 仅为可测性, 菜单/CLI 调用都不传, 落到系统真实路径。
    #   $2 = sysctl 持久化文件路径 —— 本函数唯一会真正改动机器的地方, 测试必须
    #        能重定向到沙箱, 否则用例只能在真机上跑, 或者更糟: 跑测试时顺手改了
    #        机器的 IPv6 配置。(与 _bbr_persist_files 把路径做成参数同一取舍。)
    #   $3 = nginx 配置目录 —— 它决定"是否提示 nginx 联动风险"。这条提示是给用户
    #        看的**安全警告**, 必须能验证它真的会出现; 不留注入口的话, 该分支只能
    #        靠"读代码"确认, 而 NEG 也证明不了它 (没有 nginx 的机器上改坏它,
    #        行为完全一样, 测试照样全绿)。
    local sysctl_file="${2:-/etc/sysctl.d/99-xray-script-personal-use-only-ipv6.conf}"
    local ngx_dir="${3:-}"
    local body='' cur_all='' cur_def='' tgt_all='' tgt_def=''
    local confirm='' pending='' probe='' dir=''
    local nginx6=0 done_flag=0
    local -a ngx_confs=()
    if [[ -n "${ngx_dir}" ]]; then
        ngx_confs=("${ngx_dir}")
    else
        ngx_confs=('/usr/local/nginx/conf' '/etc/nginx')
    fi

    case "${mode}" in
    enable)
        tgt_all='0'
        tgt_def='0'
        ;;
    disable)
        tgt_all='0'
        tgt_def='1'
        ;;
    disable-hard)
        tgt_all='1'
        tgt_def='1'
        ;;
    *)
        _error "$(_i18n ".${CUR_FILE}.ipv6.bad_mode")"
        ;;
    esac

    if ! cmd_exists 'sysctl'; then
        _error "$(_i18n ".${CUR_FILE}.ipv6.no_sysctl")"
    fi
    # 无协议栈时这些 sysctl 键根本不存在, 写进去必然失败 —— 提前给出准确原因,
    # 而不是让 sysctl -p 抛一串 "cannot stat" 噪音
    if [[ ! -d '/proc/sys/net/ipv6' ]]; then
        _error "$(_i18n ".${CUR_FILE}.ipv6.no_stack")"
    fi

    cur_all="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || true)"
    cur_def="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || true)"

    # ---- 幂等 ----
    if [[ "${cur_all}" == "${tgt_all}" && "${cur_def}" == "${tgt_def}" && -e "${sysctl_file}" ]]; then
        if [[ "${mode}" != 'disable' ]]; then
            done_flag=1
        else
            pending="$(_ipv6_soft_pending_ifaces)"
            if [[ -z "${pending}" ]]; then
                done_flag=1
            fi
        fi
    fi
    if [[ "${done_flag}" -eq 1 ]]; then
        echo -e "${GREEN}[$(_i18n '.title.tip')]${NC} $(_i18n ".${CUR_FILE}.ipv6.already")" >&2
        return 0
    fi

    # ---- 影响面 + 二次确认 ----
    if [[ "${mode}" == 'disable' ]]; then
        echo -e "${YELLOW}[$(_i18n '.title.tip')]${NC} $(_i18n ".${CUR_FILE}.ipv6.plan_soft")" >&2
        echo -e "  $(_i18n ".${CUR_FILE}.ipv6.plan_scope_soft")" >&2
    else
        echo -e "${YELLOW}[$(_i18n '.title.tip')]${NC} $(_i18n ".${CUR_FILE}.ipv6.plan_hard")" >&2
        echo -e "  $(_i18n ".${CUR_FILE}.ipv6.plan_scope_hard")" >&2
    fi
    echo -e "  $(_i18n ".${CUR_FILE}.ipv6.plan_file")${sysctl_file}" >&2

    # nginx 联动告警: 只在**实测**不可监听时才提 —— 见函数头
    probe="$(_ipv6_listen_probe)"
    for dir in "${ngx_confs[@]}"; do
        [[ -d "${dir}" ]] || continue
        if grep -rq 'listen[[:space:]]*\[::\]' "${dir}" 2>/dev/null; then
            nginx6=1
            break
        fi
    done
    if [[ "${nginx6}" -eq 1 && "${probe}" == 'no' ]]; then
        echo -e "${RED}[$(_i18n '.title.warn')]${NC} $(_i18n ".${CUR_FILE}.ipv6.nginx_risk")" >&2
    fi

    printf ' %s [y/N]: ' "$(_i18n ".${CUR_FILE}.ipv6.confirm")" >&2
    read -r confirm || confirm=''
    case "${confirm,,}" in
    y | yes) ;;
    *)
        echo -e "${YELLOW}[$(_i18n '.title.tip')]${NC} $(_i18n ".${CUR_FILE}.ipv6.cancelled")" >&2
        return 0
        ;;
    esac

    # ---- 写盘 + 应用 ----
    body="$(_ipv6_sysctl_body "${mode}")"
    if ! printf '%s\n' "${body}" | _atomic_write "${sysctl_file}"; then
        _error "$(_i18n ".${CUR_FILE}.ipv6.write_failed")"
    fi
    sysctl -p "${sysctl_file}" >/dev/null 2>&1 || true

    # ---- 复核 ----
    cur_all="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || true)"
    cur_def="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || true)"
    if [[ "${cur_all}" != "${tgt_all}" || "${cur_def}" != "${tgt_def}" ]]; then
        _error "$(_i18n ".${CUR_FILE}.ipv6.verify_failed")"
    fi
    if [[ "${mode}" == 'disable' ]]; then
        pending="$(_ipv6_soft_pending_ifaces)"
        if [[ -n "${pending}" ]]; then
            echo -e "${YELLOW}[$(_i18n '.title.warn')]${NC} $(_i18n ".${CUR_FILE}.ipv6.verify_ifaces")${pending}" >&2
            return 0
        fi
    fi

    case "${mode}" in
    enable)
        echo -e "${GREEN}[$(_i18n '.title.pass')]${NC} $(_i18n ".${CUR_FILE}.ipv6.done_enable")" >&2
        ;;
    disable)
        echo -e "${GREEN}[$(_i18n '.title.pass')]${NC} $(_i18n ".${CUR_FILE}.ipv6.done_soft")" >&2
        ;;
    disable-hard)
        echo -e "${GREEN}[$(_i18n '.title.pass')]${NC} $(_i18n ".${CUR_FILE}.ipv6.done_hard")" >&2
        ;;
    esac
    return 0
}

# =============================================================================
# 函数名称: handler_net_status
# 功能描述: 转发到 check.sh 的只读网络体检, 并在有结论后写审计日志。
#           体检本体放 check.sh —— 那里有现成的 _check_info/_check_pass/_check_fail 报告语汇,
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
#           6. 若第 5 步确实重启了服务, 从 /proc/<pid>/limits 读回真实值复核,
#              而不是只看文件写完没 —— 未重启时进程仍用旧上限, 复核必然不符,
#              所以这一步挂在 did_restart 之下, 不是无条件执行。
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
    # did_restart 必须显式初始化: 它只在"是否重启"分支里被赋值, 而下方复核段要靠它
#   判断是否该读 /proc/<pid>/limits (条件是 did_restart == 1), 初值缺失会在 set -u 下炸
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
#           保留 Nginx、acme.sh (含已签发证书) 与用户自建站点配置。
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
# 函数名称: _xray_unit_exists
# 功能描述: 判断 systemd 是否已存在 xray.service 单元。
#           理由: systemd 对"unit 不存在"与"unit 存在但启动失败"一视同仁地返回非 0,
#           若不在启停前拦截, Xray 压根没装时用户只会看到"未能进入运行状态"这句泛化
#           错误, 猜不到真实原因 (详见 handler_start 的前置检查注释)。
# 参数: 无
# 返回值: 0=单元存在; 非 0=不存在 / 无 systemd
# =============================================================================
function _xray_unit_exists() {
    systemctl cat xray.service >/dev/null 2>&1
}

# =============================================================================
# 函数名称: _xray_autostart_text
# 功能描述: 把 xray.service 的开机自启状态翻译成人类可读文案 ("已启用"/"未启用")。
#           用于启停/重启成功后那一行结果摘要 —— 让用户一眼看出"下次开机还会不会起来"。
# 参数: 无
# 返回值: stdout 输出文案; rc 恒 0 (查不到即按"未启用"处理, 不让 set -e 中断输出)
# =============================================================================
function _xray_autostart_text() {
    if systemctl -q is-enabled xray 2>/dev/null; then
        printf '%s' "$(_i18n '.handler.svc.autostart_yes')"
    else
        printf '%s' "$(_i18n '.handler.svc.autostart_no')"
    fi
}

# =============================================================================
# 函数名称: handler_start
# 功能描述: 启动 Xray 服务。
#           1. 前置检查 xray.service 是否存在 (不存在则直接报错, 而非笼统的"启动失败")。
#           2. 检查 Xray 服务是否已在运行: 已在运行则仅补开机自启, 不重复 start。
#           3. 未运行时启动服务, 并轮询复查是否真的进入 active (最多约 5 秒)。
#           4. 检查 Xray 服务是否已设置开机自启, 未设置则启用。
#           5. 以上全部静默完成(-q), 由本函数统一打印一条结果摘要 —— 交互场景下
#              用户选了菜单项必须看到"发生了什么", 否则下一帧菜单重绘会把一切吞掉。
# 参数: 无
# 返回值: 无 (systemctl 失败已由下方复查与 _error 兜底)
# =============================================================================
function handler_start() {
    _ensure_xray_runtime_dirs
    # 单元缺失时尽早报错 (见 _xray_unit_exists 注释): 否则用户会先白等 5 秒轮询
    _xray_unit_exists || _error "$(_i18n '.handler.svc.no_unit')"
    local was_active='n'
    systemctl -q is-active xray && was_active='y' || true
    # 已在运行: 幂等短路 —— 不重复 start, 只补齐开机自启, 并明确告知用户"早已在运行"
    # (旧实现到此完全静默, 用户点了菜单毫无反馈, 会以为脚本卡了或没生效)
    if [[ "${was_active}" == 'y' ]]; then
        print_info "$(_i18n '.handler.svc.start_already')"
    else
        print_info "$(_i18n '.handler.svc.starting')"
    fi
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
    # 复查未通过: 留痕(失败)并终止, 与 handler_restart 的兜底保持一致。
    # 第二参为可执行建议: systemctl start 的失败原因被 -q 吞掉了, 补一句让用户有地方查。
    if ! systemctl -q is-active xray; then
        _audit_log 'start.failed' 'xray'
        _error "$(_i18n '.handler.start.verify_failed')" "$(_i18n '.handler.svc.fail_hint')"
    fi
    # 审计留痕
    _audit_log 'start' 'xray'
    # 结果摘要: 运行状态 + 开机自启 (后者决定"下次开机会不会自己起来", 是最常被问的)
    print_pass "$(_i18n_sub '.handler.svc.start_done' '${autostart}' "$(_xray_autostart_text)")"
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
    # 单元缺失时尽早报错: "停止一个不存在的服务"在无 -q 输出时会表现为静默无反应,
    # 用户会误以为已经停掉 (尤其从别的机器迁移配置后)。
    _xray_unit_exists || _error "$(_i18n '.handler.svc.no_unit')"
    local was_active='n'
    systemctl -q is-active xray && was_active='y' || true
    # 已停止: 明确告知"无需停止", 而不是静默什么都不做
    if [[ "${was_active}" == 'y' ]]; then
        print_info "$(_i18n '.handler.svc.stopping')"
    else
        print_info "$(_i18n '.handler.svc.stop_already')"
    fi
    # 检查 Xray 服务是否活跃，如果活跃则停止
    # 注: `A && B` 作函数末句时, A 为假 (Xray 未运行) 会让函数返回非 0,
    #     裸调用处被 set -e 传播而中断 (连点两次"停止服务"即触发); 末尾补 || true 兜底。
    systemctl -q is-active xray && systemctl -q stop xray || true
    # 检查 Xray 服务是否已启用，如果启用则禁用
    systemctl -q is-enabled xray && systemctl -q disable xray || true
    # 停止后复查: 轮询等待服务退出 active 状态 (最多约 5 秒), 与 start/restart 两臂对称。
    # 旧实现没有这一步 —— stop 失败 (如进程僵住) 会照常打印"完成", 误报从此而来。
    local wait_i=0
    for ((wait_i = 0; wait_i < 10; wait_i++)); do
        systemctl -q is-active xray || break
        sleep 0.5
    done
    if systemctl -q is-active xray; then
        _audit_log 'stop.failed' 'xray'
        _error "$(_i18n '.handler.stop.verify_failed')" "$(_i18n '.handler.svc.fail_hint')"
    fi
    # 审计留痕
    _audit_log 'stop' 'xray'
    # 结果摘要: 已停止 + 开机自启已禁用 (顺带提醒"下次开机也不会自己起来")
    print_pass "$(_i18n_sub '.handler.svc.stop_done' '${autostart}' "$(_xray_autostart_text)")"
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
    # mKCP finalmask 类型 id 自适应自愈: Xray 升级/降级后已落盘 config 可能因 id 改名而失效, 重启前先修正
    heal_mkcp_finalmask || true
    # 重启前配置自检: 配置文件存在却无法解析时终止, 避免带着坏配置重启
    if [[ -f "${XRAY_CONFIG_PATH}" ]] && command -v jq >/dev/null 2>&1 && ! jq -e . "${XRAY_CONFIG_PATH}" >/dev/null 2>&1; then
        _error "$(_i18n '.handler.persist.invalid_json')"
    fi
    _ensure_xray_runtime_dirs
    # 单元缺失时尽早报错 (同上两臂): 安装流程中途被打断时最容易踩到,
    # 此时 xray 根本没装, 却会白等 5 秒轮询再报"未能进入运行状态"。
    _xray_unit_exists || _error "$(_i18n '.handler.svc.no_unit')"
    local was_active='n'
    systemctl -q is-active xray && was_active='y' || true
    # 未运行时 restart 会退化成 start, 文案要说清实际走了哪条路 (旧实现同样全程静默)
    if [[ "${was_active}" == 'y' ]]; then
        print_info "$(_i18n '.handler.svc.restarting')"
    else
        print_info "$(_i18n '.handler.svc.restart_to_start')"
    fi
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
        _error "$(_i18n '.handler.restart.verify_failed')" "$(_i18n '.handler.svc.fail_hint')"
    fi
    # 审计留痕 (仅在确认服务已运行后才记为成功)
    _audit_log 'restart' 'xray'
    # 结果摘要: 已运行 + 开机自启状态 (与 start/stop 两臂同一口径)
    print_pass "$(_i18n_sub '.handler.svc.restart_done' '${autostart}' "$(_xray_autostart_text)")"
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
#   $@ (可选): --yes 等开关
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
# 函数名称: handler_toggle_sniff_route_only
# 功能描述: 切换"嗅探域名仅用于路由"(sniffing.routeOnly) 开关。
#           改的是**已落盘**的运行配置 (只动 sniffing 字段, 其余原样保留), 而不是从模板
#           重新生成整份配置 —— 后者会把端口/UUID/REALITY 等一并重算, 为一个布尔开关
#           引入不必要的改动面。
#           顺序与 handler_warp 一致: **先写配置并复核, 成功后才记状态**。这样落盘失败时
#           配置已自动回滚、状态未变, 不会出现"界面说开了、配置没开"的错位。
# 参数: 无 (读全局 SCRIPT_CONFIG)
# 返回值: 0-已切换 (调用方可以重启生效); 非 0-未切换 (未装 Xray / 缺运行配置 /
#         本机不支持该字段 / 落盘复核失败), 调用方不应重启
# =============================================================================
function handler_toggle_sniff_route_only() {
    # 未装 Xray 时没有运行配置可改, 属"预期内不可用": 提示后返回非 0 (不触发重启)。
    local xray_ver=''
    xray_ver="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.version // empty' || true)"
    if [[ -z "${xray_ver}" ]]; then
        print_warn "$(_i18n '.handler.sniffing.not_installed')"
        return 1
    fi
    if [[ ! -f "${XRAY_CONFIG_PATH}" ]]; then
        print_warn "$(_i18n '.handler.sniffing.no_config')"
        return 1
    fi
    local cur='' next=''
    cur="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.sniffRouteOnly // 0' || true)"
    if is_enabled "${cur}"; then next=0; else next=1; fi
    # 读当前落盘配置到全局 XRAY_CONFIG (persist_xray_config 的输入), 再应用开关。
    XRAY_CONFIG="$(jq '.' "${XRAY_CONFIG_PATH}")" || return 1
    local XRAY_SNIFF_ROUTE_ONLY="${next}"
    _xray_apply_sniffing
    # 开启方向若本机实测不支持, 不留半开状态: 此时配置一个字节都没改, 直接返回非 0
    # (具体原因已由 _xray_sniff_mode 打印到 stderr)。
    if [[ "${next}" == '1' && "${_XRAY_SNIFF_MODE}" != 'on' ]]; then
        return 1
    fi
    if ! persist_xray_config; then
        return 1
    fi
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --argjson v "${next}" '.xray.sniffRouteOnly = $v')"
    persist_script_config
    if [[ "${next}" == '1' ]]; then
        print_info "$(_i18n '.handler.sniffing.enabled')"
    else
        print_info "$(_i18n '.handler.sniffing.disabled')"
    fi
}

# =============================================================================
# 函数名称: handler_warp
# 功能描述: 管理 WARP (原生 WireGuard 出站) 开关。
#           1. 已启用 -> 关闭: 摘掉 wireguard 出站, 并同步清理"指向它的分流规则"。
#              两处都要清 —— Xray 配置里, 以及 SCRIPT_CONFIG.rules。后者是规则的权威
#              副本 (_xray_apply_rules 的 case 0 会把它整份写回配置), 只删 Xray 配置
#              里的那份, 下次"更新配置"就会把规则写回来而出站没有 -> xray 加载失败。
#           2. 未启用 -> 开启: 取一份 WARP 凭据 (复用 warp.json, 没有才现注册),
#              追加 wireguard 出站, 状态位置 1。
# 参数: 无
# 返回值: 0-成功 (含"本次关闭"路径); 非 0-取凭据/落盘失败 (已 print_warn, 回菜单可重试)
# 注意: 落盘顺序是"先 Xray 配置、后脚本状态位" —— persist_xray_config 复核失败会回滚
#       已落盘配置, 此时状态位绝不能先变成"已启用", 否则状态与真实配置不一致。
# =============================================================================
function handler_warp() {
    local WARP_STATUS
    WARP_STATUS="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.warp' || true)"
    XRAY_CONFIG="$(jq '.' "${XRAY_CONFIG_PATH}")"
    if is_enabled "${WARP_STATUS}"; then
        WARP_STATUS=0
        # 一次清干净: 出站 (两种候选 tag) / 指向它的规则 / 观测与均衡段。
        # 规则必须两处副本都清 —— Xray 配置里那份, 以及 SCRIPT_CONFIG.rules (权威副本,
        # _xray_apply_rules 的 case 0 会整份写回配置)。只删一处的话, 下次"更新配置"会把
        # 规则写回来而出站已删 -> xray 拒绝加载整份配置。
        # 注: 配置里这份规则可能处于**两种形态** —— 开了健康探测时被 _xray_apply_warp_balancer
        # 改成了 balancerTag (见 _warp_rules_use_balancer), 否则是 outboundTag="warp"。
        # 两种都要删: 漏掉 balancerTag 那份, 关闭后 balancer 已摘而规则仍指着它 ->
        # fail-closed 静默断流。$bt 分支的注释在下行同步改写。
        # 权威副本 (SCRIPT_CONFIG.rules) 里则恒为 outboundTag="warp", 由下方单独清理。
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg bt "${WARP_BALANCER_TAG}" \
            --arg ot "${WARP_OUTBOUND_TAG}" '
            del(.outbounds[] | select(.tag == "warp" or .tag == $ot))
            | del(.routing.rules[]? | select(.outboundTag == "warp" or .balancerTag == $bt))
            | del(.observatory) | del(.burstObservatory)
            | if (.routing.balancers | type) == "array" then
                .routing.balancers |= map(select(.tag != $bt))
              else . end
            | if (.routing.balancers | type) == "array" and (.routing.balancers | length) == 0 then
                del(.routing.balancers)
              else . end')"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '
            if (.rules | type) == "array" then .rules |= map(select(.outboundTag != "warp")) else . end')"
    else
        local creds='' outbound='' tag=''
        creds="$(_warp_ensure_credentials)" || return 1
        _warp_outbound_tag
        tag="${_WARP_OB_TAG}"
        outbound="$(_warp_outbound_json "${creds}" "${tag}")" || return 1
        [[ -n "${outbound}" ]] || return 1
        WARP_STATUS=1
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson ob "${outbound}" \
            --arg ot "${WARP_OUTBOUND_TAG}" '
            del(.outbounds[] | select(.tag == "warp" or .tag == $ot)) | .outbounds += [$ob]')"
        # 同一次动作里就把观测/均衡带上 —— 否则"开 WARP"之后要再走一次"更新配置"才
        # 有自动回落, 而用户多半开完就重启了。
        _xray_apply_warp_balancer
    fi
    if ! persist_xray_config; then
        return 1
    fi
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg warp "${WARP_STATUS}" '.xray.warp = $warp')"
    persist_script_config
    if is_enabled "${WARP_STATUS}"; then
        print_info "$(_i18n '.handler.warp.enabled')"
    else
        print_info "$(_i18n '.handler.warp.disabled')"
    fi
}

# =============================================================================
# 函数名称: handler_reset_warp
# 功能描述: 重置 WARP 出口 —— 丢弃本地凭据并重新注册一台设备, 再刷新 wireguard 出站。
#           用途: 当前出口 IP 被目标站点风控时换一个 (原实现靠重建容器达成同一目的)。
# 参数: 无
# 返回值: 0-成功或未启用 (未启用直接提示返回); 非 0-重新注册/落盘失败
# 注意: 只改配置不重启服务 —— 重启会掐断用户当前连接, 交由用户自行选时机。
# =============================================================================
function handler_reset_warp() {
    local WARP_STATUS
    WARP_STATUS="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.warp' || true)"
    if ! is_enabled "${WARP_STATUS}"; then
        print_warn "$(_i18n '.handler.warp.reset_need_enable')"
        return 0
    fi
    XRAY_CONFIG="$(jq '.' "${XRAY_CONFIG_PATH}")"
    _warp_forget_credentials
    local creds='' outbound='' tag=''
    creds="$(_warp_ensure_credentials)" || return 1
    _warp_outbound_tag
    tag="${_WARP_OB_TAG}"
    outbound="$(_warp_outbound_json "${creds}" "${tag}")" || return 1
    [[ -n "${outbound}" ]] || return 1
    XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson ob "${outbound}" \
        --arg ot "${WARP_OUTBOUND_TAG}" '
        del(.outbounds[] | select(.tag == "warp" or .tag == $ot)) | .outbounds += [$ob]')"
    _xray_apply_warp_balancer   # 形态由实测决定, 顺势补齐/摘掉观测段 (幂等)
    persist_xray_config || return 1
    print_info "$(_i18n '.handler.warp.reset_done')"
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
# 返回值: 恒 0 —— nginx.sh 的 1 表示"无需更新"(正常分支), 其余非 0 属可恢复失败
#         (旧二进制在编译成功后才被替换), 两者都只提示不中断, 让菜单自然回到上一级。
# =============================================================================
function handler_nginx_update() {
    # 调用 nginx.sh 脚本更新 Nginx (带 Brotli 支持)
    # 注: service/nginx.sh 的 source_update 在「无需更新」时 return 1 (:720), 而 nginx.sh 入口
    #     刻意把该退出码原样传出供调用方判定 —— 也就是说 rc=1 是**正常分支**且**最常见**
    #     (本地已是最新版本时)。裸调用会让 set -e 的 ERR trap 把它判成脚本崩溃, 叠一条假的
    #     "[错误] 脚本在第 N 行意外失败 (退出码 1)" 并中断本次操作 —— 与 handler_nginx_purge
    #     同一处坑, 只是更隐蔽 (purge 的 rc=1 是少数派, update 的 rc=1 是多数派)。
    #     用 `|| rc=$?` 接住即进入条件上下文, errexit 与 ERR trap 都不触发, 退出码仍可读。
    local rc=0
    bash "${NGINX_PATH}" --update --brotli || rc=$?
    case "${rc}" in
    0) : ;; # 已执行更新; nginx.sh 自身已输出过程信息, 此处不重复
    1) print_info "$(_i18n ".${CUR_FILE}.nginx.no_update")" ;;
    *) print_warn "$(_i18n ".${CUR_FILE}.nginx.update_failed")" ;;
    esac
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
    # 注: 字段缺失时 jq -r 输出的是**字面量** "null" (不是空串), 只判 -n 会把"没装过
    #     nginx"当成"已安装", 于是给一个不存在的 nginx.sh 挂 cron / chmod。与
    #     handler_ssl_install 的 `[[ -z ... || ... == 'null' ]]` 口径保持一致。
    if [[ -n "${NGINX_STATUS}" && "${NGINX_STATUS}" != 'null' ]]; then
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
#           1. 检查 acme.sh 是否已安装 (已装则整个函数什么都不做)。
#           2. 未安装时从脚本配置读取两个值: .nginx.ca (邮箱) 与
#              .nginx.ca_server (证书机构, 缺失或字面 null 时兜底 zerossl)。
#           3. 调用 ssl.sh --install --email=... --ca=... 安装。
#           4. 审计留痕: 只记 CA 厂商, 不落邮箱明文。
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
#           实际编排是五个子函数依次执行 (序号见下方调用顺序):
#           1. _change_domain_read_inputs  取旧域名 / 读新域名;
#           2. _change_domain_render       渲染新站点 (**此步内部先删旧 conf**,
#              旧域名是为新域名腾地方, 不是独立的前置步骤);
#           3. _change_domain_issue        签发新证书 —— **成功之后**才去停旧域名
#              的定时续签 (且要 `exec_ssl --status --domain=<旧>` 为真才停);
#              (旧注释把"删配置"和"停续签"都写成无条件第 3 步, 与这里不符:
#               时机一个在前一个在后, 且停续签还有前置判断。)
#           4. _change_domain_only_branch  回写脚本配置里的域名;
#           5. handler_nginx_restart       重启 Nginx 使配置生效。
# 参数:
#   $1: target_domain - 目标域名类型 ("domain" 或 "cdn")
#   $2: stop_cert_service - 管理停止证书签发服务类型 ("n", 或默认的 "y")
# 返回值: 无 (通过文件操作和调用其他脚本执行)
# =============================================================================
function handler_change_domain() {
    local XHTTP_PATH
    local target_domain="${1:-}"
    local stop_cert_service="${2:-y}"
    local old_domain
    local _new_domain=''
    local _only_change_domain=''

    _change_domain_read_inputs
    _change_domain_render
    _change_domain_issue

    # 更新脚本配置中的域名 (nginx[target] / xray.target / xray.serverNames)
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg key "${target_domain}" --arg domain "${CONFIG_DATA["${target_domain}"]:-}" '.nginx[$key] = $domain')"
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg key "${target_domain}" --arg domain "${old_domain}" 'if $key == "domain" then del(.target[$key]) else . end')"
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg key "${target_domain}" --arg domain "${CONFIG_DATA["${target_domain}"]:-}" 'if $key == "domain" then .xray.target = $domain else . end')"
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg key "${target_domain}" --arg domain "${CONFIG_DATA["${target_domain}"]:-}" 'if $key == "domain" then .xray.serverNames = [$domain] else . end')"
    rebuild_stream_config "${SCRIPT_CONFIG}"
    persist_script_config

    _change_domain_only_branch

    handler_nginx_restart
}

# =============================================================================
# 函数名称: _change_domain_read_inputs
# 功能描述: 读取 XHTTP PATH 与旧域名, 同步 Nginx 支撑文件, 并按 stop_cert_service 决定
#           是否交互读取新域名 (否则沿用旧域名)。
# 参数: 无 (读写父函数 local: XHTTP_PATH / old_domain / target_domain / stop_cert_service / CONFIG_DATA)
# 返回值: 无
# =============================================================================
function _change_domain_read_inputs() {
    XHTTP_PATH="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.path')"
    old_domain="$(echo "${SCRIPT_CONFIG}" | jq -r --arg key "${target_domain}" '.nginx[$key]')"
    ensure_nginx_support_files || _error "failed to sync nginx support files"
    # 若 CONFIG_DATA 无新域名且需停止证书服务, 则交互读取; 否则沿用旧域名
    if [[ -z "${CONFIG_DATA["${target_domain}"]:-}" && "${stop_cert_service}" == "y" ]]; then
        [[ "${old_domain}" ]] && exec_read 'only-change-domain'
        exec_read "${target_domain}"
    else
        CONFIG_DATA["${target_domain}"]="${old_domain}"
    fi
}

# =============================================================================
# 函数名称: _change_domain_render
# 功能描述: 备份旧域名的 stream.conf 与站点 conf, 删除旧 available/enabled, 复制模板 ->
#           替换 example.com 与 /yourpath -> 对齐 HTTP/3 能力 -> 建立 available/enabled 软链。
#           **入口先校验模板存在**: 缺失即 _error 且不动任何现有配置 (见函数内注释:
#           原顺序是"先删旧配置、后 cp 模板", 模板缺失会留下站点消失的现场)。
# 参数: 无 (使用父函数 local: target_domain / old_domain / XHTTP_PATH / CONFIG_DATA)
# 返回值: 0-成功 1-复制模板失败 (模板缺失由入口守卫以 _error 终止)
# =============================================================================
function _change_domain_render() {
    # 守卫: 模板必须先存在, 且必须在**动任何现有配置之前**判定。
    # 本函数的原顺序是「备份旧 conf -> _remove_site_conf 真删旧 available/enabled -> cp 模板」,
    # 于是模板缺失时旧站点配置已经被删掉, 紧接着 cp 失败由 ERR trap 终止脚本,
    # _issue 里的回滚分支根本轮不到执行 —— 用户拿到的是"站点消失、配置全无"的现场。
    # 把判断前移到这里, 缺失即 _error 退出, 一个字节都不删 (失败方向从"破坏"变成"不动")。
    local site_tpl="${CONFIG_DIR}/nginx/conf/sites-available/${target_domain}.example.com.conf"
    [[ -f "${site_tpl}" ]] || _error "$(_i18n_sub ".${CUR_FILE}.nginx.site_template_missing" '${path}' "${site_tpl}")"

    [[ -e "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" ]] && cp -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" "${SCRIPT_CONFIG_DIR}/stream.conf"
    if [[ -n "${old_domain}" && -e "${NGINX_CONFIG_DIR}/sites-available/${old_domain}.conf" ]]; then
        cp -f "${NGINX_CONFIG_DIR}/sites-available/${old_domain}.conf" "${SCRIPT_CONFIG_DIR}/${old_domain}.conf"
        _remove_site_conf "${old_domain}"
    fi
    cp -f "${site_tpl}" "${NGINX_CONFIG_DIR}/sites-available/${CONFIG_DATA["${target_domain}"]:-}.conf" || return 1
    _replace_in_file "${NGINX_CONFIG_DIR}/sites-available/${CONFIG_DATA["${target_domain}"]:-}.conf" "example.com" "${CONFIG_DATA["${target_domain}"]:-}"
    _replace_in_file "${NGINX_CONFIG_DIR}/sites-available/${CONFIG_DATA["${target_domain}"]:-}.conf" "/yourpath" "${XHTTP_PATH}"
    align_site_http3 "${NGINX_CONFIG_DIR}/sites-available/${CONFIG_DATA["${target_domain}"]:-}.conf"
    ln -sf "${NGINX_CONFIG_DIR}/sites-available/${CONFIG_DATA["${target_domain}"]:-}.conf" "${NGINX_CONFIG_DIR}/sites-enabled/${CONFIG_DATA["${target_domain}"]:-}.conf"
}

# =============================================================================
# 函数名称: _change_domain_issue
# 功能描述: 为新域名申请 SSL 证书。成功且存在旧域名时停止旧域名续签; 失败则逐条容错回滚
#           (恢复 stream.conf / 旧站点 conf 与软链 / 重启 Nginx) 后 exit 1, 避免站点落入
#           新旧俱无的不可用状态 (修复: 原裸 mv 在 set -e 下中止导致回滚不完整)。
# 参数: 无 (使用父函数 local: target_domain / old_domain / stop_cert_service)
# 返回值: 无 (失败 exit 1)
# =============================================================================
function _change_domain_issue() {
    if exec_ssl '--issue' --domain="${CONFIG_DATA["${target_domain}"]:-}"; then
        if [[ -n "${old_domain}" && "${stop_cert_service}" == "y" ]] && exec_ssl '--status' --domain="${old_domain}"; then
            exec_ssl '--stop-renew' --domain="${old_domain}"
        fi
    else
        _remove_site_conf "${CONFIG_DATA["${target_domain}"]:-}"
        # 回滚路径必须逐条容错: 能恢复多少恢复多少, 最后统一重启, 绝不因单条失败中止
        if [[ -f "${SCRIPT_CONFIG_DIR}/stream.conf" ]]; then
            mv -f "${SCRIPT_CONFIG_DIR}/stream.conf" "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" || true
        else
            print_warn "$(_i18n ".${CUR_FILE}.nginx.rollback_backup_missing")"
        fi
        if [[ -n "${old_domain}" && -f "${SCRIPT_CONFIG_DIR}/${old_domain}.conf" ]]; then
            mv -f "${SCRIPT_CONFIG_DIR}/${old_domain}.conf" "${NGINX_CONFIG_DIR}/sites-available/${old_domain}.conf" || true
            ln -sf "${NGINX_CONFIG_DIR}/sites-available/${old_domain}.conf" "${NGINX_CONFIG_DIR}/sites-enabled/${old_domain}.conf"
        fi
        handler_nginx_restart
        exit 1
    fi
}

# =============================================================================
# 函数名称: _change_domain_only_branch
# 功能描述: 仅更新域名分支: 将备份的旧站点 conf 改名为新域名 conf, 替换其中旧域名为新域名,
#           对齐 HTTP/3 能力并重建软链; 备份缺失则告警跳过 (修复: 原裸 mv 在 set -e 下中止)。
# 参数: 无 (使用父函数 local: target_domain / old_domain / CONFIG_DATA)
# 返回值: 无
# =============================================================================
function _change_domain_only_branch() {
    _only_change_domain="${CONFIG_DATA['only-change-domain']:-}"
    if [[ "${_only_change_domain,,}" == "y" ]]; then
        _new_domain="${CONFIG_DATA["${target_domain}"]:-}"
        if [[ -f "${SCRIPT_CONFIG_DIR}/${old_domain}.conf" ]]; then
            mv -f "${SCRIPT_CONFIG_DIR}/${old_domain}.conf" "${NGINX_CONFIG_DIR}/sites-available/${_new_domain}.conf" || true
            rm -f "${NGINX_CONFIG_DIR}/sites-enabled/${_new_domain}.conf"
            _replace_in_file "${NGINX_CONFIG_DIR}/sites-available/${_new_domain}.conf" "${old_domain}" "${_new_domain}"
            align_site_http3 "${NGINX_CONFIG_DIR}/sites-available/${_new_domain}.conf"
            ln -sf "${NGINX_CONFIG_DIR}/sites-available/${_new_domain}.conf" "${NGINX_CONFIG_DIR}/sites-enabled/${_new_domain}.conf"
            rebuild_stream_config "${SCRIPT_CONFIG}"
        else
            print_warn "$(_i18n ".${CUR_FILE}.nginx.rollback_backup_missing")"
        fi
    fi
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
#           3. 调用 handler_x25519_config 生成 Reality 密钥对
#              (必须在 handler_xray_config **之前**: 后者要把它写进配置)。
#           4. 调用 handler_xray_config 配置 Xray。
#           5. 添加默认的阻止规则 (BT, CN IP, AD Domain)。
#           6. 调用 handler_geodata_cron 更新 GeoData 并设置 Cron。
#           7. 调用 handler_restart 重启 Xray 服务。
#           8. 调用 handler_share 显示分享链接。
#           9. 调用 handler_subscription 生成订阅 (收尾步骤, 失败不阻塞安装: `|| true`)。
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

    # 审计留痕收口 (dispatch 层): 补齐各臂没有自行记录的写操作, 见 _audit_dispatch 的说明。
    # 位置在 case **之前** —— 不少失败路径直接 _error/exit, 放到 case 之后就记不到了。
    _audit_dispatch "${option}" "$*"

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
    --sniff-route-only)
        # 嗅探域名仅用于路由: 切换开关。仅在**确实切换成功**时才重启 —— 未装 Xray /
        # 本机不支持该字段 / 落盘复核失败都会返回非 0, 此时重启既无意义又会掩盖原因。
        local _sniff_rc=0
        handler_toggle_sniff_route_only || _sniff_rc=$?
        if [[ "${_sniff_rc}" -eq 0 ]]; then
            handler_restart
        fi
        ;;
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
    --ipv6-status) handler_ipv6_status ;;   # 只读检测 IPv6 栈状态 (含出站探测)
    --ipv6-enable) handler_ipv6 'enable' ;;         # 启用 IPv6 (幂等)
    --ipv6-disable) handler_ipv6 'disable' ;;       # 软禁用 IPv6 (幂等, 需确认)
    --ipv6-disable-hard) handler_ipv6 'disable-hard' ;; # 硬禁用 IPv6 (幂等, 需确认)
    --health) handler_health ;;             # 一键全量体检 (只读)
    --net-tune) handler_net_tune ;;         # 内核网络高并发调优 (需确认)
    --nofile-limit) handler_nofile_limit ;; # 进程文件句柄上限 (需确认)
    --export-config) handler_export_config "$@" ;; # 导出配置与证书到归档
    --import-config) handler_import_config "$@" ;; # 从归档还原配置与证书
    # P1-3: 未知/未支持的参数 -> 打印用法并退出。原本 case 无 `*)` 分支, 传错参数 ->
    # 什么都不做 -> exit 0, 放进 cron 的 `--health` 写成 `--heath` 会让监控永远绿。
    # 退出码 EXIT_USAGE(=2) = 用法错误, 与正常 0、真实故障 1 区分开。
    *)
        printf "${RED}[%s]${NC} %s: %s\n" "$(_i18n '.title.error')" "$(_i18n '.handler.unknown_option')" "${option}" >&2
        exit "${EXIT_USAGE}"
        ;;
    esac

    # 配置写入收口: 本次调用若改过配置 (persist_* 置脏), 在这里统一重建一次订阅产物
    refresh_subscription_after_config_change
}

# --- 脚本执行入口 ---
# 将脚本接收到的所有参数传递给 main 函数开始执行
main "$@"
