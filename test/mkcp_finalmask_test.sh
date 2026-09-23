#!/usr/bin/env bash
# =============================================================================
# mKCP 配置 FinalMask 迁移回归测试。
#
# 背景: Xray-core 26.x 起 mKCP 的 seed/header 字段被移除, 改用 FinalMask。
#   旧 kcpSettings.seed = "xxx"  ->  新 streamSettings.finalMask.udp[0] =
#     {type:"mkcp-legacy", settings:{header:"", value:"xxx"}}
#   (官方: header 为空 = AES-128-GCM 加密, value 即密码; 旧 seed 语义完整保留)
#
# 锁定:
#   1. 模板 mKCP.json 不再含 kcpSettings.seed, 改为 finalMask.udp[0].type=mkcp-legacy;
#   2. handler.sh 注入逻辑把 seed 写入 finalMask.udp[0].settings.value, 不再写 kcpSettings.seed;
#   3. share.sh 从 finalMask.udp[].settings.value 反读 seed (分享链接 &seed= 不变);
#   4. (NEG) 旧 kcpSettings.seed 字段残留不应被读取。
#
# 运行: bash test/mkcp_finalmask_test.sh
# =============================================================================
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$REPO" || exit 1

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not available in this environment"
    exit 0
fi

PASS=0; FAIL=0
ok() { if [[ $1 -eq 0 ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $2"; fi; }
# 传值断言 (不依赖 $?, 规避 SC2319: $? 紧跟在 [[ ]] 条件后被 shellcheck 判为风险)
assert_eq() { # $1=msg $2=got $3=expected
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $1 (got '$2' want '$3')"; fi
}
assert_ne() { # $1=msg $2=got $3=unexpected
    if [[ "$2" != "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  [FAIL] $1 (got '$2' should not be '$3')"; fi
}

# ---------------------------------------------------------------------------
# T1: 模板结构 —— 无旧 seed, 有 finalMask.udp[0].type=mkcp-legacy
# ---------------------------------------------------------------------------
nseed=$(jq '.inbounds[]? | .streamSettings.kcpSettings | has("seed")' config/xray/mKCP.json | grep -c true)
assert_eq "T1: mKCP.json 模板 kcpSettings 不应含 seed 键" "$nseed" "0"

type_ok=$(jq -r '.inbounds[]? | select(.tag=="VLESS-mKCP") | .streamSettings.finalMask.udp[0].type' config/xray/mKCP.json)
assert_eq "T1b: finalMask.udp[0].type == mkcp-legacy" "$type_ok" "mkcp-legacy"

hdr_ok=$(jq -r '.inbounds[]? | select(.tag=="VLESS-mKCP") | .streamSettings.finalMask.udp[0].settings.header' config/xray/mKCP.json)
assert_eq "T1c: finalMask.udp[0].settings.header == \"\" (AES-GCM 模式)" "$hdr_ok" ""

# ---------------------------------------------------------------------------
# T2: 模拟 handler.sh 注入逻辑 (复用其真实 jq 语句) —— 注入后 value 正确, 旧字段消失
# ---------------------------------------------------------------------------
SEED="testseed123"
gen=$(jq --arg seed "$SEED" '
    .inbounds[1].streamSettings.finalMask |= (. // {"udp":[{"type":"mkcp-legacy","settings":{"header":"","value":""}}]})
    | .inbounds[1].streamSettings.finalMask.udp[0].settings.value = $seed' config/xray/mKCP.json)

val=$(echo "$gen" | jq -r '.inbounds[1].streamSettings.finalMask.udp[0].settings.value')
assert_eq "T2: 注入后 finalMask.udp[0].settings.value == seed" "$val" "$SEED"

old_seed=$(echo "$gen" | jq '.inbounds[1].streamSettings.kcpSettings | has("seed")')
assert_eq "T2b: 注入后 kcpSettings 不再含 seed 键 (旧字段已移除)" "$old_seed" "false"

# ---------------------------------------------------------------------------
# T3: 反读 —— 复用 share.sh 的真实 jq 逻辑, 从生成配置读回 seed
# ---------------------------------------------------------------------------
read_back=$(echo "$gen" | jq -r --argjson i 1 '
    .inbounds[$i].streamSettings.finalMask.udp[]?
    | select(.type=="mkcp-legacy")
    | .settings.value?
    | if . == null then empty else . end')
assert_eq "T3: 分享链接反读 seed == 注入值 (share.sh 逻辑)" "$read_back" "$SEED"

# ---------------------------------------------------------------------------
# T4: 静态守卫 —— handler/share 不再引用旧字段, 已切到 finalMask
# ---------------------------------------------------------------------------
if grep -qE 'kcpSettings\.seed[[:space:]]*=' core/handler.sh; then
    ok 1 "T4: handler.sh 仍写 kcpSettings.seed (应移除)"
else
    ok 0 "T4: handler.sh 不再写 kcpSettings.seed"
fi
if grep -qE 'finalMask\.udp\[0\]\.settings\.value' core/handler.sh; then
    ok 0 "T4b: handler.sh 写 finalMask.udp[0].settings.value"
else
    ok 1 "T4b: handler.sh 未写 finalMask.udp[0].settings.value"
fi
if grep -qE 'kcpSettings\.seed\?' core/share.sh; then
    ok 1 "T4c: share.sh 仍读 kcpSettings.seed? (应移除)"
else
    ok 0 "T4c: share.sh 不再读 kcpSettings.seed?"
fi
if grep -qE 'finalMask\.udp' core/share.sh; then
    ok 0 "T4d: share.sh 从 finalMask.udp 读取"
else
    ok 1 "T4d: share.sh 未从 finalMask.udp 读取"
fi

# ---------------------------------------------------------------------------
# T5 (NEG): 旧 kcpSettings.seed 字段残留不应被读取 (证明迁移彻底)
# ---------------------------------------------------------------------------
legacy=$(echo "$gen" | jq '.inbounds[1].streamSettings.kcpSettings.seed = "OLDSEED"')
read_legacy=$(echo "$legacy" | jq -r --argjson i 1 '
    .inbounds[$i].streamSettings.finalMask.udp[]?
    | select(.type=="mkcp-legacy")
    | .settings.value?
    | if . == null then empty else . end')
assert_eq "T5(NEG): 旧 kcpSettings.seed 残留后仍从 finalMask 读取" "$read_legacy" "$SEED"
assert_ne "T5b(NEG): 读取值不等于残留旧 seed" "$read_legacy" "OLDSEED"

# ---------------------------------------------------------------------------
echo "==== mkcp_finalmask_test: PASS=$PASS FAIL=$FAIL ===="
[[ $FAIL -eq 0 ]]
