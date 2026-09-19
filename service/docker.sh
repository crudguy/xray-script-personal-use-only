#!/usr/bin/env bash
#
# Copyright (C) 2026 crudguy
#
# xray-script-personal-use-only:
#   https://github.com/crudguy/xray-script-personal-use-only
#
# docker-install:
#   https://github.com/docker/docker-install
#
# Cloudflare WARP:
#   https://github.com/haoel/haoel.github.io?tab=readme-ov-file#1043-docker-%E4%BB%A3%E7%90%86
#   https://github.com/e7h4n/cloudflare-warp
#
# =============================================================================
# 脚本名称: docker.sh
# 功能描述: 提供 Docker 环境管理功能，包括安装 Docker、管理 Cloudflare WARP 容器。
#           支持多语言提示信息。
# 作者: crudguy
# 时间: 2026-09-19
# 版本: 1.0.0
# 依赖: bash, jq, wget, sed, awk, grep, curl, openssl, docker, docker-compose
# 配置:
#   - ${SCRIPT_CONFIG_DIR}/config.json: 用于读取语言设置 (language)
#   - ${I18N_DIR}/${lang}.json: 用于读取具体的提示文本 (i18n 数据文件)
#   - ${CONFIG_DIR}/cloudflare-warp/Dockerfile: WARP 容器的构建文件
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

readonly TOOL_DIR="${PROJECT_ROOT}/tool"
readonly DOCKER_DIR="${SCRIPT_CONFIG_DIR}/docker"
readonly WARP_DIR="${DOCKER_DIR}/cloudflare-warp"

# --- 第三方引导脚本固定版本 (供应链防篡改) ---
# Docker 官方安装脚本: 固定到 docker/docker-install 的经验证 commit 并锁定 SHA256。
# get.docker.com 与仓库同一文件, 但每次上游提交都会刷新 (摘要不稳定), 故改用固定 commit 的原始文件。
# 跟随上游最新版本时: 设 DOCKER_INSTALL_URL=https://get.docker.com 且 DOCKER_INSTALL_SHA256= 。
declare DOCKER_INSTALL_URL="${DOCKER_INSTALL_URL-https://raw.githubusercontent.com/docker/docker-install/bb2fcbb5283ede63b3ddbff5bf224cd46bbee55a/install.sh}"
declare DOCKER_INSTALL_SHA256="${DOCKER_INSTALL_SHA256-fefa50ccd50efb42f438b506fc3a88574118f314aaf2a7cd5b6e1ffb1bffcf26}"








# =============================================================================
# 函数名称: install_docker
# 功能描述: 从官方脚本安装 Docker。针对特定系统 (如 CentOS 8) 进行适配。
# 参数: 无
# 返回值: 无 (执行安装过程，失败时会调用 print_error 退出)
# =============================================================================
function install_docker() {
    print_info "$(_i18n '.docker.install.start')"

    # 下载 Docker 官方安装脚本 → 完整性体检 → 落位到工具目录
    # (取代原"wget 直下不校验、失败也继续 sh"的写法)
    local docker_installer=''
    if ! docker_installer="$(_download_verified "${DOCKER_INSTALL_URL}" "${DOCKER_INSTALL_SHA256}")"; then
        print_error "$(_i18n '.docker.install.fail_download')"
    fi
    mv -f "${docker_installer}" "${TOOL_DIR}/install-docker.sh"
    chmod 700 "${TOOL_DIR}/install-docker.sh"

    if [[ "$(_os)" == "centos" && "$(_os_ver)" -eq 8 ]]; then
            print_info "$(_i18n '.docker.install.centos8_fix')"
        # 修改安装脚本，在安装命令中添加 --allowerasing 选项以解决依赖冲突
        sed -i 's|$sh_c "$pkg_manager install -y -q $pkgs"| $sh_c "$pkg_manager install -y -q $pkgs --allowerasing"|' "${TOOL_DIR}/install-docker.sh"
    fi

    print_info "$(_i18n '.docker.install.dry_run')"
    sh "${TOOL_DIR}/install-docker.sh" --dry-run

    print_info "$(_i18n '.docker.install.running')"
    sh "${TOOL_DIR}/install-docker.sh"
}

# =============================================================================
# 函数名称: get_container_ip
# 功能描述: 获取指定 Docker 容器的 IP 地址。
# 参数:
#   $1: 容器名称或 ID (container_name)
# 返回值: 容器的 IP 地址 (echo 输出)
# =============================================================================
function get_container_ip() {
    docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${1:-}"
}

# =============================================================================
# 函数名称: build_warp
# 功能描述: 构建 Cloudflare WARP 的 Docker 镜像。
#           如果镜像已存在，则跳过构建。
# 参数: 无
# 返回值: 无 (执行构建过程，失败时会调用 print_error 退出)
# =============================================================================
function build_warp() {
    if ! docker images --format "{{.Repository}}" | grep -q ${WARP_IMAGE}; then
        print_info "$(_i18n '.docker.warp.build.start')"
        docker build -t ${WARP_IMAGE} "${CONFIG_DIR}/cloudflare-warp" || print_error "$(_i18n '.docker.warp.build.fail')"
    fi
}

# =============================================================================
# 函数名称: enable_warp
# 功能描述: 启动 Cloudflare WARP 容器。
#           如果容器已运行，则跳过启动。
# 参数: 无
# 返回值: 容器的 IP 地址 (echo 输出)，或无输出
# =============================================================================
function enable_warp() {
    if ! docker ps --format "{{.Names}}" | grep -q "^${WARP_IMAGE}\$"; then
        print_info "$(_i18n '.docker.warp.enable.start')"
        mkdir -vp "${WARP_DIR}" >&2
        docker run -d --restart=always --name=${WARP_IMAGE} --log-driver json-file --log-opt max-size=100m --log-opt max-file=3 -v "${WARP_DIR}":/var/lib/cloudflare-warp:rw ${WARP_IMAGE} >&2 || print_error "$(_i18n '.docker.warp.build.fail')"
        local container_ip
        container_ip=$(get_container_ip ${WARP_IMAGE})
        print_info "$(_i18n_sub ".docker.warp.enable.success" '${container_ip}' "${container_ip}")"
        echo "${container_ip}"
    fi
}

# =============================================================================
# 函数名称: disable_warp
# 功能描述: 停止并删除 Cloudflare WARP 容器，并清理相关数据。
# 参数: 无
# 返回值: 无 (执行停止和清理过程)
# =============================================================================
function disable_warp() {
    if docker ps --format "{{.Names}}" | grep -q "^${WARP_IMAGE}\$"; then
        print_warn "$(_i18n '.docker.warp.disable.stop')"
        docker stop ${WARP_IMAGE}
        docker rm ${WARP_IMAGE}
        docker image rm ${WARP_IMAGE}
        rm -rf "${WARP_DIR}"
        print_info "$(_i18n '.docker.warp.disable.success')"
    fi
}

# =============================================================================
# 函数名称: clean_container_logs
# 功能描述: 清空指定容器日志数据。
# 参数:
#   $1: 容器名称或 ID（默认清空 warp 日志记录）
# 返回值: 无 (执行清理过程)
# =============================================================================
function clean_container_logs() {
    local container_name_or_id="${1:-${WARP_IMAGE}}"
    truncate -s 0 "$(docker inspect --format='{{.LogPath}}' "${container_name_or_id}")"
}

# =============================================================================
# 函数名称: obtain_container_ip
# 功能描述: 获取容器 IP 地址。
# 参数: 
#   $1: 容器名称（默认获取 warp 容器 IP 地址）
# 返回值: 容器的 IP 地址 (echo 输出)，或无输出
# =============================================================================
function obtain_container_ip() {
    local container_name="${1:-${WARP_IMAGE}}"
	local container_ip
	container_ip=$(get_container_ip "${container_name}")
    if [[ -n "${container_ip}" ]]; then
        echo "${container_ip}"
    fi
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
#           1. 加载国际化数据。
#           2. 根据传入的第一个参数 (option) 调用相应的管理函数。
# 参数:
#   $@: 所有命令行参数
# 返回值: 无 (调用具体函数执行相应操作)
# =============================================================================
function main() {
    load_i18n

    case "${1,,}" in                                        # ${1,,} 将第一个参数转换为小写
    --install) install_docker ;;
    --build-warp) build_warp ;;
    --enable-warp) enable_warp ;;
    --disable-warp) disable_warp ;;
    --clean-container-logs) clean_container_logs ${2:-} ;;
    --obtain-container-ip) obtain_container_ip ${2:-} ;;
    esac
}

# --- 脚本执行入口 ---
main "$@"
