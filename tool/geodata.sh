#!/usr/bin/env bash

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

XRAY_DIR="/usr/local/share/xray"

# 数据源: 使用 GitHub Releases (每个 tag 同时发布 .sha256sum 摘要文件),
# 而非 raw/release 分支 —— 后者是移动目标且不提供任何摘要, 无法做完整性校验。
GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

[ -d "$XRAY_DIR" ] || mkdir -p "$XRAY_DIR"
cd "$XRAY_DIR"

# =============================================================================
# 函数名称: download_verified
# 功能描述: 下载数据文件并比对上流发布的 SHA256 摘要, 校验通过才原子就位。
# 参数:
#   $1: 数据文件下载地址
#   $2: 目标文件名 (如 geoip.dat)
# 返回值: 0-成功 1-失败 (失败时清理残留, 保留原有文件不被破坏)
# =============================================================================
download_verified() {
    local url="${1:-}"
    local dst="${2:-}"
    local sum_url="${url}.sha256sum"
    local want_sum=''
    local got_sum=''

    # 安全加固: 临时文件前缀随机化 (mktemp --suffix 在 Linux 生效, 防预植符号链接), 后缀保留 .new/.sha256sum
    #           以保持既有约定 (geodata_test.sh 的 mock curl 用后缀区分摘要/数据文件); 临时文件生成于 dst 同级
    #           目录确保 mv -f 原子就位; macOS 不支持 --suffix 时自动回退为固定名, 行为与原版一致。
    local dst_dir="${dst%/*}"
    [[ "${dst_dir}" != "${dst}" ]] || dst_dir="."
    local tmp_new="$(mktemp --suffix=.new "${dst_dir}/.geo.XXXXXX" 2>/dev/null || printf '%s.new' "${dst}")"
    local tmp_sum="$(mktemp --suffix=.sha256sum "${dst_dir}/.geo.XXXXXX" 2>/dev/null || printf '%s.sha256sum' "${dst}")"

    # 下载数据文件与官方摘要文件 (任一失败即清理并返回)
    curl -L --connect-timeout 15 --retry 2 --max-time 900 -o "${tmp_new}" "$url" || { rm -f "${tmp_new}" "${tmp_sum}"; return 1; }
    curl -L --connect-timeout 15 --retry 2 --max-time 60 -o "${tmp_sum}" "$sum_url" || { rm -f "${tmp_new}" "${tmp_sum}"; return 1; }

    # 摘要文件格式为 "<64位HEX>  <文件名>", 取第一列
    want_sum="$(awk 'NR==1 {print $1}' "${tmp_sum}")"
    got_sum="$(sha256sum "${tmp_new}" | awk '{print $1}')"
    rm -f "${tmp_sum}"

    # 摘要不一致说明下载被截断/被篡改, 丢弃新文件并报错
    if [ -z "$want_sum" ] || [ "$want_sum" != "$got_sum" ]; then
        rm -f "${tmp_new}"
        return 1
    fi

    # 校验通过后才原子替换, 避免校验失败时破坏已有数据
    mv -f "${tmp_new}" "${dst}"
    return 0
}

download_verified "$(_gh_url "$GEOIP_URL")" geoip.dat || {
    echo "geoip.dat download or sha256 verify failed" >&2
    exit 1
}

download_verified "$(_gh_url "$GEOSITE_URL")" geosite.dat || {
    echo "geosite.dat download or sha256 verify failed" >&2
    exit 1
}

# 注: Xray 未运行时 is-active 返回非 0, 本行作为脚本末句会把该退出码交给 cron,
#     表现为"每天假失败"(数据其实已正常刷新); 补 || true 让退出码只反映数据下载结果。
systemctl -q is-active xray && systemctl restart xray || true
