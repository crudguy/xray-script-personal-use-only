#!/usr/bin/env bash
# =============================================================================
# 测试名称: handler_routing_arm_test.sh
# 测试目标: 路由分支的两段业务回归 ——
#             A) handler_routing 臂的**决策层**: WARP 门禁、rule_tag 构造、用户输入的取值来源;
#             B) add_rule 的**写入层**: 新规则/去重/target_tag 定位/数字位置/空值守卫。
#
# 为什么需要本测试 (审计背景):
#   handler_routing 与 add_rule 都属"改配置即改现场"的臂 —— add_rule 末尾直接
#   persist_xray_config, 写坏了 xray 侧马上有反应。此前这两段在全仓零覆盖。
#
#   历史 bug 有两条, 都是"看起来像能跑、实则从未真正执行"的类型, 必须钉住防止回潮:
#     1) 旧实现从 ${XRAY_CONFIG[${rule_tag}]} 取用户输入 —— XRAY_CONFIG 是**标量**
#        (存服务端配置全文), 且 "block-ip" 这类下标会触发 bash 算术求值, 在 set -u
#        下直接 "block: 未绑定的变量" 崩溃 —— 路由菜单几个选项从未真正走到 add_rule。
#     2) .routing.rules += $new_rule (少了方括号) —— array + object 让 jq 报
#        "array and object cannot be added", 三个追加分支各漏改过一次 (commit 6fcda2a)。
#   两条都发生了较为隐蔽的方式: 产品在运行中报错，或被用户点到才暴露。故此处用静态
#   守卫 + 行为断言双保险。
#
# 锁定不变量:
#   T1 WARP 门禁  —— warp 规则 + WARP 未启用 -> _error 中断, 且**不读输入、不写规则**
#   T2 放行       —— warp + 已启用 / block + 未启用 -> 正常走到 add_rule, 参数逐项核对
#   T3 缺字段     —— .xray.warp 缺失(jq 输出 "null")不得触发 bash 算术/未绑定变量噪声
#   T4 tag 构造   —— ${type}-${target} 传给 exec_read 与 add_rule
#   T5 取值来源   —— add_rule 第三参来自 CONFIG_DATA[rule_tag] (而非 XRAY_CONFIG[ ])
#   T6 空输入     —— CONFIG_DATA 缺键也不崩 (:- 兜底)
#   T7 静态契约   —— CLI 分派存在; handler_routing 体中没有 XRAY_CONFIG[ 下标取值;
#                    add_rule 体中没有裸 `+= $new_rule` (必须是 [$new_rule])
#   T8 add_rule   —— 追加/逗号拆分去重/空值守卫/已存在规则去重/target_tag before/after/
#                    目标不存在回落末尾/数字位置/幂等, 且恰好 persist 一次
#
# 实现: 从 core/handler.sh 抽**真实函数体** eval 注入 (不另写实现); 桩只替换外边界
#   (exec_read / add_rule / _error / persist_xray_config)。被 eval 的函数体经 ( ) 子
#   shell 调用 —— _error 的真实语义是 exit 1, 不用子 shell 承接就会带走整个测试。
# =============================================================================
set -Eeuo pipefail

REPO="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$REPO"

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not available in this environment"
    exit 0
fi

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1 (期望 [$3] 实际 [$2])"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok; else bad "$1 (未包含 [$3]，实际 [$2])"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok; else bad "$1 (不应包含 [$3]，实际 [$2])"; fi; }
# 计行 helper: 文件缺失记作 0 —— "不该有副作用"的用例本就不会生成该文件,
# 直接 grep -c 会退化成空串 (无匹配时 stdout 为空 + rc=1), 断言反而假红。
count_lines() { # $1=正则 $2=文件
    if [[ -f "$2" ]]; then
        grep -c "$1" "$2" || true
    else
        printf '0'
    fi
}

SB="$REPO/.workbuddy/tmp/handler_routing.$$"
rm -rf "$SB" 2>/dev/null || true
mkdir -p "$SB"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

extract_fn() { # $1=文件 $2=函数名
    awk -v fn="$2" '$0 ~ ("^function " fn "\\(\\) \\{") { g = 1 } g { print } g && /^\}$/ { exit }' "$1"
}

routing_fn="$(extract_fn core/handler.sh handler_routing)"
add_rule_fn="$(extract_fn core/handler.sh add_rule)"
is_en_fn="$(extract_fn core/_common.sh is_enabled)"
[[ -n "$routing_fn" ]] || bad "抽取 handler_routing 失败"
[[ -n "$add_rule_fn" ]] || bad "抽取 add_rule 失败"
[[ -n "$is_en_fn" ]] || bad "抽取 is_enabled 失败"
if [[ "$FAIL" -gt 0 ]]; then echo "==== handler_routing_arm_test: PASS=$PASS FAIL=$FAIL ===="; exit 1; fi

# ---------------------------------------------------------------------------
# T1-T6: handler_routing 的决策层
#
# 变量注入说明: 命令替换 (out="$(run_routing ...)") 会 fork 子 shell, 赋值前缀
#   (VAR=x cmd) **先做命令替换再赋值**, 桩件读不到 (2026-09-24 踩过) —— 故所有开关
#   都先单独 export 再跑; 轨迹文件每个用例独立, 避免累积污染。
# ---------------------------------------------------------------------------
SC_WARP_ON='{"xray":{"version":"v1","warp":1,"tag":"vision"}}'
SC_WARP_OFF='{"xray":{"version":"v1","warp":0,"tag":"vision"}}'
SC_WARP_MISSING='{"xray":{"version":"v1","tag":"vision"}}'

run_routing() { # 无参; 读 RT(type) RTG(target) READ_VAL PLOG SC_SEL
    declare -A CONFIG_DATA
    local plog="$PLOG"
    local rc=0
    # 下面两个变量只被 eval 注入的被测函数体读取 —— shellcheck 的数据流不跨 eval,
    # 会报 SC2034 (appears unused), 故逐个前置注释抑制。注意 shellcheck 的 directive
    # 必须**前置**于命令, 写在行尾会被当成普通注释并额外报 SC1126。
    # shellcheck disable=SC2034
    CUR_FILE='handler'
    # shellcheck disable=SC2034
    SCRIPT_CONFIG="${SC_SEL}"
    _i18n() { printf '%s' "${1#.}"; }
    _error() { printf 'ERR:%s\n' "$*" >&2; exit 1; }
    exec_read() {
        printf 'READ:%s\n' "${1:-}" >>"$plog"
        # WRITE_CFG=0 用于模拟"用户直接回车、exec_read 未落任何值"
        if [[ "${WRITE_CFG:-1}" == '1' ]]; then
            # shellcheck disable=SC2034
            CONFIG_DATA["${1:-}"]="${READ_VAL:-}"
        fi
        return 0
    }
    add_rule() {
        printf 'ADD:%s|%s|%s|%s\n' "${1:-}" "${2:-}" "${3:-}" "${4:-}" >>"$plog"
    }
    eval "$is_en_fn"
    eval "$routing_fn"
    # 子 shell 承接: _error 的真实语义是 exit 1, 直接调用会带走本进程
    (handler_routing "${RT:-}" "${RTG:-}") || rc=$?
    printf 'RC=%s\n' "$rc"
    cat "$plog" 2>/dev/null || true
}

SC_SEL="$SC_WARP_OFF" RT='warp' RTG='ip' READ_VAL='9.9.9.9' WRITE_CFG=1 PLOG="$SB/t1.log"
out="$(run_routing 2>"$SB/t1.err")"

echo "== T1 WARP 门禁: warp 规则 + WARP 未启用 =="
assert_contains "T1a rc=1 (_error 即中断)" "$out" 'RC=1'
assert_contains "T1b 打出错误行" "$(cat "$SB/t1.err")" 'ERR:'
assert_not_contains "T1c 未读用户输入" "$out" 'READ:'
assert_not_contains "T1d 未写任何规则" "$out" 'ADD:'

echo "== T2 放行: warp 已启用 / block 与 WARP 无关 =="
SC_SEL="$SC_WARP_ON" RT='warp' RTG='ip' READ_VAL='9.9.9.9' WRITE_CFG=1 PLOG="$SB/t2a.log"
out="$(run_routing 2>"$SB/t2a.err")"
assert_contains "T2a rc=0" "$out" 'RC=0'
assert_contains "T2b 读的是 warp-ip" "$out" 'READ:warp-ip'
assert_contains "T2c add_rule 四参正确" "$out" 'ADD:warp-ip|ip|9.9.9.9|warp'
SC_SEL="$SC_WARP_OFF" RT='block' RTG='domain' READ_VAL='a.com' WRITE_CFG=1 PLOG="$SB/t2b.log"
out="$(run_routing 2>"$SB/t2b.err")"
assert_contains "T2d block 规则不受 WARP 未启用影响" "$out" 'ADD:block-domain|domain|a.com|block'

echo "== T3 .xray.warp 字段缺失 (jq 输出字面 null) =="
SC_SEL="$SC_WARP_MISSING" RT='warp' RTG='ip' READ_VAL='9.9.9.9' WRITE_CFG=1 PLOG="$SB/t3.log"
out="$(run_routing 2>"$SB/t3.err")"
assert_contains "T3a 仍被门禁拦下 (rc=1)" "$out" 'RC=1'
assert_not_contains "T3b 无 bash 算术求值噪声" "$(cat "$SB/t3.err")" 'arithmetic'
assert_not_contains "T3c 无未绑定变量噪声" "$(cat "$SB/t3.err")" 'unbound'

echo "== T4 rule_tag 构造: type-target =="
SC_SEL="$SC_WARP_OFF" RT='block' RTG='ip' READ_VAL='1.2.3.4' WRITE_CFG=1 PLOG="$SB/t4.log"
out="$(run_routing 2>/dev/null)"
assert_contains "T4a exec_read 与 add_rule 用同一个 tag" "$out" 'READ:block-ip'
assert_contains "T4b add_rule 首参即该 tag" "$out" 'ADD:block-ip|ip|1.2.3.4|block'

echo "== T5 取值来源: 必须来自 CONFIG_DATA[rule_tag] =="
# 桩 exec_read 真实语义就是"把用户输入写进 CONFIG_DATA"; add_rule 拿到的必须是那个值,
# 而不是 SCRIPT_CONFIG / XRAY_CONFIG 里的任何东西 (见文件头历史 bug 1)。
assert_eq "T5a add_rule 第三参 == 用户输入" \
    "$(sed -n 's/^ADD:block-ip|ip|\(.*\)|block$/\1/p' "$SB/t4.log")" '1.2.3.4'

echo "== T6 空输入 (exec_read 未落值) 也不崩 =="
SC_SEL="$SC_WARP_OFF" RT='block' RTG='ip' READ_VAL='' WRITE_CFG=0 PLOG="$SB/t6.log"
out="$(run_routing 2>"$SB/t6.err")"
assert_contains "T6a rc=0" "$out" 'RC=0'
assert_contains "T6b 第三参为空串 (:- 兜底, 非未绑定变量)" "$out" 'ADD:block-ip|ip||block'
assert_not_contains "T6c 无 set -u 崩溃噪声" "$(cat "$SB/t6.err")" 'unbound'

# ---------------------------------------------------------------------------
# T8: add_rule 的写入层
# ---------------------------------------------------------------------------
# 输入配置: 三条既有规则, private-ip 位于中间 —— 用作 target_tag 定位的坐标。
# 注: 刻意保留与生产同构的形态 (ruleTag/outboundTag + domain|ip 数组)。
IN_RULES='{"log":{"loglevel":"warning"},"routing":{"domainStrategy":"AsIs","rules":[{"ruleTag":"private-ip","ip":["geoip:private"],"outboundTag":"direct"},{"ruleTag":"ban","domain":["a.com"],"outboundTag":"block"}]},"outbounds":[{"tag":"direct","protocol":"freedom"}]}'

run_add_rule() { # $@ = add_rule 的入参; 读 PLOG
    local plog="$PLOG"
    local rc=0
    # 下面两个变量只被 eval 注入的 add_rule 读取 —— shellcheck 的数据流不跨 eval,
    # 会报 SC2034 (appears unused), 故逐行抑制。
    # shellcheck disable=SC2034
    XRAY_CONFIG="$IN_RULES"          # 已注入 -> 不会去读 XRAY_CONFIG_PATH
    # shellcheck disable=SC2034
    XRAY_CONFIG_PATH="$SB/none.json" # 占位: 注入分支用不到, 仅为 set -u 安全
    _i18n() { printf '%s' "${1#.}"; }
    _warn() { printf 'WARN:%s\n' "$*" >&2; }
    persist_xray_config() { printf 'PERSIST\n' >>"$plog"; }
    eval "$add_rule_fn"
    # 注: add_rule 内部不调用 _error (落盘失败发生在桩掉的 persist_xray_config 里),
    #     故**不能用子 shell 包裹** —— `( add_rule )` 会 fork 独立进程, 函数体内对
    #     XRAY_CONFIG 的写回出不去, 父级 printf 到的永远是注入时的那份 (实测因此
    #     把"插入类"用例全变成了假绿 —— 断言的是未被修改的输入)。
    add_rule "$@" || rc=$?
    # 输出约定: 首行必须是配置本身 —— 上层的 ${out%%$'\n'RC=*} 依赖这个顺序。
    printf '%s\n' "$XRAY_CONFIG"
    printf 'RC=%s\n' "$rc"
    if [[ -f "$plog" ]]; then cat "$plog"; fi
    return 0
}

echo "== T8a 新规则追加到末尾, 既有规则与同层字段无损 =="
PLOG="$SB/t8a.log"
out="$(run_add_rule 'block-ip' 'ip' '1.2.3.4, 5.6.7.8' 'block' 2>"$SB/t8a.err")"
cfg="${out%%$'\n'RC=*}"
assert_contains "T8a-1 rc=0" "$out" 'RC=0'
assert_eq "T8a-2 persist 恰好一次" "$(count_lines '^PERSIST$' "$SB/t8a.log")" '1'
assert_eq "T8a-3 rules 长度 +1" "$(printf '%s' "$cfg" | jq -r '.routing.rules | length')" '3'
assert_eq "T8a-4 末项即新规则" \
    "$(printf '%s' "$cfg" | jq -c '.routing.rules[-1]')" \
    '{"ruleTag":"block-ip","ip":["1.2.3.4","5.6.7.8"],"outboundTag":"block"}'
assert_eq "T8a-5 既有规则未被改动" \
    "$(printf '%s' "$cfg" | jq -c '.routing.rules[0]')" \
    '{"ruleTag":"private-ip","ip":["geoip:private"],"outboundTag":"direct"}'
assert_eq "T8a-6 domainStrategy 等同层字段无损" \
    "$(printf '%s' "$cfg" | jq -r '.routing.domainStrategy')" 'AsIs'
assert_eq "T8a-7 outbounds 无损" "$(printf '%s' "$cfg" | jq -r '.outbounds | length')" '1'

echo "== T8b 脏输入: 多余逗号 / 空元素 / 首尾空格 =="
PLOG="$SB/t8b.log"
out="$(run_add_rule 'block-ip' 'ip' ' 1.2.3.4 ,, 5.6.7.8 ,' 'block' 2>"$SB/t8b.err")"
cfg="${out%%$'\n'RC=*}"
assert_eq "T8b-1 空元素被丢弃且去空格" \
    "$(printf '%s' "$cfg" | jq -c '.routing.rules[-1].ip')" '["1.2.3.4","5.6.7.8"]'

echo "== T8c 空输入 -> 告警 + 整份零改写 + 不落盘 (value_empty 守卫) =="
PLOG="$SB/t8c.log"
out="$(run_add_rule 'block-ip' 'ip' ' ,, ' 'block' 2>"$SB/t8c.err")"
cfg="${out%%$'\n'RC=*}"
assert_eq "T8c-1 配置逐字节不变" "$cfg" "$IN_RULES"
assert_contains "T8c-2 有告警" "$(cat "$SB/t8c.err")" 'WARN:'
assert_eq "T8c-3 未触发 persist" "$(count_lines '^PERSIST$' "$SB/t8c.log")" '0'
PLOG="$SB/t8c2.log"
out2="$(run_add_rule 'block-ip' 'ip' '' 'block' 2>"$SB/t8c2.err")"
assert_eq "T8c-4 完全空串同守卫" "${out2%%$'\n'RC=*}" "$IN_RULES"

echo "== T8d 规则已存在 -> 按类型合并去重 =="
PLOG="$SB/t8d1.log"
out="$(run_add_rule 'ban' 'domain' 'a.com,b.com' 'block' 2>"$SB/t8d1.err")"
cfg="${out%%$'\n'RC=*}"
assert_eq "T8d-1 rules 数量不变 (就地合并)" "$(printf '%s' "$cfg" | jq -r '.routing.rules | length')" '2'
assert_eq "T8d-2 domain 数组去重后合并" \
    "$(printf '%s' "$cfg" | jq -c '.routing.rules[] | select(.ruleTag=="ban") | .domain')" \
    '["a.com","b.com"]'
PLOG="$SB/t8d2.log"
out="$(run_add_rule 'ban' 'domain' 'a.com' 'block' 2>"$SB/t8d2.err")"
cfg="${out%%$'\n'RC=*}"
assert_eq "T8d-3 幂等: 重复值不再追加" \
    "$(printf '%s' "$cfg" | jq -c '.routing.rules[] | select(.ruleTag=="ban") | .domain')" \
    '["a.com"]'
PLOG="$SB/t8d3.log"
out="$(run_add_rule 'private-ip' 'ip' 'geoip:cn' 'direct' 2>"$SB/t8d3.err")"
cfg="${out%%$'\n'RC=*}"
assert_eq "T8d-4 ip 数组同样合并去重 (注: .ip |= unique 会把数组重排成字典序, 这是既有行为)" \
    "$(printf '%s' "$cfg" | jq -c '.routing.rules[] | select(.ruleTag=="private-ip") | .ip')" \
    '["geoip:cn","geoip:private"]'

echo "== T8e target_tag 定位插入 =="
PLOG="$SB/t8e1.log"
out="$(run_add_rule 'cn-ip' 'ip' 'geoip:cn' 'block' 'before' 'private-ip' 2>"$SB/t8e1.err")"
cfg="${out%%$'\n'RC=*}"
assert_eq "T8e-1 before: 插到目标之前" \
    "$(printf '%s' "$cfg" | jq -r '.routing.rules[0].ruleTag')" 'cn-ip'
assert_eq "T8e-2 before: 原首位后移" \
    "$(printf '%s' "$cfg" | jq -r '.routing.rules[1].ruleTag')" 'private-ip'
PLOG="$SB/t8e2.log"
out="$(run_add_rule 'cn-ip' 'ip' 'geoip:cn' 'block' 'after' 'private-ip' 2>"$SB/t8e2.err")"
cfg="${out%%$'\n'RC=*}"
assert_eq "T8e-3 after: 插到目标之后" \
    "$(printf '%s' "$cfg" | jq -r '[.routing.rules[].ruleTag] | join(",")')" \
    'private-ip,cn-ip,ban'
PLOG="$SB/t8e3.log"
out="$(run_add_rule 'cn-ip' 'ip' 'geoip:cn' 'block' 'after' 'no-such-tag' 2>"$SB/t8e3.err")"
cfg="${out%%$'\n'RC=*}"
assert_eq "T8e-4 目标不存在 -> 回落追加末尾" \
    "$(printf '%s' "$cfg" | jq -r '.routing.rules[-1].ruleTag')" 'cn-ip'

echo "== T8f 数字位置 (无 target_tag) =="
PLOG="$SB/t8f.log"
out="$(run_add_rule 'bt' 'protocol' 'bittorrent' 'block' 1 2>"$SB/t8f.err")"
cfg="${out%%$'\n'RC=*}"
assert_eq "T8f-1 插到索引 1" "$(printf '%s' "$cfg" | jq -r '.routing.rules[1].ruleTag')" 'bt'
assert_eq "T8f-2 动态键 protocol 正确落位" \
    "$(printf '%s' "$cfg" | jq -c '.routing.rules[1]')" \
    '{"ruleTag":"bt","protocol":["bittorrent"],"outboundTag":"block"}'

# ---------------------------------------------------------------------------
# T7: 静态契约 (防止历史 bug 回潮 / 调用点漂移)
# ---------------------------------------------------------------------------
echo "== T7 静态契约 =="
cli_line="$(grep -nE '^[[:space:]]*--routing\)[[:space:]]+handler_routing' core/handler.sh || true)"
assert_contains "T7a CLI 有 --routing 分派到 handler_routing" "$cli_line" 'handler_routing'
# 判据必须剥掉整行注释 —— 函数体注释里写明了历史 bug 的**坏写法** (XRAY_CONFIG[ ]),
# 不剥会自匹配成"仍然存在该 bug", 制造恒定的假红。
routing_nc="$(printf '%s\n' "$routing_fn" | grep -vE '^[[:space:]]*#' || true)"
assert_not_contains "T7b handler_routing 不得再按下标取 XRAY_CONFIG" \
    "$routing_nc" 'XRAY_CONFIG['
assert_contains "T7c 输入经 CONFIG_DATA[rule_tag] 传入" "$routing_nc" 'CONFIG_DATA[${rule_tag}]'
# 历史 bug 2: 少了方括号 -> jq 报 "array and object cannot be added"。
# 共 6 处操作点: 3 处追加到末尾 + before/after/数字位置各一处。
body_nc="$(printf '%s\n' "$add_rule_fn" | grep -vE '^[[:space:]]*#' || true)"
assert_eq "T7d add_rule 中无裸 += \$new_rule (会导致 array+object)" \
    "$(printf '%s\n' "$body_nc" | grep -c 'routing.rules += $new_rule' || true)" '0'
assert_eq "T7e 追加分支均写成 [\$new_rule]" \
    "$(printf '%s\n' "$body_nc" | grep -c 'routing.rules += \[$new_rule\]' || true)" '3'
assert_eq "T7f 六处插入/追加点全部包了方括号" \
    "$(printf '%s\n' "$body_nc" | grep -c '\[\$new_rule\]' || true)" '6'
assert_contains "T7g add_rule 末尾落盘" "$add_rule_fn" 'persist_xray_config'

echo "---"
echo "==== handler_routing_arm_test: PASS=$PASS FAIL=$FAIL ===="
[[ $FAIL -eq 0 ]]
