#!/usr/bin/env bash
# =============================================================================
# 测试名称: heal_mkcp_test.sh
# 测试目标: 锁定 mKCP finalmask 类型 id 的"自适应自愈" (heal_mkcp_finalmask)。
#
# 背景 (接 mkcp_finalmask_test.sh):
#   Xray 26.6 把 finalmask 的类型 id 从 mkcp-aes128gcm 改名成 mkcp-legacy, 二者互不兼容。
#   上一轮把"按本机 xray 实测选定 id"做进了 handler 的 mkcp 分支 (每次更新配置都重写),
#   但**已落盘**的 mKCP 配置在用户升级/降级 Xray 后、却没有重跑"更新配置"时,
#   会因 id 过期而加载失败 (unknown config id)。本测试锁定自愈: 在 xray 安装/升级后、
#   启动前自动把已落盘 config 的 finalmask 写法按新 xray 实测重选并原地重写。
#
# 锁定:
#   1. 已落盘 config 用 mkcp-legacy 但本机 xray 只认 aes128gcm (≈ 升级到 26.3.27) ->
#      自愈重写为 aes128gcm, 并给出 healed 提示, 且保留 .bak 备份;
#   2. 反向 (已落盘 aes128gcm, 本机只认 legacy, ≈ 升级到 26.6+) -> 重写为 legacy;
#   3. 已落盘写法本机已接受 -> 自愈**不动** (幂等, 不打扰正常 config);
#   4. 非 mKCP 配置 (network != kcp) -> 自愈早退, 不动;
#   5. 配置不存在 -> 自愈早退 (全新安装本就无 config);
#   6. 校验失败但错误与 finalmask 无关 (如 routing) -> 自愈不动, 避免乱重写;
#   7. (NEG) 去掉"错误关键词过滤"后, 对非 finalmask 错误也会乱改 -> 证明该过滤非虚设。
#
# 运行: bash test/heal_mkcp_test.sh
# =============================================================================
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not available in this environment"
    exit 0
fi

PASS=0; FAIL=0
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

HEAL_HANDLER="${HEAL_HANDLER:-core/handler.sh}"
SEED='heal-seed-xyz'

SB=".workbuddy/tmp/heal_mkcp_$$"
rm -rf "$SB"; mkdir -p "$SB/bin" "$SB/cfg"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

# 桩 xray: 按 STUB_ACCEPT 决定接受哪种 finalmask id; STUB_BREAK_ROUTING=1 时对含
# __break_routing__ 的配置报一个"与 finalmask 无关"的错误 (用于锁定错误过滤逻辑)。
cat > "$SB/bin/xray" <<'STUB'
#!/usr/bin/env bash
cfg=''; prev=''
for a in "$@"; do
  if [[ "$prev" == '-config' ]]; then cfg="$a"; fi
  prev="$a"
done
if [[ -z "$cfg" || ! -f "$cfg" ]]; then exit 0; fi
if [[ "${STUB_BREAK_ROUTING:-}" == '1' ]] && grep -q '__break_routing__' "$cfg"; then
  echo 'routing rule is invalid (unrelated to finalmask)' >&2
  exit 23
fi
acc="${STUB_ACCEPT:-aes128gcm}"
has_legacy=0; has_aes=0
grep -q '"mkcp-legacy"' "$cfg" && has_legacy=1
grep -q '"mkcp-aes128gcm"' "$cfg" && has_aes=1
if [[ "$has_legacy" -eq 1 && "$acc" != 'legacy' ]]; then
  echo 'failed to build mask with type mkcp-legacy > unknown config id: mkcp-legacy' >&2
  exit 23
fi
if [[ "$has_aes" -eq 1 && "$acc" != 'aes128gcm' ]]; then
  echo 'failed to build mask with type mkcp-aes128gcm > unknown config id: mkcp-aes128gcm' >&2
  exit 23
fi
exit 0
STUB
chmod +x "$SB/bin/xray"

# 从被测脚本原样抽出真实函数体 (测真实实现, 不另写近似版)
mask_fn="$(awk '/^function _kcp_mask_json\(\) \{/,/^\}/' "$HEAL_HANDLER")"
verify_fn="$(awk '/^function _verify_xray_config\(\) \{/,/^\}/' "$HEAL_HANDLER")"
probe_fn="$(awk '/^function get_kcp_finalmask\(\) \{/,/^\}/' "$HEAL_HANDLER")"
heal_fn="$(awk '/^function heal_mkcp_finalmask\(\) \{/,/^\}/' "$HEAL_HANDLER")"
assert_ne "T0: 抽到 _kcp_mask_json 函数体" "$mask_fn" ""
assert_ne "T0b: 抽到 _verify_xray_config 函数体" "$verify_fn" ""
assert_ne "T0c: 抽到 get_kcp_finalmask 函数体" "$probe_fn" ""
assert_ne "T0d: 抽到 heal_mkcp_finalmask 函数体" "$heal_fn" ""

# 构造已落盘的 mKCP config (含指定 finalmask id)
mk_cfg() { # $1=outfile $2=type
    jq -nc --arg t "$2" --arg s "$SEED" '{
        inbounds: [
            {tag:"api"},
            {tag:"VLESS-mKCP", protocol:"vless",
             streamSettings:{network:"kcp", kcpSettings:{},
               finalmask:{udp:[{type:$t, settings:(if $t=="mkcp-legacy" then {header:"",value:$s} else {password:$s} end)}]}}}
        ]
    }' > "$1"
}
mk_nonkcp() { # $1=outfile
    jq -nc '{inbounds:[{tag:"api"},{tag:"VLESS-Vision",protocol:"vless",streamSettings:{network:"tcp"}}]}' > "$1"
}

# 组装 heal harness: 桩 _i18n/print_warn/_atomic_write/cmd_exists, 注入真实 verify/probe/mask/heal
build_harness() {
    local out="$1"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -Eeuo pipefail\n'
        printf '_i18n() { printf "%%s" "$1"; }\n'
        printf 'print_warn() { printf "WARN:%%s\\n" "$*" >> "%s"; }\n' "$SB/warn.log"
        printf 'cmd_exists() { command -v "$1" >/dev/null 2>&1; }\n'
        printf '_atomic_write() { local f="$1"; cat > "$f.tmp" && mv -f "$f.tmp" "$f"; }\n'
        printf "SCRIPT_CONFIG='%s'\n" "$(jq -nc --arg s "$SEED" '{xray:{kcp:$s}}')"
        # 真实脚本会注入的全局变量 (get_kcp_finalmask 用 TMPFILE_DIR/SCRIPT_CONFIG_DIR/SCRIPT_NAME 落临时文件)
        printf 'SCRIPT_NAME="xray-script"\n'
        printf 'SCRIPT_CONFIG_DIR="%s"\n' "$SB"
        printf 'TMPFILE_DIR="%s"\n' "$SB"
        printf '%s\n' "$mask_fn"
        printf '%s\n' "$verify_fn"
        printf '%s\n' "$probe_fn"
        printf '%s\n' "$heal_fn"
        printf 'heal_mkcp_finalmask\n'
        printf 'echo "RC=$?"\n'
    } > "$out"
}

run_heal() { # $1=config文件 $2=STUB_ACCEPT $3=STUB_BREAK_ROUTING(可选)
    local cfg="$1" accept="$2" brk="${3:-}" warn="$SB/warn.log"
    : > "$warn"
    PATH="$SB/bin:/usr/bin:/bin" STUB_ACCEPT="$accept" STUB_BREAK_ROUTING="$brk" \
        XRAY_CONFIG_PATH="$cfg" bash "$SB/heal.sh" >/dev/null 2>&1 || true
}
cfg_type() { jq -r '.inbounds[1].streamSettings.finalmask.udp[0].type' "$1" 2>/dev/null || true; }
warn_has() { grep -q "$1" "$SB/warn.log" 2>/dev/null && echo yes || echo no; }

# ---------------------------------------------------------------------------
# T1 已落盘 legacy, 本机只认 aes128gcm (≈ 升级到 26.3.27) -> 重写为 aes128gcm
# ---------------------------------------------------------------------------
build_harness "$SB/heal.sh"
mk_cfg "$SB/legacy.json" 'mkcp-legacy'
run_heal "$SB/legacy.json" 'aes128gcm'
assert_eq "T1: legacy->aes128gcm 已重写" "$(cfg_type "$SB/legacy.json")" 'mkcp-aes128gcm'
assert_eq "T1b: 重写后仍是合法 JSON" "$(jq -e . "$SB/legacy.json" >/dev/null 2>&1 && echo ok)" 'ok'
assert_eq "T1c: 给出 healed 提示" "$(warn_has '.handler.xray.kcp_mask_healed')" 'yes'
assert_eq "T1d: 写前已备份 .bak" "$([[ -f "$SB/legacy.json.bak" ]] && echo yes || echo no)" 'yes'
assert_eq "T1e: seed 落在 settings.password (aes128gcm 写法)" \
    "$(jq -r '.inbounds[1].streamSettings.finalmask.udp[0].settings.password' "$SB/legacy.json")" "$SEED"

# ---------------------------------------------------------------------------
# T2 已落盘 aes128gcm, 本机只认 legacy (≈ 升级到 26.6+) -> 重写为 legacy
# ---------------------------------------------------------------------------
mk_cfg "$SB/aes.json" 'mkcp-aes128gcm'
run_heal "$SB/aes.json" 'legacy'
assert_eq "T2: aes128gcm->legacy 已重写" "$(cfg_type "$SB/aes.json")" 'mkcp-legacy'
assert_eq "T2b: 给出 healed 提示" "$(warn_has '.handler.xray.kcp_mask_healed')" 'yes'
assert_eq "T2c: seed 落在 settings.value (legacy 写法)" \
    "$(jq -r '.inbounds[1].streamSettings.finalmask.udp[0].settings.value' "$SB/aes.json")" "$SEED"

# ---------------------------------------------------------------------------
# T3 已落盘写法本机已接受 -> 自愈不动 (幂等)
# ---------------------------------------------------------------------------
mk_cfg "$SB/ok.json" 'mkcp-aes128gcm'
run_heal "$SB/ok.json" 'aes128gcm'
assert_eq "T3: 已兼容 config 不被改动" "$(cfg_type "$SB/ok.json")" 'mkcp-aes128gcm'
assert_eq "T3b: 已兼容场景不打扰 (无提示)" "$(warn_has '.handler.xray.kcp_mask_healed')" 'no'
assert_eq "T3c: 已兼容场景不生成 .bak" "$([[ -f "$SB/ok.json.bak" ]] && echo yes || echo no)" 'no'

# ---------------------------------------------------------------------------
# T4 非 mKCP 配置 (network != kcp) -> 自愈早退不动
# ---------------------------------------------------------------------------
mk_nonkcp "$SB/nonkcp.json"
run_heal "$SB/nonkcp.json" 'aes128gcm'
assert_eq "T4: 非 mKCP 配置不被触碰" "$(jq -r '.inbounds[1].streamSettings.network' "$SB/nonkcp.json")" 'tcp'
assert_eq "T4b: 非 mKCP 场景无提示" "$(warn_has '.handler.xray.kcp_mask_healed')" 'no'

# ---------------------------------------------------------------------------
# T5 配置不存在 -> 自愈早退 (全新安装本就无 config)
# ---------------------------------------------------------------------------
rm -f "$SB/missing.json"
run_heal "$SB/missing.json" 'aes128gcm'
assert_eq "T5: 缺失 config 下无 .bak 生成" "$([[ -f "$SB/missing.json.bak" ]] && echo yes || echo no)" 'no'
assert_eq "T5b: 缺失 config 场景无提示" "$(warn_has '.handler.xray.kcp_mask_healed')" 'no'

# ---------------------------------------------------------------------------
# T6 校验失败但错误与 finalmask 无关 (routing) -> 自愈不动, 避免乱重写
# ---------------------------------------------------------------------------
mk_cfg "$SB/routing.json" 'mkcp-legacy'
# 注入一个与 finalmask 无关的坏标记, 让桩 xray 报 routing 错误
jq '. + {__break_routing__:true}' "$SB/routing.json" > "$SB/routing.json.tmp" && mv -f "$SB/routing.json.tmp" "$SB/routing.json"
run_heal "$SB/routing.json" 'aes128gcm' '1'
assert_eq "T6: 非 finalmask 错误下 config 不被改写" "$(cfg_type "$SB/routing.json")" 'mkcp-legacy'
assert_eq "T6b: 非 finalmask 错误下无 healed 提示" "$(warn_has '.handler.xray.kcp_mask_healed')" 'no'

# ---------------------------------------------------------------------------
# T7 (NEG) 守卫自证: 守卫逻辑是 "if ! grep 命中 finalmask/mkcp 关键词; then 跳过" ——
#     即错误与 finalmask 无关时**不**自愈, 避免乱重写。要证明这层过滤"在挡"而非恒绿,
#     把守卫改成"永远放行": 模式换成 '.' (任意非空错误都命中), 让 T6 那种与 finalmask
#     无关的 routing 错误也能混进来触发重写。若原过滤真是恒绿, 改不改都应不动; 实际破损
#     版会进入重写路径 (重写后复核仍因 routing 错误失败而回滚, 并打印 kcp_mask_heal_failed),
#     反向证明原守卫确实挡住了无关错误。仅替换模式串, 保留语法。
# ---------------------------------------------------------------------------
cp "$HEAL_HANDLER" "$SB/broken.sh"
# 仅替换这一行的模式串, 保留语法 (避免直接删行导致 if 语法残缺)
sed -i.bak "s/'finalmask|mkcp|unknown config id'/'.'/" "$SB/broken.sh"
broken_heal="$(awk '/^function heal_mkcp_finalmask\(\) \{/,/^\}/' "$SB/broken.sh")"
assert_ne "T7: 抽到破损副本的 heal 函数体" "$broken_heal" ""
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -Eeuo pipefail\n'
    printf '_i18n() { printf "%%s" "$1"; }\n'
    printf 'print_warn() { printf "WARN:%%s\\n" "$*" >> "%s"; }\n' "$SB/warn_neg.log"
    printf 'cmd_exists() { command -v "$1" >/dev/null 2>&1; }\n'
    printf '_atomic_write() { local f="$1"; cat > "$f.tmp" && mv -f "$f.tmp" "$f"; }\n'
    printf "SCRIPT_CONFIG='%s'\n" "$(jq -nc --arg s "$SEED" '{xray:{kcp:$s}}')"
    printf 'SCRIPT_NAME="xray-script"\n'
    printf 'SCRIPT_CONFIG_DIR="%s"\n' "$SB"
    printf 'TMPFILE_DIR="%s"\n' "$SB"
    printf '%s\n' "$mask_fn"
    printf '%s\n' "$verify_fn"
    printf '%s\n' "$probe_fn"
    printf '%s\n' "$broken_heal"
    printf 'heal_mkcp_finalmask\n'
} > "$SB/heal_neg.sh"
: > "$SB/warn_neg.log"
mk_cfg "$SB/neg.json" 'mkcp-legacy'
jq '. + {__break_routing__:true}' "$SB/neg.json" > "$SB/neg.json.tmp" && mv -f "$SB/neg.json.tmp" "$SB/neg.json"
PATH="$SB/bin:/usr/bin:/bin" STUB_ACCEPT='aes128gcm' STUB_BREAK_ROUTING='1' \
    XRAY_CONFIG_PATH="$SB/neg.json" bash "$SB/heal_neg.sh" >/dev/null 2>&1 || true
# NEG 信号: 破损守卫放行后, 自愈会真的进入重写路径 (重写后复核仍因 routing 错误失败而回滚,
# 并打印 kcp_mask_heal_failed); 而 T6 原守卫下啥也不打印。故以"是否出现 heal_failed"断言守卫非虚设。
# (config 类型因回滚仍是 mkcp-legacy, 故不能拿它做断言 —— 那是自愈"写后复核回滚"在正确工作)
assert_eq "T7(NEG): 去掉错误过滤后对非 finalmask 错误也会进入重写路径 (守卫非虚设)" \
    "$(grep -q 'kcp_mask_heal_failed' "$SB/warn_neg.log" 2>/dev/null && echo yes || echo no)" 'yes'

# ---------------------------------------------------------------------------
echo "==== heal_mkcp_test: PASS=$PASS FAIL=$FAIL ===="
[[ $FAIL -eq 0 ]]
