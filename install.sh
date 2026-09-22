#!/usr/bin/env bash
# =============================================================================
# 脚本名称: install.sh
# 脚本仓库: https://github.com/crudguy/xray-script-personal-use-only
# 功能描述: xray-script-personal-use-only 项目的安装引导脚本。
#           负责检查和安装系统依赖、下载项目文件、处理命令行参数、
#           初始化配置、设置语言以及启动主菜单。
#           自动更新: 比对本地已安装 commit 与远端分支最新 commit (见 SCRIPT_COMMIT_PATH)。
# 作者: crudguy
# 时间: 2026-09-19
# 版本: 1.0.0
# 依赖: bash, curl, wget, git, jq, sed, awk, grep
# 配置:
#   - 从 GitHub 下载项目文件到指定目录
#   - ${SCRIPT_CONFIG_DIR}/config.json: 用于读取/设置语言和版本信息
#   - ${SCRIPT_CONFIG_DIR}/commit: 记录本地已安装的 commit SHA (自动更新判据)
# Xray 官方链接:
#   - Xray-core: https://github.com/XTLS/Xray-core
#   - REALITY: https://github.com/XTLS/REALITY
#   - XHTTP: https://github.com/XTLS/Xray-core/discussions/4113
# Xray 配置模板:
#   - Xray 配置示例: https://github.com/chika0801/Xray-examples
#   - 最优组合示例: https://github.com/lxhao61/integrated-examples
#   - xhttp 五合一配置: https://github.com/XTLS/Xray-core/discussions/4118
#
# Copyright (C) 2026 crudguy
# =============================================================================

# 严格模式: -E(ERR trap 可继承) -e(命令失败即退出) -u(未定义变量报错) -o pipefail(管道任一环失败即失败)
# 注: 不再内置 -x —— xtrace 会把含密钥/口令的完整命令行写进 stderr;
#     需要排查时用 XRAY_SCRIPT_DEBUG=1 临时开启。
set -Eeuo pipefail
# 未预期失败时给出可定位的诊断 (行号 + 命令), 避免"静默退出"
# shellcheck disable=SC2154  # trap 内 rc 的赋值跨越引号, shellcheck 误报 "referenced but not assigned"
trap 'rc=$?; printf "\033[31m[错误]\033[0m 脚本在第 %s 行意外失败 (退出码 %s): %s\n" "${LINENO}" "${rc}" "${BASH_COMMAND}" >&2; exit "${rc}"' ERR
# 临时调试开关 (排查问题时设置 XRAY_SCRIPT_DEBUG=1)
if [[ "${XRAY_SCRIPT_DEBUG:-0}" == '1' ]]; then set -x; fi
:

# --- 环境与常量设置 ---
# 将常用路径添加到 PATH 环境变量，确保脚本能在不同环境中找到所需命令
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin:/snap/bin
export PATH

# 定义颜色代码，用于在终端输出带颜色的信息
# 注: 必须用 ANSI-C 引号 $'...' 让 \033 成为真正的 ESC 控制字符, 而非字面反斜杠序列。
#     否则在 printf '%s' "${GREEN}" 这类"转义在参数里"的调用中会被原样打印成
#     "\033[32m" 乱码 (菜单的 echo -e 路径能解释, 但体检查看的 printf %s 不能)。
readonly GREEN=$'\033[32m'  # 绿色
readonly YELLOW=$'\033[33m' # 黄色
readonly RED=$'\033[31m'    # 红色
readonly NC=$'\033[0m'      # 无颜色（重置）

# 获取当前脚本的目录绝对路径和文件名
CUR_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)" || exit 1 # 当前脚本所在目录
readonly CUR_DIR
CUR_FILE="$(basename "$0")" || exit 1                          # 当前脚本文件名
readonly CUR_FILE

# 项目名 (单一来源: 数据目录/安装目录/镜像名均派生自此, 与 core/_common.sh 保持一致)
readonly SCRIPT_NAME='xray-script-personal-use-only'
# 定义配置文件和相关目录的路径
readonly SCRIPT_CONFIG_DIR="${HOME}/.${SCRIPT_NAME}"              # 主配置文件目录
readonly SCRIPT_CONFIG_PATH="${SCRIPT_CONFIG_DIR}/config.json" # 脚本主配置文件路径
# 本地已安装版本的 commit 记录 (内容为 40 位 SHA)。
# 刻意放在项目目录之外: 自动更新时项目目录会被整体替换, 放在里面会一并丢失。
readonly SCRIPT_COMMIT_PATH="${SCRIPT_CONFIG_DIR}/commit"

# --- 上游仓库定位 (下载与自动更新均以此为准, 换仓库只需改这两行) ---
readonly XRAY_SCRIPT_REPO='crudguy/xray-script-personal-use-only' # GitHub 仓库 (owner/repo)
readonly XRAY_SCRIPT_REF='main'                 # 跟踪的分支/引用
# 以下 URL 均由上面的仓库与分支推导, 避免同一地址散落多处
readonly XRAY_SCRIPT_TARBALL_API="https://api.github.com/repos/${XRAY_SCRIPT_REPO}/tarball"                             # 后接 /<ref|sha>
readonly XRAY_SCRIPT_CONFIG_URL="https://raw.githubusercontent.com/${XRAY_SCRIPT_REPO}/${XRAY_SCRIPT_REF}/config.json" # 默认配置
readonly XRAY_SCRIPT_COMMIT_API="https://api.github.com/repos/${XRAY_SCRIPT_REPO}/commits/${XRAY_SCRIPT_REF}"          # 最新 commit

# --- 全局变量声明 ---
# 声明用于存储国际化数据、项目根目录和快速安装选项的全局变量
declare -A I18N_DATA=(
    ['error']='错误'
    ['root']='请使用 root 权限运行该脚本'
    ['supported']='不支持当前系统，请切换到 Ubuntu 16+、Debian 9+、CentOS 7+'
    ['ubuntu']='不支持当前版本，请切换到 Ubuntu 16+ 重试'
    ['debian']='不支持当前版本，请切换到 Debian 9+ 重试'
    ['centos']='不支持当前版本，请切换到 CentOS 7+ 重试'
    ['tip']='更新提示'
    ['new']='发现有新脚本, 是否更新'
    ['force']='强制更新脚本到最新提交'
    ['now']='是否更新 [Y/n] '
    ['promptly']='请及时更新脚本'
    ['completed']='更新完成'
    ['download']='正在下载'
    ['failed']='下载失败'
    ['downloaded']='文件已下载到'
    ['cron_disabled']='未检测到已启用且运行中的 cron 服务: 自动更新 GeoData、自动更新 Nginx、自动续签证书都不会执行, 请执行 systemctl enable --now cron 修复'
    ['installer_update_failed']='安装器自身更新失败, 已保留旧版本可继续使用; 新代码已在项目目录就位, 下次运行将生效'
    ['config_init_failed']='脚本默认配置下载或校验失败, 无法初始化。请检查网络后重试; 国内网络可设置 GH_PROXY 加速前缀后重跑'
)                        # 默认的国际化数据 (中文)
declare PROJECT_ROOT=''  # 项目安装根目录 (动态设置)
declare CORE_DIR=''      # 核心脚本目录 (动态设置)
declare QUICK_INSTALL='' # 存储快速安装选项 (如 --vision, --xhttp)
declare SCRIPT_CONFIG='' # 存储脚本配置内容
declare LANG_PARAM=''    # 存储命令行指定的语言参数
declare FORCE_CHECK_DEPS=0 # 是否强制检查/安装依赖 (0/1)
declare FORCE_UPDATE=0     # 是否强制更新脚本 (--force-update, 跳过比对与询问)

# --- GitHub 加速代理 (可选, 默认直连) ---
# 面向国内网络: raw.githubusercontent.com / api.github.com / github.com 常被阻断或极慢。
# 设 GH_PROXY 为反代前缀 (形如 https://ghfast.top) 即自动为下列域名加前缀;
# 留空 (默认) 时不做任何改写, 与历史版本行为完全一致。
declare GH_PROXY="${GH_PROXY-}"

# =============================================================================
# 函数名称: _gh_url
# 功能描述: 按需为 GitHub 系域名拼接加速前缀 (GH_PROXY 为空时原样返回)。
# 参数:
#   $1: 原始 URL
# 输出: 改写后的 URL
# 返回值: 0-成功
# =============================================================================
function _gh_url() {
    local url="${1:-}"
    # 未配置代理或 URL 为空时原样返回
    if [[ -z "${GH_PROXY:-}" || -z "${url}" ]]; then
        printf '%s' "${url}"
        return 0
    fi
    # 仅改写 GitHub 系域名; nginx.org / openssl.org / get.acme.sh 等保持原样
    case "${url}" in
    https://github.com/* | https://raw.githubusercontent.com/* | https://api.github.com/* | https://codeload.github.com/* | https://objects.githubusercontent.com/*)
        printf '%s/%s' "${GH_PROXY%/}" "${url}"
        ;;
    *)
        printf '%s' "${url}"
        ;;
    esac
}

# =============================================================================
# 函数名称: _atomic_write
# 功能描述: 将标准输入的内容原子写入目标文件。
#           先写入目标文件所在目录下的临时文件, 再通过 rename 覆盖目标文件,
#           避免写入过程中断 (如 Ctrl+C、断电、OOM) 导致目标文件被截断或损坏。
# 参数:
#   $1: 目标文件路径
# 返回值: 0-写入成功 1-写入失败
# =============================================================================
function _atomic_write() {
    local target_path="${1:-}"
    local tmp_path=''

    # 目标路径不能为空
    [[ -n "${target_path}" ]] || return 1
    # 在目标文件同目录下创建临时文件 (保证后续 mv 为同一文件系统内的原子 rename)
    tmp_path="$(mktemp "${target_path}.XXXXXX")" || return 1
    # 将标准输入写入临时文件, 失败则清理临时文件并返回
    if ! cat >"${tmp_path}"; then
        rm -f "${tmp_path}"
        return 1
    fi
    # 原子替换目标文件
    mv -f "${tmp_path}" "${target_path}" || return 1
    # 目标文件均为含密钥/口令的配置, 统一收紧为仅属主可读写
    chmod 600 "${target_path}"
}

# =============================================================================
# 函数名称: _os
# 功能描述: 检测当前操作系统的发行版名称。
# 参数: 无
# 返回值: 操作系统名称 (echo 输出: debian/ubuntu/centos; RHEL 系如 Amazon Linux 同样归为 centos)
# =============================================================================
# =============================================================================
# 以下 _os / _os_full / _os_ver / _gh_url / _atomic_write / cmd_exists 与
# core/_common.sh 中的同名函数同源 —— install.sh 被单独下载到 ${HOME} 执行,
# 运行当时仓库尚不存在, 必须保持单文件自包含 (详见 _common.sh 文件头注释)。
# 修改任一侧时请同步另一侧: 两份实现的"代码体"一致性由 test/os_detect_sync_test.sh
# 静态锁定, 任一侧改了函数逻辑而未同步另一侧时该测试立即失败 (注释差异不触发)。
#
# 例外: load_i18n 刻意**不同源**, 不属上面名单, 也不受该测试约束 ——
#   install.sh 版自带 I18N_DATA 数组 (运行当时还没有 i18n JSON 可读),
#   _common.sh 版从 i18n/<lang>.json 构建 I18N_MAP。两者本就是两套实现,
#   把它塞进同步测试只会永久常红。
# =============================================================================
function _os() {
    local os=""

    # 检查 Debian/Ubuntu 系列
    if [[ -f "/etc/debian_version" ]]; then
        # 读取 /etc/os-release 文件并提取 ID 字段
        source /etc/os-release && os="${ID}"
        printf -- "%s" "${os}" && return
    fi

    # 检查 Red Hat/CentOS 系列
    if [[ -f "/etc/redhat-release" ]]; then
        os="centos"
        printf -- "%s" "${os}" && return
    fi
}

# =============================================================================
# 函数名称: _os_full
# 功能描述: 获取当前操作系统的完整发行版信息。
# 参数: 无
# 返回值: 完整的操作系统版本信息 (echo 输出)
# =============================================================================
function _os_full() {
    # 检查 Red Hat/CentOS 系列
    if [[ -f /etc/redhat-release ]]; then
        # 从 /etc/redhat-release 文件中提取发行版名称和版本号
        awk '{print ($1,$3~/^[0-9]/?$3:$4)}' /etc/redhat-release && return
    fi

    # 检查通用的 os-release 文件
    if [[ -f /etc/os-release ]]; then
        # 从 /etc/os-release 文件中提取 PRETTY_NAME 字段
        awk -F'[= "]' '/PRETTY_NAME/{print $3,$4,$5}' /etc/os-release && return
    fi

    # 检查 LSB (Linux Standard Base) 发布文件
    if [[ -f /etc/lsb-release ]]; then
        # 从 /etc/lsb-release 文件中提取 DESCRIPTION 字段
        awk -F'[="]+' '/DESCRIPTION/{print $2}' /etc/lsb-release && return
    fi
}

# =============================================================================
# 函数名称: _os_ver
# 功能描述: 获取当前操作系统的主版本号。
# 参数: 无
# 返回值: 操作系统的主版本号 (echo 输出)
# =============================================================================
function _os_ver() {
    # 调用 _os_full 函数获取完整版本信息，然后提取其中的数字和点
    local main_ver
    main_ver="$(echo "$(_os_full)" | grep -oE "[0-9.]+" || true)"
    # 输出主版本号 (第一个点号前的部分)
    printf -- "%s" "${main_ver%%.*}"
}

# =============================================================================
# 函数名称: cmd_exists
# 功能描述: 检查指定的命令是否存在于系统中。
# 参数:
#   $1: 要检查的命令名称
# 返回值: 0-命令存在 1-命令不存在 (由命令检查工具的退出码决定)
# =============================================================================
function cmd_exists() {
    local cmd="${1:-}"

    # 与 core/_common.sh:cmd_exists 同源 (install.sh 需保持单文件自包含, 故保留副本;
    # 修改任一处时请同步另一处)。
    # 此前用 `eval type "$cmd"`: 命令名先被展开再求值, 参数里的分号/反引号会被当成
    # shell 代码执行 (已实测: 传入 'x; touch /tmp/marker' 会真的创建文件)。且降级分支
    # `elif command` 缺参数、恒为真, 导致后面的 command -v / which 两个分支永远走不到。
    # command -v 是 POSIX 内建, bash 必有, 单分支即可覆盖原先三种写法的实际能力。
    [[ -n "${cmd}" ]] || return 1
    command -v -- "${cmd}" >/dev/null 2>&1
}

# =============================================================================
# 函数名称: parse_args
# 功能描述: 解析命令行参数。
# 参数:
#   $@: 所有命令行参数
# 返回值: 无 (直接修改全局变量 QUICK_INSTALL, PROJECT_ROOT, LANG_PARAM)
# =============================================================================
function parse_args() {
    # 遍历所有命令行参数
    while [[ $# -gt 0 ]]; do
        case "${1:-}" in
        # 如果参数是语言设置
        --lang=*)
            LANG_PARAM="${1:-}"
            ;;
        --check-deps)
            FORCE_CHECK_DEPS=1
            ;;
        # 强制更新: 不比对 commit, 也不询问, 直接把项目刷新到远端最新提交
        --force-update)
            FORCE_UPDATE=1
            ;;
        --help | -h)
            # P1-3 附属: 安装器此前无 --help, 未知参数被静默忽略。
            printf '%s\n' "用法: bash install.sh [选项]"
            printf '  (无参数)          交互式安装 / 首次部署\n'
            printf '  --lang=<zh|en>    指定界面语言\n'
            printf '  --check-deps      仅检查并安装依赖\n'
            printf '  --force-update    强制刷新到远端最新提交\n'
            printf '  --help, -h        显示本帮助\n'
            exit 0
            ;;
        esac
        shift
    done
}

# =============================================================================
# 函数名称: load_i18n
# 功能描述: 加载国际化 (i18n) 数据。
# 参数: 无
# 返回值: 无 (直接修改全局变量 I18N_DATA)
# =============================================================================
function load_i18n() {
    local lang="${LANG_PARAM#*=}" # 从 LANG_PARAM 中提取语言代码

    # 如果存在脚本配置文件，则尝试从文件中获取语言代码
        if [[ -z "${lang}" && -f "${SCRIPT_CONFIG_PATH}" ]]; then
            if cmd_exists "jq"; then
            lang="$(jq -r '.language' "${SCRIPT_CONFIG_PATH}" 2>/dev/null)"
        fi
    fi

    # 如果语言设置为 "auto"，则使用系统环境变量 LANG 的第一部分作为语言代码
    if [[ "$lang" == "auto" ]]; then
        lang=$(echo "$LANG" | cut -d'_' -f1)
    fi

    # 如果语言设置为 "en"，则加载英文提示信息
    if [[ "$lang" == "en" ]]; then
        I18N_DATA=(
            ['error']='Error'
            ['root']='This script must be run as root'
            ['supported']='Not supported OS'
            ['ubuntu']='Not supported OS, please change to Ubuntu 16+ and try again.'
            ['debian']='Not supported OS, please change to Debian 9+ and try again.'
            ['centos']='Not supported OS, please change to CentOS 7+ and try again.'
            ['tip']='Update Notice'
            ['new']='A new version of the script is available. Do you want to update?'
            ['force']='Force updating the script to the latest commit'
            ['now']='Update now? [Y/n]'
            ['promptly']='Please update the script promptly.'
            ['completed']='Update completed'
            ['download']='Downloading'
            ['failed']='Download failed'
            ['downloaded']='The file has been downloaded to'
            ['cron_disabled']='No enabled and running cron service detected: automatic GeoData updates, automatic Nginx updates and certificate renewal will not run. Please fix it with: systemctl enable --now cron'
            ['installer_update_failed']='Failed to update the installer itself; the previous version is kept and still usable. The new code is already in place under the project directory and will take effect on the next run'
            ['config_init_failed']='Failed to download or verify the default script configuration, cannot initialize. Please check your network and retry; you can also set a GH_PROXY prefix and rerun'
        )
    fi
}

# =============================================================================
# 函数名称: _error
# 功能描述: 以红色打印错误信息并退出脚本。
# 参数:
#   $@: 错误消息内容
# 返回值: 无 (直接打印到标准错误输出 >&2，然后 exit 1)
# =============================================================================
function _error() {
    printf "${RED}[%s] ${NC}" "${I18N_DATA['error']}"
    printf -- "%s" "$@"
    printf "\n"
    exit 1
}

# =============================================================================
# 函数名称: check_os
# 功能描述: 检查操作系统是否受支持 (脚本运行的【通用基线】)。
#
# 注意: 这是 install.sh 单文件自包含副本, 与 service/nginx.sh 的 check_os 同名但
#       基线**不同**是刻意的 —— 那边是"编译 Nginx"的专项要求 (Ubuntu>=20/Debian>=10,
#       受构建依赖的库版本约束), 这里是"本脚本能否运行"的通用要求。两者不要互相
#       对齐: 一旦把通用基线抬到 20, Ubuntu 18 用户将连脚本都装不上; 反之若把编译
#       基线降到 16, 又会在编译中途因库版本不足失败。
# 参数: 无
# 返回值: 无 (如果不支持则调用 _error 退出)
# =============================================================================
function check_os() {
    # 取一次版本号复用, 避免每个分支各 fork 一次子进程
    local ver
    ver="$(_os_ver)"

    # 版本号取不到时不做"过低"判定:
    # _os_ver 依赖 /etc/os-release 等文件的文本解析, 在精简镜像/非标准发行版上可能
    # 返回空。空串参与 -lt 会被算术上下文当成 0, 于是 <16 成立 —— 明明只是"识别不出
    # 版本", 却把用户拦在门外并报出误导性的"版本过低"。识别不出时应放行, 让后续
    # 依赖检查去暴露真实问题。
    local ver_unknown=0
    [[ -n "${ver}" ]] || ver_unknown=1

    # 检查操作系统类型和版本
    case "$(_os)" in
    # CentOS 系列
    centos)
        # 检查版本号是否大于等于 7
        if [[ "${ver_unknown}" -eq 0 && "${ver}" -lt 7 ]]; then
            _error "${I18N_DATA['centos']}"
        fi
        ;;
    # Ubuntu 系列
    ubuntu)
        # 检查版本号是否大于等于 16
        if [[ "${ver_unknown}" -eq 0 && "${ver}" -lt 16 ]]; then
            _error "${I18N_DATA['ubuntu']}"
        fi
        ;;
    # Debian 系列
    debian)
        # 检查版本号是否大于等于 9
        if [[ "${ver_unknown}" -eq 0 && "${ver}" -lt 9 ]]; then
            _error "${I18N_DATA['debian']}"
        fi
        ;;
    # 其他不支持的操作系统
    *)
        _error "${I18N_DATA['supported']}"
        ;;
    esac
}

# =============================================================================
# 函数名称: check_dependencies
# 功能描述: 检查必要的依赖软件是否已安装。
# 参数: 无
# 返回值: 0-所有依赖都已安装 1-有依赖缺失 (由命令检查结果决定)
# =============================================================================
function check_dependencies() {
    local packages=("ca-certificates" "openssl" "curl" "wget" "git" "jq" "tzdata" "qrencode" "socat")
    local missing_packages=()

    # 根据操作系统类型检查特定的软件包
    case "$(_os)" in
    centos)
        # 为 CentOS/RHEL 添加系统管理工具
        packages+=("crontabs" "util-linux" "iproute" "procps-ng" "bind-utils")
        # 遍历包列表，检查是否安装
        for pkg in "${packages[@]}"; do
            if ! rpm -q "$pkg" &>/dev/null; then
                missing_packages+=("$pkg") # 如果未安装，添加到缺失列表
            fi
        done
        ;;
    debian | ubuntu)
        # 为 Debian/Ubuntu 添加系统管理工具
        packages+=("cron" "bsdmainutils" "iproute2" "procps" "dnsutils")
        # 遍历包列表，检查是否安装
        for pkg in "${packages[@]}"; do
            if ! dpkg -s "$pkg" &>/dev/null; then
                missing_packages+=("$pkg") # 如果未安装，添加到缺失列表
            fi
        done
        ;;
    esac

    # 如果缺失包列表为空，则返回 0 (成功)
    [[ ${#missing_packages[@]} -eq 0 ]]
}

# =============================================================================
# 函数名称: install_dependencies
# 功能描述: 根据操作系统类型安装必要的依赖包。
# 参数: 无
# 返回值: 无 (执行包管理器命令安装软件)
# =============================================================================
function install_dependencies() {
    local packages=("ca-certificates" "openssl" "curl" "wget" "git" "jq" "tzdata" "qrencode" "socat")

    # 根据操作系统类型添加特定的软件包并执行安装
    case "$(_os)" in
    centos)
        # 为 CentOS/RHEL 添加系统管理工具
        packages+=("crontabs" "util-linux" "iproute" "procps-ng" "bind-utils")
        # 检查是否使用 dnf 包管理器 (较新版本)
        if cmd_exists "dnf"; then
            # 使用 dnf 更新系统并安装软件包
            # 注: 依赖安装失败统一收敛, 由后续"命令是否存在"自检兜底,
            #     避免 set -e 因个别包在特定仓库缺失而提前中断整个安装流程
            dnf update -y || true
            dnf install -y dnf-plugins-core || true
            dnf update -y || true
            for pkg in "${packages[@]}"; do
                dnf install -y "${pkg}" || true
            done
        else
            # 使用 yum 包管理器 (较旧版本)
            yum update -y || true
            yum install -y epel-release yum-utils || true
            yum update -y || true
            for pkg in "${packages[@]}"; do
                yum install -y "${pkg}" || true
            done
        fi
        ;;
    ubuntu | debian)
        # 为 Debian/Ubuntu 添加系统管理工具
        packages+=("cron" "bsdmainutils" "iproute2" "procps" "dnsutils")
        # 更新包列表并安装软件包
        apt update -y || true
        for pkg in "${packages[@]}"; do
            apt install -y "${pkg}" || true
        done
        ;;
    esac
}

# =============================================================================
# 函数名称: check_cron_service
# 功能描述: 检查 cron 守护进程是否已启用且正在运行。
#           本项目三条定时任务全部依赖 crond: GeoData 每日更新 (6:30)、
#           Nginx 每日检查更新 (3:00)、acme.sh 证书续期。crond 被禁用时它们会
#           静默不执行, 其中证书不续签会让 SNI 模式在证书到期后直接断服,
#           故在此显式告警。仅告警, 不擅自动用户系统服务的启停与 enable 状态。
# 参数: 无
# 返回值: 0 (无论检查结果如何都不阻断安装流程)
# =============================================================================
function check_cron_service() {
    # 非 systemd 环境 (如容器) 无法用 systemctl 判定, 直接跳过
    [[ -d /run/systemd/system ]] || return 0
    # Debian/Ubuntu 的单元名是 cron, CentOS/RHEL 是 crond; 任一"已启用且运行中"即视为正常
    local unit=''
    for unit in cron crond; do
        if systemctl -q is-enabled "${unit}" >/dev/null 2>&1 && systemctl -q is-active "${unit}" >/dev/null 2>&1; then
            return 0
        fi
    done
    echo -e "${YELLOW}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['cron_disabled']}" >&2
    return 0
}

# =============================================================================
# 函数名称: download_github_files
# 功能描述: 从 GitHub API 下载指定目录的文件。
# 参数:
#   $1: 本地目标目录
#   $2: GitHub API 项目 URL
# 返回值: 无 (执行文件下载和解压过程)
# =============================================================================
function download_github_files() {
    local target_dir="${1:-}"     # 本地目标目录
    local github_api_url="${2:-}" # GitHub API 项目 URL

    mkdir -p "${target_dir}"
    cd "${target_dir}"

    echo -e "${GREEN}[${I18N_DATA['download']}]${NC} ${github_api_url}"
    # 先整包落盘再解压 (不再 `curl | tar`):
    # 管道模式下 curl 一旦重试就会把重复数据写进 tar, 归档必然损坏;
    # 落盘后可安全启用 --retry, 并在解压前做 gzip 结构体检。
    local pkg_file=".xray-script-personal-use-only-pkg.tar.gz" # 已在 target_dir 内 (见上方 cd, 用相对名避免相对路径错位)
    if ! curl -fsSL --connect-timeout 15 --max-time 300 --retry 2 -o "${pkg_file}" "$(_gh_url "${github_api_url}")"; then
        rm -f "${pkg_file}"
        # 如果下载失败，则调用 _error 退出
        _error "${I18N_DATA['failed']}: ${github_api_url}"
    fi
    # gzip 结构体检: 拦截截断包与伪装成 tar.gz 的错误页
    if ! gzip -t "${pkg_file}" 2>/dev/null; then
        rm -f "${pkg_file}"
        _error "${I18N_DATA['failed']}: ${github_api_url}"
    fi
    # 解压 (strip 掉 GitHub tarball 的顶层目录)
    if ! tar -xzf "${pkg_file}" --strip-components=1; then
        rm -f "${pkg_file}"
        _error "${I18N_DATA['failed']}: ${github_api_url}"
    fi
    rm -f "${pkg_file}"
}

# =============================================================================
# 函数名称: download_xray_script_files
# 功能描述: 下载 xray-script-personal-use-only 项目的全部文件。
# 参数:
#   $1: 本地目标根目录
#   $2: 可选, 要下载的 commit SHA 或分支名 (缺省用跟踪分支 XRAY_SCRIPT_REF)。
#       传入 SHA 可把下载内容精确钉在某个提交上, 与随后记录的 commit 严格一致
#       (否则下载期间上游恰好有新提交, 记录值与实际内容就会错位)。
# 返回值: 无 (调用 download_github_files 下载项目)
# =============================================================================
function download_xray_script_files() {
    local target_dir="${1:-}"
    local ref="${2:-}"
    # 未指定引用时退回跟踪分支
    [[ -n "${ref}" ]] || ref="${XRAY_SCRIPT_REF}"
    # 定义 GitHub API 项目 URL (tarball/<ref> 同时接受分支名与 commit SHA)
    local script_github_api="${XRAY_SCRIPT_TARBALL_API}/${ref}"

    download_github_files "${target_dir}" "${script_github_api}"
}

# =============================================================================
# 函数名称: get_remote_commit_sha
# 功能描述: 查询远端跟踪分支的最新 commit SHA。
#           自动更新以 commit 为判据 (而非版本号), 上游只要产生新提交即可被发现,
#           无需再手工改动任何版本号。
# 参数: 无
# 输出: 40 位 commit SHA
# 返回值: 0-成功 1-网络失败或响应不可解析 (调用方据此跳过更新检查)
# =============================================================================
function get_remote_commit_sha() {
    local body='' sha=''

    # 拉取 commits/<ref> 响应 (顶层第一个字段即 sha)
    body="$(curl -fsSL --connect-timeout 10 --max-time 30 --retry 2 "$(_gh_url "${XRAY_SCRIPT_COMMIT_API}")")" || return 1

    # 首选 jq 解析; 无 jq 时退回正则提取, 两种写法都只取顶层 sha
    if cmd_exists "jq"; then
        sha="$(printf '%s' "${body}" | jq -r '.sha // empty' 2>/dev/null)" || sha=''
    fi
    if [[ ! "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
        sha="$(printf '%s' "${body}" | grep -oE '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]{40}"' | head -n1 | cut -d'"' -f4)" || sha=''
    fi

    # 格式校验: 拦截错误页 / 空响应, 避免把异常当成合法 SHA 记入本地
    [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || return 1
    printf '%s' "${sha}"
}

# =============================================================================
# 函数名称: read_local_commit_sha
# 功能描述: 读取本地记录的已安装 commit SHA。
# 参数: 无
# 输出: 40 位 commit SHA
# 返回值: 0-读取成功 1-文件不存在或内容非法 (旧版脚本安装的机器尚无记录)
# =============================================================================
function read_local_commit_sha() {
    local sha=''

    if [[ -r "${SCRIPT_COMMIT_PATH}" ]]; then
        sha="$(head -n1 "${SCRIPT_COMMIT_PATH}" 2>/dev/null | tr -d '[:space:]')" || sha=''
    fi
    [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || return 1
    printf '%s' "${sha}"
}

# =============================================================================
# 函数名称: save_local_commit_sha
# 功能描述: 记录本次实际安装到本地的 commit SHA (下次据此判断是否需要更新)。
# 参数:
#   $1: commit SHA
# 返回值: 0 (SHA 为空或格式非法时静默跳过; 写盘失败也不阻断安装流程,
#            代价仅是下次运行多检查一次)
# =============================================================================
function save_local_commit_sha() {
    local sha="${1:-}"

    # 只在拿到合法 SHA 时记录: 宁可下次多检查一遍, 也不写入错误判据
    [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || return 0
    if [[ ! -d "${SCRIPT_CONFIG_DIR}" ]]; then
        (umask 077 && mkdir -p "${SCRIPT_CONFIG_DIR}")
    fi
    printf '%s\n' "${sha}" | _atomic_write "${SCRIPT_COMMIT_PATH}" || true
}

# =============================================================================
# 函数名称: _sync_script_version_label
# 功能描述: 把界面展示用的版本号同步为新项目自带的版本号。
#           自本版起版本号仅用于展示, 更新判据改为 commit, 因此无需再手工维护。
# 参数: 无 (使用全局变量 PROJECT_ROOT 与 SCRIPT_CONFIG_PATH)
# 返回值: 无
# =============================================================================
function _sync_script_version_label() {
    local repo_config="${PROJECT_ROOT}/config.json" # 新项目自带的配置 (版本号来源)
    local repo_version=''
    local local_version=''

    # 任一文件缺失或 jq 不可用时直接跳过, 不阻断安装
    [[ -f "${repo_config}" && -f "${SCRIPT_CONFIG_PATH}" ]] || return 0
    repo_version="$(jq -r '.version // empty' "${repo_config}" 2>/dev/null)" || repo_version=''
    [[ -n "${repo_version}" ]] || return 0
    local_version="$(jq -r '.version // empty' "${SCRIPT_CONFIG_PATH}" 2>/dev/null)" || local_version=''
    # 版本号一致时不做无谓写入
    [[ "${local_version}" != "${repo_version}" ]] || return 0

    # 注: 原写法 `jq ... "${F}" | _atomic_write "${F}"` 是**同文件管道写**, 有实质风险:
    #     jq 一旦失败(输入非法 JSON / 读取异常)就输出空内容, 而 _atomic_write 会忠实
    #     地把收到的 0 字节写入临时文件并 rename 覆盖原路径 —— config.json 被**清空**,
    #     且失败分支只打印一句提示, 用户往往事后才发现配置没了。
    #     改为"先取结果 -> 判空 -> 再写", 与 main.sh 中既有的正确写法保持一致:
    #     写失败或内容为空都只跳过本次同步(版本号仅用于展示), 绝不覆盖原文件。
    local new_config=''
    new_config="$(jq --arg v "${repo_version}" '.version = $v' "${SCRIPT_CONFIG_PATH}" 2>/dev/null || true)"
    if [[ -z "${new_config}" ]]; then
        echo -e "${YELLOW}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['promptly']}" >&2
        return 0
    fi
    if ! printf '%s\n' "${new_config}" | _atomic_write "${SCRIPT_CONFIG_PATH}"; then
        echo -e "${YELLOW}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['promptly']}" >&2
    fi
}

# =============================================================================
# 函数名称: _update_xray_script
# 功能描述: 下载指定提交并替换本地项目目录, 记录 commit, 然后重启脚本。
# 参数:
#   $1: 目标 commit SHA (为空时退回跟踪分支)
# 返回值: 无 (下载失败即 _error 退出; 成功后重启脚本并 exit 0)
# =============================================================================
function _update_xray_script() {
    local target_sha="${1:-}"

    # 切换到 HOME 目录
    cd "${HOME}"
    # 定义临时目录 (先清空, 避免上次失败残留的文件混进新版本)
    local temp_dir="${SCRIPT_CONFIG_DIR}/xray-script-personal-use-only-temp"
    rm -rf "${temp_dir}"
    mkdir -vp "${temp_dir}"
    # 下载最新文件到临时目录 (钉在目标 commit 上, 保证与随后记录的 commit 一致)
    download_xray_script_files "${temp_dir}" "${target_sha}"
    # 升级前把旧项目目录重命名为同级备份 (而非直接删除), 失败时可回滚。
    # 安全加固: 备份名改用 mktemp -u 生成的不可预测随机后缀 (替代原 PID 名 ${PROJECT_ROOT}.old.$$),
    #           消除 root 下"可预测临时名被预植符号链接"的 TOCTOU 竞态 (CWE-367);
    #           并在删除/移动前显式拒绝已存在的符号链接, 防 rm -rf/mv 跟随链接穿透目标树。
    local backup_dir
    backup_dir="$(mktemp -u "${PROJECT_ROOT}.old.XXXXXX" 2>/dev/null || printf '%s.old.%s' "${PROJECT_ROOT}" "$$")"
    if [[ -L "${backup_dir}" ]]; then
        _error "${I18N_DATA['failed']}: 检测到备份路径被符号链接占用, 已中止自更新以防误删数据"
        return 1
    fi
    if [[ -d "${PROJECT_ROOT}" ]]; then
        rm -rf "${backup_dir}" 2>/dev/null || true
        mv -f "${PROJECT_ROOT}" "${backup_dir}" 2>/dev/null || backup_dir=''
    fi
    # 移动临时目录成为新项目目录; 失败则把备份还原回去, 避免项目永久丢失
    if ! mv -f "${temp_dir}" "${PROJECT_ROOT}" 2>/dev/null; then
        if [[ -n "${backup_dir}" && -d "${backup_dir}" ]]; then
            mv -f "${backup_dir}" "${PROJECT_ROOT}" 2>/dev/null || true
        fi
        _error "${I18N_DATA['failed']}: ${PROJECT_ROOT}"
    fi
    # 更新当前脚本文件 (原子替换: 先写同目录临时文件, 再 rename 覆盖)
    #
    # 为什么不能"先 rm 再 cp": 两步之间一旦 cp 失败 (磁盘满 / 权限 / 新包里缺该文件),
    # 安装器就永久消失, 用户连"重跑一次自更新"的入口都没了 —— 而此时新代码其实已经
    # 在 ${PROJECT_ROOT} 就位, 本可以下次运行自然生效, 不该为此搭上整个入口。
    # 直接 cp 原地覆盖同样不行: 当前进程正按偏移读取这个脚本, 原地覆写会让 bash
    # 后续读到新旧混杂的内容; rename 是原子的, 执行中的进程继续持有旧 inode, 不受影响。
    # 原子替换安装器: 用 mktemp 生成 0600 随机临时文件 (替代原固定名 ${CUR_FILE}.new.$$),
    # 避免 root 下固定名被预植符号链接导致 cp 穿透写入目标之外的文件; 写毕 mv -f 原子覆盖。
    local self_new
    self_new="$(umask 077; mktemp "${CUR_DIR}/.${CUR_FILE}.new.XXXXXX" 2>/dev/null || printf '%s/.%s.new.%s' "${CUR_DIR}" "${CUR_FILE}" "$$")"
    if cp -f "${PROJECT_ROOT}/install.sh" "${self_new}" 2>/dev/null &&
        mv -f "${self_new}" "${CUR_DIR}/${CUR_FILE}" 2>/dev/null; then
        : # 替换成功
    else
        # 替换失败: 清理临时文件, 保留旧安装器并明确告知 (不中断, 新代码下次生效)
        rm -f "${self_new}" 2>/dev/null || true
        echo -e "${YELLOW}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['installer_update_failed']}" >&2
    fi
    # 界面展示的版本号随新代码同步
    _sync_script_version_label
    # 记录本次安装的 commit, 作为下次"是否需要更新"的判据
    save_local_commit_sha "${target_sha}"
    # 升级成功, 清理旧项目备份
    [[ -n "${backup_dir}" && -d "${backup_dir}" ]] && rm -rf "${backup_dir}" || true
    # 打印更新完成信息
    echo -e "${GREEN}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['completed']}"
    # 重启脚本
    bash "${CUR_DIR}/${CUR_FILE}"
    # 退出脚本，避免重复执行
    exit 0
}

# =============================================================================
# 函数名称: check_xray_script_update
# 功能描述: 比对「本地已安装的 commit」与「远端跟踪分支的最新 commit」,
#           有差异 (或本地尚无记录) 时提示用户更新; --force-update 则直接更新。
#           判据是 commit 而非版本号: 上游任何一次提交都能被发现, 不再依赖手工改版本号。
# 参数: 无 (直接使用全局变量 PROJECT_ROOT)
# 返回值: 无
# =============================================================================
function check_xray_script_update() {
    local local_sha=''
    local remote_sha=''
    local is_update='n' # 初始化更新标志为 'n' (不更新)

    # 读取本地记录 (--force-update 时无需本地记录, 失败也不影响)
    local_sha="$(read_local_commit_sha)" || local_sha=''
    remote_sha="$(get_remote_commit_sha)" || remote_sha=''

    # 取不到远端 commit (网络抖动等) 时静默跳过, 避免把"网络失败"误报成"发现新版本"
    # 例外: 显式 --force-update 是用户的明确要求, 失败必须如实告知, 不能静默装作无事发生
    if [[ -z "${remote_sha}" ]]; then
        if [[ "${FORCE_UPDATE}" -eq 1 ]]; then
            echo -e "${YELLOW}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['failed']}: ${XRAY_SCRIPT_COMMIT_API}" >&2
        fi
        return 0
    fi

    if [[ "${FORCE_UPDATE}" -eq 1 ]]; then
        # 显式强制更新: 跳过比对与询问
        echo -e "${GREEN}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['force']}"
    elif [[ "${local_sha}" == "${remote_sha}" ]]; then
        # 已是最新提交, 无需处理
        return 0
    else
        # 本地与远端不一致 (含"本地尚无记录"的旧版安装), 提示用户更新
        echo -e "${GREEN}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['new']}"
        # 询问用户是否更新
        # 注: Ctrl+D/EOF 时 read 返回非 0, 兜底为 "n" (不更新)
        read -rp "${I18N_DATA['now']}" -e -i "Y" is_update || is_update="n"

        case "${is_update,,}" in # ${is_update,,} 转换为小写
        y | yes) ;;
        *)
            echo -e "${YELLOW}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['promptly']}"
            return 0
            ;;
        esac
    fi

    # 执行更新 (成功后内部会重启脚本并退出)
    _update_xray_script "${remote_sha}"
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
#           1. 解析命令行参数。
#           2. 加载国际化数据。
#           3. 检查 root 权限。
#           4. 检查操作系统。
#           5. 检查并安装依赖。
#           6. 处理项目目录和配置。
#           7. 启动主脚本。
# 参数:
#   $@: 所有命令行参数
# 返回值: 无 (协调调用其他函数完成整个安装流程)
# =============================================================================
function main() {
    # 解析命令行参数
    parse_args "$@"
    # 加载国际化数据
    load_i18n

    # 检查是否以 root 权限运行
    [[ $EUID -ne 0 ]] && _error "${I18N_DATA['root']}"

    # 检查操作系统
    check_os

    local is_first_run=0
    if [[ ! -f "${SCRIPT_CONFIG_PATH}" ]]; then
        is_first_run=1
    fi

    # 仅首次运行或显式强制时检查/安装依赖
    if [[ "${is_first_run}" -eq 1 || "${FORCE_CHECK_DEPS}" -eq 1 ]]; then
        # 检查依赖，如果缺失则安装
        if ! check_dependencies; then
            install_dependencies
        fi

        # 再次检查依赖 (安装后)
        if ! check_dependencies; then
            install_dependencies
        fi
    fi

    # cron 守护进程自检: 本项目的定时任务 (GeoData 更新/Nginx 更新/证书续期) 全部依赖它。
    # 放在依赖安装之后, 使首次安装时刚装好的 cron 包能先由包管理器完成 enable/start。
    # 每次运行都检查: crond 被事后禁用时同样需要告警。
    check_cron_service

    # 检查脚本配置目录和配置文件是否存在，如果不存在则创建并下载默认配置
    if [[ ! -d "${SCRIPT_CONFIG_DIR}" ]]; then
        (umask 077 && mkdir -p "${SCRIPT_CONFIG_DIR}")
    fi
    # 收紧配置目录权限, 避免同机其它用户读取其中的配置与密钥
    chmod 700 "${SCRIPT_CONFIG_DIR}"
    if [[ ! -f "${SCRIPT_CONFIG_PATH}" ]]; then
        # 先下载到临时文件并校验 JSON 有效, 再原子写入 (写入权限统一收为 600)
        local default_config_tmp="${SCRIPT_CONFIG_PATH}.download"
        if wget --timeout=30 --tries=2 -q -O "${default_config_tmp}" "$(_gh_url "${XRAY_SCRIPT_CONFIG_URL}")" &&
            jq -e . "${default_config_tmp}" >/dev/null 2>&1; then
            _atomic_write "${SCRIPT_CONFIG_PATH}" <"${default_config_tmp}"
        else
            # 下载/校验失败必须显式终止, 不能静默跳过:
            # 后续流程会把 SCRIPT_CONFIG_PATH 当作"已存在"继续用 —— 缺文件时
            # `jq --arg path ... "${SCRIPT_CONFIG_PATH}"` 报错、取到空结果, 再被原子写
            # 回磁盘, 于是生成一个**空配置文件**; 之后再跑任何菜单都会以 jq 解析失败
            # 的形式崩溃, 而真实原因(这次下载失败)早已淹没在输出里。
            rm -f "${default_config_tmp}"
            _error "${I18N_DATA['config_init_failed']}"
        fi
        rm -f "${default_config_tmp}"
    fi

    # 处理命令行参数: 快速安装 / 自定义目录 / "无交互直达"参数
    #
    # 为什么要有第三类: --health / --export-config / --import-config / --bbr / --net-status
    # 等参数是刻意设计成"不经菜单直接调用"的 (见 core/main.sh 的 case 与注释), 卖点正是能
    # 放进 cron 与脚本化调用。但入口此前只透传了上面三项快速安装 —— `bash xray-script-personal-use-only.sh
    # --health` 会把参数静默丢掉、直接落回交互菜单。这里把它们 (连同各自的附加参数) 原样
    # 收集起来, 安装完成后整体转发给 core/main.sh。
    local -a DIRECT_ARGS=()
    local DIRECT_CALL=''
    while [[ $# -gt 0 ]]; do
        case "${1:-}" in
        # 快速安装选项
        --vision | --xhttp | --fallback)
            QUICK_INSTALL="${1:-}"
            ;;
        # 自定义安装目录选项
        -d)
            shift
            PROJECT_ROOT="${1:-}"
            ;;
        # 无交互直达参数 (与 core/main.sh 的 case 一一对应)
        --health | --net-status | --bbr | --net-tune | --nofile-limit | --export-config | --import-config | --subscription | --start | --stop | --restart | --share)
            DIRECT_CALL="${1:-}"
            DIRECT_ARGS+=("${1:-}")
            ;;
        # 安装器专用参数: 不属于 core 侧, 显式"不转发" —— 若落到下面的 *) 兜底里,
        # 会被当成直达参数的附加项一起塞给 core/main.sh, 那里的 case 认不出它就会
        # 落回交互菜单, 反而把 --health 这类诉求弄丢。它们由 parse_args 单独处理。
        --lang=* | --check-deps | --force-update)
            : # 有意留空: 不转发, 也不终止直达参数的收集
            ;;
        *)
            # 只吸收"直达参数之后"的附加项 (如 --with-docker / --yes / 归档路径);
            # 未出现直达参数时不收集, 避免把无关参数带出去
            if [[ -n "${DIRECT_CALL}" ]]; then
                DIRECT_ARGS+=("${1:-}")
            fi
            ;;
        esac
        shift
    done

    # 从脚本配置文件中读取已记录的安装路径
    local script_path
    script_path="$(jq -r '.path' "${SCRIPT_CONFIG_PATH}" || true)"
    # 如果配置文件中没有记录路径，且命令行也未指定，则使用默认路径
    if [[ -z "${script_path}" && -z "${PROJECT_ROOT}" ]]; then
        PROJECT_ROOT="/usr/local/${SCRIPT_NAME}" # 设置默认项目根目录
        # 将默认路径更新到脚本配置文件中
        SCRIPT_CONFIG="$(jq --arg path "${PROJECT_ROOT}" '.path = $path' "${SCRIPT_CONFIG_PATH}")"
        printf '%s\n' "${SCRIPT_CONFIG}" | _atomic_write "${SCRIPT_CONFIG_PATH}"
    # 如果配置文件中已有记录的路径，则使用该路径
    elif [[ -n "${script_path}" ]]; then
        PROJECT_ROOT="${script_path}"
    # 如果配置文件中没有路径，但命令行指定了路径，则使用命令行指定的路径并更新配置文件
    elif [[ -n "${PROJECT_ROOT}" ]]; then
        # 将命令行指定的路径更新到脚本配置文件中
        SCRIPT_CONFIG="$(jq --arg path "${PROJECT_ROOT}" '.path = $path' "${SCRIPT_CONFIG_PATH}")"
        printf '%s\n' "${SCRIPT_CONFIG}" | _atomic_write "${SCRIPT_CONFIG_PATH}"
    fi

# 设置核心脚本目录 (其余子目录由各 core 脚本自行解析, 不在此集中持有)
    CORE_DIR="${PROJECT_ROOT}/core"

    # 检查项目根目录是否存在
    if [[ -d "${PROJECT_ROOT}" ]]; then
        # 已安装: 比对远端最新 commit, 决定是否需要更新
        check_xray_script_update
    else
        # 未安装: 直接下载远端最新提交 (顺带取一次 SHA 钉住版本), 并记录该 commit,
        # 这样首次安装后不会在下次运行时被误判为"需要更新"
        local init_sha=''
        init_sha="$(get_remote_commit_sha)" || init_sha=''
        download_xray_script_files "${PROJECT_ROOT}" "${init_sha}"
        save_local_commit_sha "${init_sha}"
        _sync_script_version_label
    fi

    # 检查配置文件中的语言设置
    local lang
    lang="$(jq -r '.language' "${SCRIPT_CONFIG_PATH}" || true)"
    if [[ -z "${lang}" && -z "${LANG_PARAM}" ]]; then
        # 如果语言未设置且未通过命令行指定，则运行菜单脚本选择语言
        # 注: menu.sh 的退出码是"用户选择的语言编号"(2=英文), 非 0 属正常业务语义;
        #     必须本地接住, 否则用户一选完语言 set -e 就会中断整个安装引导流程。
        local lang_rc=0
        bash "${CORE_DIR}/menu.sh" '--language' || lang_rc=$?
        case ${lang_rc} in
        2) LANG_PARAM="en" ;; # 选择英文
        *) LANG_PARAM="zh" ;; # 默认中文
        esac
        # 更新配置文件中的语言设置
        SCRIPT_CONFIG="$(jq --arg language "${LANG_PARAM}" '.language = $language' "${SCRIPT_CONFIG_PATH}")"
        printf '%s\n' "${SCRIPT_CONFIG}" | _atomic_write "${SCRIPT_CONFIG_PATH}"
    elif [[ "${LANG_PARAM}" =~ ^--lang= ]]; then
        # 如果通过命令行指定了语言，则更新配置文件
        SCRIPT_CONFIG="$(jq --arg language "${LANG_PARAM#*=}" '.language = $language' "${SCRIPT_CONFIG_PATH}")"
        printf '%s\n' "${SCRIPT_CONFIG}" | _atomic_write "${SCRIPT_CONFIG_PATH}"
    fi

    # 启动主脚本: 无交互直达参数原样转发 (含其附加参数), 否则只传快速安装选项
    if [[ -n "${DIRECT_CALL}" ]]; then
        bash "${CORE_DIR}/main.sh" "${DIRECT_ARGS[@]}"
    else
        bash "${CORE_DIR}/main.sh" "${QUICK_INSTALL}"
    fi
}

# --- 脚本执行入口 ---
main "$@"
