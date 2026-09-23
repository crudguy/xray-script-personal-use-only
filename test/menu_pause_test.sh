#!/usr/bin/env bash
# =============================================================================
# 测试名称: menu_pause_test.sh
# 测试目标: 锁定"输出型命令执行后暂停" (_pause_after_action) 的行为与挂载范围。
#
# 背景: 菜单每轮重绘 ≈ 39 行 (banner 10 + 状态 7 + 菜单 21 + 提示 1), 而菜单 7 的
#   分享链接 + 二维码、菜单 10 的体检报告本身也是三四十行 —— 打印后立刻重绘会把
#   刚输出的内容整屏顶走 (24 行终端直接看不见), 用户只能上翻回看。
#   修复: 输出型命令后暂停, 读完再回菜单。
#
# 锁定:
#   1. main.sh 定义 _pause_after_action, 含 TTY 门控 / XRAY_MENU_PAUSE 三档 / q 退出;
#   2. 该函数恒返回 0 (不得污染调用方返回值), 唯一非 0 出口是 exit 0;
#   3. 只挂在输出型分支 7/8/10/11; 动作型 (1-6/9) 不得挂;
#   4. 行为: 回车回菜单 / q 与 Q 退出 / EOF 不触发 ERR trap / never 与非 TTY 的
#      auto 立即返回且不打印提示;
#   5. i18n: .main.pause_hint 在 zh / en 均存在且非空;
#   6. 安装收尾 (一键安装) 同属输出型: processes_full_installation 的两处快速安装
#      分支必须都挂暂停 (否则刚装好的分享链接会被菜单重绘顶出屏幕);
#   7. (NEG) 把 7) 分支的暂停去掉后, 静态守卫必须报错 —— 证明守卫不是摆设。
#
# 运行: bash test/menu_pause_test.sh
# =============================================================================
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not available in this environment"
    exit 0
fi

PASS=0; FAIL=0
# 传值/包含断言 (不依赖 $?, 规避 SC2319: $? 紧跟 [[ ]] 条件会被 shellcheck 判为风险)
assert_eq() { # $1=msg $2=got $3=expected
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $1 (got '$2' want '$3')"; fi
}
assert_ne() { # $1=msg $2=got $3=unexpected
    if [[ "$2" != "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $1 (got '$2' should not be '$3')"; fi
}
assert_contains() { # $1=msg $2=haystack $3=needle
    if [[ "$2" == *"$3"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $1 (missing '$3')"; fi
}
assert_not_contains() { # $1=msg $2=haystack $3=needle
    if [[ "$2" != *"$3"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $1 (unexpectedly has '$3')"; fi
}

SB=".workbuddy/tmp/menu_pause_$$"
rm -rf "$SB"; mkdir -p "$SB"
# EXIT trap: 断言失败提前退出时也要收掉沙箱
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

MAIN="${MENU_PAUSE_MAIN:-core/main.sh}"

# ---------------------------------------------------------------------------
# 被测函数体 (从 main.sh 原样抽出 —— 测真实实现, 不另写近似版)
# ---------------------------------------------------------------------------
fn_body="$(awk '/^function _pause_after_action\(\) \{/,/^\}/' "$MAIN")"
assert_ne "T1: main.sh 定义 _pause_after_action" "$fn_body" ""
if [[ -z "$fn_body" ]]; then
    echo "==== menu_pause_test: PASS=$PASS FAIL=$FAIL ===="
    exit 1
fi

# ---------------------------------------------------------------------------
# T1 静态机制: TTY 门控 / 三档开关 / q 退出 / set -e 安全 / 返回值卫生
# ---------------------------------------------------------------------------
assert_contains "T1a: 支持 XRAY_MENU_PAUSE 开关" "$fn_body" 'XRAY_MENU_PAUSE'
assert_contains "T1b: 含 TTY 门控 (-t 0)" "$fn_body" '-t 0'
assert_contains "T1c: 支持 never 档" "$fn_body" "'never'"
assert_contains "T1d: 支持 always 档 (供测试在管道下驱动)" "$fn_body" "'always'"
assert_contains "T1e: 处理 q 退出" "$fn_body" "'q'"
assert_contains "T1f: q 走 exit 0" "$fn_body" 'exit 0'
assert_contains "T1g: read 用 || 接住 EOF 非 0 (set -e 安全)" "$fn_body" 'read -r answer || answer='

# 返回值卫生: 除 exit 0 外不得有 return 非 0 —— 否则 `cmd; _pause_after_action`
# 会把分支返回值污染成非 0 (本项目已踩过"末条命令污染返回值"的同类坑)。
bad_ret="$(printf '%s\n' "$fn_body" | grep -E 'return[[:space:]]+[1-9]' || true)"
assert_eq "T1h: 无 return 非 0 (不污染调用方返回值)" "$bad_ret" ""

# ---------------------------------------------------------------------------
# T2 挂载范围: 只在 processes_index 的输出型分支, 动作型分支不得挂
# ---------------------------------------------------------------------------
awk '/^function processes_index\(\) \{/,/^\}/' "$MAIN" > "$SB/index.fn"
assert_ne "T2: 抽到 processes_index 函数体" "$(cat "$SB/index.fn")" ""

for n in 7 8 10 11; do
    line="$(grep -E "^[[:space:]]*${n}\)" "$SB/index.fn" || true)"
    assert_contains "T2a: 输出型分支 ${n}) 挂 _pause_after_action" "$line" '_pause_after_action'
done
for n in 1 2 3 4 5 6 9; do
    line="$(grep -E "^[[:space:]]*${n}\)" "$SB/index.fn" || true)"
    assert_not_contains "T2b: 动作型分支 ${n}) 不挂暂停" "$line" '_pause_after_action'
done

# ---------------------------------------------------------------------------
# T3 (NEG) 守卫自证: 去掉 7) 的暂停后, 同一套判据必须报"未挂"
# ---------------------------------------------------------------------------
sed '/^ *7) exec_handler/ s/; _pause_after_action//' "$MAIN" > "$SB/main_broken.sh"
awk '/^function processes_index\(\) \{/,/^\}/' "$SB/main_broken.sh" > "$SB/index_broken.fn"
line_broken="$(grep -E '^[[:space:]]*7\)' "$SB/index_broken.fn" || true)"
assert_ne "T3(NEG): 破损副本的 7) 分支抽到了内容" "$line_broken" ""
assert_not_contains "T3(NEG): 去掉 7) 暂停后守卫捕获到缺失" "$line_broken" '_pause_after_action'

# ---------------------------------------------------------------------------
# T4 行为: 用真实函数体 + 桩 _i18n 驱动 (set -Eeuo pipefail + ERR trap 与生产一致)
# ---------------------------------------------------------------------------
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'trap '"'"'echo "TRAP_HIT" >&2; exit 99'"'"' ERR'
    printf '%s\n' "YELLOW=''; NC=''"
    printf '%s\n' '_i18n() { printf "%s" "$1"; }'
    printf '%s\n' "$fn_body"
    printf '%s\n' '_pause_after_action'
    printf '%s\n' 'echo "RC=$?"'
} > "$SB/harness.sh"

run_case() { # $1=mode $2=末字符转义串 (喂给 printf %b)
    local mode="$1" payload="$2" out='' rc=0
    out="$(printf '%b' "${payload}" | XRAY_MENU_PAUSE="${mode}" bash "$SB/harness.sh" 2>&1)" || rc=$?
    printf '%s\n%s\n' "${rc}" "${out}"
}

res="$(run_case always '\n')"
rc="${res%%$'\n'*}"; out="${res#*$'\n'}"
assert_eq "T4a: 回车 -> rc=0" "${rc}" "0"
assert_contains "T4b: 回车后继续执行 (RC=0)" "${out}" 'RC=0'
assert_not_contains "T4c: 回车无 ERR trap" "${out}" 'TRAP_HIT'
assert_contains "T4d: always 下确实打印了暂停提示" "${out}" 'pause_hint'

res="$(run_case always 'q\n')"
rc="${res%%$'\n'*}"; out="${res#*$'\n'}"
assert_eq "T4e: q -> rc=0" "${rc}" "0"
assert_not_contains "T4f: q 当场退出 (未走到 RC= 回显)" "${out}" 'RC='
assert_not_contains "T4g: q 无 ERR trap" "${out}" 'TRAP_HIT'

res="$(run_case always 'Q\n')"
rc="${res%%$'\n'*}"; out="${res#*$'\n'}"
assert_eq "T4h: Q -> rc=0" "${rc}" "0"
assert_not_contains "T4i: Q 当场退出" "${out}" 'RC='

res="$(run_case always '')"
rc="${res%%$'\n'*}"; out="${res#*$'\n'}"
assert_eq "T4j: EOF (输入耗尽) rc=0, 未被 set -e 判死" "${rc}" "0"
assert_not_contains "T4k: EOF 无 ERR trap" "${out}" 'TRAP_HIT'
assert_contains "T4l: EOF 视作回车继续" "${out}" 'RC=0'

res="$(run_case never '\n')"
rc="${res%%$'\n'*}"; out="${res#*$'\n'}"
assert_eq "T4m: never -> rc=0" "${rc}" "0"
assert_not_contains "T4n: never 不暂停也不打印提示" "${out}" 'pause_hint'

res="$(run_case auto '\n')"
rc="${res%%$'\n'*}"; out="${res#*$'\n'}"
assert_eq "T4o: auto + 非 TTY (管道) -> rc=0" "${rc}" "0"
assert_not_contains "T4p: auto + 非 TTY 自动跳过暂停 (不阻塞脚本化调用)" "${out}" 'pause_hint'

# ---------------------------------------------------------------------------
# T5 i18n: 暂停提示文案 zh / en 双侧齐备且非空
# ---------------------------------------------------------------------------
for f in zh en; do
    v="$(jq -r '.main.pause_hint // ""' "i18n/${f}.json" 2>/dev/null || true)"
    assert_ne "T5: i18n/${f}.json 的 .main.pause_hint 非空" "${v}" ""
done

# ---------------------------------------------------------------------------
# T6 安装收尾也是一次"输出型": 一键安装的两个分支 (1) 与 *) 必须都挂暂停
#   背景: handler_quick_install 末尾打印分享链接 + 二维码 (handler.sh:3391) 与
#   订阅三件套 (3396), 三四十行; 不暂停则紧接的菜单重绘 (≈39 行) 把刚装好的
#   链接直接顶出屏幕 —— 正是用户"装完看不到分享链接"的那次反馈。
# ---------------------------------------------------------------------------
awk '/^function processes_full_installation\(\) \{/,/^\}/' "$MAIN" > "$SB/full.fn"
assert_ne "T6: 抽到 processes_full_installation 函数体" "$(cat "$SB/full.fn")" ""

# 判定规则: 每处 exec_handler '--quick' 起, 到本分支结束 (;;) 之间必须出现暂停调用。
quick_pause_report() { # $1=待检函数体文件
    awk '
        /exec_handler .--quick/ { in_blk=1; has=0; next }
        in_blk && /_pause_after_action/ { has=1 }
        in_blk && /;;/ { print (has ? "PAUSED" : "MISSING"); in_blk=0; seen=1 }
        END { if (!seen) print "NOQUICK" }
    ' "$1"
}

rep="$(quick_pause_report "$SB/full.fn")"
assert_eq "T6a: 两处快速安装分支都挂了暂停 (期望两行 PAUSED)" "$rep" "$(printf 'PAUSED\nPAUSED')"

# T6b: 快速安装分支确实打印了完成提示 (提示与暂停配套, 缺一即回归)
assert_eq "T6b: 完成提示出现在两处快速安装分支" "$(grep -c 'install_done_tip' "$SB/full.fn" || true)" "2"

# T6 (NEG): 删掉 1) 分支的暂停后, 同一套判据必须报 MISSING (守卫非摆设)
awk '
    /exec_handler .--quick/ { in_blk=1 }
    in_blk && /^[[:space:]]*_pause_after_action/ && !done { done=1; next }
    { print }
' "$MAIN" > "$SB/main_nopause.sh"
awk '/^function processes_full_installation\(\) \{/,/^\}/' "$SB/main_nopause.sh" > "$SB/full_nopause.fn"
assert_eq "T6(NEG): 删掉 1) 分支的暂停后守卫报 MISSING" \
    "$(quick_pause_report "$SB/full_nopause.fn")" "$(printf 'MISSING\nPAUSED')"

# T6c: 安装完成文案 zh / en 双侧非空 (与暂停提示配套展示)
for f in zh en; do
    v="$(jq -r '.main.install_done_tip // ""' "i18n/${f}.json" 2>/dev/null || true)"
    assert_ne "T6c(${f}): i18n/${f}.json 的 .main.install_done_tip 非空" "${v}" ""
done

# ---------------------------------------------------------------------------
echo "==== menu_pause_test: PASS=$PASS FAIL=$FAIL ===="
[[ $FAIL -eq 0 ]]
