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
#   3. 只挂在输出型分支 7/8/10/11 **以及** 4/5/6 (启停重启); 其余动作型 (1/2/3/9) 不得挂;
#      为什么 4/5/6 从"动作型"改判为"输出型": 它们原实现全程 `systemctl -q` 静默, 成功
#      一个字都不打印, 用户选完看着像没执行 —— 这不是"输出少", 而是"看起来没干活"。
#      现已在 handler_start/stop/restart 补齐"正在做 / 早已如此 / 做成了 / 没做成"四类
#      反馈 (见 xray_service_feedback_test.sh), 但摘要同样只有一两行, 33 行重绘照样把它
#      顶出一屏之外 —— 与菜单 7/8/10/11 是同一个坑, 故一并纳入挂载范围。
#      注意分层: 挂的只是**交互菜单**这条路; `bash script.sh --start` 这类 CLI 入口保持
#      不挂 (要能进 cron / 被外层脚本嵌套), 详见 xray_service_feedback_test.sh 的 D 组。
#   4. 行为: 回车回菜单 / q 与 Q 退出 / EOF 不触发 ERR trap / never 与非 TTY 的
#      auto 立即返回且不打印提示;
#   5. i18n: .main.pause_hint 在 zh / en 均存在且非空;
#   6. 安装收尾 (一键安装) 同属输出型: processes_full_installation 的两处快速安装
#      分支必须都挂暂停 (否则刚装好的分享链接会被菜单重绘顶出屏幕);
#   7. 配置更新收尾 (processes_xray_config 非 SNI 分支) 与 SNI 完整安装收尾
#      (processes_web_config 完整安装分支) 同样打分享三件套, 也必须挂暂停;
#   8. (NEG) 去掉 7) 分支 / web_config 收尾的暂停后, 静态守卫必须报错 —— 证明守卫不是摆设。
#   9. 管理配置下**所有**单动作分支 (本层 4/5/9 与 SNI 配置 / 路由规则 / 自定义站点 /
#      BBR / IPv6 / 备份 / 卸载 各级子菜单) 执行后都必须有一次暂停, 且顺序在动作之后 ——
#      用"记录调用顺序"的行为断言 (H:动作 / P / H:动作 / P …) 锁定, 不做形态 grep。
#   10. "预期内不可用"的拦截分支只要打印了告警就必须挂暂停 (非 SNI 模式下的 SNI 配置、
#      WARP 未开启时的分流、备份未填归档路径) —— 判据是"有没有向终端输出", 不是
#      "有没有执行动作"; 被菜单重绘顶走的告警同样等于用户看不到。
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

for n in 4 5 6 7 8 10 11; do
    line="$(grep -E "^[[:space:]]*${n}\)" "$SB/index.fn" || true)"
    assert_contains "T2a: 输出型分支 ${n}) 挂 _pause_after_action" "$line" '_pause_after_action'
done
for n in 1 2 3 9; do
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

# T3b (NEG): 同上, 针对 4) (启停反馈类)。T3 只证明"输出型"那套判据有效, 而 4/5/6 是
#   后来才并入挂载范围的 —— 必须单独自证, 否则将来漏挂暂停时守卫会静默放行。
sed '/^ *4) exec_handler/ s/; _pause_after_action//' "$MAIN" > "$SB/main_broken4.sh"
awk '/^function processes_index\(\) \{/,/^\}/' "$SB/main_broken4.sh" > "$SB/index_broken4.fn"
line_broken4="$(grep -E '^[[:space:]]*4\)' "$SB/index_broken4.fn" || true)"
assert_ne "T3b(NEG): 破损副本的 4) 分支抽到了内容" "$line_broken4" ""
assert_not_contains "T3b(NEG): 去掉 4) 暂停后守卫捕获到缺失" "$line_broken4" '_pause_after_action'

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
# 注: 匹配限定为行首的真实调用行 —— 若写成裸 /_pause_after_action/, 注释里
#     "见 _pause_after_action 的说明" 也会被算作"已挂", 令 NEG 假绿 (T7 踩到过)。
quick_pause_report() { # $1=待检函数体文件
    awk '
        /exec_handler .--quick/ { in_blk=1; has=0; next }
        in_blk && /^[[:space:]]*_pause_after_action/ { has=1 }
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
# T7 配置更新 / SNI 安装收尾同样是"输出型"
#   背景: processes_xray_config 的非 SNI 分支 (即「更新配置」: 改协议类型后重新安装)
#   与 processes_web_config 的完整安装分支, 末尾都打分享链接 + 二维码
#   (exec_handler '--share') 加订阅三件套 (share.sh --subscription), 三四十行。
#   不暂停则紧接的菜单重绘把刚生成的分享信息顶出屏幕 —— 与 T6 是同一个坑
#   (用户反馈: 更新配置后安装完直接跳菜单, 生成的分享信息被顶上去)。
# ---------------------------------------------------------------------------
awk '/^function processes_xray_config\(\) \{/,/^\}/' "$MAIN" > "$SB/xcfg.fn"
assert_ne "T7: 抽到 processes_xray_config 函数体" "$(cat "$SB/xcfg.fn")" ""
awk '/^function processes_web_config\(\) \{/,/^\}/' "$MAIN" > "$SB/wcfg.fn"
assert_ne "T7b: 抽到 processes_web_config 函数体" "$(cat "$SB/wcfg.fn")" ""

# 判定规则: 每处 exec_handler '--share' 起, 到本分支结束 (;;) 或函数末尾 (}) 之间,
#   必须出现暂停调用。
share_pause_report() { # $1=待检函数体文件
    awk '
        /exec_handler .--share/ { in_blk=1; has=0; next }
        in_blk && /^[[:space:]]*_pause_after_action/ { has=1 }
        in_blk && (/;;/ || /^}$/) { print (has ? "PAUSED" : "MISSING"); in_blk=0; seen=1 }
        END { if (!seen) print "NOSHARE" }
    ' "$1"
}

assert_eq "T7c: 更新配置收尾 (processes_xray_config) 挂了暂停" \
    "$(share_pause_report "$SB/xcfg.fn")" "PAUSED"
assert_eq "T7d: SNI 完整安装收尾 (processes_web_config) 挂了暂停" \
    "$(share_pause_report "$SB/wcfg.fn")" "PAUSED"

# T7e/T7f: 确认锚点分支确实是"会打分享信息"的那一支 —— 否则报告恒 NOSHARE
#          也不算通过 (守卫必须锚在有输出的分支上)。
assert_contains "T7e: 更新配置分支确实调用 --share" "$(cat "$SB/xcfg.fn")" "--share"
assert_contains "T7f: 更新配置分支确实生成订阅三件套" "$(cat "$SB/xcfg.fn")" '--subscription'
assert_contains "T7g: SNI 完整安装分支确实调用 --share" "$(cat "$SB/wcfg.fn")" "--share"

# T7 (NEG): 删掉 web_config 那个新增暂停后, 同一判据必须报 MISSING (守卫非摆设);
#           同时同一副本里 xray_config 的暂停不得被误伤 (仍 PAUSED)。
awk '
    /exec_handler .--share/ { in_blk=1 }
    in_blk && /^[[:space:]]*_pause_after_action/ && !done { done=1; next }
    { print }
' "$MAIN" > "$SB/main_nopause2.sh"
awk '/^function processes_web_config\(\) \{/,/^\}/' "$SB/main_nopause2.sh" > "$SB/wcfg_nopause.fn"
awk '/^function processes_xray_config\(\) \{/,/^\}/' "$SB/main_nopause2.sh" > "$SB/xcfg_nopause.fn"
assert_eq "T7h(NEG): 删掉 web_config 暂停后守卫报 MISSING" \
    "$(share_pause_report "$SB/wcfg_nopause.fn")" "MISSING"
assert_eq "T7i(NEG): 同一 NEG 副本里 xray_config 的暂停不受影响 (仍 PAUSED)" \
    "$(share_pause_report "$SB/xcfg_nopause.fn")" "PAUSED"

# ---------------------------------------------------------------------------
# T8 二级菜单一致性: 管理配置下的子菜单 (SNI 配置 / 设置语言 / 切换 CA / 修改 Web)
#   动作执行后也挂 _pause_after_action, 与主控菜单 4/5/6/7/8/10/11 同规则
#   (返回结果 + 提示"返回/退出", 不再静默跳回管理配置选择页)。
# ---------------------------------------------------------------------------
awk '/^function processes_sni_config\(\) \{/,/^\}/' "$MAIN" > "$SB/sni.fn"
awk '/^function processes_language\(\) \{/,/^\}/'  "$MAIN" > "$SB/lang.fn"
awk '/^function processes_ca_vendor\(\) \{/,/^\}/' "$MAIN" > "$SB/ca.fn"
awk '/^function processes_web_config\(\) \{/,/^\}/' "$MAIN" > "$SB/web.fn"

assert_contains "T8a: SNI 配置各动作后挂暂停"   "$(cat "$SB/sni.fn")" '_pause_after_action'
assert_contains "T8b: 设置语言后挂暂停"         "$(cat "$SB/lang.fn")" '_pause_after_action'
assert_contains "T8c: 切换 CA 厂商后挂暂停"     "$(cat "$SB/ca.fn")"  '_pause_after_action'
assert_contains "T8d: 修改 Web 配置后挂暂停"    "$(cat "$SB/web.fn")" '_pause_after_action'

# T8 (NEG): 去掉 languages 收尾的暂停后, 同一判据必须报缺失 (守卫非摆设)
awk '
    /_pause_after_action/ && !done { done=1; next }
    { print }
' "$SB/lang.fn" > "$SB/lang_nopause.fn"
assert_not_contains "T8(NEG): 去掉语言暂停后守卫捕获到缺失" "$(cat "$SB/lang_nopause.fn")" '_pause_after_action'

# ---------------------------------------------------------------------------
# T9 管理配置下的单动作分支 (行为级): 每个动作执行后必须有一次暂停, 且顺序在动作之后
#   背景: T8 只是形态 grep, 且覆盖范围漏了管理配置**本层**的单动作项 —— 4 改端口 /
#   5 GeoData Cron / 9 嗅探, 以及路由规则 / 自定义站点 / BBR / IPv6 / 备份 / 卸载
#   各级子菜单的动作分支。这些分支执行完直接落回 while 循环, 菜单立刻重绘, 把 handler
#   刚打印的结果整屏顶走 —— 用户反馈"执行后没停在结果页, 直接跳回选择页"。
#   判据: 跑真实函数体 (从 main.sh 原样抽出) + 桩 exec_handler / _pause_after_action,
#   两者都往同一个 trace 追加行 (H:<动作参数> / P), 再比对完整调用序列。既证明"挂了",
#   也证明"挂在动作之后"—— 形态 grep 做不到后者。
# ---------------------------------------------------------------------------

build_action_runner() { # $1=被测函数名 $2=exec_menu 返回序列字面量 (如 '4 5 9 0')
    local fn="$1" seq="$2"
    # 注: 拆两条 local —— 同一条里 runner=...$fn... 引用的是本语句尚未生效的 fn (SC2318)。
    local runner="$SB/run_${fn}.sh"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -Eeuo pipefail'
        printf '%s\n' 'TRACE="${TRACE_FILE:?}"'
        printf '%s\n' "GREEN=''; NC=''; YELLOW=''"
        printf '%s\n' "SCRIPT_CONFIG_PATH='/dev/null'"
        printf '%s\n' "CUR_FILE='handler'"
        printf '%s\n' '_i18n() { printf "%s" "$1"; }'
        printf '%s\n' 'print_warn() { :; }'
        # 受 FAKE_TAG 控制: 默认 sni (照常进菜单), 设 vision 即可测"非 SNI 模式"拦截分支
        printf '%s\n' 'jq() { printf "%s" "${FAKE_TAG:-sni}"; }'
        # 受 FAKE_WARP 控制: 默认 on (放行), 设 off 即可测"WARP 未开启"拦截分支。
        # 注: 不能用 `[[ ... ]] && return 0` —— 条件为假时该复合命令整体非 0, 在
        #     set -e 下会直接把脚本打死, 走不到后面的 print_warn/return 1。
        printf '%s\n' '_require_warp_enabled() {'
        printf '%s\n' '    if [[ "${FAKE_WARP:-on}" == "on" ]]; then return 0; fi'
        printf '%s\n' '    print_warn warp_off'
        printf '%s\n' '    return 1'
        printf '%s\n' '}'
        printf '%s\n' 'exec_handler() { printf "H:%s\n" "$*" >> "$TRACE"; }'
        printf '%s\n' '_pause_after_action() { printf "P\n" >> "$TRACE"; }'
        printf '%s\n' "SEQ=(${seq})"
        # ⚠ exec_menu 的调用点都是 `choose="$(exec_menu ...)"`, 即**子 shell**; 若用普通
        #   变量做游标, 递增只发生在子 shell 里, 父进程永远读到 SEQ[0] -> 死循环。
        #   故游标落文件。(真实 exec_menu 每次 fork menu.sh 子进程, 天然无此问题。)
        printf '%s\n' 'IDX_FILE="${TRACE}.idx"'
        printf '%s\n' 'printf "0" > "$IDX_FILE"'
        printf '%s\n' 'exec_menu() {'
        printf '%s\n' '    local i'
        printf '%s\n' '    i="$(cat "$IDX_FILE")"'
        printf '%s\n' '    printf "%s" "${SEQ[$i]:-0}"'
        printf '%s\n' '    printf "%s" "$((i+1))" > "$IDX_FILE"'
        printf '%s\n' '}'
        # 进入型子流程统一桩成 no-op; 被测函数若注入真实体会覆盖同名桩 (注入在后)
        for dep in processes_xray_config processes_routing processes_sni_config \
            processes_language processes_bbr processes_backup processes_ipv6 \
            processes_custom_sites processes_uninstall processes_web_config \
            processes_ca_vendor; do
            printf '%s\n' "${dep}() { :; }"
        done
        awk "/^function ${fn}\\(\\) \\{/,/^\\}/" "$MAIN" # 注入真实函数体
        printf '%s\n' "$fn"
    } > "$runner"
    printf '%s' "$runner"
}

run_trace() { # $1=函数名 $2=序列 $3=stdin 内容 (printf %b 格式, 可空) $4=额外环境变量 (VAR=val, 可空)
    local fn="$1" seq="$2" payload="${3:-}" runner trace
    local -a extra=()
    if [[ -n "${4:-}" ]]; then extra=("$4"); fi
    runner="$(build_action_runner "$fn" "$seq")"
    trace="$SB/trace_${fn}_$(printf '%s' "$seq" | tr -d ' ').txt"
    : > "$trace"
    if [[ -n "${payload}" ]]; then
        printf '%b' "${payload}" | env TRACE_FILE="$trace" "${extra[@]}" bash "$runner" >/dev/null 2>&1 || true
    else
        env TRACE_FILE="$trace" "${extra[@]}" bash "$runner" </dev/null >/dev/null 2>&1 || true
    fi
    cat "$trace"
}

assert_eq "T9a: 管理配置 4/5/9 三个单动作各自挂暂停 (H/P 交替)" \
    "$(run_trace processes_config '4 5 9 0')" \
    "$(printf 'H:--change-port\nP\nH:--geodata-cron\nP\nH:--sniff-route-only\nP')"
assert_eq "T9b: 路由规则每个动作后 (含末行重启) 挂暂停" \
    "$(run_trace processes_routing '3 4 0')" \
    "$(printf 'H:--routing block ip\nH:--restart\nP\nH:--routing block domain\nH:--restart\nP')"
assert_eq "T9c: 自定义站点增删改查后挂暂停" \
    "$(run_trace processes_custom_sites '1 4 0')" \
    "$(printf 'H:--custom-sites list\nP\nH:--custom-sites delete\nP')"
assert_eq "T9d: BBR 子菜单动作后挂暂停" \
    "$(run_trace processes_bbr '1 2 0')" \
    "$(printf 'H:--bbr\nP\nH:--net-status\nP')"
assert_eq "T9e: IPv6 子菜单动作后挂暂停" \
    "$(run_trace processes_ipv6 '2 3 0')" \
    "$(printf 'H:--ipv6-disable\nP\nH:--ipv6-disable-hard\nP')"
assert_eq "T9f: 备份导出后挂暂停" \
    "$(run_trace processes_backup '1 0')" \
    "$(printf 'H:--export-config\nP')"
assert_eq "T9g: 备份导入后挂暂停 (路径经 stdin 输入)" \
    "$(run_trace processes_backup '2 0' '/tmp/x.tar.gz\n')" \
    "$(printf 'H:--import-config /tmp/x.tar.gz\nP')"
assert_eq "T9h: 卸载两个动作后挂暂停" \
    "$(run_trace processes_uninstall '1')" \
    "$(printf 'H:--purge\nP')"

# T9i~T9k: "预期内不可用"的**拦截分支**同样会打印告警, 也必须挂暂停。
#   判据是"有没有向终端输出用户需要读的内容", 不是"有没有执行动作" —— 一句被菜单重绘
#   顶走的告警与一段被顶走的分享链接后果相同: 用户以为功能没反应。
#   (用户实测反馈: 选「3 SNI 配置」而当前非 SNI 模式时, 那句告警被顶走,
#   看起来就像"点了 3 什么都没发生"。)
assert_eq "T9i: 非 SNI 模式下选 SNI 配置, 告警后挂暂停再回菜单" \
    "$(run_trace processes_sni_config '0' '' 'FAKE_TAG=vision')" \
    "$(printf 'P')"
assert_eq "T9j: WARP 未开启时选 WARP 分流, 告警后挂暂停且不进 handler" \
    "$(run_trace processes_routing '5 0' '' 'FAKE_WARP=off')" \
    "$(printf 'P')"
assert_eq "T9k: 备份未填归档路径而取消, 告警后挂暂停" \
    "$(run_trace processes_backup '2 0')" \
    "$(printf 'P')"

# T9 (NEG) 守卫自证 1: 删掉管理配置 4) 的暂停 -> trace 少一次 P。
#   cmp 先证明变异真的落地 (sed 没匹配到时文件逐字节相同, 那种"变异"什么也没测)。
sed '/^ *4) exec_handler .--change-port/ s/; _pause_after_action//' "$MAIN" > "$SB/main_neg9.sh"
if cmp -s "$MAIN" "$SB/main_neg9.sh"; then
    FAIL=$((FAIL+1)); echo "  [FAIL] T9(NEG1): 变异未落地, sed 没匹配到 config 4) 那行"
else
    PASS=$((PASS+1))
fi
saved_main="$MAIN"; MAIN="$SB/main_neg9.sh"
assert_eq "T9(NEG1): 删掉 config 4) 的暂停后 trace 少一次 P" \
    "$(run_trace processes_config '4 5 9 0')" \
    "$(printf 'H:--change-port\nH:--geodata-cron\nP\nH:--sniff-route-only\nP')"
MAIN="$saved_main"

# T9 (NEG) 守卫自证 2: 循环末尾统一挂载的形态 (routing) 同样要能被守卫抓到 ——
#   这类函数没有把暂停写在 case 行上, 形态 grep 会漏; 行为断言必须仍然变红。
awk '
    /^function processes_routing\(\) \{/ { in_fn=1 }
    in_fn && /^}$/ { in_fn=0 }
    in_fn && /^[[:space:]]*_pause_after_action$/ && !done { done=1; next }
    { print }
' "$MAIN" > "$SB/main_neg9b.sh"
if cmp -s "$MAIN" "$SB/main_neg9b.sh"; then
    FAIL=$((FAIL+1)); echo "  [FAIL] T9(NEG2): 变异未落地, awk 没匹配到 routing 里的暂停调用"
else
    PASS=$((PASS+1))
fi
MAIN="$SB/main_neg9b.sh"
assert_eq "T9(NEG2): 删掉循环末尾的暂停后 trace 里 P 消失" \
    "$(run_trace processes_routing '3 0')" \
    "$(printf 'H:--routing block ip\nH:--restart')"
MAIN="$saved_main"

# T9 (NEG) 守卫自证 3: 拦截分支的暂停删掉后 trace 变空 —— 证明 T9i 的判据非恒真
awk '
    /^function processes_sni_config\(\) \{/ { in_fn=1 }
    in_fn && /^}$/ { in_fn=0 }
    in_fn && /^[[:space:]]*_pause_after_action$/ && !done { done=1; next }
    { print }
' "$MAIN" > "$SB/main_neg9c.sh"
if cmp -s "$MAIN" "$SB/main_neg9c.sh"; then
    FAIL=$((FAIL+1)); echo "  [FAIL] T9(NEG3): 变异未落地, awk 没匹配到 sni_config 里的暂停调用"
else
    PASS=$((PASS+1))
fi
MAIN="$SB/main_neg9c.sh"
assert_eq "T9(NEG3): 删掉非 SNI 拦截分支的暂停后 trace 变空" \
    "$(run_trace processes_sni_config '0' '' 'FAKE_TAG=vision')" ""
MAIN="$saved_main"

# ---------------------------------------------------------------------------
echo "==== menu_pause_test: PASS=$PASS FAIL=$FAIL ===="
[[ $FAIL -eq 0 ]]
