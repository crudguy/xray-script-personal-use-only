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
# 某菜单打印的说明行编号集合 (去重)
# 锚定 ${CYAN} 是刻意的: 说明行与选项行同样以 "N. " 起头, 若正则放宽成 '"[0-9]+\. ',
# 就会把选项行一并匹配进来, 而选项编号恒 <= 项数 —— 于是"说明行整段消失"这类改动
# 反而恒绿, 守卫形同虚设。抽不到任何说明行时 T3 直接判红, 不做静默跳过。
# 注: 末尾必须 tr 成空格分隔 —— sort -u 输出是换行分隔, 而下方用 `case " ${inums} "`
#     做"包含某个编号"的判断; 换行不是空格, 会让它恒不匹配, 报出一堆假的"缺说明"。
info_nums() {
    printf '%s\n' "$(menu_block "$1")" \
        | grep -oE 'echo -e "\$\{CYAN\}[0-9]+\. ' | grep -oE '[0-9]+' | sort -u | tr '\n' ' ' || true
}

# ---------------------------------------------------------------------------
# T1: 每个 menu_* 的显示编号必须严格连续 1..N (无空档 / 无重复)
# ---------------------------------------------------------------------------
# 函数名字符集必须含数字: 曾写作 [a-z_]+, 于是 menu_ipv6 被截断成不存在的
# "menu_ipv", 抽到空函数体 -> 报"未解析到任何选项编号"。这个失败信息指向的是
# 菜单有问题, 实际却是抽取正则的问题 —— 排查成本白花在错方向上。
echo "[T1] 各菜单显示编号连续"
for fn in $(grep -oE '^function menu_[a-z0-9_]+' core/menu.sh | awk '{print $2}' | sort -u); do
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
#     (BBR 与 IPv6 一并纳入: 它们同样是"菜单打印 / case 分派 / i18n 键"三层,
#      且 BBR 刚扩到 6 项、IPv6 是新加的, 正是最容易改漏的组合)
#     注: json_block 取的是第一个 `"key": {` —— menu 段在 handler/check 段之前,
#     所以 "bbr" / "ipv6" 稳定命中 menu 段那一份。
# ---------------------------------------------------------------------------
echo "[T2] 管理配置 / SNI 配置 / BBR / IPv6 三层编号一致"
for pair in "menu_config processes_config config_management" \
            "menu_sni_config processes_sni_config sni_config" \
            "menu_bbr processes_bbr bbr" \
            "menu_ipv6 processes_ipv6 ipv6"; do
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
# T3: 说明行编号不得越界, 且**每个选项都必须有说明**
#     (越界 = 说明指向不存在的选项; 缺项 = 选项无从得知是干什么的, 两者都让用户困惑)
#     背景: 管理配置的"设置语言"、SNI 配置的"强制续签/更新 nginx/nginx 自动更新/Web 配置"
#     曾长期没有说明行 (编号从 5 直接跳到 7、从 2 直接跳到 7), 而旧 T3 只查"越界",
#     恰好放过了这两处。
# ---------------------------------------------------------------------------
echo "[T3] 说明行编号不越界且不缺项"
# 例外是刻意的三类: 主菜单靠分组标题自解释; Web 配置是自动直通菜单 (不消费选择, 只有一项);
# 语言菜单只有"中文 / English"两项, 选项名即说明。
SKIP_INFO=' menu_index menu_web_config menu_language '
for fn in $(grep -oE '^function menu_[a-z0-9_]+' core/menu.sh | awk '{print $2}' | sort -u); do
    case "${SKIP_INFO}" in *" ${fn} "*) continue ;; esac
    nums="$(menu_nums "$fn" | seq_of || true)"
    n=0; for _v in $nums; do n=$((n+1)); done
    inums="$(info_nums "$fn")"
    if [[ -z "${inums}" ]]; then
        assert_ok false "$fn: 未抽到说明行 (说明行须以 \${CYAN} 起头)"
        continue
    fi
    bad=''; missing=''
    for i in $inums; do [[ "$i" -le "$n" ]] || bad+="$i "; done
    for i in $nums; do case " ${inums} " in *" ${i} "*) ;; *) missing+="$i " ;; esac; done
    if [[ -z "${bad}" && -z "${missing}" ]]; then
        assert_ok true "$fn: 说明行覆盖 1..$n 且不越界"
    else
        assert_ok false "$fn: 越界[${bad}] 缺说明的选项[${missing}]"
    fi
done

# ---------------------------------------------------------------------------
echo
echo "==== menu_test: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
