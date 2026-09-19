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

_APISERVER=127.0.0.1:32768
_XRAY=/usr/local/bin/xray

# 功能描述: 调用 xray API statsquery 拉取流量统计, 用 awk 把 JSON 流解析为
#           "方向:协议->目标<TAB>字节数" 的扁平记录, 供 print_sum 汇总 (带 reset 时附 -reset=true)。
apidata() {
    local ARGS=
    if [[ ${1:-} == "reset" ]]; then
        ARGS="-reset=true"
    fi
    $_XRAY api statsquery --server=$_APISERVER "${ARGS}" |
        awk '{
        if (match($1, /"name":/)) {
            f=1; gsub(/^"|link"|,$/, "", $2);
            split($2, p,  ">>>");
            printf "%s:%s->%s\t", p[1],p[2],p[4];
        }
        else if (match($1, /"value":/) && f){
          f = 0;
          gsub(/"/, "", $2);
          printf "%.0f\n", $2;
        }
        else if (match($0, /}/) && f) { f = 0; print 0; }
    }'
}

# 功能描述: 按前缀 (inbound/outbound/user) 过滤流量记录, 用单条 awk 完成
#           IEC 单位换算与列宽对齐, 并打印合计行 (零外部依赖, 原因见下方长注释)。
print_sum() {
    local DATA="${1:-}"
    local PREFIX="${2:-}"
    local SORTED
    SORTED=$(echo "$DATA" | grep "^${PREFIX}" | sort -r || true)
    local SUM
    SUM=$(echo "$SORTED" | awk '
        /->up/{us+=$2}
        /->down/{ds+=$2}
        END{
            printf "SUM->up:\t%.0f\nSUM->down:\t%.0f\nSUM->TOTAL:\t%.0f\n", us, ds, us+ds;
        }' || true)
    # 刻意不使用 numfmt / column: 两者都不在 install.sh 的依赖清单里, 而依赖安装只在
    # 首次运行 (或 --force-check-deps) 时执行 —— 最小化系统 / 事后丢包的机器上点"信息
    # 统计"会直接 command not found (Debian 12 起 column 已移入 bsdextrautils, 仅靠
    # bsdmainutils 传递带入)。改用单条 awk 完成 IEC 单位换算 + 标签列宽对齐, 零外部依赖。
    # 用 printf 而非 echo -e: 标签里若含反斜杠, echo -e 会把它解释成转义序列。
    # 空行 (SORTED 为空时的占位) 直接跳过, 避免凭空多出一行 "0B"。
    printf '%s\n%s\n' "${SORTED}" "${SUM}" | awk -F'\t' '
        function human(v,   i, u) {
            i = 0
            while (v >= 1024 && i < 4) { v /= 1024; i++ }
            u = (i == 0) ? "" : substr("KMGT", i, 1)
            return ((i == 0 || v >= 10) ? sprintf("%.0f", v) : sprintf("%.1f", v)) u "B"
        }
        NF == 0 { next }
        { line[++n] = $1 "\t" human($2 + 0); if (length($1) > w) w = length($1) }
        END {
            for (i = 1; i <= n; i++) {
                split(line[i], a, "\t")
                printf "%-*s  %s\n", w, a[1], a[2]
            }
        }'
}

DATA="$(apidata "${1:-}")" || DATA=
echo "------------Inbound----------"
print_sum "$DATA" "inbound"
echo "-----------------------------"
echo "------------Outbound----------"
print_sum "$DATA" "outbound"
echo "-----------------------------"
echo
echo "-------------User------------"
print_sum "$DATA" "user"
echo "-----------------------------"
