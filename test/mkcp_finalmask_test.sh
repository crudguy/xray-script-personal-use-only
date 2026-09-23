#!/usr/bin/env bash
# =============================================================================
# 测试名称: mkcp_finalmask_test.sh
# 测试目标: 锁定 mKCP 的 finalmask 写法 —— 尤其是"类型 id 由本机 xray 实测选定"这一点。
#
# 背景 (2026-09-23, 上游源码 + 用户实机报错双向确认):
#   Xray 26.x 把 mKCP 的 seed/header 移出 kcpSettings, 迁进 streamSettings.finalmask。
#   但类型 id 在 26.6 前后又改过一次名, 两种写法互不兼容, 写错任一边都会被 xray 以
#   "unknown config id" 拒绝加载**整份**配置:
#     A) mkcp-legacy    + settings.{header:"", value:"<seed>"}   26.6 起 / 当前主线
#     B) mkcp-aes128gcm + settings.password:"<seed>"             26.2.6 ~ 26.5.x
#   两者线上协议一致 (空 header + 密码 = AES-128-GCM, 密码即旧 seed), 只是配置写法不同。
#   实测: 26.3.27 报 `unknown config id: mkcp-legacy`; 26.5.9 源码里只有 mkcp-aes128gcm;
#   26.6.27 起源码里只剩 mkcp-legacy。
#
# 锁定:
#   1. 模板 mKCP.json 不含 kcpSettings.seed, 也不得硬编码任何版本相关的 finalmask id
#      (硬编码正是本次故障根因: 模板写 A, 机器上是 B, 整份配置加载失败);
#   2. _kcp_mask_json 按 id 正确拼装两种写法 (字段名不同: value vs password);
#   3. get_kcp_finalmask 拿本机 xray 逐个试跑 (xray run -test), 取第一个被接受的写法;
#      探测不出来时返回非 0, 且不留临时文件;
#   4. handler 的 mkcp 分支: 探测成功 -> 写 finalmask (并清掉残留的 camelCase finalMask 旧键);
#      探测失败 -> 退回旧 kcpSettings.seed (宁可在 26.2+ 上明确报错, 也不留静默故障);
#   5. share.sh 反读 seed 时三种写法都要认 (value / password / kcpSettings.seed);
#   6. i18n .handler.xray.kcp_mask_fallback 在 zh / en 均存在;
#   7. (NEG) 把写法写死成 mkcp-legacy (正是回归发生时的样子) 后, 同一套判据必须报错 ——
#      证明这套断言真能挡住"又一次写死版本", 而不是恒绿。
#
# 运行: bash test/mkcp_finalmask_test.sh
#       可设 MKCP_HANDLER=<path> 指向破损副本做负向校验。
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

HANDLER="${MKCP_HANDLER:-core/handler.sh}"
TEMPLATE='config/xray/mKCP.json'
SEED='probe-seed-123'

SB=".workbuddy/tmp/mkcp_finalmask_$$"
rm -rf "$SB"; mkdir -p "$SB/cfg" "$SB/bin"
# EXIT trap: 断言失败提前退出时也要收掉沙箱
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# T1 模板: 既无旧 seed, 也不许硬编码任何 finalmask id (硬编码 = 上次故障的根因)
# ---------------------------------------------------------------------------
nseed=$(jq '.inbounds[]? | .streamSettings.kcpSettings | has("seed")' "$TEMPLATE" | grep -c true)
assert_eq "T1: 模板 kcpSettings 不含 seed 键" "$nseed" "0"

hard=$(jq -r '[.inbounds[]?.streamSettings | (has("finalmask") or has("finalMask"))] | any' "$TEMPLATE")
assert_eq "T1b: 模板不硬编码 finalmask (id 由运行时探测决定)" "$hard" "false"

caps=$(jq -r '.inbounds[]? | select(.tag=="VLESS-mKCP") | "\(.streamSettings.kcpSettings.uplinkCapacity)/\(.streamSettings.kcpSettings.downlinkCapacity)/\(.streamSettings.kcpSettings.congestion)"' "$TEMPLATE")
assert_eq "T1c: 迁移不得顺手删掉 kcpSettings 原有容量参数" "$caps" "100/100/true"

# ---------------------------------------------------------------------------
# 被测函数体: 从 handler.sh 原样抽出 —— 测真实实现, 不另写近似版
# ---------------------------------------------------------------------------
mask_fn="$(awk '/^function _kcp_mask_json\(\) \{/,/^\}/' "$HANDLER")"
probe_fn="$(awk '/^function get_kcp_finalmask\(\) \{/,/^\}/' "$HANDLER")"
assert_ne "T2: 抽到 _kcp_mask_json 函数体" "$mask_fn" ""
assert_ne "T2b: 抽到 get_kcp_finalmask 函数体" "$probe_fn" ""

# mkcp 分支在 handler 里出现多次 (另两处在 generate/read 的 case 中), 故按内容挑选:
# 逐个 mkcp 臂写文件, 取含 get_kcp_finalmask 的那个。
awk -v dir="$SB" '
    /^    mkcp\)$/ { n++; f=1; buf=$0 "\n"; next }
    f { buf = buf $0 "\n" }
    f && /^        ;;$/ { f=0; print buf > (dir "/arm_" n ".txt") }
' "$HANDLER"
ARM_FILE="$(grep -l 'get_kcp_finalmask' "$SB"/arm_*.txt 2>/dev/null | head -1 || true)"
assert_ne "T2c: 抽到 handler 的 mkcp 分支" "$ARM_FILE" ""
assert_eq "T2d: mkcp 分支在 handler 中唯一" "$(grep -l 'get_kcp_finalmask' "$SB"/arm_*.txt 2>/dev/null | wc -l | tr -d ' ')" "1"

if [[ -z "$mask_fn" || -z "$probe_fn" || -z "$ARM_FILE" ]]; then
    echo "==== mkcp_finalmask_test: PASS=$PASS FAIL=$FAIL ===="
    exit 1
fi

# ---------------------------------------------------------------------------
# T3 _kcp_mask_json: 两种写法的字段名必须各自正确
# ---------------------------------------------------------------------------
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' "$mask_fn"
    printf '%s\n' 'if _kcp_mask_json "$1" "$2"; then printf "\nRC=0\n"; else printf "\nRC=1\n"; fi'
} > "$SB/mask.sh"

legacy_json="$(bash "$SB/mask.sh" 'mkcp-legacy' "$SEED" 2>&1 || true)"
assert_contains "T3: mkcp-legacy 用 settings.value" "$legacy_json" '"value":"probe-seed-123"'
assert_contains "T3b: mkcp-legacy 的 header 为空串 (即 AES-128-GCM)" "$legacy_json" '"header":""'
assert_contains "T3c: 正常 id 返回 0" "$legacy_json" 'RC=0'

aes_json="$(bash "$SB/mask.sh" 'mkcp-aes128gcm' "$SEED" 2>&1 || true)"
assert_contains "T3d: mkcp-aes128gcm 用 settings.password" "$aes_json" '"password":"probe-seed-123"'
assert_not_contains "T3e: mkcp-aes128gcm 不带 value 字段" "$aes_json" '"value"'

unknown_json="$(bash "$SB/mask.sh" 'mkcp-nonsense' "$SEED" 2>&1 || true)"
assert_contains "T3f: 未知 id 返回非 0 (不静默生成错配置)" "$unknown_json" 'RC=1'

# ---------------------------------------------------------------------------
# T4 get_kcp_finalmask: 用桩 xray 驱动 (探测顺序 / 清理 / 探测不出的回退信号)
# ---------------------------------------------------------------------------
cat > "$SB/bin/xray" <<'STUB'
#!/usr/bin/env bash
# 桩 xray: 只认 STUB_MODE 指定的那一种写法; 记录被调用的配置路径以便断言探测次数。
cfg="${!#}"
printf '%s\n' "$cfg" >> "${STUB_LOG:-/dev/null}"
case "${STUB_MODE:-neither}" in
legacy)  grep -q '"mkcp-legacy"' "$cfg" ;;
aes)     grep -q '"mkcp-aes128gcm"' "$cfg" ;;
notest)  printf 'flag provided but not defined: -test\n' >&2; exit 2 ;;
*)       exit 1 ;;
esac
STUB
chmod +x "$SB/bin/xray"

{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'cmd_exists() { command -v "$1" >/dev/null 2>&1; }'
    printf '%s\n' "SCRIPT_NAME='xray-script-personal-use-only'"
    printf '%s\n' "SCRIPT_CONFIG_DIR='${SB}/cfg'"
    printf '%s\n' "TMPFILE_DIR=''"
    printf '%s\n' "$mask_fn"
    printf '%s\n' "$probe_fn"
    printf '%s\n' 'if get_kcp_finalmask "$1"; then printf "\nRC=0\n"; else printf "\nRC=1\n"; fi'
} > "$SB/probe.sh"

run_probe() { # $1=mode  $2=1 时把桩 xray 加入 PATH
    local mode="$1" with_stub="${2:-1}" path=''
    if [[ "$with_stub" == '1' ]]; then
        path="$SB/bin:/usr/bin:/bin"
    else
        path='/usr/bin:/bin'
    fi
    : > "$SB/calls.log"
    PATH="$path" STUB_MODE="$mode" STUB_LOG="$SB/calls.log" bash "$SB/probe.sh" "$SEED" 2>&1 || true
}

# 探测残留的临时文件数 (用 glob 而非 ls|grep: 文件名可能含非常规字符)
count_leftover() {
    local n=0 f=''
    for f in "$SB"/cfg/.*kcp*; do
        [[ -e "$f" ]] && n=$((n + 1))
    done
    printf '%s' "$n"
}

out_legacy="$(run_probe 'legacy')"
assert_contains "T4: 只认 mkcp-legacy 的 xray -> 探测出 mkcp-legacy" "$out_legacy" '"type":"mkcp-legacy"'
assert_contains "T4b: 探测成功返回 0" "$out_legacy" 'RC=0'
assert_eq "T4c: 命中首个候选即停 (只调一次 xray)" "$(wc -l < "$SB/calls.log" | tr -d ' ')" "1"
assert_eq "T4d: 探测不留临时文件" "$(count_leftover)" "0"

out_aes="$(run_probe 'aes')"
assert_contains "T4e: 只认 mkcp-aes128gcm 的 xray (26.3.27 实测所见)" "$out_aes" '"type":"mkcp-aes128gcm"'
assert_contains "T4f: 该场景返回 0" "$out_aes" 'RC=0'
assert_eq "T4g: 首个候选被拒后继续试第二个 (共调两次)" "$(wc -l < "$SB/calls.log" | tr -d ' ')" "2"

out_none="$(run_probe 'neither')"
assert_contains "T4h: 两种写法都被拒 -> 返回非 0 (交调用方回退)" "$out_none" 'RC=1'
assert_not_contains "T4i: 回退场景不得吐出任何 finalmask JSON" "$out_none" '"udp"'
assert_eq "T4j: 探测不留临时文件 (回退路径)" "$(count_leftover)" "0"

out_noflag="$(run_probe 'notest')"
assert_contains "T4k: xray 不支持 -test -> 返回非 0 (不硬猜写法)" "$out_noflag" 'RC=1'

if PATH='/usr/bin:/bin' command -v xray >/dev/null 2>&1; then
    echo "  [SKIP] T4l: 本机 /usr/bin 下真有 xray, 跳过'无 xray'用例"
else
    out_noxray="$(run_probe 'legacy' 0)"
    assert_contains "T4l: 本机无 xray -> 返回非 0" "$out_noxray" 'RC=1'
fi

# ---------------------------------------------------------------------------
# T5 handler 的 mkcp 分支: 端到端驱动真实分支 —— 桩 xray 决定这台机器"是什么版本"
#     (模板路径用 HARNESS_TEMPLATE 注入, 以便喂"带 camelCase 残留"的脏模板)
# ---------------------------------------------------------------------------
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' '_i18n() { printf "%s" "$1"; }'
    printf '%s\n' 'print_warn() { printf "[WARN] %s\n" "$*" >&2; }'
    printf '%s\n' 'cmd_exists() { command -v "$1" >/dev/null 2>&1; }'
    printf '%s\n' "SCRIPT_NAME='xray-script-personal-use-only'"
    printf '%s\n' "SCRIPT_CONFIG_DIR='${SB}/cfg'"
    printf '%s\n' "TMPFILE_DIR=''"
    printf '%s\n' "$mask_fn"
    printf '%s\n' "$probe_fn"
    printf '%s\n' 'XRAY_CONFIG="$(cat "${HARNESS_TEMPLATE}")"'
    printf '%s\n' "KCP_SEED='${SEED}'"
    printf '%s\n' 'CONFIG_TAG=mkcp'
    printf '%s\n' 'apply() {'
    printf '%s\n' '    case "${CONFIG_TAG,,}" in'
    cat "$ARM_FILE"
    printf '%s\n' '    esac'
    printf '%s\n' '}'
    printf '%s\n' 'apply'
    printf '%s\n' 'printf "%s" "$XRAY_CONFIG"'
} > "$SB/harness.sh"

# 脏模板: 模拟上个版本留下的 camelCase finalMask (Go 的 json 解码大小写不敏感, 并存看顺序)
jq '.inbounds[1].streamSettings.finalMask = {"udp":[{"type":"mkcp-legacy","settings":{"header":"","value":"STALE"}}]}' \
    "$TEMPLATE" > "$SB/dirty_template.json"

run_apply() { # $1=mode  $2=模板路径(可选)
    local mode="$1" tpl="${2:-$TEMPLATE}"
    PATH="$SB/bin:/usr/bin:/bin" STUB_MODE="$mode" STUB_LOG=/dev/null \
        HARNESS_TEMPLATE="$tpl" bash "$SB/harness.sh" 2>"$SB/err.txt" || true
}

cfg_legacy="$(run_apply 'legacy')"
assert_eq "T5: 26.6+ 机器 -> 写入 finalmask(mkcp-legacy)" \
    "$(printf '%s' "$cfg_legacy" | jq -r '.inbounds[1].streamSettings.finalmask.udp[0].type')" 'mkcp-legacy'
assert_eq "T5b: seed 落在 settings.value" \
    "$(printf '%s' "$cfg_legacy" | jq -r '.inbounds[1].streamSettings.finalmask.udp[0].settings.value')" "$SEED"
assert_eq "T5c: 现代写法下不再写 kcpSettings.seed" \
    "$(printf '%s' "$cfg_legacy" | jq -r '.inbounds[1].streamSettings.kcpSettings | has("seed")')" 'false'
assert_eq "T5d: 产出仍是合法 JSON" \
    "$(printf '%s' "$cfg_legacy" | jq -e . >/dev/null 2>&1 && echo ok)" 'ok'
assert_eq "T5e: 现代写法下不打印回退告警" "$(grep -c 'WARN' "$SB/err.txt" || true)" '0'

cfg_aes="$(run_apply 'aes')"
assert_eq "T5f: 26.3.27 机器 -> 写入 finalmask(mkcp-aes128gcm)" \
    "$(printf '%s' "$cfg_aes" | jq -r '.inbounds[1].streamSettings.finalmask.udp[0].type')" 'mkcp-aes128gcm'
assert_eq "T5g: seed 落在 settings.password" \
    "$(printf '%s' "$cfg_aes" | jq -r '.inbounds[1].streamSettings.finalmask.udp[0].settings.password')" "$SEED"
assert_eq "T5h: 该场景不打印回退告警" "$(grep -c 'WARN' "$SB/err.txt" || true)" '0'

cfg_fallback="$(run_apply 'neither')"
assert_eq "T5i: 探测不出 -> 退回旧写法 kcpSettings.seed" \
    "$(printf '%s' "$cfg_fallback" | jq -r '.inbounds[1].streamSettings.kcpSettings.seed')" "$SEED"
assert_eq "T5j: 回退时不得留下任何 finalmask (避免静默不生效)" \
    "$(printf '%s' "$cfg_fallback" | jq -r '[.inbounds[1].streamSettings | (has("finalmask") or has("finalMask"))] | any')" 'false'
assert_contains "T5k: 回退时给出提示 (提示走 stderr)" "$(cat "$SB/err.txt")" 'WARN'

cfg_dirty="$(run_apply 'legacy' "$SB/dirty_template.json")"
assert_eq "T5l: 注入前确带 camelCase finalMask (前置条件)" \
    "$(jq -r '.inbounds[1].streamSettings.finalMask.udp[0].settings.value' "$SB/dirty_template.json")" 'STALE'
assert_eq "T5m: 注入后被清理掉 (否则键名大小写并存, 取值看顺序)" \
    "$(printf '%s' "$cfg_dirty" | jq -r '.inbounds[1].streamSettings | has("finalMask")')" 'false'
assert_eq "T5n: 只留小写 finalmask, 值为本次注入的 seed" \
    "$(printf '%s' "$cfg_dirty" | jq -r '.inbounds[1].streamSettings.finalmask.udp[0].settings.value')" "$SEED"

# ---------------------------------------------------------------------------
# T6 share.sh 反读: 抽出真实 jq 表达式, 喂三种写法的配置
# ---------------------------------------------------------------------------
seed_block="$(sed -n '/^    CLIENT_CONFIG\[seed\]=/,/^            \/\/ "" )/p' core/share.sh)"
seed_jq="$(printf '%s\n' "$seed_block" | sed -e "1s/^[^']*'//" -e '$s/'"'"')"$//')"
assert_ne "T6: 抽到 share.sh 的 seed 反读 jq 表达式" "$seed_jq" ""
assert_contains "T6b: 反读认得 mkcp-legacy" "$seed_jq" 'mkcp-legacy'
assert_contains "T6c: 反读认得 mkcp-aes128gcm" "$seed_jq" 'mkcp-aes128gcm'
assert_contains "T6d: 反读保留对老配置 kcpSettings.seed 的兼容" "$seed_jq" 'kcpSettings.seed'

read_back() { # $1=配置 JSON
    printf '%s' "$1" | jq -r --argjson i 1 "$seed_jq"
}
assert_eq "T6e: finalmask(mkcp-legacy) -> 反读出 seed" "$(read_back "$cfg_legacy")" "$SEED"
assert_eq "T6f: finalmask(mkcp-aes128gcm) -> 反读出 seed" "$(read_back "$cfg_aes")" "$SEED"
assert_eq "T6g: 老配置 kcpSettings.seed -> 仍能反读" "$(read_back "$cfg_fallback")" "$SEED"
assert_eq "T6h: camelCase finalMask -> 也能反读 (兼容旧写入)" "$(read_back "$(cat "$SB/dirty_template.json")")" 'STALE'

# ---------------------------------------------------------------------------
# T7 静态守卫: 回退分支必须"明确提示 + 明确落旧字段", 不得静默硬猜
# ---------------------------------------------------------------------------
assert_contains "T7: 回退分支有提示" "$(cat "$ARM_FILE")" 'kcp_mask_fallback'
assert_contains "T7b: 回退分支写 kcpSettings.seed" "$(cat "$ARM_FILE")" 'kcpSettings.seed = $seed'
assert_not_contains "T7c: 分支内不再有硬编码的模板默认值写法" "$(cat "$ARM_FILE")" '|= (. //'

# ---------------------------------------------------------------------------
# T8 i18n: 回退提示双语齐备
# ---------------------------------------------------------------------------
zh_tip="$(jq -r '.handler.xray.kcp_mask_fallback // ""' i18n/zh.json)"
en_tip="$(jq -r '.handler.xray.kcp_mask_fallback // ""' i18n/en.json)"
assert_ne "T8: zh 回退提示非空" "$zh_tip" ""
assert_ne "T8b: en 回退提示非空" "$en_tip" ""

# ---------------------------------------------------------------------------
# T9 (NEG) 守卫自证: 换成"写法写死成 mkcp-legacy"的分支 (回归发生时的样子),
#     在"只认 aes128gcm"的机器上跑, 同一套判据 (T5f) 必须报错。
# ---------------------------------------------------------------------------
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' '_i18n() { printf "%s" "$1"; }'
    printf '%s\n' 'print_warn() { printf "[WARN] %s\n" "$*" >&2; }'
    printf '%s\n' 'cmd_exists() { command -v "$1" >/dev/null 2>&1; }'
    printf '%s\n' "SCRIPT_NAME='xray-script-personal-use-only'"
    printf '%s\n' "SCRIPT_CONFIG_DIR='${SB}/cfg'"
    printf '%s\n' "TMPFILE_DIR=''"
    printf '%s\n' "XRAY_CONFIG=\"\$(cat '${TEMPLATE}')\""
    printf '%s\n' 'KCP_MASK='"'"'{"udp":[{"type":"mkcp-legacy","settings":{"header":"","value":"'"$SEED"'"}}]}'"'"''
    printf '%s\n' 'XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson fm "${KCP_MASK}" '"'"'
        .inbounds[1].streamSettings |= (del(.finalMask) | .finalmask = $fm)'"'"')"'
    printf '%s\n' 'printf "%s" "$XRAY_CONFIG"'
} > "$SB/neg_harness.sh"

neg_cfg="$(PATH="$SB/bin:/usr/bin:/bin" STUB_MODE='aes' STUB_LOG=/dev/null bash "$SB/neg_harness.sh" 2>/dev/null || true)"
neg_type="$(printf '%s' "$neg_cfg" | jq -r '.inbounds[1].streamSettings.finalmask.udp[0].type' 2>/dev/null || true)"
assert_ne "T9: 破损副本确实产出了配置" "$neg_type" ""
assert_ne "T9b(NEG): 写死的写法在 aes-only 机器上被同一判据抓到 (判据非恒绿)" "$neg_type" 'mkcp-aes128gcm'

# ---------------------------------------------------------------------------
echo "==== mkcp_finalmask_test: PASS=$PASS FAIL=$FAIL ===="
[[ $FAIL -eq 0 ]]
