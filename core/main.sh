#!/usr/bin/env bash
# =============================================================================
# 脚本名称: main.sh
# 脚本仓库: https://github.com/crudguy/xray-script-personal-use-only
# 功能描述: xray-script-personal-use-only 项目的主要管理脚本。
#           提供交互式菜单和命令行接口，用于安装、配置、管理 Xray-core
#           和相关服务（如 Nginx, GeoIP, WARP 等），支持多语言。
# 作者: crudguy
# 时间: 2026-09-19
# 版本: 1.0.0
# 依赖: bash, jq, cut, sed
# 配置:
#   - ${SCRIPT_CONFIG_DIR}/config.json: 用于读取语言设置 (language) 和脚本配置
#   - ${I18N_DIR}/${lang}.json: 用于读取具体的提示文本 (i18n 数据文件)
#
# Copyright (C) 2026 crudguy
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

# 定义配置文件和相关目录/脚本的路径
readonly MENU_PATH="${CUR_DIR}/menu.sh"                        # 菜单脚本路径
readonly HANDLER_PATH="${CUR_DIR}/handler.sh"                  # 处理器脚本路径
# 单实例锁文件 (放在已收紧为 700 的配置目录内)
readonly LOCK_FILE="${SCRIPT_CONFIG_DIR}/.${SCRIPT_NAME}.lock"

# --- 全局变量声明 ---
declare SCRIPT_CONFIG='' # 存储脚本配置内容

# =============================================================================
# 函数名称: _error
# 功能描述: 打印错误信息到标准错误输出并退出脚本。
# 参数:
#   $@: 要输出的错误信息文本
# 返回值: 无 (直接打印到标准错误输出 >&2 并退出)
# 退出码: 1
# =============================================================================

function _error() {
    # $1=错误消息; $2=可选的可执行建议 (非空时以 [建议] 追加一行)
    # 注: 统一输出到 stderr (与 _common.sh 的 print_error / handler.sh 的 _error 一致),
    #     避免错误信息污染 $(...) 捕获的 stdout。
    local msg="${1:-}" hint="${2:-}"
    printf "${RED}[%s] ${NC}%s\n" "$(_i18n '.title.error')" "${msg}" >&2
    if [[ -n "${hint}" ]]; then
        printf "${YELLOW}[%s] ${NC}%s\n" "$(_i18n '.title.hint')" "${hint}" >&2
    fi
    exit 1
}

# =============================================================================
# 函数名称: exec_menu
# 功能描述: 执行菜单脚本 (menu.sh)，并将菜单脚本的退出码作为返回值。
# 参数:
#   $@: 传递给 menu.sh 脚本的参数
# 返回值: menu.sh 脚本的退出码 (通过 return ${OPTION} 返回)
# =============================================================================

function exec_menu() {
    # 菜单选择经 stdout 返回, 而非退出码 (见审计报告 P1-1)。
    #   - menu.sh 的 UI 渲染整体走 stderr (见 menu.sh 末尾 dispatch 的 `>&2` 包裹),
    #     其 stdout 是干净的, 仅承载"退出码即选择编号"这一旧约定; 我们在子进程外
    #     捕获该退出码, 通过 stdout 输出, 让 exec_menu 自身恒 return 0。
    #   - 退出码恢复标准语义 (0=成功), 调用方不再需要 `|| choose=$?` 这种反直觉写法,
    #     也就杜绝了"漏写接住 -> 用户选了非 0 项被 set -e / ERR trap 误判为脚本崩溃"。
    local OPTION=0 # 初始化局部变量 OPTION 为 0
    # 执行菜单脚本, 捕获其退出码 (即用户选择的菜单编号); UI 经 stderr 显示到终端
    bash "${MENU_PATH}" "$@" || OPTION=$?
    # 经 stdout 返回选择编号 (命令替换只捕获 stdout, 不捕获 stderr, 故 UI 不受影响)
    printf '%s' "${OPTION}"
}

# =============================================================================
# 函数名称: exec_handler
# 功能描述: 执行处理器脚本 (handler.sh)。
# 参数:
#   $@: 传递给 handler.sh 脚本的参数
# 返回值: 无 (handler.sh 的退出码即为当前函数的退出码)
# =============================================================================

function exec_handler() {
    # 执行处理器脚本，并传递所有参数
    # 注: handler.sh 返回非 0 属可预期情况, 需先接住再自行判定, 不能让 set -e 抢先退出
    local exit_code=0
    bash "${HANDLER_PATH}" "$@" || exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        _error "$(_i18n ".${CUR_FILE}.handler_failed")"
    fi
}

function exec_read() {
    # read.sh 在 EOF (无输入源) 时以非 0 退出, 这是**刻意的上报**而非脚本故障
    # (见 core/read.sh 与审计报告 P0-1); 此处只需"取到什么算什么" —— 读不到即空串,
    # 交由调用方按业务语义处理, 故用 || true 接住, 不让 set -e 把它当失败。
    bash "${CUR_DIR}/read.sh" "$@" || true
}

# =============================================================================
# 函数名称: processes_web_config
# 功能描述: 处理 Web 配置相关的流程。
#           1. 显示 Web 配置菜单 (仅 Nginx 默认页面一项)。
#           2. Web 前端固定为 Nginx 默认页面。
#           3. 根据 is_change 参数决定是仅更改配置还是执行完整安装流程。
# 参数:
#   $1: is_change - 控制流程模式。'y' 表示仅更改 web 配置；
#                   'n' 表示执行完整安装流程 (安装脚本、Nginx、Xray 配置)。
#                   默认为 'y'。
# 返回值: 无 (通过调用其他函数和脚本执行操作)
# =============================================================================

function processes_web_config() {
    local is_change="${1:-y}" # 获取 is_change 参数，默认为 'y'
    local current_tag
    current_tag="$(jq -r '.xray.tag' "${SCRIPT_CONFIG_PATH}")"
    # 显示 Web 配置菜单 (仅 Nginx 默认页面一项)
    # web 菜单固定选中 Nginx 默认页, 无需消费选择; exec_menu 恒 return 0
    exec_menu '--web' >/dev/null
    local web='normal' # Web 前端固定为 Nginx 默认页面
    # 如果 is_change 为 'y'，则仅更改 web 配置
    if [[ "${is_change}" == 'y' ]]; then
        exec_handler '--web' "${web}"
    else
        # 如果 is_change 为 'n'，则执行完整安装流程
        if [[ "${current_tag,,}" != 'sni' ]]; then
            exec_handler '--sni-ports'
        fi
        exec_handler '--script-config' 'SNI'  # 设置脚本配置为 SNI
        exec_handler '--install'              # 安装核心组件
        exec_handler '--nginx-install'        # 安装 Nginx
        exec_handler '--xray-config' "${web}" # 配置 Xray 使用选定的 web 类型
        exec_handler '--restart'              # 重启 Xray 服务
        exec_handler '--share'                # 显示分享链接
        # SNI 安装完成后同样生成订阅三件套 (base64/Clash/sing-box), 让用户一次拿到所有客户端配置。
        # best-effort, 失败不中断安装。
        bash "${CUR_DIR}/share.sh" --subscription || true
    fi
}

# =============================================================================
# 函数名称: processes_ca_vendor
# 功能描述: 处理证书颁发机构 (CA) 流程: 显示 CA 菜单读取用户选择, 与当前 CA 比较后
#           按 apply_mode 执行 —— 'preview' 仅预览; 'switch' 在二次确认后切换;
#           其他模式直接切换。
# 参数:
#   $1: apply_mode - 运行模式 ('preview' / 'switch' / 其他)
# 返回值: 无 (用户未确认时提前返回)
# =============================================================================
function processes_ca_vendor() {
    local apply_mode="${1:-preview}"

    local choose=0
    choose="$(exec_menu '--ca')"
    local ca_server='zerossl'
    local current_ca_server
    current_ca_server="$(jq -r '.nginx.ca_server' "${SCRIPT_CONFIG_PATH}" || true)"
    local switch_confirm='n'
    case ${choose} in
    2) ca_server='letsencrypt' ;;
    *) ca_server='zerossl' ;;
    esac
    [[ -z "${current_ca_server}" || "${current_ca_server}" == 'null' ]] && current_ca_server='zerossl'

    if [[ "${apply_mode}" != 'preview' ]]; then
        if [[ "${apply_mode}" == 'switch' && "${ca_server}" != "${current_ca_server}" ]]; then
            # 注: 读不到确认 (无输入源) 即视为"未确认" —— 落空串后由下方判定为不切换,
            #     而不是让 set -e 中断整个脚本。切换 CA 属显式的、需要用户点头的动作。
            switch_confirm="$(exec_read '--switch-ca')" || switch_confirm=''
            [[ "${switch_confirm,,}" == 'y' ]] || return 0
        fi
        exec_handler '--ca-server' "${ca_server}"
    fi
}

# =============================================================================
# 函数名称: processes_xray_config
# 功能描述: 处理 Xray 配置相关的流程。
#           1. 显示 Xray 配置菜单。
#           2. 根据用户选择确定 XTLS 配置类型 (Vision, mKCP, XHTTP, Trojan, Fallback, SNI)。
#           3. 如果选择了 SNI，则调用 processes_web_config 进行特殊处理。
#           4. 否则，设置脚本配置并执行安装和 Xray 配置。
# 参数: 无
# 返回值: 无 (通过调用其他函数和脚本执行操作)
# =============================================================================

function processes_xray_config() {
    # 显示 Xray 配置菜单

    local choose=0
    choose="$(exec_menu '--config')"
    local XTLS_CONFIG='Vision' # 初始化 XTLS 配置类型为 'Vision'
    # 根据用户选择设置具体的 XTLS 配置类型
    case ${choose} in
    1) XTLS_CONFIG='mKCP' ;;     # 选择 1 对应 mKCP
    3) XTLS_CONFIG='XHTTP' ;;    # 选择 3 对应 XHTTP
    4) XTLS_CONFIG='Trojan' ;;   # 选择 4 对应 Trojan
    5) XTLS_CONFIG='Fallback' ;; # 选择 5 对应 Fallback
    6) XTLS_CONFIG='SNI' ;;      # 选择 6 对应 SNI
    *) XTLS_CONFIG='Vision' ;;   # 其他情况 (包括 2 和默认) 对应 Vision
    esac
    # 如果选择了 SNI 配置
    if [[ "${XTLS_CONFIG}" == 'SNI' ]]; then
        processes_ca_vendor 'init'
        # 调用 processes_web_config 处理 SNI 特殊流程 (不执行完整安装)
        processes_web_config 'n'
    else
        # 对于其他配置类型
        exec_handler '--script-config' "${XTLS_CONFIG}" # 设置脚本配置
        exec_handler '--install'                        # 安装核心组件
        exec_handler '--xray-config'                    # 配置 Xray
        exec_handler '--restart'                        # 重启 Xray 服务
        exec_handler '--share'                          # 显示分享链接
        # 安装完成后顺带生成订阅三件套 (base64/Clash/sing-box): Clash/sing-box 不能直接吃屏幕裸链接,
        # 必须靠订阅文件; 首次安装特意生成, 之后配置变更由刷新机制自动重建。best-effort, 失败不中断安装。
        bash "${CUR_DIR}/share.sh" --subscription || true
    fi
}

# =============================================================================
# 函数名称: processes_xray
# 功能描述: 处理 Xray 安装相关的流程。
#           1. 显示 Xray 安装菜单。
#           2. 根据用户选择确定 Xray 版本 (release, latest, custom)。
#           3. 根据 is_exec 参数决定是立即安装还是设置版本后进入配置流程。
# 参数:
#   $1: is_exec - 控制流程模式。'y' 表示立即执行安装；
#                 'n' 表示仅设置版本，然后进入 Xray 配置流程。
#                 默认为 'y'。
# 返回值: 无 (通过调用其他函数和脚本执行操作)
# =============================================================================

function processes_xray() {
    local is_exec="${1:-y}" # 获取 is_exec 参数，默认为 'y'
    local version='release' # 初始化 Xray 版本为 'release'
    # 显示 Xray 安装菜单

    local choose=0
    choose="$(exec_menu '--xray')"
    # 根据用户选择设置具体的 Xray 版本
    case ${choose} in
    1) version='latest' ;;  # 选择 1 对应 latest
    3) version='custom' ;;  # 选择 3 对应 custom
    *) version='release' ;; # 其他情况 (包括 2 和默认) 对应 release
    esac
    # 如果 is_exec 为 'y'，则立即执行安装
    if [[ "${is_exec}" == 'y' ]]; then
        exec_handler '--install' "${version}" 'y' # 安装指定版本的 Xray
    else
        # 如果 is_exec 为 'n'，则仅设置版本，然后进入配置流程
        exec_handler '--version' "${version}" # 设置 Xray 版本
        processes_xray_config                 # 进入 Xray 配置流程
    fi
}

# =============================================================================
# 函数名称: processes_full_installation
# 功能描述: 处理一键安装相关的流程。
#           1. 显示一键安装菜单。
#           2. 根据用户选择决定是执行快速安装 Vision 还是进入详细 Xray 安装流程。
# 参数: 无
# 返回值: 无 (通过调用其他函数和脚本执行操作)
# =============================================================================

function processes_full_installation() {
    # 显示一键安装菜单

    local choose=0
    choose="$(exec_menu '--full')"
    # 根据用户选择执行不同操作
    # 注: 空回车(默认)与显式选 1 都直接执行一键安装 —— 与菜单上
    #     "1. 一键安装 (默认)" 标注一致, 避免此前"敲回车反而取消/卡在二次确认"的
    #     反直觉陷阱 (用户敲回车期望选默认项, 却落到一个需再输 y 的确认, 再回车即取消)。
    case ${choose} in
    1)
        # 选择 1：一键安装 Vision
        exec_handler '--quick' 'Vision'
        echo -e "${GREEN}$( _i18n '.main.install_done_tip')${NC}"
        ;;
    2)
        # 选择 2：进入详细的 Xray 安装流程 (不立即执行安装)
        processes_xray 'n'
        ;;
    255)
        # 显式选择 "0. 返回主菜单": get_choose 把字面 "0" 映射为 255,
        # 与空回车(默认=一键安装)区分, 见 get_choose。
        return 0
        ;;
    *)
        # 默认(空回车)与其它未明确列出的选择: 直接执行一键安装 Vision,
        # 与菜单上 "1. 一键安装 (默认)" 标注一致, 避免此前"敲回车反而取消/卡在二次确认"的陷阱。
        exec_handler '--quick' 'Vision'
        echo -e "${GREEN}$( _i18n '.main.install_done_tip')${NC}"
        ;;
    esac
}

# =============================================================================
# 函数名称: _require_warp_enabled
# 功能描述: WARP 分流的前置检查 —— 读本机配置的 .xray.warp, 判断 WARP Proxy 是否开启。
# 参数: 无 (读全局 SCRIPT_CONFIG_PATH)
# 返回值: 0 = WARP 已开启, 可继续; 1 = 未开启 (已打印警告), 调用方应 return 0 回菜单
# 说明: 分流菜单 5/6 标注了"需要开启 WARP"。未开启属"预期内不可用", 必须提示后回菜单,
#       不得 _error 中断整个脚本 —— 旧实现在 handler_routing 里 _error, 用户会看到
#       "[错误] WARP PROXY 没有开启..." 紧接 install.sh trampoline 的
#       "[错误] 脚本在第 N 行意外失败 (退出码 1)" (同 processes_sni_config 的处置)。
#       注: 在菜单侧预检而非放行给 handler, 还顺带避免白跑 processes_routing 末尾那次
#       `exec_handler '--restart'` (它在 case 之后无条件执行)。handler 侧的 _error
#       保留作 CLI 直调 (bash handler.sh --routing warp ip) 的兜底。
# =============================================================================

function _require_warp_enabled() {
    local warp_status=''
    # 2>/dev/null || true: 配置缺失/字段缺失时按"未开启"处理, 不让 jq 失败冒泡。
    warp_status="$(jq -r '.xray.warp' "${SCRIPT_CONFIG_PATH}" 2>/dev/null || true)"
    # 注: 用 is_enabled 而非数字比较 —— jq 对缺失字段输出字面 "null" (见 _common.sh)。
    is_enabled "${warp_status}" && return 0
    # 复用 handler 段的文案 (同一条"WARP 未开启, 无法添加分流"), 避免两处漂移。
    print_warn "$(_i18n '.handler.warp.status')"
    return 1
}

# =============================================================================
# 函数名称: processes_routing
# 功能描述: 处理路由规则配置相关的流程。
#           1. 显示路由规则菜单。
#           2. 根据用户选择执行不同的路由配置操作 (WARP, Block IP/Domain, WARP IP/Domain)。
#           3. 选择 5/6 (WARP 分流) 前先经 _require_warp_enabled 检查 WARP 是否开启;
#              未开启属"预期内不可用" -> 提示后返回本菜单, 不进 handler 也不重启 Xray。
# 参数: 无
# 返回值: 无 (通过调用其他函数和脚本执行操作)
# =============================================================================

function processes_routing() {
    # 显示路由规则菜单 (循环: 完成一项 / 守卫拦截后回到本菜单, 便于连续配置多条规则;
    # 选 0 / EOF / 非法输入 -> break 退回上级, 避免重新下钻)。

    local choose=0
    while true; do
        choose="$(exec_menu '--route')"
        # 根据用户选择执行不同的路由配置操作
        case ${choose} in
        1) exec_handler '--warp' ;;                     # 选择 1：配置 WARP
        2) exec_handler '--reset-warp' ;;               # 选择 2：重置 WARP
        3) exec_handler '--routing' 'block' 'ip' ;;     # 选择 3：配置阻止 IP 规则
        4) exec_handler '--routing' 'block' 'domain' ;; # 选择 4：配置阻止 Domain 规则
        5 | 6)
            # 选择 5/6：WARP 分流 (需先开启 WARP)。未开启时提示并回到本菜单 (continue),
            # 不进 handler、也不触发末尾的 Xray 重启 (见 _require_warp_enabled)。
            _require_warp_enabled || continue
            if [[ "${choose}" == '5' ]]; then
                exec_handler '--routing' 'warp' 'ip'     # 选择 5：配置 WARP IP 规则
            else
                exec_handler '--routing' 'warp' 'domain' # 选择 6：配置 WARP Domain 规则
            fi
            ;;
        *) break ;;                                       # 0/EOF/非法 -> 退回上级菜单
        esac
        exec_handler '--restart' # 重启 Xray 服务
    done
}

# =============================================================================
# 函数名称: processes_custom_sites
# 功能描述: 处理自定义站点流程: 显示自定义站点菜单, 按选择派发到
#           list / add / update / delete 对应 handler。
# 参数: 无
# 返回值: 无
# =============================================================================
function processes_custom_sites() {
    # 显示自定义站点子菜单 (循环: 完成一项后回到本菜单; 0/EOF -> 退回上级)。

    local choose=0
    while true; do
        choose="$(exec_menu '--custom-sites')"
        case ${choose} in
        1) exec_handler '--custom-sites' 'list' ;;
        2) exec_handler '--custom-sites' 'add' ;;
        3) exec_handler '--custom-sites' 'update' ;;
        4) exec_handler '--custom-sites' 'delete' ;;
        *) break ;;
        esac
    done
}

# =============================================================================
# 函数名称: processes_sni_config
# 功能描述: 处理 SNI 配置相关的流程。
#           1. 检查当前 Xray 配置是否为 SNI 模式，如果不是则提示并返回菜单 (不退出)。
#           2. 显示 SNI 配置菜单。
#           3. 根据用户选择执行不同的 SNI 相关操作 (更改域名/CDN, 更新 Nginx, 配置 Cron, Web 配置, 重置 V3)。
# 参数: 无
# 返回值: 无 (通过调用其他函数和脚本执行操作)
# 退出码: 无 —— 非 SNI 模式属"预期内不可用"(用户可能只是想看看), 仅 print_warn
#         提示后 return 0 回到菜单, 不中断脚本。真正的操作失败仍由 exec_handler
#         的 _error 兜底退出。
# =============================================================================

function processes_sni_config() {
    # 从配置文件中读取当前 Xray 的 tag
    local tag
    tag="$(jq -r '.xray.tag' "${SCRIPT_CONFIG_PATH}")"
    # 检查 tag 是否为 'sni' (不区分大小写)。
    # 非 SNI 模式下本菜单项不适用 —— 属"预期内不可用", 提示一句后返回菜单即可;
    # 不能用 _error: 它会 exit 1, 一路冒泡成 install.sh trampoline 的
    # "[错误] 脚本在第 N 行意外失败 (退出码 1)", 用户只看到崩溃且被迫重进脚本,
    # 连"换个菜单项"都做不到。与同级 processes_* 的 `*) return 0` 惯例保持一致。
    if [[ "${tag,,}" != 'sni' ]]; then
        print_warn "$(_i18n ".${CUR_FILE}.not_support")"
        return 0
    fi
    # 显示 SNI 配置菜单

    local choose=0
    choose="$(exec_menu '--sni')"
    # 根据用户选择执行不同的 SNI 相关操作
    case ${choose} in
    1) exec_handler '--change-domain' 'domain' ;; # 选择 1：更改域名
    2) exec_handler '--change-domain' 'cdn' ;;    # 选择 2：更改 CDN
    3) exec_handler '--renew-certificate' ;;      # 选择 3：强制证书续签
    4) exec_handler '--nginx-update' ;;           # 选择 4：更新 Nginx 配置
    5) exec_handler '--nginx-cron' ;;             # 选择 5：配置 Nginx Cron 任务
    6) processes_web_config ;;                    # 选择 6：进入 Web 配置流程
    7) processes_ca_vendor 'switch' ;;
    8) processes_custom_sites ;;
    9) exec_handler '--remove-certificate' ;;    # 选择 9：移除单域名证书
    *) return 0 ;;                                  # 其他情况：退出脚本
    esac
}


# =============================================================================
# 函数名称: processes_config
# 功能描述: 处理主配置管理相关的流程。
#           1. 显示主配置管理菜单。
#           2. 根据用户选择进入不同的子流程 (Xray 配置, 路由规则, SNI 配置, GeoData Cron)。
# 参数: 无
# 返回值: 无 (通过调用其他函数和脚本执行操作)
# =============================================================================

# =============================================================================
# 函数名称: processes_language
# 功能描述: 处理语言设置相关的流程。
#           1. 显示语言设置菜单。
#           2. 根据用户选择设置不同的语言（zh: 中文，en: 英语）。
#           3. 同进程内清空并重新加载 i18n, 立即生效, 随后返回到调用方菜单。
# 参数: 无 (不再接收来源菜单名; 见下方说明)
# 返回值: 无 (无 re-launch, 直接返回调用方)
# 说明: 早期实现改完语言后 re-launch 子进程 (`bash main.sh`) 以重载 i18n, 带来
#       两个致命问题 —— (1) 父进程持单实例锁 (fd 9) 时子进程再次 _acquire_lock
#       冲突, 误报 "已有实例正在运行"; (2) 子进程继承父进程 TTY stdin, 交互态下
#       读不到正确输入而卡死 (光标不动)。改为同进程内 `I18N_MAP=(); load_i18n`
#       即可一次性消除这两类问题, 且语言切换即时可见。返回后由 processes_index
#       主循环重新渲染菜单 (已是新语言)。
# =============================================================================

function processes_language() {
    # 显示语言设置菜单
    local choose=0
    choose="$(exec_menu '--language')"
    # 根据用户选择设置不同的语言
    case ${choose} in
    2) LANG_PARAM="en" ;; # 选择英文
    *) LANG_PARAM="zh" ;; # 默认中文
    esac
    # 更新配置文件中的语言设置
    SCRIPT_CONFIG="$(jq --arg language "${LANG_PARAM}" '.language = $language' "${SCRIPT_CONFIG_PATH}")"
    printf '%s\n' "${SCRIPT_CONFIG}" | _atomic_write "${SCRIPT_CONFIG_PATH}"
    # 同进程内重载 i18n, 无需 re-launch 子进程:
    #   (1) 避免父进程持锁时 re-launch 子进程再次 _acquire_lock 导致的 lock_busy 误报;
    #   (2) 避免子进程继承父进程 TTY stdin 造成的交互卡死 (光标不动)。
    # shellcheck disable=SC2034  # I18N_MAP 实际在 _common.sh 的 _i18n 中跨文件读取; shellcheck 单文件分析无法追踪, 此处清空仅为触发 load_i18n 重新填充
    I18N_MAP=()
    load_i18n
}

function processes_config() {
    # 显示主配置管理菜单 (循环: 完成一项后回到本菜单; 0/EOF/非法 -> 退回主菜单)。

    local choose=0
    while true; do
        choose="$(exec_menu '--management')"
        # 根据用户选择进入不同的子流程
        case ${choose} in
        1) processes_xray_config ;;         # 选择 1：进入 Xray 配置流程
        2) processes_routing ;;             # 选择 2：进入路由规则配置流程
        3) processes_sni_config ;;          # 选择 3：进入 SNI 配置流程
        4) exec_handler '--change-port' ;;  # 选择 4：修改 Xray 端口
        5) exec_handler '--geodata-cron' ;; # 选择 5：配置 GeoData Cron 任务
        6) processes_language ;;            # 选择 6：设置语言 (同进程内重载 i18n)
        7) processes_bbr ;;                 # 选择 7：BBR 与内核网络加速（体检/调优）
        8) processes_backup ;;              # 选择 8：配置备份与迁移（导出/导入）
        *) break ;;                          # 0/EOF/非法 -> 退回主菜单
        esac
    done
}

# =============================================================================
# 函数名称: processes_bbr
# 功能描述: 处理 BBR 与内核网络加速流程。
#           1. 显示 BBR 子菜单。
#           2. 选项 1 幂等开启/修复 BBR; 2 只读体检; 3 内核网络高并发调优;
#              4 进程文件句柄上限 —— 后两项影响面覆盖整机, 故各自独立成项,
#              不并入"开启 BBR", 也不自动执行。
# 参数: 无
# 返回值: 无 (通过调用 exec_handler 执行操作)
# =============================================================================

function processes_bbr() {
    # 显示 BBR 子菜单 (循环: 完成一项后回到本菜单; 0/EOF -> 退回管理配置菜单)。

    local choose=0
    while true; do
        choose="$(exec_menu '--bbr')"
        case ${choose} in
        1) exec_handler '--bbr' ;;          # 选择 1：开启/修复 BBR (幂等)
        2) exec_handler '--net-status' ;;   # 选择 2：只读体检 BBR 与内核网络
        3) exec_handler '--net-tune' ;;     # 选择 3：内核网络高并发调优
        4) exec_handler '--nofile-limit' ;; # 选择 4：进程文件句柄上限
        *) break ;;                          # 0/EOF/非法 -> 退回管理配置菜单
        esac
    done
}

# =============================================================================
# 函数名称: processes_backup
# 功能描述: 处理配置备份与迁移流程。
#           1. 显示备份子菜单。
#           2. 导出：调用 handler 走默认路径打包 (路径由 backup.sh 打印)。
#           3. 导入：先读取归档路径, 再交给 handler —— 归档来源必须由用户显式给出,
#              不做"自动挑选最近一份备份"这类隐含行为。
# 参数: 无
# 返回值: 无 (通过调用 exec_handler 执行操作)
# =============================================================================

function processes_backup() {
    # 显示备份与迁移子菜单 (循环: 完成一项后回到本菜单; 0/EOF/非法 -> 退回管理配置菜单)。

    local choose=0
    local archive=''
    while true; do
        choose="$(exec_menu '--backup')"
        case ${choose} in
        1) exec_handler '--export-config' ;; # 选择 1：导出配置与证书
        2)                                   # 选择 2：从归档导入
            printf "${GREEN}[%s]${NC}" "$(_i18n '.title.config')" >&2
            printf ' %s: ' "$(_i18n '.main.backup_input_path')" >&2
            # 读到 EOF (无 TTY) 时留空串 —— 视为"未指定路径"。
            read -r archive || archive=''
            # 未填路径属"用户临时取消/漏填"(文案本身就是"已取消导入"), 提示后回到本菜单即可;
            # 与上方 processes_sni_config 同一处置: "预期内不可用" -> 提示, 只有真正的操作失败
            # 才交给 exec_handler 的 _error。此处用 continue 留在备份菜单, 便于改填路径重试,
            # 而非一路退回主菜单。
            if [[ -z "${archive}" ]]; then
                print_warn "$(_i18n '.main.backup_ipath_required')"
                continue
            fi
            exec_handler '--import-config' "${archive}"
            ;;
        *) break ;;                         # 0/EOF/非法 -> 退回管理配置菜单
        esac
    done
}

# =============================================================================
# 函数名称: processes_index
# 功能描述: 处理脚本主界面的流程。
#           1. 显示 Banner、状态和主菜单。
#           2. 根据用户选择执行不同的主操作 (一键安装, Xray 安装, 卸载, 启动, 停止, 重启, 分享链接, 流量统计, 配置管理)。
# 参数: 无
# 返回值: 无 (通过调用其他函数和脚本执行操作)
# =============================================================================

function processes_index() {
    # 主循环 (P1-2): 操作完成后回到主菜单, 支持连续配置而无需重敲命令/重渲染 banner+status。
    #   - 顶层 `* / EOF` 仍 exit 0 (get_choose 在 EOF 归一为 0, 见 menu.sh, 不会空转);
    #   - exec_handler 失败会 _error 退出整个脚本 (真实错误, 预期行为), 不回菜单。
    while true; do
        # 显示 Banner + 状态信息 + 主菜单, 并读取用户选择。
        # 注: 原实现为 banner / status / index 各 fork 一次 menu.sh —— 3 个子进程、
        #     3 次 load_i18n (解析 i18n JSON 建表), 实测约 325ms/往返, 切换菜单有迟滞感。
        #     现合并为单次 --index-full 调用: 只 fork 一次、只加载一次 i18n,
        #     渲染结果与原先逐字一致 (UI 走 stderr 直显, 选择编号经 stdout 捕获)。
        local choose=0
        choose="$(exec_menu '--index-full')"
        # 根据用户选择执行不同的主操作
        case ${choose} in
        1) processes_full_installation ;; # 选择 1：进入一键安装流程
        2) processes_xray ;;              # 选择 2：进入 Xray 安装流程
        3) processes_uninstall ;;         # 选择 3：卸载
        4) exec_handler '--start' ;;      # 选择 4：启动服务
        5) exec_handler '--stop' ;;       # 选择 5：停止服务
        6) exec_handler '--restart' ;;    # 选择 6：重启服务
        7) exec_handler '--share' ;;      # 选择 7：显示分享链接
        8) exec_handler '--traffic' ;;    # 选择 8：显示流量统计
        9) processes_config ;;            # 选择 9：进入配置管理流程
        10) exec_handler '--health' ;;       # 选择 10：一键全量体检 (只读)
        11) exec_handler '--subscription' ;; # 选择 11：生成订阅
        *) exit 0 ;;                      # 其他情况：退出脚本
        esac
    done
}

# =============================================================================
# 函数名称: processes_uninstall
# 功能描述: 处理卸载管理流程。让用户明确选择卸载对象 (Xray / Nginx),
#           避免把"卸载 Nginx"藏在一键卸载里造成误操作。
# 参数: 无
# 返回值: 无 (通过调用其他函数执行卸载)
# =============================================================================

function processes_uninstall() {
    # 显示卸载管理子菜单

    local choose=0
    choose="$(exec_menu '--uninstall')"
    # 根据用户选择执行不同的卸载操作
    case ${choose} in
    1) exec_handler '--purge' ;;       # 选择 1：卸载 Xray (保留 Nginx/acme.sh/证书/Docker)
    2) exec_handler '--nginx-purge' ;; # 选择 2：卸载 Nginx (仅本项目编译版, 发行版拒绝)
    *) return 0 ;;                       # 其他情况：返回主菜单
    esac
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
#           1. 加载国际化数据。
#           2. 检查传入的第一个参数 ($1)。
#           3. 如果是特定的快速配置参数 (--vision, --xhttp, --fallback)，则直接执行快速安装。
#           4. 否则，进入主索引流程 (processes_index)。
# 参数:
#   $1: 命令行选项 (例如 --vision, --xhttp, --fallback)
#   $2: 传递给 processes_index 的第二个参数 (如果主流程被调用)
# 返回值: 无 (通过调用其他函数和脚本执行操作)
# =============================================================================

function main() {
    # 加载国际化数据
    load_i18n
    # 获取单实例锁 (放在 i18n 之后, 保证占用提示文案可用)
    _acquire_lock
    # 将第一个参数转换为小写进行匹配
    # 注: 用 ${1:-} 先兜底 —— 直接写 "${1,,}" 在零参数调用下会被 set -u 判为 unbound 而崩溃
    local _cmd="${1:-}"
    case "${_cmd,,}" in
    --help | -h)
        # P1-3 附属: 主入口此前无 --help, 传错参数会落回交互菜单而非报错。
        printf '%s\n' "$(_i18n '.main.usage')"
        exit 0
        ;;
    # 如果参数是 --vision，则执行快速安装 Vision
    --vision) exec_handler '--quick' 'Vision' ;;
    # 如果参数是 --xhttp，则执行快速安装 XHTTP
    --xhttp) exec_handler '--quick' 'XHTTP' ;;
    # 如果参数是 --fallback，则执行快速安装 Fallback
    --fallback) exec_handler '--quick' 'Fallback' ;;
    # 配置备份 / 迁移: 直达 handler, 便于脚本化与 cron 无交互调用
    # 注: shift 之后用 "$@" 透传剩余参数 —— 写死 "${2:-}" 会吞掉 --with-docker / --yes
    --export-config) shift; exec_handler '--export-config' "$@" ;;
    --import-config) shift; exec_handler '--import-config' "$@" ;;
    # BBR 与内核网络: 直达 handler, 便于脚本化与 cron 无交互调用
    # (--net-status 是只读的, 适合放进监控定时任务里盯"BBR 有没有掉")
    --bbr) exec_handler '--bbr' ;;
    --net-status) exec_handler '--net-status' ;;
    # 一键全量体检: 只读, 适合放进 cron / 监控脚本。
    #
    # 这里刻意**不走** exec_handler: handler_health 为了不中断菜单而恒 return 0,
    # 若 CLI 也走它, cron 里的 `--health` 永远拿到退出码 0 —— 体检项全红照样报成功
    # (假绿), 监控形同虚设。故直接调 check.sh 并用 exit 透传其退出码:
    #   0 = 无失败项, 1 = 有失败项
    # 代价: 这条路径不经过 handler, 因此不写审计日志 (审计只在菜单路径记录);
    #       体检是只读操作, 且 cron 场景更看重退出码, 此权衡可接受。
    --health)
        local _health_rc=0
        bash "${CUR_DIR}/check.sh" '--health' || _health_rc=$?
        exit "${_health_rc}"
        ;;
    --net-tune) exec_handler '--net-tune' ;;
    --nofile-limit) exec_handler '--nofile-limit' ;;
    # 订阅生成: 与其它功能保持一致提供 CLI 入口 (菜单 11 的等价形式),
    # 产物落在 ~/.xray-script-personal-use-only/, 便于脚本化与"改完配置后重新生成"
    --subscription) exec_handler '--subscription' ;;
    # 服务启停与分享: 直达 handler, 便于脚本化与 cron 无交互调用
    # (菜单项「启动 / 停止 / 重启 / 分享」的等价 CLI 形式)
    --start) exec_handler '--start' ;;
    --stop) exec_handler '--stop' ;;
    --restart) exec_handler '--restart' ;;
    # --share 支持附加参数 (--save / --no-qr), 用 shift + "$@" 透传, 与 --export-config 同款
    --share) shift; exec_handler '--share' "$@" ;;
    # 对于其他参数，进入主索引流程，并将第二个参数传递给它
    *) processes_index "${2:-}" ;;
    esac
}

# =============================================================================
# 函数名称: _acquire_lock
# 功能描述: 获取脚本单实例锁, 避免两个实例同时改配置/装服务互相踩踏。
#           1. 系统无 flock 时直接放行 (降级, 不把锁变成新的失败点)。
#           2. 已被占用时提示并退出, 不做任何写操作。
#           3. 锁 fd (9) 会被子进程继承, 因此 handler/menu 等子脚本运行期间锁一直有效。
# 参数: 无
# 返回值: 无 (获取失败时直接退出脚本)
# 说明: 设 XRAY_SCRIPT_NO_LOCK=1 可跳过互斥 (确需并行操作时使用)。
# =============================================================================
function _acquire_lock() {
    # 逃生开关: 明确需要并行运行时跳过
    if [[ "${XRAY_SCRIPT_NO_LOCK:-0}" == '1' ]]; then return 0; fi
    # 系统没有 flock 时降级放行
    command -v flock >/dev/null 2>&1 || return 0
    # 确保配置目录存在
    (umask 077 && mkdir -p "${SCRIPT_CONFIG_DIR}") 2>/dev/null || true
    # 先探测锁文件可写性: 不可写则降级放行 (也避免 exec 重定向失败导致 shell 退出)
    : >>"${LOCK_FILE}" 2>/dev/null || return 0
    # 打开 fd 9 指向锁文件, 非阻塞加锁; 失败说明已有实例在运行
    exec 9>>"${LOCK_FILE}"
    if ! flock -n 9; then
        _error "$(_i18n '.main.lock_busy')"
    fi
}

# =============================================================================
# 函数名称: _release_lock
# 功能描述: 释放单实例锁 (与 _acquire_lock 配对)。仅在即将 re-launch 子进程
#           (语言切换重启脚本) 时调用, 把锁干净地交接给子进程, 避免子进程
#           _acquire_lock 与父进程持锁冲突而误报 "已有实例正在运行"
#           (见用户日志: 选择 6 设置语言后报 lock_busy, 根因是父进程仍持锁时
#           又拉起一个会再次加锁的同脚本进程)。
# 参数: 无
# 返回值: 无
# 说明: flock 不可用时 (NO_LOCK / 无 flock 命令 / 锁文件不可写) fd 9 根本未打开,
#       下面两条均做了容错, 不会因 fd 未打开而报错。
# =============================================================================
function _release_lock() {
    flock -u 9 2>/dev/null || true   # 释放 fd 9 上的锁 (若未持有则静默忽略)
    exec 9>&- 2>/dev/null || true    # 关闭 fd 9, 彻底断开与锁文件的关联
}

# --- 脚本执行入口 ---
# 将脚本接收到的所有参数传递给 main 函数开始执行
main "$@"
