#!/usr/bin/env bash
# =============================================================================
# 回归测试: i18n 文案不得落在 printf 的**格式串**位置
# 运行: bash test/printf_format_test.sh
#
# 背景 (为什么固化成脚本):
#   旧写法 `printf "${RED}[$(_i18n '.title.error')] ${NC}%s\n" "$*"` 把译文放进格式串,
#   printf 会解释其中的 % —— 实测 i18n/zh.json 的 menu.route_management.info2
#   (含 URL 编码 %E4%BB%A3%E7%90%86) 走格式串时输出:
#       bash: printf: `B': invalid format character
#   且 %E4 被渲染成 0.000000E+004, 输出已损坏。更坏的情况是译文含 %x / %s 类格式串
#   时会去读栈上的后续参数, 构成信息泄露面。
#   修法: 格式串里只留 %s, 译文作为参数传入。本用例防止被改回去。
#
# 覆盖:
#   T1 静态守卫: 全仓不得出现 "printf "...$(_i18n" / ${title} / ${msg} / ${I18N_DATA[}
#   T2 行为: 标题译文含 % 时原样输出 (旧写法会损坏)
#   T3 行为: 真实 i18n 中含 % 的原文能原样输出
#   T4 守卫: 修法存在于 service/*.sh 三份同构实现中 (不只 core/)
#
# 依赖: bash, awk, grep, jq (T3 需要, 缺失则跳过)
# =============================================================================
set -Eeuo pipefail

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$REPO"

SB="$REPO/.workbuddy/tmp/printf_format.$$"
rm -rf "$SB" 2>/dev/null || true
mkdir -p "$SB"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

PASS=0; FAIL=0
assert_ok() { if eval "$1"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $2"; fi; }

# ---------------------------------------------------------------------------
# T1 静态守卫: 译文/变量不得出现在 printf 的格式串里
# ---------------------------------------------------------------------------
echo "[T1] 静态守卫: 无 i18n 处于 printf 格式串位置"
hit="$(grep -rnE 'printf[[:space:]]+"[^"]*\$\(_i18n' service/ core/ tool/ install.sh 2>/dev/null || true)"
if [[ -z "$hit" ]]; then assert_ok true '无 printf "...$(_i18n 形态'; else assert_ok false "仍在格式串内插值 -> $hit"; fi

hit2="$(grep -rnE 'printf[[:space:]]+"[^"]*\$\{(title|msg|I18N_DATA)\[' service/ core/ tool/ install.sh 2>/dev/null || true)"
if [[ -z "$hit2" ]]; then assert_ok true '无 printf "...${title}/${msg}/${I18N_DATA[} 形态'; else assert_ok false "变量仍在格式串内 -> $hit2"; fi

# ---------------------------------------------------------------------------
# T2 行为: 标题译文含 % 时原样输出
# ---------------------------------------------------------------------------
echo "[T2] 行为: 含 % 的标题原样输出"
# 抽取 check.sh 里真实的 _info, 用桩件提供颜色常量与 i18n
awk '/^function _info\(\) \{/{c=1} c{print} c&&/^\}$/{exit}' core/check.sh > "$SB/fns.sh"
if [[ ! -s "$SB/fns.sh" ]]; then
    echo "  [FAIL] 无法从 core/check.sh 抽取 _info"
    FAIL=$((FAIL+1))
else
    cat > "$SB/drv.sh" <<'DRV'
YELLOW=$'\033[33m'; GREEN=$'\033[32m'; RED=$'\033[31m'; NC=$'\033[0m'
_i18n() { printf '%s' 'INFO 100% done %E4%BB%A3 %x'; }
source "$1"
_info 'body message'
DRV
    out="$(bash "$SB/drv.sh" "$SB/fns.sh" 2>&1 || true)"
    if [[ "$out" == *'INFO 100% done %E4%BB%A3 %x'* ]]; then
        assert_ok true '含 % 的标题原样输出'
    else
        assert_ok false "标题被格式串改写 -> $out"
    fi
    if [[ "$out" == *'invalid format'* ]]; then assert_ok false 'printf 仍报 invalid format'; else assert_ok true '无 invalid format 报错'; fi
    if [[ "$out" == *'0.000000E'* ]]; then assert_ok false '%E4 仍被渲染成科学计数法'; else assert_ok true '无科学计数法污染'; fi
fi

# ---------------------------------------------------------------------------
# T3 行为: 真实 i18n 中含 % 的原文能原样输出
# ---------------------------------------------------------------------------
echo "[T3] 行为: 真实 i18n 含 % 的原文原样输出"
if command -v jq >/dev/null 2>&1; then
    sample="$(jq -r '[paths(scalars) as $p | getpath($p) | tostring] | map(select(test("%"))) | .[0] // empty' i18n/zh.json 2>/dev/null || true)"
    if [[ -z "$sample" ]]; then
        echo "  (跳过: zh.json 当前无含 % 的文案)"
    else
        cat > "$SB/drv2.sh" <<'DRV'
YELLOW=$'\033[33m'; GREEN=$'\033[32m'; RED=$'\033[31m'; NC=$'\033[0m'
_i18n() { printf '%s' "$SAMPLE"; }
source "$1"
_info 'body message'
DRV
        out2="$(SAMPLE="$sample" bash "$SB/drv2.sh" "$SB/fns.sh" 2>&1 || true)"
        if [[ "$out2" == *"$sample"* ]]; then
            assert_ok true "真实文案原样输出 (${sample:0:40}...)"
        else
            assert_ok false "真实文案被改写 -> $out2"
        fi
    fi
else
    echo "  (跳过: 无 jq)"
fi

# ---------------------------------------------------------------------------
#   T4 守卫: 日志函数(下沉后的唯一副本)已参数化 —— 锚 core/_common.sh
# ---------------------------------------------------------------------------
# 注: 这些函数原先在 service/*.sh 里各有三份逐字相同的副本, 已统一下沉到
#     core/_common.sh。守卫目标随之从 service/*.sh 改为 _common.sh —— 否则
#     "副本已删除"会被误判成"修法丢失"。
echo "[T4] 日志函数唯一副本 (core/_common.sh) 已参数化"
for fn in print_info print_warn print_error; do
    if grep -qE "^function ${fn}\(\) \{" core/_common.sh; then
        assert_ok true "_common.sh: 已定义 ${fn}"
    else
        assert_ok false "_common.sh: 缺少 ${fn}"
    fi
done
if grep -qE 'printf "\$\{GREEN\}\[%s\] \$\{NC\}%s' core/_common.sh; then
    assert_ok true '_common.sh: print_info 已参数化'
else
    assert_ok false '_common.sh: print_info 仍在格式串内插值'
fi

# ---------------------------------------------------------------------------
# T5 守卫: 已下沉的函数不得再出现重复定义 (install.sh 因需单文件自包含而豁免)
# ---------------------------------------------------------------------------
# 背景: cmd_exists 曾 4 份、_os* 各 3 份、print_* 各 3 份、_download_verified 3 份。
#       其中 _download_verified 是取代 `curl | bash` 的供应链防线, 开三个口子意味着
#       将来给一份补校验、另两份会静默保持裸奔。本守卫防止副本再生。
echo "[T5] 下沉后的函数为单一来源 (install.sh 自包含豁免)"
SINKED="cmd_exists|_os|_os_full|_os_ver|print_info|print_warn|print_error|_download_verified|is_local_nginx_installed"
dup="$(grep -rnE "^function ($SINKED)\(\)" core/ service/ tool/ install.sh 2>/dev/null \
      | grep -v '^install.sh:' | grep -v '^core/_common.sh:' || true)"
if [[ -z "$dup" ]]; then
    assert_ok true '除 install.sh 外无重复定义'
else
    assert_ok false "发现重复定义 -> $dup"
fi
# 反向守卫: _common.sh 必须真的提供了这些函数, 防止"删了副本却忘了落共享头"
for fn in cmd_exists _os _os_full _os_ver print_info print_warn print_error _download_verified is_local_nginx_installed; do
    if grep -qE "^function ${fn}\(\) \{" core/_common.sh; then
        assert_ok true "_common.sh 提供 ${fn}"
    else
        assert_ok false "_common.sh 缺少 ${fn}"
    fi
done

# ---------------------------------------------------------------------------
# T6 守卫: cmd_exists 不得再走 eval (命令注入)
# ---------------------------------------------------------------------------
# 旧写法 `eval type "$cmd"`: 实测传入 'x; touch /tmp/marker' 会真的创建文件。
echo "[T6] cmd_exists 无 eval 注入面"
# 只看代码行: 注释形态 (`# 此前用 eval type`) 不计入, 避免守卫被文档误伤
ev="$(grep -rnE '^[[:space:]]*eval ' core/ service/ tool/ install.sh 2>/dev/null \
      | grep -E 'eval (type|"?\$)' || true)"
if [[ -z "$ev" ]]; then
    assert_ok true '无 eval 形式的命令探测'
else
    assert_ok false "仍存在 eval 命令探测 -> $ev"
fi
# 行为验证: 注入串不得产生副作用
tmpmark="$SB/cexmark"
mkdir -p "$tmpmark"
cat > "$SB/cex.sh" <<CEX
source "$REPO/core/_common.sh"
cmd_exists 'x; touch ${tmpmark}/pwned' >/dev/null 2>&1
CEX
bash "$SB/cex.sh" >/dev/null 2>&1 || true
if [[ -e "${tmpmark}/pwned" ]]; then
    assert_ok false 'cmd_exists 注入产生了副作用'
else
    assert_ok true 'cmd_exists 注入无副作用'
fi

echo
echo "==== printf_format_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
