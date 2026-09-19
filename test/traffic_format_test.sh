#!/usr/bin/env bash
#
# 用例: tool/traffic.sh 的 print_sum 输出格式
#
# 背景 (为什么值得单独测): 菜单 8「信息统计」原先用 `numfmt | column` 做单位换算与列对齐,
# 这两个命令都不在 install.sh 的依赖清单里, 而依赖安装只在首次运行时执行 —— 最小化系统 /
# 事后丢包的机器上会直接 command not found。现已改为纯 awk。本用例锁两件事:
#   1. 源码里不再出现 numfmt / column (防回潮, 否则同一类故障会再次出现);
#   2. 输出与旧管道逐字节等价 (单位进位、小数位、列宽都不能漂)。
#
# 依赖: bash, awk。不依赖 jq 与被测脚本之外的任何命令。
set -Eeuo pipefail

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
SRC="${REPO}/tool/traffic.sh"

fail=0
ok() { printf '  ok   %s\n' "$1"; }
bad() {
    printf '  FAIL %s\n' "$1"
    fail=1
}

# ---------------------------------------------------------------------------
# 1. 依赖守卫: 去掉注释后再看是否还引用 numfmt / column
# ---------------------------------------------------------------------------
code="$(grep -vE '^[[:space:]]*#' "${SRC}")"
if printf '%s\n' "${code}" | grep -qE '(numfmt|column)'; then
    bad "tool/traffic.sh 仍引用 numfmt/column —— 二者不在 install.sh 依赖清单里"
else
    ok "不依赖 numfmt/column (纯 awk)"
fi

# ---------------------------------------------------------------------------
# 2. 抽出 print_sum 用夹具驱动 (不跑 apidata: 那需要真实 xray 与监听端口)
# ---------------------------------------------------------------------------
extracted="$(awk '/^print_sum\(\) \{/,/^\}/' "${SRC}")"
if [[ -z "${extracted}" || "${extracted}" != *'print_sum() {'* ]]; then
    bad "无法从 tool/traffic.sh 抽出 print_sum 函数"
    printf '\n结果: 失败\n'
    exit 1
fi
eval "${extracted}"

# 与真实 apidata 一致的格式: "<prefix>:<tag>->up<TAB><bytes>"
FIXTURE="$(printf 'inbound:vision->up\t1073741824\ninbound:vision->down\t536870912\ninbound:xhttp->up\t0\noutbound:direct->up\t1024\nuser:nobody->up\t0\n')"

# 2a. 列宽 + 单位 + 小数位 (期望值 = 旧管道 numfmt --to=iec --suffix=B | column -t 的实测输出)
expected="$(printf '%-20s  %s\n' \
    'inbound:xhttp->up' '0B' \
    'inbound:vision->up' '1.0GB' \
    'inbound:vision->down' '512MB' \
    'SUM->up:' '1.0GB' \
    'SUM->down:' '512MB' \
    'SUM->TOTAL:' '1.5GB')"
actual="$(print_sum "${FIXTURE}" 'inbound')"
if [[ "${actual}" == "${expected}" ]]; then
    ok "列宽/单位/小数位与 numfmt+column 等价"
else
    bad "print_sum 输出与期望不一致"
    printf '  ---- 实际 ----\n%s\n  ---- 期望 ----\n%s\n' "${actual}" "${expected}"
fi

# 2b. 无匹配前缀: 只剩三行合计, 且不得凭空多出空行/0B 行
expected="$(printf '%-11s  %s\n' 'SUM->up:' '0B' 'SUM->down:' '0B' 'SUM->TOTAL:' '0B')"
actual="$(print_sum "${FIXTURE}" 'nowhere')"
if [[ "${actual}" == "${expected}" ]]; then
    ok "前缀无匹配时只输出合计行"
else
    bad "前缀无匹配时输出不符 (可能凭空多出空行或 0B 行)"
    printf '  ---- 实际 ----\n%s\n' "${actual}"
fi

# 2c. 空输入: 同样只输出合计 (旧实现的 echo -e 会带出一个空行)
actual="$(print_sum '' 'inbound')"
if [[ "$(printf '%s\n' "${actual}" | grep -c .)" -eq 3 ]]; then
    ok "空输入时输出 3 行合计"
else
    bad "空输入时输出行数不是 3"
    printf '  ---- 实际 ----\n%s\n' "${actual}"
fi

# 2d. IEC 进位边界 (逐值核对, 与 numfmt --to=iec --suffix=B 一致)
check_size() {
    local bytes="$1" want="$2" got=''
    # 注: 必须按标签精确取行 —— 合计行 "SUM->up:" 也会被 /->up/ 匹配到
    got="$(print_sum "$(printf 'user:t->up\t%s\n' "${bytes}")" 'user' | awk '$1 == "user:t->up" {print $NF}')"
    if [[ "${got}" == "${want}" ]]; then
        ok "human(${bytes}) = ${want}"
    else
        bad "human(${bytes}) = ${got}, 期望 ${want}"
    fi
}
check_size 0 '0B'
check_size 1023 '1023B'
check_size 1024 '1.0KB'
check_size 1536 '1.5KB'
check_size 10240 '10KB'
check_size 123456 '121KB'
check_size 1048576 '1.0MB'
check_size 1073741824 '1.0GB'

# ---------------------------------------------------------------------------
if [[ "${fail}" -eq 0 ]]; then
    printf '结果: 通过\n'
else
    printf '结果: 失败\n'
fi
exit "${fail}"
