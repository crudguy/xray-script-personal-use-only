#!/usr/bin/env bash
# =============================================================================
# 菜单编号一致性回归测试。
#
# 保证三层编号同步且连续:
#   1. core/menu.sh      —— 菜单打印的选项编号 (GREEN N.)
#   2. core/main.sh      —— case 分支编号 (N))
#   3. i18n/{zh,en}.json —— 键名 optionN
#
# 背景: 移除 Cloudreve 后, 管理配置与 SNI 配置菜单曾从 6 直接跳到 8 (7 号是
#       Cloudreve)。空档不影响功能, 但会让人误以为菜单坏了, 且三层极易改漏。
# 运行: bash test/menu_test.sh
# =============================================================================
set -Eeuo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

PASS=0; FAIL=0
assert_ok()  { if eval "$1"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $2"; fi; }
# 三参: assert_eq 实际值 期望值 描述
assert_eq()  { if [[ "$1" == "$2" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $3 (got '$1' want '$2')"; fi; }

# 取 core/menu.sh 中某 menu_* 函数的函数体 (定义行格式固定为 `function name() {`)
menu_block() {
    awk -v fn="$1" '$0 == "function " fn "() {" {f=1} f {print} f && /^}/ {exit}' core/menu.sh
}
# 取 core/main.sh 中某 processes_* 函数的函数体
proc_block() {
    awk -v fn="$1" '$0 == "function " fn "() {" {f=1} f {print} f && /^}/ {exit}' core/main.sh
}
# 取 i18n 文件里某块的原文 (大括号配平)
json_block() {
    awk -v key="\"$2\"" '
        !f && index($0, key) && index($0, "{") { f=1 }
        f { print; t=$0; d += gsub(/\{/,"{",t) - gsub(/\}/,"}",t); if (d==0) exit }
    ' "$1"
}
# 杂串中抽出所有编号, 归一成 "1 2 3"
seq_of() { grep -oE '[0-9]+' | tr '\n' ' ' | sed 's/ *$//'; }
# 生成 "1 2 ... N"
expect_seq() {
    local n="$1" out='' i=1
    while [[ "$i" -le "$n" ]]; do out+="$i "; i=$((i+1)); done
    printf '%s' "${out% }"
}
# 某菜单打印的选项编号序列
menu_nums() { printf '%s\n' "$(menu_block "$1")" | grep -oE '\$\{GREEN\}[0-9]+\.\$\{NC\}' || true; }

# ---------------------------------------------------------------------------
# T1: 每个 menu_* 的显示编号必须严格连续 1..N (无空档 / 无重复)
# ---------------------------------------------------------------------------
echo "[T1] 各菜单显示编号连续"
for fn in $(grep -oE '^function menu_[a-z_]+' core/menu.sh | awk '{print $2}' | sort -u); do
    nums="$(menu_nums "$fn" | seq_of || true)"
    n=0; for _v in $nums; do n=$((n+1)); done
    if [[ "$n" -eq 0 ]]; then
        assert_ok false "$fn: 未解析到任何选项编号"
        continue
    fi
    assert_eq "$nums" "$(expect_seq "$n")" "$fn: 编号连续 1..$n"
done

# ---------------------------------------------------------------------------
# T2: 曾出现空档的两个菜单 —— 显示编号 == case 分支编号 == i18n 键编号
# ---------------------------------------------------------------------------
echo "[T2] 管理配置 / SNI 配置 三层编号一致"
for pair in "menu_config processes_config config_management" \
            "menu_sni_config processes_sni_config sni_config"; do
    set -- $pair
    mfn="$1"; pfn="$2"; jblk="$3"
    mnums="$(menu_nums "$mfn" | seq_of || true)"
    pnums="$(proc_block "$pfn" | grep -oE '^[[:space:]]+[0-9]+\)' | seq_of || true)"
    znums="$(json_block i18n/zh.json "$jblk" | grep -oE '"option[0-9]+"' | grep -v '"option0"' | seq_of || true)"
    enums="$(json_block i18n/en.json "$jblk" | grep -oE '"option[0-9]+"' | grep -v '"option0"' | seq_of || true)"
    assert_eq "$pnums" "$mnums" "$mfn: 菜单显示编号 == case 分支编号"
    assert_eq "$znums" "$mnums" "$mfn: zh 键编号 == 显示编号"
    assert_eq "$enums" "$mnums" "$mfn: en 键编号 == 显示编号"
done

# ---------------------------------------------------------------------------
# T3: 说明行编号不得越界 (说明指向不存在的选项 = 用户困惑)
# ---------------------------------------------------------------------------
echo "[T3] 说明行编号不越界"
for pair in "menu_config config_management" "menu_sni_config sni_config"; do
    set -- $pair
    mfn="$1"
    n=0; for _v in $(menu_nums "$mfn" | seq_of || true); do n=$((n+1)); done
    info_nums="$(menu_block "$mfn" | grep -oE 'echo -e "[0-9]+\. ' | grep -oE '[0-9]+' | sort -u || true)"
    bad=''
    for i in $info_nums; do [[ "$i" -le "$n" ]] || bad+="$i "; done
    if [[ -z "$bad" ]]; then
        assert_ok true "$mfn: 说明行编号均在 1..$n 内"
    else
        assert_ok false "$mfn: 说明行编号越界 -> $bad"
    fi
done

# ---------------------------------------------------------------------------
echo
echo "==== menu_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
