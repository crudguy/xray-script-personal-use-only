#!/usr/bin/env bash
# P2-1 性能项回归守卫 (纯 bash, 不依赖 jq / 真实菜单).
# 锁定两项低成本性能修复:
#   (1) print_banner 不再 fork `bash generate.sh --random` 子进程, 改用内置 $RANDOM;
#   (2) load_i18n 加"已加载则跳过"守卫, 主循环每轮不再重展平 683 键 JSON.
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1" >&2; }

MENU=core/menu.sh
COMMON=core/_common.sh

echo "== P2-1 性能项守卫 =="

# T1: banner 改用 $RANDOM (不再 fork bash generate.sh --random 取随机 banner)
if grep -qF 'case $((RANDOM % 2)) in' "$MENU"; then
    ok "print_banner 使用内置 \$RANDOM"
else
    bad "print_banner 未改用 \$RANDOM"
fi
if grep -qF "bash \"\${GENERATE_PATH}\" '--random'" "$MENU"; then
    bad "menu.sh 仍 fork bash generate.sh --random 取 banner"
else
    ok "menu.sh 不再为随机 banner fork 子进程"
fi

# T2: load_i18n 加"已加载则跳过"守卫 (避免主循环每轮重展平 i18n)
if grep -qF '[[ -n "${I18N_MAP[*]:-}" ]]' "$COMMON"; then
    ok "load_i18n 含已加载守卫 (I18N_MAP 非空则 return)"
else
    bad "load_i18n 缺少已加载守卫"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
