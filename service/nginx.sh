#!/usr/bin/env bash
# =============================================================================
# 脚本名称: nginx.sh
# 脚本仓库: https://github.com/crudguy/xray-script-personal-use-only
# 功能描述: 用于从源代码编译、安装、更新和卸载 Nginx 的脚本。
#           支持集成最新版 OpenSSL 和可选的 Brotli 压缩模块。
#           负责管理 Nginx 的 systemd 服务配置。
# 作者: crudguy
# 时间: 2026-09-19
# 版本: 1.0.0
# 依赖: bash, curl, wget, git, gcc, make, awk, grep, sed, sort, tr, systemctl, jq,
#       dnf/yum/apt (用于安装编译依赖)
# 配置:
#   - ${TMPFILE_DIR}/: 用于下载和编译的临时工作目录
#   - ${NGINX_PATH}/: Nginx 的安装目录 (/usr/local/nginx)
#   - ${NGINX_LOG_PATH}/: Nginx 的日志目录 (/var/log/nginx)
#   - /etc/systemd/system/nginx.service: Nginx systemd 服务文件
#   - ${SCRIPT_CONFIG_DIR}/config.json: 用于读取语言设置 (language)
#   - ${I18N_DIR}/${lang}.json: 用于读取具体的提示文本 (i18n 数据文件)
# 相关链接:
#   - NGINX 官方文档: https://nginx.org/en/linux_packages.html
#   - NGINX 更新参考: https://zhuanlan.zhihu.com/p/193078620
#   - GCC 优化参考 (第三方外部仓库, 名称与本仓库旧称巧合相同, 非本项目): https://github.com/kirin10000/Xray-script
#   - Brotli 模块参考: https://www.nodeseek.com/post-37224-1
#   - ngx_brotli 模块: https://github.com/google/ngx_brotli
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
if [[ ! -f "${_XRAY_SCRIPT_DIR}/../core/_common.sh" ]]; then
    printf '\033[31m[错误]\033[0m 脚本文件不完整: 缺少 %s\n' "../core/_common.sh" >&2
    printf '        (请重新克隆仓库, 或运行 install.sh 重新下载)\n' >&2
    exit 1
fi
# shellcheck source=../core/_common.sh
source "${_XRAY_SCRIPT_DIR}/../core/_common.sh"

# 注册一个退出时执行的清理函数 egress
trap egress EXIT

# 定义项目中各个重要目录与配置文件的路径

# 创建一个唯一的临时目录用于编译工作，并在脚本退出时清理
# 如果创建失败则退出脚本
TMPFILE_DIR="$(mktemp -d -p "${PROJECT_ROOT}" -t nginxtemp.XXXXXXXX)" || exit 1
readonly TMPFILE_DIR

# 定义 Nginx 和其日志的安装/存储路径
# 注意: 这里的 NGINX_PATH 是「Nginx 安装目录」, 而 core/handler.sh 里的同名
#       NGINX_PATH 是「Nginx 服务管理脚本的文件路径」—— 同名不同义, 极易误改。
#       判断"是否已安装编译版 Nginx"请直接用 _common.sh 的 is_local_nginx_installed:
#       它走 _nginx_binary, 只认 NGINX_PREFIX_DIR, 因此下面同步派生一个同名只读变量
#       把两个命名空间对齐, 将来改安装前缀时只需改这一处。
readonly NGINX_PATH="/usr/local/nginx"        # Nginx 安装主目录 (非服务脚本路径!)
# shellcheck disable=SC2034  # 本变量由 core/_common.sh 的 _nginx_binary 跨文件读取, 非死赋值
readonly NGINX_PREFIX_DIR="${NGINX_PATH}"     # 与 core/_common.sh / _nginx_binary 对齐
readonly NGINX_LOG_PATH="/var/log/nginx"      # Nginx 日志目录

# --- 全局变量声明 ---
# 声明用于存储是否启用 Brotli 模块选项、语言参数和国际化数据的全局变量
# 注: 变量名统一为小写 is_enable_brotli —— 历史上声明用大写 IS_ENABLE_BROTLI 而引用用小写,
#     在 set -u 下"不带 --brotli 执行 --install"会因 unbound variable 直接失败。
declare is_enable_brotli='' # 是否启用 Brotli ('Y' 启用 / '' 不启用)
declare is_force_install='' # 是否强制重装 (--force 或 NGINX_FORCE_INSTALL=1)

# --- 第三方源码固定版本 (供应链防篡改) ---
# ngx_brotli: 固定到经验证的 commit (2023-10-09, 上游此后未变动);
# git checkout 该 commit 会同时锁定 brotli 子模块版本 (由父 commit 的 gitlink 决定)。
declare NGX_BROTLI_REF="${NGX_BROTLI_REF-a71f9312c2deb28875acc7bacfdd5695a111aa53}"
# --- Nginx 源码包签名校验 (PGP) ---
# nginx.org 对源码 tarball 只发布 detached PGP 签名 (.asc), 无 .sha256/.md5。
# 实测: 源码包由发布者个人 key 签名 (Roman Arutyunyan / Sergey Kandaurov /
# Sergey Budnevitch / Konstantin Pavlov), 而 nginx_signing.key 仅用于包与仓库签名,
# 故不做单 key 固定, 改为"官方公钥白名单 + 有效签名"双重判定。
# 白名单取自 https://nginx.org/en/pgp_keys.html 所列全部官方 key 的主指纹。
declare NGINX_SIGNING_FPRS="${NGINX_SIGNING_FPRS-43387825DDB1BB97EC36BA5D007C8D7C15D87369 D6786CE303D9A9022998DC6CC8464D549AF75C0A 7338973069ED3F443F4D37DFA64FD5B17ADB39A8 13C82A63B603576156E30A4EA0EA981B66B0D967 8540A6F18833A80E9C1653A42FD21310B49F6B46 573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62 9E9BE90EACBCDE69FE9B204CBCDCD8A38D88A2B3}"
declare NGINX_SIGNING_KEYS="${NGINX_SIGNING_KEYS-arut.key nginx_signing.key pluknet.key sb.key thresh.key}"
declare NGINX_SIGNING_SKIP="${NGINX_SIGNING_SKIP-}"
declare NGINX_KEYS_BASE_URL="${NGINX_KEYS_BASE_URL-https://nginx.org/keys}"
declare NGINX_DOWNLOAD_BASE_URL="${NGINX_DOWNLOAD_BASE_URL-https://nginx.org/download}"
# OpenSSL 源码官方入口 (www.openssl.org/source 会 301 跳转至 GitHub Releases;
# release tarball 随包提供官方 .sha256, 与 git archive 自动生成包不同, 可真摘要校验)
declare OPENSSL_SOURCE_BASE_URL="${OPENSSL_SOURCE_BASE_URL-https://www.openssl.org/source}"

# 声明用于存储编译器优化标志的全局数组
declare -a cflags=() # 存储 GCC 编译优化选项

# =============================================================================
# 函数名称: egress
# 功能描述: 在脚本退出时执行的清理操作。
#           主要用于删除临时工作目录。
# 参数: 无
# 返回值: 无 (直接执行清理命令)
# =============================================================================
function egress() {
    # 如果 swap 文件存在，则关闭 swap
    [[ -e "${TMPFILE_DIR}/swap" ]] && swapoff "${TMPFILE_DIR}/swap"
    # 删除临时工作目录
    rm -rf "${TMPFILE_DIR}"
}








# =============================================================================
# 函数名称: _error_detect
# 功能描述: 执行命令并检查其退出状态，如果失败则打印错误并退出。
# 参数:
#   $1: 要执行的命令字符串
# 返回值: 无 (执行成功或失败后退出)
# =============================================================================
function _error_detect() {
    local cmd="${1:-}"                                                                                 # 获取要执行的命令
    print_info "$(_i18n_sub '.nginx.compile.executing' '${cmd}' "${cmd}")" # 打印将要执行的命令
    # 用 if ! 包裹: 保留"失败即报错退出"语义, 同时让 set -e 不会抢在 print_error 之前退出
    if ! eval "${cmd}"; then
        print_error "$(_i18n_sub '.nginx.compile.fail_exec_cmd' '${cmd}' "${cmd}")" # 如果失败则打印错误并退出
    fi
}

# =============================================================================
# 函数名称: _verify_archive
# 功能描述: 校验已下载源码压缩包的完整性, 拦截截断文件与被替换的错误页。
#           1. gzip 容器完整性: `gzip -t` 能完整解压。
#           2. tar 结构完整性: `tar -tzf` 能列出成员清单。
#           3. 摘要校验: 给定期望 SHA256 时逐字节比对 (可选)。
# 参数:
#   $1: 待校验文件路径
#   $2 (可选): 期望的 SHA256 摘要 (十六进制, 忽略大小写)
# 返回值: 0-校验通过 1-校验失败
# 说明: nginx.org 仅发布 PGP 签名 (.asc) 而无 .sha256, OpenSSL 走的是 GitHub
#       archive 自动生成包 (无官方摘要), 故默认做容器 + 结构完整性校验;
#       需要强校验可通过环境变量固定摘要后传入 $2。
# =============================================================================
function _verify_archive() {
    local file="${1:-}"           # 待校验文件
    local expect_sha256="${2:-}"  # 期望摘要 (可选)
    local got_sha256=''

    [[ -s "${file}" ]] || return 1
    # gzip 容器完整性 (拦截截断下载与被替换的 HTML 错误页)
    gzip -t "${file}" >/dev/null 2>&1 || return 1
    # tar 结构完整性
    tar -tzf "${file}" >/dev/null 2>&1 || return 1
    # 摘要校验 (可选, 忽略大小写)
    if [[ -n "${expect_sha256}" ]]; then
        got_sha256="$(sha256sum "${file}" | cut -d' ' -f1)"
        [[ "${got_sha256,,}" == "${expect_sha256,,}" ]] || return 1
    fi
    return 0
}

# =============================================================================
# 函数名称: _verify_nginx_signature
# 功能描述: 校验 Nginx 源码包的官方 detached PGP 签名 (.asc)。
#           1. 下载并导入 nginx.org 官方发布的签名公钥。
#           2. `gpg --verify` 必须得到有效签名 (VALIDSIG)。
#           3. 签名者主 key 指纹必须命中官方白名单 (NGINX_SIGNING_FPRS)。
# 参数:
#   $1: 待校验的源码包路径
#   $2: 对应的 .asc 签名文件路径
# 返回值: 0-校验通过 1-校验失败
# 说明: 源码包由发布者个人 key 签名, key 会随发布者变化, 故用白名单而非单一
#       指纹固定; 白名单外的新 key 需更新 NGINX_SIGNING_FPRS, 或临时以
#       NGINX_SIGNING_SKIP=1 跳过。校验使用隔离的 GNUPGHOME, 不污染用户 keyring。
# =============================================================================
function _verify_nginx_signature() {
    local file="${1:-}" # 待校验源码包
    local asc="${2:-}"  # detached 签名文件

    command -v gpg >/dev/null 2>&1 || return 1
    [[ -s "${file}" && -s "${asc}" ]] || return 1

    # 隔离的 GNUPGHOME: 不污染用户 keyring, 每次编译独立
    local gnupg_home="${TMPFILE_DIR}/gnupg"
    mkdir -p "${gnupg_home}" && chmod 700 "${gnupg_home}"

    # 导入官方公钥 (单个失败不致命, 只要有能验签的 key 即可)
    local key_file key_url
    for key_file in ${NGINX_SIGNING_KEYS}; do
        key_url="${NGINX_KEYS_BASE_URL}/${key_file}"
        if curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 -o "${TMPFILE_DIR}/${key_file}" "${key_url}" 2>/dev/null \
            && [[ -s "${TMPFILE_DIR}/${key_file}" ]]; then
            GNUPGHOME="${gnupg_home}" gpg --batch --quiet --import "${TMPFILE_DIR}/${key_file}" >/dev/null 2>&1 || true
        fi
    done

    # 验签: status 走 fd 1, 人类可读输出丢弃
    local status_out=''
    status_out="$(GNUPGHOME="${gnupg_home}" gpg --batch --status-fd 1 --verify "${asc}" "${file}" 2>/dev/null)" || true

    # 必须存在有效签名
    grep -q '^\[GNUPG:\] VALIDSIG ' <<<"${status_out}" || return 1

    # 签名者主 key 指纹须命中白名单 (VALIDSIG 行最后一个字段即主 key 指纹)
    local primary_fpr='' allow=''
    primary_fpr="$(awk '/^\[GNUPG:\] VALIDSIG /{print $NF}' <<<"${status_out}" | head -1)"
    [[ -n "${primary_fpr}" ]] || return 1
    for allow in ${NGINX_SIGNING_FPRS}; do
        [[ "${primary_fpr^^}" == "${allow^^}" ]] && return 0
    done
    return 1
}

# =============================================================================
# 函数名称: _version_ge
# 功能描述: 比较两个版本号字符串，判断第一个是否大于等于第二个。
# 参数:
#   $1: 第一个版本号
#   $2: 第二个版本号
# 返回值: 0-第一个版本 >= 第二个版本 1-否则 (由 test 命令决定)
# =============================================================================
function _version_ge() {
    # 使用 sort -rV (版本号逆序排序) 来比较版本
    test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" == "${1:-}"
}

# =============================================================================
# 函数名称: _install
# 功能描述: 根据操作系统类型安装指定的软件包。
# 参数:
#   $@: 要安装的软件包名称列表
# 返回值: 无 (执行包管理器命令安装软件)
# =============================================================================
function _install() {
    local packages_name="$*"    # 获取所有要安装的包名 (标量上下文, "$@" 与 "$*" 等价)
    local installed_packages="" # 存储已安装的包列表

    case "$(_os)" in # 根据操作系统类型进行分支处理
    centos)
        # 检查是否使用 dnf 包管理器 (较新版本 CentOS/Fedora)
        if cmd_exists "dnf"; then
            # 添加必要的 dnf 插件和 EPEL 源
            packages_name="dnf-plugins-core epel-release epel-next-release ${packages_name}"
            installed_packages="$(dnf list installed 2>/dev/null)" # 获取已安装包列表
            # 针对 CentOS 9 的特殊处理
            if [[ -n "$(_os_ver)" && "$(_os_ver)" -eq 9 ]]; then
                # 启用 EPEL 和 Remi 仓库
                if [[ "${packages_name}" =~ geoip\-devel ]] && ! echo "${installed_packages}" | grep -iwq "geoip-devel"; then
                    dnf update -y || true
                    # 安装 EPEL 和 EPEL-Next 源
                    _error_detect "dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
                    _error_detect "dnf install -y https://dl.fedoraproject.org/pub/epel/epel-next-release-latest-9.noarch.rpm"
                    _error_detect "dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm"
                    # 启用 Remi 模块化仓库
                    _error_detect "dnf config-manager --set-enabled remi-modular"
            _error_detect "dnf update --refresh"
                    # 安装 GeoIP-devel，指定使用 Remi 仓库
                    dnf update -y || true
                    _error_detect "dnf --enablerepo=remi install -y GeoIP-devel"
                fi
            # 针对 CentOS 8 的特殊处理
            elif [[ -n "$(_os_ver)" && "$(_os_ver)" -eq 8 ]]; then
                # 禁用可能冲突的 container-tools 模块流
                if ! dnf module list 2>/dev/null | grep container-tools | grep -iwq "\[x\]"; then
                    _error_detect "dnf module disable -y container-tools"
                fi
            fi
            dnf update -y || true # 更新包列表
            for package_name in ${packages_name}; do
                if ! echo "${installed_packages}" | grep -iwq "${package_name}"; then
                    _error_detect "dnf install -y ${package_name}"
                fi
            done
        else
            # 使用 yum 包管理器 (较旧版本 CentOS)
            packages_name="epel-release yum-utils ${packages_name}"
            installed_packages="$(yum list installed 2>/dev/null)"
            yum update -y || true
            for package_name in ${packages_name}; do
                if ! echo "${installed_packages}" | grep -iwq "${package_name}"; then
                    _error_detect "yum install -y ${package_name}"
                fi
            done
        fi
        ;;
    # 处理 Debian 和 Ubuntu 系统
    ubuntu | debian)
        apt update -y || true                                    # 更新包列表
        installed_packages="$(apt list --installed 2>/dev/null)" # 获取已安装包列表
        for package_name in ${packages_name}; do
            if ! echo "${installed_packages}" | grep -iwq "${package_name}"; then
                _error_detect "apt install -y ${package_name}"
            fi
        done
        ;;
    esac
}

# =============================================================================
# 函数名称: check_os
# 功能描述: 检查操作系统是否受支持。
# 参数: 无
# 返回值: 无 (受支持则继续，不受支持则 print_error 退出)
# =============================================================================
function check_os() {
    [[ -z "$(_os)" ]] && print_error "$(_i18n '.nginx.os.unsupported_os')" "$(_i18n '.nginx.os.unsupported_os_hint')"

    case "$(_os)" in
    ubuntu)
        # Ubuntu 需要 20.04 或更高版本
        [[ -n "$(_os_ver)" && "$(_os_ver)" -lt 20 ]] && print_error "$(_i18n '.nginx.os.unsupported_ubuntu')"
        ;;
    debian)
        # Debian 需要 10 或更高版本
        [[ -n "$(_os_ver)" && "$(_os_ver)" -lt 10 ]] && print_error "$(_i18n '.nginx.os.unsupported_debian')"
        ;;
    centos)
        # CentOS/RHEL 需要 7 或更高版本
        [[ -n "$(_os_ver)" && "$(_os_ver)" -lt 7 ]] && print_error "$(_i18n '.nginx.os.unsupported_centos')"
        ;;
    *)
        # 其他识别到但不支持的系统
        print_error "$(_i18n '.nginx.os.unsupported_os')" "$(_i18n '.nginx.os.unsupported_os_hint')"
        ;;
    esac
}

# =============================================================================
# 函数名称: swap_on
# 功能描述: 创建并启用临时 swap 空间。
# 参数:
#   $1: 请求的 swap 大小 (MB)
# 返回值: 无 (执行 swap 文件创建和启用)
# =============================================================================
function swap_on() {
    local mem=${1:-}
    if [[ ${mem} -ne '0' ]]; then
        if dd if=/dev/zero of="${TMPFILE_DIR}/swap" bs=1M count=${mem} 2>&1; then
            chmod 0600 "${TMPFILE_DIR}/swap"
            mkswap "${TMPFILE_DIR}/swap"
            swapon "${TMPFILE_DIR}/swap"
        fi
    fi
}

# =============================================================================
# 函数名称: backup_files
# 功能描述: 备份指定目录下的所有文件。
# 参数:
#   $1: 要备份的目录路径
# 返回值: 无 (执行文件备份操作)
# =============================================================================
function backup_files() {
    local backup_dir="${1:-}"            # 获取要备份的目录路径
    local current_date
    current_date="$(date +%F)" # 获取当前日期 (YYYY-MM-DD)
    # 遍历目录中的所有文件
    for file in "${backup_dir}/"*; do
        if [[ -f "$file" ]]; then                                          # 检查是否为普通文件
            local file_name
            file_name="$(basename "$file")"                          # 获取文件名
            local backup_file="${backup_dir}/${file_name}_${current_date}" # 构造备份文件名
            mv "$file" "$backup_file"                                      # 重命名文件以进行备份
            echo "$(_i18n '.nginx.backup_files.backup'): ${file} -> ${backup_file}。"
        fi
    done
}

# =============================================================================
# 函数名称: compile_dependencies
# 功能描述: 安装编译 Nginx 所需的依赖包。
# 参数: 无
# 返回值: 无 (调用 _install 安装依赖)
# =============================================================================
function compile_dependencies() {
    # 打印安装依赖信息
    print_info "$(_i18n '.nginx.compile.install_deps')"
    # 安装基础工具和库
    _install ca-certificates curl wget gcc make git openssl tzdata socat
    case "$(_os)" in
    centos)
        # 安装 CentOS 特定的工具和开发库
        _install bind-utils gcc-c++ perl-IPC-Cmd perl-Getopt-Long perl-Data-Dumper perl-Time-Piece gnupg2
        _install pcre2-devel zlib-devel libxml2-devel libxslt-devel gd-devel geoip-devel perl-ExtUtils-Embed gperftools-devel perl-devel brotli-devel
        # 检查并安装 Perl 模块 FindBin
        if ! perl -e "use FindBin" &>/dev/null; then
            _install perl-FindBin
        fi
        ;;
    debian | ubuntu)
        # 安装 Debian/Ubuntu 特定的工具和开发库
        _install dnsutils g++ perl-base perl gnupg
        _install libpcre2-dev zlib1g-dev libxml2-dev libxslt1-dev libgd-dev libgeoip-dev libgoogle-perftools-dev libperl-dev libbrotli-dev
        ;;
    esac
}

# =============================================================================
# 函数名称: gen_cflags
# 功能描述: 生成优化的 C 编译器标志 (CFLAGS)。
# 参数: 无
# 返回值: 无 (直接修改全局数组 cflags)
# =============================================================================
function gen_cflags() {
    # 初始化 cflags 数组，包含基本优化
    cflags=('-g0' '-O3') # -g0: 不生成调试信息; -O3: 最高级别优化
    # 检查 GCC 是否支持特定标志，如果支持则添加到 cflags 数组中
    # 这些检查旨在移除可能导致性能下降或不必要的安全特性
    if gcc -v --help 2>&1 | grep -qw "\\-fstack\\-reuse"; then
        cflags+=('-fstack-reuse=all')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fdwarf2\\-cfi\\-asm"; then
        cflags+=('-fdwarf2-cfi-asm')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fplt"; then
        cflags+=('-fplt')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-ftrapv"; then
        cflags+=('-fno-trapv')
    fi
    # 异常处理相关
    if gcc -v --help 2>&1 | grep -qw "\\-fexceptions"; then
        cflags+=('-fno-exceptions')
    elif gcc -v --help 2>&1 | grep -qw "\\-fhandle\\-exceptions"; then
        cflags+=('-fno-handle-exceptions')
    fi
    # unwind 表相关
    if gcc -v --help 2>&1 | grep -qw "\\-funwind\\-tables"; then
        cflags+=('-fno-unwind-tables')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fasynchronous\\-unwind\\-tables"; then
        cflags+=('-fno-asynchronous-unwind-tables')
    fi
    # 栈检查相关
    if gcc -v --help 2>&1 | grep -qw "\\-fstack\\-check"; then
        cflags+=('-fno-stack-check')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fstack\\-clash\\-protection"; then
        cflags+=('-fno-stack-clash-protection')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fstack\\-protector"; then
        cflags+=('-fno-stack-protector')
    fi
    # 控制流保护相关
    if gcc -v --help 2>&1 | grep -qw "\\-fcf\\-protection="; then
        cflags+=('-fcf-protection=none')
    fi
    # 分割栈相关
    if gcc -v --help 2>&1 | grep -qw "\\-fsplit\\-stack"; then
        cflags+=('-fno-split-stack')
    fi
    # sanitizer 相关
    if gcc -v --help 2>&1 | grep -qw "\\-fsanitize"; then
        : >temp.c # 创建一个空的 C 文件用于测试
        if gcc -E -fno-sanitize=all temp.c >/dev/null 2>&1; then
            cflags+=('-fno-sanitize=all')
        fi
        rm temp.c # 删除临时文件
    fi
    # instrumentation 相关
    if gcc -v --help 2>&1 | grep -qw "\\-finstrument\\-functions"; then
        cflags+=('-fno-instrument-functions')
    fi
}

# =============================================================================
# 函数名称: source_compile
# 功能描述: 下载源码并编译 Nginx。
# 参数: 无
# 返回值: 无 (执行下载、配置和编译过程)
# =============================================================================
function source_compile() {
    cd "${TMPFILE_DIR}" # 切换到临时目录
    print_info "$(_i18n '.nginx.compile.fetch_versions')"
    # 从 GitHub API 获取最新的 Nginx release 标签名
    local nginx_version
    nginx_version="$(wget -qO- --timeout=30 --tries=2 "$(_gh_url 'https://api.github.com/repos/nginx/nginx/tags')" | grep 'name' | cut -d\" -f4 | grep 'release' | head -1 | sed 's/release/nginx/' || true)"
    # 白名单校验: 标签经 `sed 's/release/nginx/'` 后应为 nginx-x.y.z; 未校验就流入下方
    # eval (nginx.sh 内 _error_detect 的 `curl -o ${nginx_version}...`), 一旦 GitHub API
    # 被劫持/返回异常, 可能注入命令 (与 openssl_version 的约束对齐, 纵深防御)。
    if [[ -z "${nginx_version}" || ! "${nginx_version}" =~ ^nginx-[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        print_error "$(_i18n '.nginx.compile.bad_nginx_version')"
    fi
    # 获取最新的 OpenSSL 标签名 (格式为 openssl-x.y.z)
    local openssl_version
    openssl_version="openssl-$(wget -qO- --timeout=30 --tries=2 "$(_gh_url 'https://api.github.com/repos/openssl/openssl/tags')" | grep 'name' | cut -d\" -f4 | grep -Eoi '^openssl-([0-9]\.?){3}$' | head -1 || true)"

    # 生成编译器优化标志
    gen_cflags

    print_info "$(_i18n '.nginx.compile.download_nginx')"
    # 下载 Nginx 源码包 (nginx.org 只发布 PGP 签名 .asc 而无 .sha256)
    _error_detect "curl -fsSL --connect-timeout 15 --max-time 600 --retry 2 -o ${nginx_version}.tar.gz ${NGINX_DOWNLOAD_BASE_URL}/${nginx_version}.tar.gz"
    # 解压前先做完整性校验, 避免截断文件或错误页进入编译流程
    if ! _verify_archive "${nginx_version}.tar.gz" "${NGINX_TARBALL_SHA256:-}"; then
        print_error "$(_i18n_sub '.nginx.compile.verify_fail' '${file}' "${nginx_version}.tar.gz")"
    fi
    # 官方 detached PGP 签名校验 (nginx 源码只提供 PGP 签名, 无 .sha256/.md5)
    if [[ "${NGINX_SIGNING_SKIP}" == '1' ]]; then
        print_warn "$(_i18n '.nginx.compile.pgp_skipped')"
    elif cmd_exists "gpg"; then
        if ! curl -fsSL --connect-timeout 15 --max-time 60 --retry 2 \
            -o "${nginx_version}.tar.gz.asc" "${NGINX_DOWNLOAD_BASE_URL}/${nginx_version}.tar.gz.asc" 2>/dev/null \
            || ! _verify_nginx_signature "${nginx_version}.tar.gz" "${nginx_version}.tar.gz.asc"; then
            print_error "$(_i18n_sub '.nginx.compile.pgp_fail' '${file}' "${nginx_version}.tar.gz")"
        fi
        print_info "$(_i18n '.nginx.compile.pgp_ok')"
    else
        print_warn "$(_i18n '.nginx.compile.pgp_no_gpg')"
    fi
    # 解压 Nginx 源码
    tar -zxf "${nginx_version}.tar.gz"

    print_info "$(_i18n '.nginx.compile.download_openssl')"
    # 下载 OpenSSL 源码包 (注意 URL 结构; GitHub archive 自动生成包不发布官方摘要)
    # 官方源 (www.openssl.org/source) 会 301 跳转至 GitHub Releases 的 release tarball;
    # 与 git archive 自动生成包不同, release tarball 随包提供官方 .sha256, 可真摘要校验。
    local openssl_srcname="${openssl_version#*-}" # 形如 openssl-3.6.4 (官方发布名)
    _error_detect "curl -fsSL --connect-timeout 15 --max-time 900 --retry 2 -o ${openssl_version}.tar.gz ${OPENSSL_SOURCE_BASE_URL}/${openssl_srcname}.tar.gz"
    # 拉取官方摘要 (显式传入 OPENSSL_TARBALL_SHA256 时优先使用传入值)
    local openssl_expect="${OPENSSL_TARBALL_SHA256:-}"
    if [[ -z "${openssl_expect}" ]] \
        && curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 \
            -o "${openssl_version}.tar.gz.sha256" "${OPENSSL_SOURCE_BASE_URL}/${openssl_srcname}.tar.gz.sha256" 2>/dev/null; then
        openssl_expect="$(awk '{print $1; exit}' "${openssl_version}.tar.gz.sha256" 2>/dev/null | tr -d '\r\n')"
    fi
    # 摘要格式体检: 必须是 64 位十六进制, 否则视为不可用并回退结构校验
    if [[ ! "${openssl_expect}" =~ ^[0-9a-fA-F]{64}$ ]]; then
        openssl_expect=''
        print_warn "$(_i18n_sub '.nginx.compile.sha_unavailable' '${file}' "${openssl_version}.tar.gz")"
    fi
    # 解压前先做完整性校验 (有官方摘要时逐字节比对)
    if ! _verify_archive "${openssl_version}.tar.gz" "${openssl_expect}"; then
        print_error "$(_i18n_sub '.nginx.compile.verify_fail' '${file}' "${openssl_version}.tar.gz")"
    fi
    # 解压 OpenSSL 源码
    tar -zxf "${openssl_version}.tar.gz"
    # 探测实际顶层目录名 (官方 release 包为 openssl-x.y.z/, 与变量名不一致), 供 --with-openssl 引用
    local openssl_dir=''
    openssl_dir="$(tar -tzf "${openssl_version}.tar.gz" 2>/dev/null | head -1 | cut -d/ -f1)"
    [[ -n "${openssl_dir}" ]] || openssl_dir="${openssl_srcname}"

    # 如果启用了 Brotli，则下载并初始化 ngx_brotli 模块
    if [[ "${is_enable_brotli}" =~ ^[Yy]$ ]]; then
        print_info "$(_i18n '.nginx.compile.fetch_brotli')"
        # 固定到经验证的 commit 后再初始化子模块 (避免跟随上游默认分支)
        _error_detect "git clone $(_gh_url https://github.com/google/ngx_brotli) && cd ngx_brotli && git checkout ${NGX_BROTLI_REF} && git submodule update --init"
        cd "${TMPFILE_DIR}" # 返回临时目录
    fi

    # 进入 Nginx 源码目录
    cd "${nginx_version}"

    # 对 Nginx 源码进行一些 sed 修改，以优化 Perl 模块的编译
    sed -i "s/OPTIMIZE[ \\t]*=>[ \\t]*'-O'/OPTIMIZE          => '-O3'/g" src/http/modules/perl/Makefile.PL
    sed -i 's/NGX_PERL_CFLAGS="$CFLAGS `$NGX_PERL -MExtUtils::Embed -e ccopts`"/NGX_PERL_CFLAGS="`$NGX_PERL -MExtUtils::Embed -e ccopts` $CFLAGS"/g' auto/lib/perl/conf
    sed -i 's/NGX_PM_CFLAGS=`$NGX_PERL -MExtUtils::Embed -e ccopts`/NGX_PM_CFLAGS="`$NGX_PERL -MExtUtils::Embed -e ccopts` $CFLAGS"/g' auto/lib/perl/conf

    # 执行 Nginx 的 configure 脚本，设置各种编译选项和模块
    print_info "$(_i18n '.nginx.compile.configure')"
    if [[ "${is_enable_brotli}" =~ ^[Yy]$ ]]; then
        # 如果启用 Brotli，则添加 --add-module 选项
        ./configure --prefix="${NGINX_PATH}" --user=root --group=root --with-threads --with-file-aio --with-http_ssl_module --with-http_v2_module --with-http_v3_module --with-http_realip_module --with-http_addition_module --with-http_xslt_module=dynamic --with-http_image_filter_module=dynamic --with-http_geoip_module=dynamic --with-http_sub_module --with-http_dav_module --with-http_flv_module --with-http_mp4_module --with-http_gunzip_module --with-http_gzip_static_module --with-http_auth_request_module --with-http_random_index_module --with-http_secure_link_module --with-http_degradation_module --with-http_slice_module --with-http_stub_status_module --with-http_perl_module=dynamic --with-mail=dynamic --with-mail_ssl_module --with-stream --with-stream_ssl_module --with-stream_realip_module --with-stream_geoip_module=dynamic --with-stream_ssl_preread_module --with-google_perftools_module --add-module="../ngx_brotli" --with-compat --with-cc-opt="${cflags[*]}" --with-openssl="../${openssl_dir}" --with-openssl-opt="${cflags[*]}"
    else
        # 不启用 Brotli
        ./configure --prefix="${NGINX_PATH}" --user=root --group=root --with-threads --with-file-aio --with-http_ssl_module --with-http_v2_module --with-http_v3_module --with-http_realip_module --with-http_addition_module --with-http_xslt_module=dynamic --with-http_image_filter_module=dynamic --with-http_geoip_module=dynamic --with-http_sub_module --with-http_dav_module --with-http_flv_module --with-http_mp4_module --with-http_gunzip_module --with-http_gzip_static_module --with-http_auth_request_module --with-http_random_index_module --with-http_secure_link_module --with-http_degradation_module --with-http_slice_module --with-http_stub_status_module --with-http_perl_module=dynamic --with-mail=dynamic --with-mail_ssl_module --with-stream --with-stream_ssl_module --with-stream_realip_module --with-stream_geoip_module=dynamic --with-stream_ssl_preread_module --with-google_perftools_module --with-compat --with-cc-opt="${cflags[*]}" --with-openssl="../${openssl_dir}" --with-openssl-opt="${cflags[*]}"
    fi

    print_info "$(_i18n '.nginx.compile.swap')"
    # 创建并启用 512MB swap 空间以辅助编译
    swap_on 512

    print_info "$(_i18n '.nginx.compile.start_compile')"
    # 使用所有 CPU 核心并行编译
    _error_detect "make -j$(nproc)"
}


# =============================================================================
# 函数名称: source_install
# 功能描述: 编译并安装 Nginx。
# 参数: 无
# 返回值: 无 (执行编译和安装过程)
# =============================================================================
function source_install() {
    # 幂等保护: 已存在本项目编译版时不再重复编译安装 (避免覆盖正在运行的二进制);
    # 需要强制重装 (例如切换是否启用 Brotli) 时用 --force 或 NGINX_FORCE_INSTALL=1。
    if is_local_nginx_installed && [[ "${is_force_install}" != 'Y' && "${NGINX_FORCE_INSTALL:-}" != '1' ]]; then
        print_info "$(_i18n '.nginx.install.already_installed')"
    else
        source_compile # 先执行编译
        print_info "$(_i18n '.nginx.install.start_install')"
        make install # 执行安装 (将文件复制到 --prefix 指定的目录)
    fi
    mkdir -p /var/log/nginx                           # 创建日志目录 (已存在时无副作用)
    ln -sf "${NGINX_PATH}/sbin/nginx" /usr/sbin/nginx # 创建软链接以便全局使用 nginx 命令 (幂等)
}

# =============================================================================
# 函数名称: source_update
# 功能描述: 检查并更新 Nginx (如果需要)。
# 参数: 无
# 返回值: 0-执行了更新 1-无需更新 (由 return 语句决定)
# =============================================================================
function source_update() {
    print_info "$(_i18n '.nginx.update.fetch_versions')"
    # 获取最新的版本号
    local latest_nginx_version
    latest_nginx_version="$(wget -qO- --timeout=30 --tries=2 "$(_gh_url 'https://api.github.com/repos/nginx/nginx/tags')" | grep 'name' | cut -d\" -f4 | grep 'release' | head -1 | sed 's/release/nginx/' || true)"
    local latest_openssl_version
    latest_openssl_version="$(wget -qO- --timeout=30 --tries=2 "$(_gh_url 'https://api.github.com/repos/openssl/openssl/tags')" | grep 'name' | cut -d\" -f4 | grep -Eoi '^openssl-([0-9]\.?){3}$' | head -1 || true)"

    print_info "$(_i18n '.nginx.update.read_current_versions')"
    # 获取当前安装的 Nginx 和 OpenSSL 版本
    local current_version_nginx
    current_version_nginx="$(nginx -V 2>&1 | grep "^nginx version:.*" | cut -d / -f 2 || true)"
    local current_version_openssl
    current_version_openssl="$(nginx -V 2>&1 | grep "^built with OpenSSL" | awk '{print $4}' || true)"

    print_info "$(_i18n '.nginx.update.check_update')"
    # 使用 _version_ge 函数比较版本，如果任一组件有新版本则进行更新
    if _version_ge "${latest_nginx_version#*-}" "${current_version_nginx}" || _version_ge "${latest_openssl_version#*-}" "${current_version_openssl}"; then
        source_compile # 重新编译新版本
        print_info "$(_i18n '.nginx.update.start_update')"
        # 备份旧的 nginx 二进制文件
        mv "${NGINX_PATH}/sbin/nginx" "${NGINX_PATH}/sbin/nginx_$(date +%F)"
        # 备份旧的动态模块
        backup_files "${NGINX_PATH}/modules"
        # 复制新编译的 nginx 二进制文件和动态模块
        cp objs/nginx "${NGINX_PATH}/sbin/"
        cp objs/*.so "${NGINX_PATH}/modules/"
        # 更新软链接
        ln -sf "${NGINX_PATH}/sbin/nginx" /usr/sbin/nginx

        # 如果 Nginx 服务正在运行，则执行平滑升级
        if systemctl is-active --quiet nginx; then
            print_info "$(_i18n '.nginx.update.smooth_upgrade')"
            # 启动新的 Nginx 主进程 (旧进程仍在运行)
            # 注: 服务在跑但 pid 文件缺失属异常场景, 不应让升级流程因 set -e 中断
            kill -USR2 "$(cat /run/nginx.pid)" || print_warn "$(_i18n '.nginx.update.smooth_upgrade')"
            # 检查旧主进程是否存在
            if [[ -e "/run/nginx.pid.oldbin" ]]; then
                # 优雅地关闭旧工作进程
                kill -WINCH "$(cat /run/nginx.pid.oldbin)" || true
                # 重新打开日志文件
                kill -HUP "$(cat /run/nginx.pid.oldbin)" || true
                # 优雅地退出旧主进程
                kill -QUIT "$(cat /run/nginx.pid.oldbin)" || true
            else
                print_info "$(_i18n '.nginx.update.no_old_process')"
            fi
        fi
        return 0 # 表示执行了更新
    fi
    return 1 # 表示无需更新
}

# =============================================================================
# 函数名称: _nginx_package_owner
# 功能描述: 打印 nginx 二进制的包归属 (仅在"拒绝卸载"时调用, 给出处置线索)。
# 参数: 无
# 返回值: 无 (尽力而为, 查不到归属不视为错误)
# =============================================================================
function _nginx_package_owner() {
    local bin=''
    bin="$(command -v nginx 2>/dev/null || true)" # command 为 bash 内建, 不受 PATH 白名单影响
    [[ -n "${bin}" ]] || return 0
    print_info "$(_i18n_sub '.nginx.purge.owner_path' '${path}' "${bin}")"
    # dpkg (Debian/Ubuntu) 与 rpm (RHEL/CentOS) 二选一, 都查不到就静默跳过
    if cmd_exists 'dpkg'; then
        dpkg -S "${bin}" 2>/dev/null || true
    elif cmd_exists 'rpm'; then
        rpm -qf "${bin}" 2>/dev/null || true
    fi
}

# =============================================================================
# 函数名称: rollback_nginx_config
# 功能描述: 回滚本项目写入 Nginx 的配置 (卸载 Xray 时调用), 保留 Nginx 本体。
#
#           删除依据只有两条, 目的是"绝不误删用户的站点配置":
#           1. 与仓库模板 config/nginx/conf/ 同名、且逐字节一致 —— 可证明是本项目原样
#              拷贝进来的; 用户改动过的文件内容不一致, 会原样保留。
#           2. 本项目按 config.json 里的 domain / cdn 生成的站点配置 (available + enabled)。
#
#           另外还原被项目移走的 nginx.conf (default.conf.bak)、清理回滚后产生的死软链,
#           最后用 nginx -t 校验。日志目录 /var/log/nginx 与其它站点共用, 一律不动。
# 参数: 无
# 返回值: 0-回滚完成 (含无需回滚) 1-模板缺失等硬失败
# =============================================================================
function rollback_nginx_config() {
    # 非本项目编译版 -> 项目从未写过它的配置 (handler_nginx_install 段三有守卫)
    if ! is_local_nginx_installed; then
        print_warn "$(_i18n '.nginx.rollback.not_local')"
        return 0
    fi
    local tmpl_dir="${CONFIG_DIR}/nginx/conf"
    if [[ ! -d "${tmpl_dir}" ]]; then
        # 没有模板就无法判定"哪些配置是项目写的", 此时不做任何删除
        print_error "$(_i18n '.nginx.rollback.no_template')"
        return 1
    fi

    local conf_dir="${NGINX_PATH}/conf"
    local cur_conf="${conf_dir}/nginx.conf"
    local removed=0 kept=0 rel='' src='' dst=''

    print_info "$(_i18n '.nginx.rollback.begin')"

    # --- 第一类: 与模板同名且逐字节一致的文件 ---
    # 注: 用进程替换而非管道, 否则 while 在子 shell 中执行, removed/kept 会被丢弃
    while IFS= read -r rel; do
        [[ -n "${rel}" ]] || continue
        src="${tmpl_dir}/${rel}"
        dst="${conf_dir}/${rel}"
        [[ -f "${dst}" ]] || continue
        if cmp -s "${dst}" "${src}"; then
            rm -f "${dst}"
            removed=$((removed + 1))
        else
            kept=$((kept + 1))
        fi
    done < <(cd "${tmpl_dir}" && find . -type f | sed 's|^\./||' | sort)

    # --- 第二类: 项目按域名重建过的 stream.conf (内容与模板不同, 第一类抓不到) ---
    local stream_conf="${conf_dir}/modules-enabled/stream.conf"
    if [[ -f "${stream_conf}" ]] && grep -qF 'tcpsni_name' "${stream_conf}"; then
        rm -f "${stream_conf}"
        removed=$((removed + 1))
    fi

    # --- 第三类: 项目按 config.json 生成的站点配置 (含软链) ---
    # 只认项目自己写进 config.json 的 domain / cdn, 不扫描、不猜测其它站点
    local key='' site_name=''
    for key in domain cdn; do
        site_name=''
        if [[ -f "${SCRIPT_CONFIG_PATH}" ]] && cmd_exists 'jq'; then
            site_name="$(jq -r --arg k "${key}" '.nginx[$k] // empty' "${SCRIPT_CONFIG_PATH}" 2>/dev/null || true)"
        fi
        [[ -n "${site_name}" && "${site_name}" != 'null' ]] || continue
        if [[ -f "${conf_dir}/sites-available/${site_name}.conf" ]]; then
            rm -f "${conf_dir}/sites-available/${site_name}.conf"
            rm -f "${conf_dir}/sites-enabled/${site_name}.conf"
            removed=$((removed + 1))
        fi
    done

    # --- 第四类: 清理指向已删配置的死软链 (死链会让 nginx -t 直接失败) ---
    local enabled_dir="${conf_dir}/sites-enabled"
    if [[ -d "${enabled_dir}" ]]; then
        local name='' link='' target=''
        while IFS= read -r name; do
            [[ -n "${name}" ]] || continue
            link="${enabled_dir}/${name}"
            [[ -L "${link}" ]] || continue
            target="$(readlink "${link}" 2>/dev/null || true)"
            # 只处理"指向本项目 sites-available 目录、且目标已不存在"的软链;
            # 用户自己的软链指向的是仍存在的文件, 不会被命中。
            if [[ -n "${target}" && "${target}" == "${conf_dir}/sites-available/"* && ! -e "${target}" ]]; then
                rm -f "${link}"
                removed=$((removed + 1))
            fi
        done < <(cd "${enabled_dir}" && find . -maxdepth 1 -type l | sed 's|^\./||' | sort)
    fi

    # --- 第五类: 还原被项目移走的 nginx.conf ---
    local bak_conf="${conf_dir}/default.conf.bak"
    if [[ -f "${bak_conf}" ]]; then
        if grep -qE 'sites-enabled|nginxconfig\.io' "${bak_conf}"; then
            # 备份已被项目自身的 nginx.conf 覆盖 (重复执行 handler_nginx_config 所致):
            # 还原它没有意义, 故保留现状并提示, 以保住这个仍可追溯的现场。
            print_warn "$(_i18n '.nginx.rollback.bak_is_project')"
        else
            mv -f "${bak_conf}" "${cur_conf}"
            print_info "$(_i18n '.nginx.rollback.conf_restored')"
        fi
    fi

    print_info "$(_i18n_sub '.nginx.rollback.summary' '${removed}' "${removed}" '${kept}' "${kept}")"

    # --- 收尾: 配置校验; 失败只告警, 不擅自恢复已删文件 ---
    if cmd_exists 'nginx' && [[ -f "${cur_conf}" ]]; then
        if nginx -t >/dev/null 2>&1; then
            print_info "$(_i18n '.nginx.rollback.check_ok')"
            # 配置已变, 让运行中的 Nginx 重新加载以生效 (校验通过后才 reload)
            if systemctl -q is-active nginx; then
                systemctl -q reload nginx || print_warn "$(_i18n '.nginx.rollback.reload_fail')"
            fi
        else
            print_warn "$(_i18n '.nginx.rollback.check_fail')"
            nginx -t || true
        fi
    fi
    print_info "$(_i18n '.nginx.rollback.done')"
}

# =============================================================================
# 函数名称: purge_nginx
# 功能描述: 卸载 Nginx —— 仅限本项目编译版。
#           1. 归属判定: 发行版 (apt/yum) Nginx 一律拒绝卸载, 只打印包归属。
#           2. /usr/sbin/nginx 与 systemd unit 仅在确认属于本项目时才删除。
#           3. 日志目录与其它站点共用, 一律保留。
# 参数: 无
# 返回值: 0-已卸载 / 未安装 1-拒绝卸载 (非本项目编译版)
# =============================================================================
function purge_nginx() {
    # 本项目编译版固定装在 ${NGINX_PATH} (/usr/local/nginx); 发行版不在该目录, 且 dpkg/rpm
    # 能查到包归属。误删发行版会让机器上其它站点一起失去 Web 服务, 故一律拒绝。
    if ! is_local_nginx_installed; then
        if cmd_exists 'nginx'; then
            print_error "$(_i18n '.nginx.purge.refuse_foreign')"
            print_warn "$(_i18n '.nginx.purge.foreign_hint')"
            _nginx_package_owner
            return 1
        fi
        print_warn "$(_i18n '.nginx.purge.not_installed')"
        return 0
    fi

    print_info "$(_i18n '.nginx.purge.start_purge')"

    # 归属判定必须在删除安装目录之前完成: readlink 需要目标仍存在
    # 注: 软链目标可能是绝对或相对写法 (ln -s 的形态不唯一), 故两侧都做 readlink -f 归一后再比,
    #     否则相对写法会被误判为"不是本项目的软链"而残留下来。
    local remove_sbin=0
    local sbin_link=''
    local sbin_real=''
    sbin_link="$(readlink -f /usr/sbin/nginx 2>/dev/null || true)"
    sbin_real="$(readlink -f "${NGINX_PATH}/sbin/nginx" 2>/dev/null || true)"
    if [[ -L /usr/sbin/nginx && -n "${sbin_link}" && -n "${sbin_real}" && "${sbin_link}" == "${sbin_real}" ]]; then
        remove_sbin=1
    fi
    # 本项目写入的 unit 带 tcmalloc 共享内存准备步骤, 依此判定归属
    local remove_unit=0
    if [[ -f /etc/systemd/system/nginx.service ]] && grep -qF '/dev/shm/nginx/tcmalloc' /etc/systemd/system/nginx.service; then
        remove_unit=1
    fi

    # 注: 服务/unit 可能本就不存在, 停止失败不应阻断卸载
    systemctl stop nginx >/dev/null 2>&1 || true # 停止 Nginx 服务
    rm -rf "${NGINX_PATH}"                       # 删除本项目安装目录

    if (("${remove_sbin}" == 1)); then
        rm -f /usr/sbin/nginx # 删除本项目的软链接
    else
        print_warn "$(_i18n '.nginx.purge.skip_sbin')"
    fi
    if (("${remove_unit}" == 1)); then
        rm -f /etc/systemd/system/nginx.service
    else
        print_warn "$(_i18n '.nginx.purge.skip_unit')"
    fi
    # 日志目录与其它站点共用, 一律保留 (仅提示位置)
    print_warn "$(_i18n_sub '.nginx.purge.keep_logs' '${path}' "${NGINX_LOG_PATH}")"
    systemctl daemon-reload >/dev/null 2>&1 || true
    print_info "$(_i18n '.nginx.purge.purged')"
}

# =============================================================================
# 函数名称: systemctl_config_nginx
# 功能描述: 配置 Nginx 的 systemd 服务文件。
# 参数: 无
# 返回值: 无 (创建服务文件并重新加载 systemd)
# =============================================================================
function systemctl_config_nginx() {
    _ensure_nginx_user
    print_info "$(_i18n '.nginx.service.configure')"
    # 使用 here document 创建服务文件内容
    cat >/etc/systemd/system/nginx.service <<EOF
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=syslog.target network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
# 清理并创建共享内存目录用于 tcmalloc
ExecStartPre=/bin/rm -rf /dev/shm/nginx
ExecStartPre=/bin/mkdir /dev/shm/nginx
ExecStartPre=/bin/chown nginx:nginx /dev/shm/nginx
ExecStartPre=/bin/chmod 711 /dev/shm/nginx
ExecStartPre=/bin/mkdir /dev/shm/nginx/tcmalloc
ExecStartPre=/bin/chown nginx:nginx /dev/shm/nginx/tcmalloc
ExecStartPre=/bin/chmod 0755 /dev/shm/nginx/tcmalloc
# 测试配置文件
ExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on; master_process on;'
# 启动 Nginx
ExecStart=/usr/sbin/nginx -g 'daemon on; master_process on;'
# 重载 Nginx
ExecReload=/usr/sbin/nginx -g 'daemon on; master_process on;' -s reload
# 停止 Nginx
ExecStop=/bin/kill -s QUIT \$MAINPID
# 停止后清理共享内存
ExecStopPost=/bin/rm -rf /dev/shm/nginx
TimeoutStopSec=5
KillMode=mixed
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload # 重新加载 systemd 配置以使新服务生效
    print_info "$(_i18n '.nginx.service.complete')"
}

# =============================================================================
# 函数名称: show_help
# 功能描述: 显示脚本使用帮助信息。
# 参数: 无
# 返回值: 无 (打印帮助信息到标准输出并 exit 0)
# =============================================================================
function show_help() {
    # 从 i18n 数据中读取帮助信息的各个部分
    local usage
    usage="$(_i18n_sub '.nginx.help.usage' '${script_name}' "$0")"
    local options_title
    options_title="$(_i18n '.nginx.help.options_title')"
    local opt_install
    opt_install="$(_i18n '.nginx.help.opt_install')"
    local opt_update
    opt_update="$(_i18n '.nginx.help.opt_update')"
    local opt_brotli
    opt_brotli="$(_i18n '.nginx.help.opt_brotli')"
    local opt_purge
    opt_purge="$(_i18n '.nginx.help.opt_purge')"
    local opt_force
    opt_force="$(_i18n '.nginx.help.opt_force')"
    local opt_help
    opt_help="$(_i18n '.nginx.help.opt_help')"
    # 注: 本项刻意拆开声明与赋值, 避免给 SC2155 棘轮新增债务
    local opt_rollback_config=''
    opt_rollback_config="$(_i18n '.nginx.help.opt_rollback_config')"

    # 使用 here document 打印帮助信息
    cat <<EOF
${usage}
${options_title}:
  --install          ${opt_install}
  --update           ${opt_update}
  --brotli           ${opt_brotli}
  --force            ${opt_force}
  --purge            ${opt_purge}
  --rollback-config  ${opt_rollback_config}
  --help             ${opt_help}
EOF
    # 退出脚本，状态码为 0 (成功)
    exit 0
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
#           1. 检查操作系统。
#           2. 解析命令行参数。
#           3. 根据参数执行安装、更新或卸载操作。
# 参数:
#   $@: 所有命令行参数
# 返回值: 无 (协调调用其他函数完成 Nginx 管理)
# =============================================================================
function main() {
    # 加载国际化数据
    load_i18n

    # 首先检查操作系统兼容性
    check_os

    # 初始化 action 变量
    local action=''

    while [[ $# -gt 0 ]]; do
        case "${1:-}" in
        # 处理主要操作参数
        --install | --update | --purge | --rollback-config)
            action="${1#--}" # 移除 '--' 前缀，获取操作名称 (install/update/purge/rollback-config)
            ;;
        # 处理 Brotli 选项
        --brotli)
            is_enable_brotli='Y' # 设置启用 Brotli 的标志
            ;;
        # 处理强制重装选项 (忽略"已安装"幂等保护)
        --force)
            is_force_install='Y'
            ;;
        # 处理帮助选项
        --help)
            show_help # 显示帮助信息并退出
            ;;
        # 处理无效选项
        *)
            print_error "$(_i18n_sub '.nginx.main.invalid_option' '${option}' "${1:-}")"
            ;;
        esac
        shift
    done

    # 根据解析出的 action 执行相应的操作
    case "${action}" in
    install)
        compile_dependencies   # 安装依赖
        source_install         # 编译并安装
        systemctl_config_nginx # 配置 systemd 服务
        ;;
    update)
        compile_dependencies # 安装/更新依赖 (如果需要)
        source_update        # 检查并更新
        ;;
    purge)
        purge_nginx # 卸载 (仅限本项目编译版, 归属判定在 purge_nginx 内)
        ;;
    rollback-config)
        rollback_nginx_config # 回滚本项目写入的 Nginx 配置 (保留 Nginx 本体)
        ;;
    esac
}

# --- 脚本执行入口 ---
# 调用 main 函数，并将所有命令行参数传递给它
# 注: main 的返回码在此显式收敛。purge_nginx 主动"拒绝卸载"时返回非 0 属正常分支,
#     裸调用 `main "$@"` 会让它触发 ERR trap (打印行号+命令), 干扰调用方判断。
_xray_script_rc=0
main "$@" || _xray_script_rc=$?
exit "${_xray_script_rc}"
