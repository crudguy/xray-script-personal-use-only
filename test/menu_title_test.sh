#!/usr/bin/env bash
# P2-4 界面对齐回归守卫 (纯 bash, 不依赖 jq / 真实菜单).
# 锁定标题栏与分隔线的"同宽同源":
#   (1) _disp_width 的 CJK 双宽计算与 wc -L 基准一致 (中文占 2 列);
#   (2) _menu_title 输出恒为 _MENU_RULE_WIDTH 列 (与 _menu_rule 等宽), 中英文标题均对齐;
#   (3) 过长标题原样打印不截断; 空标题仍为满宽;
#   (4) menu.sh / share.sh 中旧的散落字面量标题/分隔线已全部替换为 _menu_title / _menu_rule.
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1" >&2; }
assert_eq(){ # $1=名称 $2=期望 $3=实际
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (期望 [$2] 实际 [$3])"; fi
}

COMMON=core/_common.sh
MENU=core/menu.sh
SHARE=core/share.sh

# --- 从 _common.sh 抽取真实函数体 (避免复制漂移) ---
extract_fn(){ # $1=file $2=funcname
    awk -v fn="$2" '
        $0 ~ ("^function " fn "\\(\\) \\{") { grab=1 }
        grab { print }
        grab && /^\}$/ { exit }
    ' "$1"
}

echo "== P2-4 界面对齐守卫 =="

COMMON_BODY="$(extract_fn "$COMMON" _disp_width)"$'\n'"$(extract_fn "$COMMON" _menu_rule)"$'\n'"$(extract_fn "$COMMON" _menu_title)"
if [[ -z "$COMMON_BODY" ]]; then
    bad "无法从 $COMMON 抽取 _disp_width/_menu_rule/_menu_title"
    echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi
# shellcheck disable=SC1090
eval "$COMMON_BODY"

_MENU_RULE_WIDTH=54
_DISP_WIDTH=0

# 独立基准: GNU coreutils wc -L (显示列宽, CJK 感知). 不可用则退化为跳过对照.
#
# ⚠️ 探测样本必须与实际比对样本【同类】: 原先用纯 ASCII 的 'a' 探测, 而任何 locale 下
# 'a' 的宽度都是 1 —— 守卫恒真, 于是 T2 拿着 CJK 串去比对一个在 C/POSIX locale 下
# 对多字节返回 0 的 oracle (中文测试: C locale=0 / C.UTF-8=8), 直接产出 6 处假红。
# 改用中文串探测: 只有 wc -L 真能识别双宽字符时才认为基准可用。
_HAS_WCL=0
if printf '中文\n' | wc -L >/dev/null 2>&1 && [[ "$(printf '中文\n' | wc -L)" == "4" ]]; then
    _HAS_WCL=1
fi
oracle_wc(){ printf '%s\n' "$1" | wc -L | tr -d '[:space:]'; }

# --- T1: _disp_width 基本正确性 ---
_disp_width "abc";                       assert_eq "disp_width ASCII 'abc' = 3" "3" "$_DISP_WIDTH"
_disp_width "中文测试";                    assert_eq "disp_width CJK '中文测试' = 8" "8" "$_DISP_WIDTH"
_disp_width "BBR 与内核网络加速";           assert_eq "disp_width 混合 'BBR 与内核网络加速' = 18" "18" "$_DISP_WIDTH"
_disp_width "xray-script-personal-use-only"; assert_eq "disp_width 主标题 = 29" "29" "$_DISP_WIDTH"
_disp_width "（只读）";                    assert_eq "disp_width 全角标点 = 8" "8" "$_DISP_WIDTH"
_disp_width "";                          assert_eq "disp_width 空串 = 0" "0" "$_DISP_WIDTH"

# --- T2: _disp_width 与 wc -L 基准逐条一致 ---
if (( _HAS_WCL )); then
    mism=0
    for s in "abc" "中文测试" "BBR 与内核网络加速" "xray-script-personal-use-only" \
             "（只读）" "Web 配置" "SNI Configuration" "配置备份与迁移" "one·two" ; do
        _disp_width "$s"; mine="$_DISP_WIDTH"; ref="$(oracle_wc "$s")"
        [[ "$mine" == "$ref" ]] || { mism=$((mism+1)); printf '    [diff] %q mine=%s wc-L=%s\n' "$s" "$mine" "$ref" >&2; }
    done
    assert_eq "disp_width 与 wc -L 基准全一致" "0" "$mism"
else
    ok "跳过 wc -L 对照 (无 GNU wc -L, 或当前 locale 非 UTF-8 导致多字节宽度不可信)"
fi

# --- T3: _menu_rule 恒为满宽纯 '-' ---
ru="$(printf '%s\n' "$(_menu_rule)")"
assert_eq "menu_rule 长度(字符) = 54" "54" "${#ru}"
_disp_width "$ru"; assert_eq "menu_rule 显示宽度 = 54" "54" "$_DISP_WIDTH"
case "$ru" in *[!-]*) bad "menu_rule 含非 '-' 字符" ;; *) ok "menu_rule 全为 '-'" ;; esac

# --- T4: _menu_title 对各真实标题恒为 54 列 (与分隔线等宽) ---
check_title(){ # $1=标题
    local t="$1" out w
    out="$(_menu_title "$t")"
    _disp_width "$out"; w="$_DISP_WIDTH"
    assert_eq "标题[$t] 宽=$w" "54" "$w"
}
check_title "卸载管理"
check_title "BBR 与内核网络加速"
check_title "xray-script-personal-use-only"
check_title "Configuration Management"
check_title "Web 配置"
check_title "客户端配置"
check_title "XHTTP 扩展配置(extra)"

# --- T5: _menu_title 左右以 '-' 起始/收尾 (包裹结构) ---
out="$(_menu_title "配置备份与迁移")"
case "$out" in -*) ok "标题行以 '-' 起始" ;; *) bad "标题行未以 '-' 起始" ;; esac
case "$out" in *-) ok "标题行以 '-' 收尾" ;; *) bad "标题行未以 '-' 收尾" ;; esac
case "$out" in *" 配置备份与迁移 "*) ok "标题文本被空格包裹" ;; *) bad "标题文本未被空格包裹" ;; esac

# --- T6: 过长标题原样打印 (不截断/不报错) ---
long="$(printf 'x%.0s' {1..60})"
out="$(_menu_title "$long")"
assert_eq "过长标题原样返回" "$long" "$out"

# --- T7: 空标题仍为满宽 54 ---
out="$(_menu_title "")"
_disp_width "$out"; assert_eq "空标题行宽 = 54" "54" "$_DISP_WIDTH"

# --- T8: 残留守卫 (旧字面量已全部替换) ---
if grep -rnE '\-{18} \$\(_i18n' "$MENU" "$SHARE" >/dev/null 2>&1; then
    bad "menu.sh/share.sh 仍残留旧标题字面量 '-{18} \$(_i18n'"
else
    ok "无残留旧标题字面量 (全部改用 _menu_title)"
fi
if grep -nE 'echo -e "-{54}"' "$MENU" "$SHARE" >/dev/null 2>&1; then
    bad "menu.sh/share.sh 仍残留 echo -e \"-{54}\" 分隔线"
else
    ok "无残留字面量分隔线 (全部改用 _menu_rule)"
fi
if grep -qF '_menu_title' "$MENU" && grep -qF '_menu_title' "$SHARE"; then
    ok "_menu_title 已在 menu.sh / share.sh 使用"
else
    bad "_menu_title 未在两个文件中使用"
fi
if grep -qF '_menu_rule' "$MENU"; then
    ok "_menu_rule 已在 menu.sh 使用"
else
    bad "_menu_rule 未在 menu.sh 使用"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
