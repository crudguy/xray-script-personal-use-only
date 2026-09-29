#!/usr/bin/env bash
# _i18n_sub 功能回归测试 (纯 bash, 不依赖 jq / 框架)
# 锁定 P2-3 修复: 原 "_i18n '...' | sed 's|${ph}|${val}|'" 的两类隐患 ——
#   1) 替换值为空时 sed 退化为 s|| 非法表达式, 在 set -Eeuo pipefail + ERR trap 下直接中止脚本;
#   2) 替换值含 sed 定界符(|)或 & 时, & 被当"整行匹配"注入、| 破坏表达式。
# 本测试在真实严格模式下验证 _i18n_sub 对以上场景安全且输出正确。
set -Eeuo pipefail

PASS=0
FAIL=0

# 抽取仓库内真实的 _i18n_sub 定义 (避免复制漂移)
SRC="$(awk '/^function _i18n_sub\(\) \{/,/^}/' core/_common.sh)"
if [[ -z "$SRC" ]]; then
    echo "FATAL: 未能从 core/_common.sh 抽取 _i18n_sub"; exit 1
fi
eval "$SRC"

# stub _i18n: 按 key 返回带占位符的模板 (模拟 i18n JSON 文本, 占位符为字面量)
_i18n() {
    case "$1" in
        .greet)  printf '%s' 'Hello ${name}, you are ${role}.' ;;
        .domain) printf '%s' 'Domain ${domain} ok' ;;
        .pipe)   printf '%s' 'val=${pipe}' ;;
        .amp)    printf '%s' 'val=${amp}' ;;
        .empty)  printf '%s' 'val=${empty}' ;;
        .double) printf '%s' 'removed=${removed} kept=${kept}' ;;
        .glob)   printf '%s' 'x=${star}y' ;;
        *)       printf '%s' "" ;;
    esac
}

assert() {
    local desc="$1" got="$2" exp="$3"
    if [[ "$got" == "$exp" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc"
        echo "  got: [$got]"
        echo "  exp: [$exp]"
    fi
}

# 1. 基础双占位符替换
got="$(_i18n_sub .greet '${name}' "Alice" '${role}' "admin")"
assert "basic-double" "$got" "Hello Alice, you are admin."

# 2. 空值 (原 sed 会因 s|| 触发 ERR trap —— 此处必须不中止)
got="$(_i18n_sub .domain '${domain}' "")"
assert "empty-val" "$got" "Domain  ok"

# 3. 值含定界符 | (原 sed 表达式会被破坏)
got="$(_i18n_sub .pipe '${pipe}' "a|b")"
assert "pipe-val" "$got" "val=a|b"

# 4. 值含 & (原 sed 会把 & 当作"整行匹配"注入)
got="$(_i18n_sub .amp '${amp}' "x&y")"
assert "amp-val" "$got" "val=x&y"

# 5. 双占位符 + 顺序
got="$(_i18n_sub .double '${removed}' "3" '${kept}' "7")"
assert "double-order" "$got" "removed=3 kept=7"

# 6. 值含 glob 字符 * (确保不被当作通配)
got="$(_i18n_sub .glob '${star}' "a*b")"
assert "glob-val" "$got" "x=a*by"

# 7. 占位符不在文本中 -> 原样返回 (不报错)
got="$(_i18n_sub .domain '${missing}' "zzz")"
assert "no-ph" "$got" 'Domain ${domain} ok'

# 8. 仅一个 ph/val 参数 (奇数保护)
got="$(_i18n_sub .domain '${domain}')"
assert "odd-args" "$got" 'Domain ${domain} ok'

echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
