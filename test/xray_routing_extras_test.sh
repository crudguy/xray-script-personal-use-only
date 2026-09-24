#!/usr/bin/env bash
# =============================================================================
# 测试名称: xray_routing_extras_test.sh
# 测试目标: 锁定"配置增强三段"在本机 xray 支持面不同的机器上的行为 ——
#             1) observatory + routing.balancers: WARP 出站健康探测与自动回落;
#             2) 顶层 dns 段: 显式解析器, 不再依赖系统 resolver;
#             3) routing.domainStrategy: 有 IP 类规则时才切 IPIfNonMatch。
#
# 背景:
#   这三段都属于"低版本 xray 不认识就拒绝**整份**配置"的字段 (mKCP finalmask 有过
#   一次教训: 两种写法互不兼容, 写错一边整份被拒)。所以产品不再按版本号猜, 而是拿
#   本机二进制 run -test 实测后逐档降级。本测试用"按字段内容判定"的桩 xray 模拟
#   几类机器, 把这套降级链钉死。
#
# 锁定:
#   A  _xray_config_probe: 接受 / 拒绝 / 空片段 / 不留临时文件;
#   B  _xray_observatory_mode: full / plain 降级, 告警只打一次, 进程内只探测一次;
#   C  _warp_outbound_tag: 按形态给出 warp-out / warp;
#   D  _xray_apply_warp: full 形态出站改名 warp-out, 并清掉旧 warp 出站;
#   E  _xray_apply_warp_balancer: 注入内容逐字段核对; **不改写规则 tag**; 幂等;
#   F  降级形态下不写 balancer (它的 selector 会解析不到 warp-out);
#   G  未启用 WARP 时清掉残留的观测/均衡段;
#   H  handler_warp 关闭: 出站(两种 tag)/规则/观测/均衡四样一起清;
#   H2 handler_warp 开启: 同一次动作就写入观测/均衡 (不依赖后续"更新配置");
#   I  _xray_dns_mode / _xray_apply_dns: full -> minimal -> off 三档降级;
#   J  _xray_apply_domain_strategy: 有 IP 规则才切 IPIfNonMatch, 否则清掉残留。
#
# 运行: bash test/xray_routing_extras_test.sh
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

HANDLER="${EXTRAS_HANDLER:-core/handler.sh}"
COMMON="core/_common.sh"

SB=".workbuddy/tmp/xray_extras_$$"
rm -rf "$SB"; mkdir -p "$SB/bin" "$SB/cfg"
trap 'rm -rf "$SB" 2>/dev/null || true' EXIT

export PATH="$SB/bin:$PATH"
export SCRIPT_NAME='xray-script-personal-use-only'
export SCRIPT_CONFIG_DIR="$SB/cfg"
export TMPFILE_DIR="$SB"
XRAY_CALL_LOG="$SB/xray.log"
export XRAY_CALL_LOG
: > "$XRAY_CALL_LOG"
# 桩 xray 是**外部脚本** (子进程), 所以 STUB_MODE / XRAY_PROBE_COPY 必须 export ——
# 裸赋值只改当前 shell, 子进程读到的仍是默认值 (表现为所有模式都走 accept, 断言假绿)。
STUB_MODE='accept'
export STUB_MODE
XRAY_PROBE_COPY="$SB/last-probe.json"
export XRAY_PROBE_COPY

# ---- 桩 xray: 按"配置里出现了哪些字段"判定接受与否 ----
# 这正是真实世界的行为: 不认识的字段 -> 整份配置被拒 (而不是忽略该字段)。
cat > "$SB/bin/xray" <<'STUB_XRAY'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${XRAY_CALL_LOG:-/dev/null}"
[[ "${1:-}" == 'run' ]] || exit 0
cfg=''; prev=''
for a in "$@"; do
    [[ "$prev" == '-config' ]] && cfg="$a"
    prev="$a"
done
[[ -n "$cfg" && -f "$cfg" ]] || exit 0
[[ -n "${XRAY_PROBE_COPY:-}" ]] && cp -f "$cfg" "$XRAY_PROBE_COPY"
case "${STUB_MODE:-accept}" in
    no_observatory)   grep -q 'observatory' "$cfg" && exit 23 ;;
    dns_full_reject)  grep -qE 'queryStrategy|enableParallelQuery' "$cfg" && exit 23 ;;
    no_dns)           grep -q '"dns"' "$cfg" && exit 23 ;;
esac
exit 0
STUB_XRAY
chmod +x "$SB/bin/xray"

# ---- 从产品代码抽真实实现 (不另写一份, 避免与产品漂移) ----
extract() { # $1=函数名 $2=文件
    awk -v fn="$1" '$0 ~ "^function " fn "\\(\\) \\{" {f=1} f{print} f && /^}$/ {exit}' "$2"
}
for fn in _xray_bin_path _xray_config_probe _xray_observatory_mode _warp_outbound_tag \
          _warp_outbound_json _xray_apply_warp _xray_apply_warp_balancer \
          _xray_dns_mode _xray_apply_dns _xray_apply_domain_strategy handler_warp; do
    body="$(extract "$fn" "$HANDLER")"
    if [[ -z "$body" ]]; then
        echo "  [FAIL] 抽取产品函数失败: $fn"
        FAIL=$((FAIL+1))
    fi
    eval "$body"
done
eval "$(extract is_enabled "$COMMON")"
eval "$(extract cmd_exists "$COMMON")"

# 常量与产品同源 (WARP_ 与 XRAY_DNS_ 前缀)。经临时文件中转而非进程替换:
# 沙箱/CI 未必有 /dev/fd, 进程替换会静默失效 (表现为常量全空 -> 断言假绿)。
grep -E '^readonly (WARP_|XRAY_DNS_)' "$HANDLER" > "$SB/consts.sh"
while IFS= read -r line; do eval "$line"; done < "$SB/consts.sh"

# 产品里由 handler.sh 顶层赋值的三个缓存变量 (本测试只抽函数体, 必须显式声明,
# 否则 set -u 下读取即 nounset)
_XRAY_OBS_MODE=''
_WARP_OB_TAG=''
_XRAY_DNS_MODE=''

# ---- 其余桩件 ----
WARN_LOG="$SB/warn.log"
_i18n() { printf '%s' "${1//\"/}"; }
print_warn() { printf '%s\n' "$*" >>"$WARN_LOG"; }
print_info() { :; }
XRAY_WRITTEN="$SB/cfg/xray-written.json"
SCRIPT_WRITTEN="$SB/cfg/script-written.json"
XRAY_CONFIG_PATH="$SB/cfg/live.json"
persist_xray_config() {
    printf '%s\n' "${XRAY_CONFIG}" > "$XRAY_WRITTEN"
    return "${STUB_PERSIST_XRAY_RC:-0}"
}
persist_script_config() {
    printf '%s\n' "${SCRIPT_CONFIG}" > "$SCRIPT_WRITTEN"
    return 0
}
STUB_CREDS='{"private_key":"PRIV","address":["172.16.0.2/32"],"peer_public_key":"PUB","endpoint":"162.159.192.1:2408","reserved":[1,2,3]}'
_warp_ensure_credentials() { printf '%s' "${STUB_CREDS}"; }

reset_modes() { # 清掉进程内缓存, 模拟"新一次运行"
    _XRAY_OBS_MODE=''
    _WARP_OB_TAG=''
    _XRAY_DNS_MODE=''
    : > "$XRAY_CALL_LOG"
    : > "$WARN_LOG"
}

echo "== A  _xray_config_probe: 实测接受/拒绝 =="
STUB_MODE=accept
assert_eq "A1a 接受 -> rc=0" "$(_xray_config_probe '{"observatory":{}}' && echo ok)" "ok"
assert_eq "A1b 空片段 -> rc=1" "$(_xray_config_probe '' >/dev/null 2>&1 && echo ok || echo bad)" "bad"
STUB_MODE=no_dns
assert_eq "A2a 片段含 dns, 该机拒绝 -> rc=1" \
    "$(_xray_config_probe '{"dns":{"servers":["1.1.1.1"]}}' >/dev/null 2>&1 && echo ok || echo bad)" "bad"
assert_eq "A2b 同一机器换成不含 dns 的片段 -> rc=0" \
    "$(_xray_config_probe '{"observatory":{}}' >/dev/null 2>&1 && echo ok || echo bad)" "ok"
assert_eq "A3 探测不留临时文件" \
    "$(find "$TMPFILE_DIR" -maxdepth 1 -name '.*xrayprobe*' -print 2>/dev/null | wc -l | tr -d ' ')" "0"
STUB_MODE=accept
_xray_config_probe '{"kv":1}' >/dev/null 2>&1
assert_eq "A4 骨架含四个占位出站 (balancer 的 selector 与 fallbackTag 才解析得动)" \
    "$(jq -r '[.outbounds[].tag] | sort | join(",")' "$XRAY_PROBE_COPY")" "block,direct,warp,warp-out"
assert_eq "A4b 待测片段被合并进骨架" "$(jq -r '.kv' "$XRAY_PROBE_COPY")" "1"

echo "== B  _xray_observatory_mode: full / 降级 =="
reset_modes
STUB_MODE=accept
_xray_observatory_mode
assert_eq "B1 支持 -> full" "${_XRAY_OBS_MODE}" "full"
assert_eq "B1b 支持时不告警" "$(wc -l < "$WARN_LOG")" "0"
assert_eq "B1c 只为探测跑一次 xray" "$(wc -l < "$XRAY_CALL_LOG")" "1"
_xray_observatory_mode
_xray_observatory_mode
assert_eq "B1d 结果被缓存, 不再重复探测" "$(wc -l < "$XRAY_CALL_LOG")" "1"

reset_modes
STUB_MODE=no_observatory
_xray_observatory_mode
assert_eq "B2 不支持 -> plain (降级)" "${_XRAY_OBS_MODE}" "plain"
assert_eq "B2b 降级告警一次" "$(wc -l < "$WARN_LOG")" "1"
_xray_observatory_mode
assert_eq "B2c 告警不重复" "$(wc -l < "$WARN_LOG")" "1"

echo "== C  _warp_outbound_tag =="
reset_modes
STUB_MODE=accept
_warp_outbound_tag
assert_eq "C1 full 形态 -> warp-out" "${_WARP_OB_TAG}" "${WARP_OUTBOUND_TAG}"
assert_eq "C1b 且不等于 warp" "$([[ "${_WARP_OB_TAG}" != 'warp' ]] && echo yes)" "yes"
reset_modes
STUB_MODE=no_observatory
_warp_outbound_tag
assert_eq "C2 降级形态 -> warp" "${_WARP_OB_TAG}" "warp"

echo "== D  _xray_apply_warp (full 形态) =="
reset_modes
STUB_MODE=accept
export WARP_STATUS=1
XRAY_CONFIG='{"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"warp","protocol":"wireguard"}],"routing":{"rules":[]}}'
_xray_apply_warp
assert_eq "D1 新出站 tag 变为 warp-out" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.outbounds[] | select(.tag == "warp-out") | .protocol')" "wireguard"
assert_eq "D2 旧 warp 出站被清掉" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '[.outbounds[] | select(.tag == "warp")] | length')" "0"
assert_eq "D3 出站总数不变 (就地替换)" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.outbounds | length')" "2"
assert_eq "D4 mtu 写入" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.outbounds[] | select(.tag == "warp-out") | .settings.mtu')" "${WARP_MTU}"

echo "== E  _xray_apply_warp_balancer (启用, full) =="
XRAY_CONFIG='{"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"warp-out","protocol":"wireguard"},{"tag":"block","protocol":"blackhole"}],"routing":{"rules":[{"ruleTag":"warp-ip","ip":["1.2.3.4"],"outboundTag":"warp"}]}}'
_xray_apply_warp_balancer
assert_eq "E1 observatory 探测对象" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -c '.observatory.subjectSelector')" '["warp-out"]'
assert_eq "E2 探测地址" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.observatory.probeUrl')" "${WARP_PROBE_URL}"
assert_eq "E3 探测间隔" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.observatory.probeInterval')" "${WARP_PROBE_INTERVAL}"
assert_eq "E4 balancer tag" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.routing.balancers[0].tag')" "${WARP_BALANCER_TAG}"
assert_eq "E5 balancer 只选 WARP (不把 direct 拉进来选优)" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -c '.routing.balancers[0].selector')" '["warp-out"]'
assert_eq "E6 fallbackTag 指向 direct" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.routing.balancers[0].fallbackTag')" "direct"
assert_eq "E6b fallbackTag 目标出站确实存在" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '[.outbounds[] | select(.tag == "direct")] | length')" "1"
assert_eq "E7 策略 leastPing (需要 observatory 供数)" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.routing.balancers[0].strategy.type')" "leastPing"
assert_eq "E8 规则 tag **未**被改写 (仍是 warp, 靠 balancer 顶替同名 tag)" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.routing.rules[0].outboundTag')" "warp"
_xray_apply_warp_balancer
assert_eq "E9 重复应用幂等" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.routing.balancers | length')" "1"

echo "== F  _xray_apply_warp_balancer (降级形态不写 balancer) =="
reset_modes
STUB_MODE=no_observatory
XRAY_CONFIG='{"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"warp","protocol":"wireguard"}],"routing":{"rules":[]}}'
_xray_apply_warp_balancer
assert_eq "F1 降级时不写 observatory" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.observatory // "none"')" "none"
assert_eq "F2 降级时不写 balancer" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.routing.balancers // "none"')" "none"

echo "== G  未启用 WARP: 清理残留 =="
reset_modes
STUB_MODE=accept
export WARP_STATUS=0
XRAY_CONFIG='{"outbounds":[{"tag":"direct","protocol":"freedom"}],"observatory":{"subjectSelector":["warp-out"]},"routing":{"balancers":[{"tag":"warp-balancer","selector":["warp-out"]}],"rules":[]}}'
_xray_apply_warp_balancer
assert_eq "G1 observatory 已摘" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.observatory // "none"')" "none"
assert_eq "G2 balancers 键整体移除 (不留空数组)" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.routing.balancers // "none"')" "none"

echo "== H  handler_warp 关闭: 出站/规则/观测/均衡四样一起清 =="
reset_modes
STUB_MODE=accept
cat > "$XRAY_CONFIG_PATH" <<'JSON'
{
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "warp-out", "protocol": "wireguard"},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "observatory": {"subjectSelector": ["warp-out"]},
  "routing": {
    "balancers": [{"tag": "warp-balancer", "selector": ["warp-out"], "fallbackTag": "direct"}],
    "rules": [
      {"ruleTag": "warp-ip", "ip": ["1.2.3.4"], "outboundTag": "warp"},
      {"ruleTag": "private-ip", "outboundTag": "block"}
    ]
  }
}
JSON
SCRIPT_CONFIG='{"xray":{"warp":1},"rules":[{"ruleTag":"warp-ip","ip":["1.2.3.4"],"outboundTag":"warp"},{"ruleTag":"private-ip","outboundTag":"block"}]}'
handler_warp
assert_eq "H1 出站 (warp-out) 已摘" \
    "$(jq -r '[.outbounds[] | select(.tag == "warp-out")] | length' "$XRAY_WRITTEN")" "0"
assert_eq "H2 出站 (warp) 也没有" \
    "$(jq -r '[.outbounds[] | select(.tag == "warp")] | length' "$XRAY_WRITTEN")" "0"
assert_eq "H3 指向 warp 的规则已清" \
    "$(jq -r '[.routing.rules[] | select(.outboundTag == "warp")] | length' "$XRAY_WRITTEN")" "0"
assert_eq "H4 无关规则 (private-ip) 保留" \
    "$(jq -r '[.routing.rules[] | select(.ruleTag == "private-ip")] | length' "$XRAY_WRITTEN")" "1"
assert_eq "H5 observatory 已摘" \
    "$(jq -r '.observatory // "none"' "$XRAY_WRITTEN")" "none"
assert_eq "H6 balancers 已清" \
    "$(jq -r '.routing.balancers // "none"' "$XRAY_WRITTEN")" "none"
assert_eq "H7 .rules 权威副本里的 warp 规则也清了" \
    "$(jq -r '[.rules[] | select(.outboundTag == "warp")] | length' "$SCRIPT_WRITTEN")" "0"
assert_eq "H8 .rules 权威副本保留无关规则" \
    "$(jq -r '.rules | length' "$SCRIPT_WRITTEN")" "1"
assert_eq "H9 状态位翻 0" "$(jq -r '.xray.warp' "$SCRIPT_WRITTEN")" "0"

echo "== H2 handler_warp 开启: 同一次动作就把观测/均衡带上 =="
# 用户开完 WARP 通常直接重启 Xray, 不会再多走一次"更新配置"; 所以开关动作本身就要
# 落好观测段, 否则自动回落要等到下次改配置才生效。
reset_modes
STUB_MODE=accept
cat > "$XRAY_CONFIG_PATH" <<'JSON'
{"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"block","protocol":"blackhole"}],"routing":{"rules":[]}}
JSON
SCRIPT_CONFIG='{"xray":{"warp":0},"rules":[]}'
handler_warp
assert_eq "H2a 出站改为 warp-out (开探测形态)" \
    "$(jq -r '.outbounds[] | select(.tag == "warp-out") | .protocol' "$XRAY_WRITTEN")" "wireguard"
assert_eq "H2b observatory 同一次动作写入" \
    "$(jq -r '.observatory.subjectSelector[0]' "$XRAY_WRITTEN")" "warp-out"
assert_eq "H2c balancer 同一次动作写入" \
    "$(jq -r '.routing.balancers[0].tag' "$XRAY_WRITTEN")" "warp-balancer"
assert_eq "H2d 状态位翻 1" "$(jq -r '.xray.warp' "$SCRIPT_WRITTEN")" "1"

echo "== I  _xray_dns_mode / _xray_apply_dns =="
reset_modes
STUB_MODE=accept
_xray_dns_mode
assert_eq "I1 全字段被接受 -> full" "${_XRAY_DNS_MODE}" "full"
assert_eq "I1b 探测次数 1" "$(wc -l < "$XRAY_CALL_LOG")" "1"
reset_modes
STUB_MODE=dns_full_reject
_xray_dns_mode
assert_eq "I2 拒绝新字段 -> 降级 minimal" "${_XRAY_DNS_MODE}" "minimal"
assert_eq "I2b 探测次数 2 (先试全字段再试最简)" "$(wc -l < "$XRAY_CALL_LOG")" "2"
reset_modes
STUB_MODE=no_dns
_xray_dns_mode
assert_eq "I3 完全不吃 dns 段 -> off" "${_XRAY_DNS_MODE}" "off"
assert_eq "I3b 告警一次" "$(wc -l < "$WARN_LOG")" "1"

reset_modes
STUB_MODE=accept
XRAY_CONFIG='{"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}'
_xray_apply_dns
assert_eq "I4 servers 写入" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.dns.servers | length')" "3"
assert_eq "I4b queryStrategy 写入" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.dns.queryStrategy')" "${XRAY_DNS_QUERY_STRATEGY}"
assert_eq "I4c 并行查询写入" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.dns.enableParallelQuery')" "true"
reset_modes
STUB_MODE=dns_full_reject
XRAY_CONFIG='{"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}'
_xray_apply_dns
assert_eq "I5 minimal 档: servers 仍在" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.dns.servers | length')" "3"
assert_eq "I5b minimal 档: 不写 queryStrategy" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.dns.queryStrategy // "none"')" "none"
reset_modes
STUB_MODE=no_dns
XRAY_CONFIG='{"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}'
_xray_apply_dns
assert_eq "I6 off 档: 不写 dns 段" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.dns // "none"')" "none"

echo "== J  _xray_apply_domain_strategy =="
XRAY_CONFIG='{"outbounds":[],"routing":{"rules":[{"ruleTag":"cn-ip","ip":["geoip:cn"],"outboundTag":"block"}]}}'
_xray_apply_domain_strategy
assert_eq "J1 有 IP 规则 -> IPIfNonMatch" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.routing.domainStrategy')" "IPIfNonMatch"
XRAY_CONFIG='{"outbounds":[],"routing":{"rules":[{"ruleTag":"ad-domain","domain":["geosite:category-ads-all"],"outboundTag":"block"}]}}'
_xray_apply_domain_strategy
assert_eq "J2 只有域名规则 -> 不设 domainStrategy" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.routing.domainStrategy // "none"')" "none"
XRAY_CONFIG='{"outbounds":[],"routing":{"domainStrategy":"IPIfNonMatch","rules":[{"ruleTag":"ad-domain","domain":["a.com"],"outboundTag":"block"}]}}'
_xray_apply_domain_strategy
assert_eq "J3 残留的 domainStrategy 被清掉 (开关关了要能退回去)" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.routing.domainStrategy // "none"')" "none"
XRAY_CONFIG='{"outbounds":[],"routing":{"rules":[]}}'
_xray_apply_domain_strategy
assert_eq "J4 空规则集不报错" \
    "$(printf '%s' "$XRAY_CONFIG" | jq -r '.routing.domainStrategy // "none"')" "none"

echo
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
