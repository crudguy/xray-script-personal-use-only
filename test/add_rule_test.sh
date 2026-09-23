#!/usr/bin/env bash
# add_rule 路由规则路径回归测试 (真实 jq, 抽函数体 + 桩件隔离)
#
# 历史: 路由菜单 3/4/5/6 调用的 add_rule 在"追加到末尾"分支曾写成
#   .routing.rules += $new_rule
# 而 $new_rule 是 jq -nc 构造的单个对象, 于是 jq 报
#   "array and object cannot be added"
# 这个 bug 在 6fcda2a (位置插入分支) 修了一半, 直到 0a0ecbf 才把三处追加分支补完,
# 期间两次才被用户用真实端口号踩出。根因是 test/ 从未覆盖 add_rule / 路由规则路径。
#
# 本测试锁死:
#   1. 行为层 —— 6 个分支 (末尾追加 / before / after / 数字索引 / 已存在规则追加去重 /
#      target 不存在回退末尾) 均能产出合法 JSON 且 ruleTag 顺序/值符合预期;
#   2. 静态契约 —— 三处追加分支必须写成 `+= [$new_rule]`, 三处位置插入必须写成
#      `+ [$new_rule] +`; 严禁出现裸 `+= $new_rule` (旧 bug 写法)。
#   回退到旧写法时, 行为用例的 jq 会报错 -> 结果非法 JSON -> 断言失败, 把 bug 挡在 CI。
#
# 运行: bash test/add_rule_test.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

HANDLER="core/handler.sh"
if [[ ! -r "$HANDLER" ]]; then
    echo "  [FAIL] 找不到 $HANDLER"
    exit 1
fi

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1" >&2; }

# --- 抽取 add_rule 函数体 (不加载整个 handler.sh, 避免其顶层副作用) ---
extract_fn() {
    awk -v name="$1" '$0 ~ ("^function " name "\\(\\) \\{") {f=1} f{print} f&&/^\}/{exit}' "$HANDLER"
}
SRC="$(extract_fn add_rule)"
if [[ -z "$SRC" ]]; then
    echo "  [FAIL] 未能从 $HANDLER 抽取 add_rule"
    exit 1
fi

# --- 桩件: persist_xray_config 改为空操作, 由 run_add 直接回读更新后的 XRAY_CONFIG ---
persist_xray_config() { :; }

# 加载抽出的函数体 (add_rule 可见 persist_xray_config 桩)
eval "$SRC"

# 执行一次 add_rule 并返回更新后的 routing.rules (紧凑 JSON)。
# $1 = 初始 Xray 配置 JSON; $2.. = 原样透传给 add_rule。
# 不用 set -e: 若 jq 报错 (旧 bug 形态), XRAY_CONFIG 会被赋空, 这里原样返回空串,
# 下游断言据"非法/空 JSON"判定失败, 给出清晰信息而非整脚本崩溃。
run_add() {
    local fixture="$1"; shift
    (
        XRAY_CONFIG="$fixture"
        add_rule "$@" 2>/dev/null
        printf '%s' "$XRAY_CONFIG"
    )
}

# 取 routing.rules 的 ruleTag 顺序, 用逗号连接
order() { printf '%s' "$1" | jq -r '[.routing.rules[].ruleTag] | join(",")'; }

echo "== add_rule 路由规则路径回归守卫 =="

# 基础夹具: routing.rules 含 api 与 private-ip 两条, 供 before/after/数字位插入
FIX='{"routing":{"rules":[{"ruleTag":"api","type":"field","inboundTag":["api"],"outboundTag":"api"},{"ruleTag":"private-ip","type":"field","ip":["geoip:private"],"outboundTag":"direct"}]}}'

# ---- T1 末尾追加 (无 target_tag / 无 position) —— 历史 bug 主战场 ----
# 同时验证: 逗号分隔值 -> JSON 数组 (新建路径本身不去重, 去重仅在"已存在规则追加"分支)
RES="$(run_add "$FIX" "ad-domain" "domain" "geosite:a,geosite:b" "block")"
LEN="$(printf '%s' "$RES" | jq -r '.routing.rules | length')"
if [[ "$LEN" == "3" ]]; then ok "T1: 末尾追加后 rules 长度=3"; else bad "T1: rules 长度应为 3, 实测 $LEN (res=$(printf '%s' "$RES" | tr '\n' '|'))"; fi
LAST_TAG="$(printf '%s' "$RES" | jq -r '.routing.rules[-1].ruleTag')"
if [[ "$LAST_TAG" == "ad-domain" ]]; then ok "T1: 末尾新增规则 ruleTag=ad-domain"; else bad "T1: 末尾应为 ad-domain, 实测 $LAST_TAG"; fi
DOM="$(printf '%s' "$RES" | jq -c '.routing.rules[-1].domain')"
if [[ "$DOM" == '["geosite:a","geosite:b"]' ]]; then ok "T1: domain 逗号拆分正确"; else bad "T1: domain 应为 [\"geosite:a\",\"geosite:b\"], 实测 $DOM"; fi
OUT="$(printf '%s' "$RES" | jq -r '.routing.rules[-1].outboundTag')"
if [[ "$OUT" == "block" ]]; then ok "T1: outboundTag=block"; else bad "T1: outboundTag 应为 block, 实测 $OUT"; fi

# ---- T2 before target: 插到 private-ip 之前 ----
RES="$(run_add "$FIX" "bt" "protocol" "bittorrent" "block" "before" "private-ip")"
ORD="$(order "$RES")"
if [[ "$ORD" == "api,bt,private-ip" ]]; then ok "T2: before private-ip -> api,bt,private-ip"; else bad "T2: 顺序应为 api,bt,private-ip, 实测 $ORD"; fi
LEN="$(printf '%s' "$RES" | jq -r '.routing.rules | length')"
if [[ "$LEN" == "3" ]]; then ok "T2: 长度=3 (插入非新增末尾)"; else bad "T2: 长度应为 3, 实测 $LEN"; fi

# ---- T3 after target: 插到 private-ip 之后 ----
RES="$(run_add "$FIX" "bt" "protocol" "bittorrent" "block" "after" "private-ip")"
ORD="$(order "$RES")"
if [[ "$ORD" == "api,private-ip,bt" ]]; then ok "T3: after private-ip -> api,private-ip,bt"; else bad "T3: 顺序应为 api,private-ip,bt, 实测 $ORD"; fi

# ---- T4 数字位置 0: 插到最前 ----
RES="$(run_add "$FIX" "bt" "protocol" "bittorrent" "block" "0")"
ORD="$(order "$RES")"
if [[ "$ORD" == "bt,api,private-ip" ]]; then ok "T4: 位置 0 -> bt,api,private-ip"; else bad "T4: 顺序应为 bt,api,private-ip, 实测 $ORD"; fi

# ---- T5 target 不存在 -> 回退到末尾追加 ----
RES="$(run_add "$FIX" "x" "domain" "d.com" "block" "before" "nonexistent")"
LEN="$(printf '%s' "$RES" | jq -r '.routing.rules | length')"
LAST_TAG="$(printf '%s' "$RES" | jq -r '.routing.rules[-1].ruleTag')"
if [[ "$LEN" == "3" && "$LAST_TAG" == "x" ]]; then ok "T5: target 不存在 -> 末尾追加 (x 在末位)"; else bad "T5: 应回退末尾追加, len=$LEN last=$LAST_TAG"; fi

# ---- T6 已存在 domain 规则 -> 追加值并去重 (不新增条目) ----
FIX6='{"routing":{"rules":[{"ruleTag":"ad-domain","type":"field","domain":["geosite:category-ads-all"],"outboundTag":"block"}]}}'
RES="$(run_add "$FIX6" "ad-domain" "domain" "geosite:category-ads-all,geosite:new" "block")"
LEN="$(printf '%s' "$RES" | jq -r '.routing.rules | length')"
if [[ "$LEN" == "1" ]]; then ok "T6: 已存在规则不新增条目 (长度=1)"; else bad "T6: 长度应为 1, 实测 $LEN"; fi
DOM="$(printf '%s' "$RES" | jq -c '.routing.rules[0].domain')"
if [[ "$DOM" == '["geosite:category-ads-all","geosite:new"]' ]]; then ok "T6: 已存在 domain 规则追加+去重正确"; else bad "T6: domain 应为 [\"geosite:category-ads-all\",\"geosite:new\"], 实测 $DOM"; fi

# ---- T7 静态契约: 禁止裸 `+= $new_rule`, 必须包成 [$new_rule] ----
# 先剔除整行注释: 源码注释里会刻意写下旧 bug 形态 `.routing.rules += $new_rule` 作说明,
# 若不过滤会把注释误判为代码 (N_BARE 虚高)。
SRC_NOCOMMENT="$(grep -v '^[[:space:]]*#' "$HANDLER")"
N_BARE="$(printf '%s\n' "$SRC_NOCOMMENT" | grep -cF '.routing.rules += $new_rule')"
if [[ "$N_BARE" -eq 0 ]]; then ok "T7: 无裸 .routing.rules += \$new_rule (array+object 回归已锁死)"; else bad "T7: 仍存在 $N_BARE 处裸 += \$new_rule (会触发 jq array+object 报错)"; fi

N_APPEND="$(printf '%s\n' "$SRC_NOCOMMENT" | grep -cF '.routing.rules += [$new_rule]')"
if [[ "$N_APPEND" -eq 3 ]]; then ok "T7: 三处追加分支均为 += [\$new_rule]"; else bad "T7: 追加分支 += [\$new_rule] 应为 3, 实测 $N_APPEND"; fi

N_POS="$(printf '%s\n' "$SRC_NOCOMMENT" | grep -cF '+ [$new_rule] +')"
if [[ "$N_POS" -eq 3 ]]; then ok "T7: 三处位置插入分支均为 + [\$new_rule] +"; else bad "T7: 位置插入 + [\$new_rule] + 应为 3, 实测 $N_POS"; fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
