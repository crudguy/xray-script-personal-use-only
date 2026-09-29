#!/usr/bin/env bash
# shellcheck disable=SC2034  # GREEN/YELLOW/RED/NC/CUR_FILE/_HEALTH_ITEMS/_i18n 由下方 eval 注入的 _health_summary 读取 (shellcheck 数据流不跨 eval)。
# _health_summary 汇总行形态回归测试 (纯 bash, 不 source core/check.sh, 零副作用)
#
# 为什么单独锁这一行: 拆分 check_health_report 时它曾被改坏过一次, 且坏得"看着正常"——
#   printf '  %s: %s%s%s  %s%s%s  %s%s%s\n'   # 10 个 %s 配 10 个实参 (标签 + 三档各 颜色/文本/复位)
# 误删格式串里的 ": " 后只剩 9 个 %s, printf 会把实参整体前移一位吃错,
# 后果有二: ①标签与统计数字之间少了 ": " 分隔; ②末尾 ${NC} 被吞掉, 终端从此保持红色,
# 渗染后续所有输出。shellcheck SC2183 能拦, 但该规则不在本仓库历史门禁的覆盖记忆里,
# 故再用行为测试兜一层 —— 误改格式串会在这里立刻 FAIL。
set -Eeuo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }

FUNC_SRC="$(awk '/^function _health_summary\(\) \{/{f=1} f{print} f&&/^\}/{exit}' core/check.sh)"
if [[ -z "$FUNC_SRC" ]]; then
    echo "  [FAIL] 无法从 core/check.sh 抽取 _health_summary 函数体"
    exit 1
fi

# ---- 桩件: 常量 / i18n / 三档计数 (被 eval 注入的函数体读取) ----
GREEN='<G>'
YELLOW='<Y>'
RED='<R>'
NC='</>'
CUR_FILE='check'
_i18n() { printf '%s' "${1}"; }
_HEALTH_ITEMS=('pass|a' 'warn|b' 'fail|c')

eval "$FUNC_SRC"

pass=0
warn=0
fail=0
OUT="$(_health_summary 2>&1)"
LINE="$(printf '%s\n' "$OUT" | grep -F 'health.summary' | head -1)"

if [[ -z "$LINE" ]]; then
    echo "  [FAIL] 未捕获到汇总行 (health.summary 文案缺失)"
    echo "==== health_summary_test: PASS=$PASS FAIL=$FAIL ===="
    exit 1
fi

echo "== _health_summary 汇总行形态 =="

# T1 标签后必须有 ": " 分隔 —— 锁死被误删过一次的那个冒号
case "$LINE" in
*".health.summary: "*) ok ;;
*) bad "T1: 汇总行缺少 '<标签>: ' 分隔 (格式串疑似被改坏) -> [$LINE]" ;;
esac

# T2 行尾必须回到 NC —— 实参错位时末尾 ${NC} 会被 printf 吞掉 (终端颜色渗染的根因)
case "$LINE" in
*"${NC}") ok ;;
*) bad "T2: 汇总行未以颜色复位收尾 (printf 实参个数与格式符不匹配?) -> [$LINE]" ;;
esac

# T3 三档各自复位 = NC 恰好出现 3 次 (1 档 1 次)
nc_n="$(printf '%s' "$LINE" | grep -oF -- "${NC}" 2>/dev/null | wc -l || true)"
nc_n="${nc_n//[!0-9]/}"
if [[ "$nc_n" == "3" ]]; then ok; else bad "T3: 颜色复位应出现 3 次, 实际 ${nc_n} 次 -> [$LINE]"; fi

# T4 三档计数各自正确 (各 1 个)
case "$LINE" in
*"health.summary_pass 1${NC}"*) ok ;;
*) bad "T4a: pass 档渲染不符 -> [$LINE]" ;;
esac
case "$LINE" in
*"health.summary_warn 1${NC}"*) ok ;;
*) bad "T4b: warn 档渲染不符 -> [$LINE]" ;;
esac
case "$LINE" in
*"health.summary_fail 1${NC}"*) ok ;;
*) bad "T4c: fail 档渲染不符 -> [$LINE]" ;;
esac

# T5 fail>0 时应收尾于 done_fail 提示 (锁死分支选择)
case "$OUT" in
*"health.done_fail"*) ok ;;
*) bad "T5: fail=1 时应输出 health.done_fail 提示" ;;
esac

echo "==== health_summary_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
